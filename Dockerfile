FROM alpine:3.21.3

# Install bash, docker (for docker CLI), curl, and cronie (cron daemon)
RUN apk add --no-cache bash docker-cli curl cronie

# Create working directory
WORKDIR /app

# Copy the wg-easy-sentinel.sh script into the container and make it executable
COPY wg-easy-sentinel.sh /app/wg-easy-sentinel.sh
RUN chmod +x /app/wg-easy-sentinel.sh

# The following cron will run the script every minute and log output to stdout
RUN echo "* * * * * /app/wg-easy-sentinel.sh >> /proc/1/fd/1 2>&1" >> /etc/crontabs/root

# Expose environment variables if needed (or set defaults here)
# ENV WG_CONTAINER_NAME=wg-easy
# ENV TIMEOUT_THRESHOLD=120
# ENV STATE_FILE=/path/to/state
# ENV PUSHOVER_APP_TOKEN=your_app_token
# ENV PUSHOVER_USER_KEY=your_user_key

CMD echo "$(date '+%Y-%m-%d %H:%M:%S %Z') - ⏳ Container started. Waiting for scheduled tasks... ⏳" && crond -f -n
