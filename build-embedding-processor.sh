#!/bin/bash
# Build, tag, and push the embedding-processor Docker image to Docker Hub
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EMBEDDING_PROCESSOR_DIR="$SCRIPT_DIR/embedding-processor"
cd "$EMBEDDING_PROCESSOR_DIR"

./mvnw spring-boot:build-image -Dspring-boot.build-image.imageName=dbbaskette/embedding-processor:0.0.1-SNAPSHOT

echo "Docker image 'dbbaskette/embedding-processor:0.0.1-SNAPSHOT' built successfully."

echo "Pushing image to Docker Hub..."
docker push dbbaskette/embedding-processor:0.0.1-SNAPSHOT

echo "Docker image pushed to Docker Hub as dbbaskette/embedding-processor:0.0.1-SNAPSHOT."
