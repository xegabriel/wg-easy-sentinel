# wg-easy-sentinel

## 📖 Overview
WireGuard Easy Sentinel watches your `wg-easy` container for VPN client connection/disconnection events and sends push notifications via Pushover. It detects connection state changes by monitoring WireGuard handshake timestamps and maintaining state between runs.

## ✨ Features

* 🔔 Push notifications when clients connect or disconnect
* 👤 User-friendly client identification using names from WireGuard configuration
* 🔄 Persistent state tracking between container restarts
* 🔒 Prevents duplicate execution with file locking
* 🐳 Runs in a Docker container alongside your WireGuard Easy instance
* ⚙️ Configurable timeout thresholds

## 🚀 Getting started

```shell
# Define the env vars
touch .env
PUSHOVER_APP_TOKEN=your_app_token_here
PUSHOVER_USER_KEY=your_user_key_here
# Start the service
docker-compose up -d
# Check the logs
docker logs wg-easy-sentinel

# Stop the service
docker-compose down
```

## ⚙️ Configuration

The following environment variables can be adjusted in the `docker-compose.yml` file:

| Variable | Description | Default |
|----------|-------------|---------|
| `WG_CONTAINER_NAME` | Name of your WireGuard Easy container | `wg-easy` |
| `VPN_NAME` | VPN Identifier included in the notification title | `wg-vpn` |
| `TIMEOUT_THRESHOLD` | Maximum seconds since last handshake for a peer to be considered connected or disconnected | `120` |
| `PUSHOVER_APP_TOKEN` | Your Pushover application token | Required for notifications |
| `PUSHOVER_USER_KEY` | Your Pushover user key | Required for notifications |

## 🔍 How It Works

1. **Connection Detection**:
   - The script runs every minute via [cron](https://github.com/xegabriel/wg-easy-sentinel/blob/main/Dockerfile#L14)
   - It queries the `wg-easy` container for the latest handshake timestamps
   - Peers with handshakes newer than `TIMEOUT_THRESHOLD` are considered connected

2. **State Tracking**:
   - Connection states are saved to a persistent file
   - The script compares previous and current states to detect changes
   - This prevents duplicate notifications when the container restarts

3. **Notifications**:
   - When a connection change is detected, a notification is sent via Pushover
   - Notifications include the client's friendly name from the WireGuard config

## 🛠️ Troubleshooting

### No notifications are being sent

- Verify your Pushover credentials in the `.env` file
- Check the logs for any error messages related to notifications
- Ensure the container has internet access to reach the Pushover API

### Script cannot access the WireGuard container

- Verify that the `WG_CONTAINER_NAME` matches your WireGuard container name
- Ensure the Docker socket is properly mounted as a volume
- Check that the WireGuard container is running

### State file issues

- Make sure the `/srv/Appdata/wg-easy-sentinel` directory exists and has proper permissions
- Check the logs for any errors related to reading or writing the state file

## 📜 Disclaimer
This tool is provided as-is without any warranty under the [MIT License](https://github.com/xegabriel/wg-easy-sentinel/blob/main/LICENSE).

You are free to modify, distribute, and use this software for any purpose. The script interacts with Docker socket and container internals, which could potentially change with future updates to Docker or WireGuard Easy.

Use at your own risk. The authors are not responsible for any issues that might arise from using this software.

## ⭐ Support

If you find this project useful, please consider giving it a ⭐ on GitHub! For issues or questions, open an issue on the repository with relevant logs and configuration details.

Contributions are welcome through pull requests.