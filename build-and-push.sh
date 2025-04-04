#!/bin/bash

# Exit immediately if a command fails
set -e

# Function to get the next semantic version
get_next_version() {
    latest_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "0")

    # If the latest tag is just "0", start from 1.0.0
    if [[ "$latest_tag" == "0" ]]; then
        echo "1.0.0"
        return
    fi

    major=$(echo $latest_tag | cut -d. -f1)
    minor=$(echo $latest_tag | cut -d. -f2)
    patch=$(echo $latest_tag | cut -d. -f3)

    # If the tag does not follow semantic versioning, start from 1.0.0
    if [[ -z "$minor" || -z "$patch" ]]; then
        echo "1.0.0"
        return
    fi

    # Increment the patch version
    new_version="$major.$minor.$((patch + 1))"
    echo "$new_version"
}

# Generate a new version tag
NEW_TAG=$(get_next_version)
IMAGE_NAME="wg-easy-sentinel"

# Confirm before proceeding
echo "🚀 New version to be tagged: $IMAGE_NAME:$NEW_TAG"
read -p "Do you want to proceed? (y/N): " CONFIRM
if [[ "$CONFIRM" != "y" ]]; then
    echo "❌ Aborting."
    exit 1
fi

# Tag the new version
echo "🏷️ Creating new Git tag: $NEW_TAG"
git tag -a "$NEW_TAG" -m "Release $NEW_TAG"
git push origin "$NEW_TAG"

# Docker registry and image name
DOCKER_USER=${DOCKER_USER}

# Build the Docker image
echo "🐳 Building Docker image: $DOCKER_USER/$IMAGE_NAME:$NEW_TAG"
docker build -t $DOCKER_USER/$IMAGE_NAME:$NEW_TAG .

# Tag the image as latest
docker tag $DOCKER_USER/$IMAGE_NAME:$NEW_TAG $DOCKER_USER/$IMAGE_NAME:latest

# Log in to Docker (if required)
echo "🔑 Logging in to Docker..."
docker login

# Push the images
echo "📤 Pushing Docker images..."
docker push $DOCKER_USER/$IMAGE_NAME:$NEW_TAG
docker push $DOCKER_USER/$IMAGE_NAME:latest

echo "✅ Docker images pushed successfully!"
echo "📌 Image tags available:"
echo "   - $DOCKER_USER/$IMAGE_NAME:$NEW_TAG"
echo "   - $DOCKER_USER/$IMAGE_NAME:latest"