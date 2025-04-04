FROM alpine:3.21.3

# Install bash, docker-cli, curl, and cronie
# Using docker-cli instead of full docker package
RUN apk add --no-cache bash docker-cli curl cronie tzdata

# Create working directory
WORKDIR /app

COPY wg-easy-sentinel.sh /app/wg-easy-sentinel.sh
COPY entrypoint.sh /app/entrypoint.sh

# Make scripts executable
RUN chmod +x /app/wg-easy-sentinel.sh /app/entrypoint.sh

# Create the cron job definition
# Add MAILTO="" at the beginning to disable cron's email attempts.
RUN echo "MAILTO=\"\"" > /etc/crontabs/root && \
    echo "* * * * * . /app/environment.sh; /app/wg-easy-sentinel.sh >> /proc/1/fd/1 2>&1" >> /etc/crontabs/root

# Optional: Define default ENV vars here.
# These will be captured by entrypoint.sh if not overridden by 'docker run -e'.
# ENV WG_CONTAINER_NAME=wg-easy
# ENV VPN_NAME=wg-vpn
# ENV TIMEOUT_THRESHOLD=120
# ENV PUSHOVER_APP_TOKEN="" # Leave sensitive vars empty
# ENV PUSHOVER_USER_KEY=""

# Create state directory if using one (adjust path if needed)
# RUN mkdir -p /app/state

# Use the entrypoint script to set up the environment and run CMD
ENTRYPOINT ["/app/entrypoint.sh"]

# Start the cron daemon in the foreground
# This command is passed as arguments ($@) to the entrypoint script
CMD ["crond", "-f", "-n"]
# -f: Foreground
# -L /dev/stdout : Log cron actions (like job start) to stdout