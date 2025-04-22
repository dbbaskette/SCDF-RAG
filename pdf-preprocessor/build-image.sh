#!/bin/bash
# Build the pdf-preprocessor Docker image using Spring Boot's build-image goal
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

./mvnw spring-boot:build-image -Dspring-boot.build-image.imageName=pdf-preprocessor:0.0.1-SNAPSHOT

echo "Docker image 'pdf-preprocessor:0.0.1-SNAPSHOT' built successfully."
