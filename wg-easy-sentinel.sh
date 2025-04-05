#!/bin/bash

# Make script exit immediately if a command exits with a non-zero status,
# if it uses an unset variable, or if any command in a pipeline fails.
set -euo pipefail

# --- General Configuration ---
CONTAINER_NAME="${WG_CONTAINER_NAME:-wg-easy}" # Default to wg-easy if not set
VPN_NAME="${VPN_NAME:-wg-vpn}" # Default to wg0 if not set
# TIMEOUT_THRESHOLD: Seconds of inactivity before considering a peer disconnected.
# This now determines disconnection based on the *last recorded handshake* across script runs.
TIMEOUT_THRESHOLD="${TIMEOUT_THRESHOLD:-120}" # Default to 2 minutes if not set
# STATE_FILE: Path to store connection status between runs. Use an absolute path.
# Ensure the directory exists and the user running cron has write permissions.
STATE_FILE="/app/data/.wg_easy_sentinel_state" # Example: in user's home directory
# LOCK_FILE: Path for lock file to prevent concurrent runs. Use an absolute path.
LOCK_FILE="/tmp/wg_monitor.lock"

# --- Pushover Configuration ---
# Read from environment variables. Ensure these are set in the cron environment.
PUSHOVER_APP_TOKEN="${PUSHOVER_APP_TOKEN:-}"
PUSHOVER_USER_KEY="${PUSHOVER_USER_KEY:-}"
PUSHOVER_API_URL="https://api.pushover.net/1/messages.json"

# --- Helper Functions ---

# Log messages with timestamps and timezone
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S %Z') - $*"
}

# Send Pushover notification with retries
send_notification() {
  local title="$1"
  local message="$2"
  local max_retries=3
  local retry_delay=5
  local attempt=1

  # Avoid sending if keys are empty (allows running without Pushover for testing)
  if [[ -z "$PUSHOVER_APP_TOKEN" || -z "$PUSHOVER_USER_KEY" ]]; then
      log "      ⚠️ Warning: Pushover credentials not set. 🔕 Skipping notification: '${title}'"
      return 0 # Indicate non-fatal issue
  fi

  while [[ $attempt -le $max_retries ]]; do
    log "      📤 Attempt $attempt/$max_retries: Sending notification '${title}'..."
    local response status body
    response=$(curl -s -w "HTTPSTATUS:%{http_code}" \
      --form-string "token=${PUSHOVER_APP_TOKEN}" \
      --form-string "user=${PUSHOVER_USER_KEY}" \
      --form-string "title=${title}" \
      --form-string "message=${message}" \
      "${PUSHOVER_API_URL}")
    status=$(echo "$response" | sed -e 's/.*HTTPSTATUS://')
    body=$(echo "$response" | sed -e 's/HTTPSTATUS\:.*//g')

    if [[ "$status" -eq 200 ]]; then
      log "      ✅ Notification '${title}' sent successfully on attempt $attempt."
      return 0
    fi

    log "      ❌ Attempt $attempt/$max_retries failed for notification '${title}': HTTP status $status. Response: $body"
    if [[ $attempt -lt $max_retries ]]; then
      log "⏳ Waiting ${retry_delay}s before next attempt... ⏳"
      sleep "$retry_delay"
    fi
    ((attempt++))
  done
  log "      ❌ Error: Failed to send notification '${title}' after $max_retries attempts."
  return 1
}

# Fetch WireGuard configuration from the container
fetch_wg_config() {
  docker exec "$CONTAINER_NAME" cat /etc/wireguard/wg0.conf 2>/dev/null || {
    log "❌ Error retrieving /etc/wireguard/wg0.conf from container $CONTAINER_NAME."
    return 1 # Use return code instead of exit for functions
  }
}

# Build mapping of PublicKey to friendly name
build_friendly_names() {
  local config_content current_friendly line pubkey
  # Clear previous names in case config changed
  friendly_names=()
  declare -gA friendly_names # Ensure it's globally accessible within the script

  config_content=$(fetch_wg_config) || return 1 # Propagate fetch error

  current_friendly=""
  while IFS= read -r line; do
    if [[ "$line" =~ ^#\ Client:\ (.*)\ \(.+\)$ ]]; then
      current_friendly="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^PublicKey[[:space:]]*=[[:space:]]*(.+)$ ]]; then
      pubkey="${BASH_REMATCH[1]}"
      if [[ -n "$current_friendly" && -n "$pubkey" ]]; then
        friendly_names["$pubkey"]="$current_friendly"
        log "ℹ️ Mapped PublicKey $pubkey to friendly name '$current_friendly'" # Debug log
      else
         log "⚠️ Warning: Found PublicKey '$pubkey' without preceding friendly name comment."
      fi
      current_friendly="" # Reset for the next peer block
    fi
  done <<< "$config_content"

  # Log if no names were found
  if [[ ${#friendly_names[@]} -eq 0 ]]; then
      log "⚠️ Warning: No friendly names found in the WireGuard config."
  fi
}

# Get a peer's display name
get_peer_display() {
  local peer_key="$1"
  local name
  # Check if the key exists and the value is not empty
  name="${friendly_names[$peer_key]:-}" # Use bash parameter expansion for safety
  if [[ -n "$name" ]]; then
    echo "'${name}' (${peer_key})"
  else
    echo "$peer_key"
  fi
}

# Fetch handshake info from the container
fetch_handshake_info() {
  local output exit_code
  # Capture stderr to check for specific errors if needed
  output=$(docker exec "$CONTAINER_NAME" wg show all latest-handshakes 2>&1)
  exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    log "❌ Error retrieving handshake info from container $CONTAINER_NAME. Exit code: $exit_code. Output: $output"
    return 1
  fi

  # Filter out empty lines or potential headers/interface lines if any exist
  echo "$output" | grep -E '^[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[0-9]+$' || {
      log "⚠️ No valid handshake lines found in 'wg show' output."
      # Return success but empty output, which is valid (no peers or no handshakes)
      return 0
  }
}

# Format seconds into a human-readable duration string (e.g., 1d 2h 3m 4s)
format_duration() {
    local total_seconds=$1
    local days hours minutes seconds result=""

    # Ensure input is non-negative integer
    if ! [[ "$total_seconds" =~ ^[0-9]+$ ]]; then
        echo "Invalid input"
        return 1
    fi

    # Prevent issues if somehow negative, treat as 0
    if [[ $total_seconds -lt 0 ]]; then total_seconds=0; fi

    days=$((total_seconds / 86400))
    total_seconds=$((total_seconds % 86400))
    hours=$((total_seconds / 3600))
    total_seconds=$((total_seconds % 3600))
    minutes=$((total_seconds / 60))
    seconds=$((total_seconds % 60))

    # Build the string, adding units only if they are greater than zero
    if [[ $days -gt 0 ]]; then result+="${days}d "; fi
    if [[ $hours -gt 0 ]]; then result+="${hours}h "; fi
    if [[ $minutes -gt 0 ]]; then result+="${minutes}m "; fi

    # Always include seconds if the total duration was less than a minute,
    # OR if the seconds part is non-zero,
    # OR if the entire result string is still empty (handles the 0s case).
    if [[ $1 -lt 60 || $seconds -gt 0 || -z "$result" ]]; then
         result+="${seconds}s"
    fi

    # Trim potential trailing space if the last unit added was not seconds
    # and seconds was 0 (e.g., exactly 2 minutes results in "2m ")
    result=$(echo "$result" | xargs)

    echo "$result"
}

# --- State Management Functions ---

# Load state from file into associative arrays
load_state() {
  # Clear existing state first
  last_handshakes=()
  connected_peers=()
  declare -gA last_handshakes connected_peers # Make them global

  if [[ ! -f "$STATE_FILE" ]]; then
    log "ℹ️ State file '$STATE_FILE' not found. Starting fresh. "
    return 0
  fi

  log "ℹ️ Loading state from $STATE_FILE"
  local line type key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip empty lines
    [[ -z "$line" ]] && continue
    
    # Split the line by ':'
    IFS=':' read -r type key value <<< "$line"
    
    # Trim whitespace which might sneak in
    type=$(echo "$type" | xargs)
    key=$(echo "$key" | xargs)
    value=$(echo "$value" | xargs)

    if [[ "$type" == "handshake" && -n "$key" && "$value" =~ ^[0-9]+$ ]]; then
      last_handshakes["$key"]="$value"
    elif [[ "$type" == "connected" && -n "$key" && "$value" == "1" ]]; then
      connected_peers["$key"]="1"
    else
      log "⚠️ Warning: Skipping malformed line in state file: $line"
    fi
  done < "$STATE_FILE"
  log "ℹ️ Loaded state: ${#connected_peers[@]} previously connected peers, ${#last_handshakes[@]} known handshakes."
}

# Save state from associative arrays to file (atomically)
save_state() {
  local temp_state_file="${STATE_FILE}.tmp"
  log "ℹ️ Saving state to $STATE_FILE"
  # Truncate or create temp file
  >$temp_state_file

  local peer timestamp
  # Write currently connected peers (those active in this run)
  for peer in "${!current_connected_peers[@]}"; do
    echo "connected:$peer:1" >> "$temp_state_file"
  done

  # Write last handshake times for all recently seen peers
  for peer in "${!current_handshakes[@]}"; do
    timestamp="${current_handshakes[$peer]}"
    echo "handshake:$peer:$timestamp" >> "$temp_state_file"
  done

  # Atomically replace the old state file with the new one
  if mv "$temp_state_file" "$STATE_FILE"; then
    log "✅ State saved successfully."
  else
    log "❌ Error: Failed to move temporary state file $temp_state_file to $STATE_FILE."
    # Attempt to clean up temp file
    rm -f "$temp_state_file"
    return 1
  fi
}

# --- Main Script Logic ---

# Acquire Lock (using flock - create lock file first if needed)
# The lock file descriptor (200) is arbitrary but must be consistent.
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  log "❌ Error: Script is already running or lock file '$LOCK_FILE' is stale. Exiting."
  exit 1
fi
# Lock acquired, will be released automatically when the script exits (due to exec 200>...)

log "🚀 Performing check ..."

# Check prerequisites
if ! command -v docker &> /dev/null; then
    log "❌ Error: 'docker' command not found. Please install Docker."
    exit 1 # Exit, lock will be released
fi
if ! docker info > /dev/null 2>&1; then
    log "❌ Error: Cannot connect to the Docker daemon. Is it running and accessible?"
    exit 1 # Exit, lock will be released
fi
# Check Pushover variables *after* potential exit points
if [[ -z "$PUSHOVER_APP_TOKEN" || -z "$PUSHOVER_USER_KEY" ]]; then
  log "⚠️ Warning: PUSHOVER_APP_TOKEN or PUSHOVER_USER_KEY is not set. Notifications will be skipped."
  # Continue execution without notifications
fi

if ! docker container inspect "$CONTAINER_NAME" --format '{{.State.Status}}' 2>/dev/null | grep -q "running"; then
    log "❌ Error: Container $CONTAINER_NAME is not running"
    exit 1
fi

# Check if the vpn name length exceeds the maximum
# Get the length of the VPN_NAME variable
VPN_NAME_LENGTH="${#VPN_NAME}"
MAX_LENGTH=220 # Pushover supports up to 250 characters, but we leave some space for the message

if [ "$VPN_NAME_LENGTH" -gt "$MAX_LENGTH" ]; then
  # Trim the VPN_NAME variable to the maximum length
  VPN_NAME="${VPN_NAME:0:$MAX_LENGTH}"

  # Log a warning message with the warning emoji
  echo "⚠️ Warning: VPN_NAME was longer than $MAX_LENGTH characters and has been trimmed."
  echo "ℹ️ Trimmed VPN_NAME: $VPN_NAME"
fi

# Declare state arrays globally (though load/save manage this too)
declare -gA friendly_names
declare -gA last_handshakes
declare -gA connected_peers
declare -gA current_handshakes # Store timestamps from the current check
declare -gA current_connected_peers # Store peers considered connected *in this run*

# Load previous state
load_state

# Build friendly name mapping (do this each run in case config changed)
log "ℹ️ Building friendly names map..."
if ! build_friendly_names; then
    log "❌ Error building friendly names. Exiting."
    exit 1 # Exit, lock will be released
fi

# Fetch current handshake info
log "ℹ️ Fetching current handshake info..."
handshake_output=$(fetch_handshake_info)
fetch_status=$?

# --- Count peers found
peer_count=0
# Only count if the function succeeded (status 0) and output is not empty
if [[ $fetch_status -eq 0 && -n "$handshake_output" ]]; then
    # Count non-empty lines in the output variable
    peer_count=$(grep -c . <<< "$handshake_output")
fi
# Always log the number of peers found after filtering
log "ℹ️ Found $peer_count peers in filtered handshake info."
# Handle case where fetch_handshake_info succeeded but returned no data
if [[ $fetch_status -ne 0 ]]; then
    log "❌ Error fetching handshake info. Exiting."
    exit 1 # Exit, lock will be released
elif [[ -z "$handshake_output" ]]; then
    log "ℹ️ No active peers found in current handshake info."
    # Proceed to check for disconnections based on old state
fi

# Process current handshake output
current_time=$(date +%s)
while IFS= read -r line; do
  # Skip empty lines just in case
  [[ -z "$line" ]] && continue

  # Expected format from fetch_handshake_info: "interface publicKey timestamp"
  # We filtered ensures this format, so we can be less defensive here
  read -r _ peer handshake_timestamp <<< "$line" # Use _ for unused 'interface'
  
  log "➡️ Processing Peer: $peer, Handshake: $handshake_timestamp"
  # Record the latest handshake time for *all* peers seen in this run
  current_handshakes["$peer"]=$handshake_timestamp

  # Check if this handshake is recent enough to consider the peer "connected" now
  time_since_handshake=$((current_time - handshake_timestamp))
  friendly_duration_since_handshake=$(format_duration "$time_since_handshake")
  log "   ℹ️ Time since handshake: ${friendly_duration_since_handshake} ago (${time_since_handshake}s total)"
  
  if [[ $time_since_handshake -lt $TIMEOUT_THRESHOLD ]]; then
    log "   ℹ️ Handshake is recent. Marking as currently connected."
    current_connected_peers["$peer"]=1 # Mark as connected in *this* run
    # Check if it was NOT connected in the *previous* run (new connection)
    if [[ -z "${connected_peers[$peer]:-}" ]]; then
      log "   ✅ Peer $peer was NOT connected previously. Sending notification."
      peer_display=$(get_peer_display "$peer")
      log "      ℹ️ Sending notification for $peer_display (Handshake - ${friendly_duration_since_handshake} (${time_since_handshake}s) ago)."
      send_notification "🟢 [$VPN_NAME] Peer Connected" "👤 Peer $peer_display is now online. (Connected: ${friendly_duration_since_handshake} ago)." || log "⚠️ Warning: Failed to send connection notification for $peer_display"
      # No need to update connected_peers here, save_state handles the final state
    else
        log "   ℹ️ Peer $peer WAS already connected previously. No notification needed."
    fi
  fi
done <<< "$handshake_output" # Feed the output, even if empty

# Check for disconnections based on comparing previous state to current connections
log "ℹ️ Checking for disconnections..."
if [[ ${#connected_peers[@]} -eq 0 ]]; then
    # If the array of previously connected peers is empty, log a message.
    log "ℹ️ No previously connected peers to check for disconnections."
else
  for peer in "${!connected_peers[@]}"; do # Iterate peers connected *last time*
    log "➡️ Processing Peer: $peer"
    last_seen=${last_handshakes[$peer]:-0} # Get last handshake time from loaded state
    time_since_last_seen=$(( current_time - last_seen ))
    friendly_last_seen=$(format_duration "$time_since_last_seen")
    log "   ℹ️ Last seen: ${friendly_last_seen} ago (${time_since_last_seen}s total)"
    # Check if a previously connected peer is NOT connected *this time*
    if [[ -z "${current_connected_peers[$peer]:-}" ]]; then
      # Peer was connected, but isn't now. Check how long ago its *last known* handshake was.
      peer_display=$(get_peer_display "$peer")

      # We don't strictly need the TIMEOUT_THRESHOLD check here again if we trust
      # current_connected_peers, but it adds clarity/safety. A peer missing from
      # current_connected_peers *implies* its handshake is older than the threshold.
      # The more robust check is simply: If it was connected before, and not now, it's disconnected.
      log "   ✅ Peer $peer_display has disconnected (Last handshake seen ${time_since_last_seen}s ago)."
      send_notification "🔴 [$VPN_NAME] Peer Disconnected" "👤 Peer $peer_display appears to be offline (Last seen: ${friendly_last_seen} ago)." || log "⚠️ Warning: Failed to send disconnection notification for $peer_display"
      # The state update happens during save_state; no need to unset here
    else
          log "   ℹ️ Peer $peer is still connected. No notification needed."
    fi
  done
fi


# Save the current state for the next run
if ! save_state; then
    log "❌ Error saving state. State might be inconsistent for the next run."
    # Decide if this is a fatal error or not
    # exit 1 # Optional: Exit with error if saving state failed
fi

log "✅ Script finished."
# Lock is released automatically upon exit
exit 0