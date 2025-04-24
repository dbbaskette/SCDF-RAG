#!/bin/bash
# Build, tag, and push the pdf-preprocessor Docker image to Docker Hub
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PDF_PREPROCESSOR_DIR="$SCRIPT_DIR/pdf-preprocessor"
cd "$PDF_PREPROCESSOR_DIR"

./mvnw spring-boot:build-image -Dspring-boot.build-image.imageName=dbbaskette/pdf-preprocessor:0.0.1-SNAPSHOT

echo "Docker image 'dbbaskette/pdf-preprocessor:0.0.1-SNAPSHOT' built successfully."

echo "Pushing image to Docker Hub..."
docker push dbbaskette/pdf-preprocessor:0.0.1-SNAPSHOT

echo "Docker image pushed to Docker Hub as dbbaskette/pdf-preprocessor:0.0.1-SNAPSHOT."
