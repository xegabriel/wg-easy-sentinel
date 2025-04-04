#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

echo "$(date '+%Y-%m-%d %H:%M:%S %Z') - 🚀 Entrypoint: Capturing environment variables for cron..."

# Define the path for the environment file
ENV_FILE="/app/environment.sh"

# Clear the file initially
> "$ENV_FILE"
# Append 'export' statements for all environment variables that might be needed by the script.
# This captures variables set by 'docker run -e'.
echo "Exporting runtime environment variables:" >> "$ENV_FILE"
# --- Save the REAL values to the file ---
printenv | sed 's/^\(.*\)=\(.*\)$/export \1="\2"/' >> "$ENV_FILE"

chmod 644 "$ENV_FILE"

echo "$(date '+%Y-%m-%d %H:%M:%S %Z') - 🚀 Entrypoint: Environment variables saved to $ENV_FILE."
echo "--- 🔒 Content of $ENV_FILE (Sensitive values redacted for logging) 🔒 ---"
# --- Log the content, but REDACT sensitive keys ---
cat "$ENV_FILE" | sed -E 's/^(export (PUSHOVER_APP_TOKEN|PUSHOVER_USER_KEY))=".*"$/\1="[REDACTED]"/'
echo "--------------------------------------------------------------------"

# Now, execute the command passed into the entrypoint (which will be 'crond -f -n' from the Dockerfile CMD)
echo "$(date '+%Y-%m-%d %H:%M:%S %Z') - 🚀 Entrypoint: Starting cron daemon ($@)..."
exec "$@"