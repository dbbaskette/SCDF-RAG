#!/bin/bash
# test_hdfs_app.sh - Test HDFS app with Cloud Foundry authentication
# Usage: test_hdfs_app

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKEN_FILE="$SCRIPT_DIR/../.cf_token"

# Load environment and properties
. "$SCRIPT_DIR/env_setup.sh"
source_properties

# Check if token is still valid
check_token_validity() {
  if [ ! -f "$TOKEN_FILE" ]; then
    return 1
  fi
  
  local token=$(cat "$TOKEN_FILE")
  if [ -z "$token" ]; then
    return 1
  fi
  
  # Try to access a protected endpoint to validate token
  if curl -s -H "Authorization: Bearer $token" "$SCDF_API_URL/management/info" | grep -q '"version"'; then
    return 0
  fi
  
  return 1
}

# Get OAuth token from Cloud Foundry
get_oauth_token() {
  echo "=== Cloud Foundry Authentication ==="
  
  # Check if we already have a valid token
  if check_token_validity; then
    echo "Using existing valid token from $TOKEN_FILE"
    return 0
  fi
  
  echo "No valid token found. Please provide Cloud Foundry credentials:"
  
  # Read credentials if not provided as environment variables
  if [ -z "$CF_CLIENT_ID" ]; then
    read -p "Client ID: " CF_CLIENT_ID
  fi
  
  if [ -z "$CF_CLIENT_SECRET" ]; then
    read -s -p "Client Secret: " CF_CLIENT_SECRET
    echo
  fi
  
  if [ -z "$CF_TOKEN_URL" ]; then
    CF_TOKEN_URL="${CF_TOKEN_URL:-$SCDF_API_URL/oauth/token}"
  fi
  
  echo "Authenticating with token URL: $CF_TOKEN_URL"
  
  # Get the access token
  local response=$(curl -s -X POST "$CF_TOKEN_URL" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -u "$CF_CLIENT_ID:$CF_CLIENT_SECRET" \
    -d "grant_type=client_credentials")
  
  # Extract token from response
  local token=$(echo "$response" | grep -o '"access_token":"[^"]*' | cut -d'"' -f4)
  
  if [ -z "$token" ]; then
    echo "Failed to get access token. Response: $response"
    return 1
  fi
  
  # Save token to file
  echo "$token" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  echo "Authentication successful. Token saved to $TOKEN_FILE"
}

# Main function
test_hdfs_app() {
  # Skip authentication in test mode
  if [[ "${TEST_MODE:-0}" -eq 1 ]]; then
    echo "[TEST_MODE] Skipping Cloud Foundry authentication"
    echo "[TEST_MODE] Ready to proceed with HDFS app testing."
    return 0
  fi
  
  # First authenticate
  if ! get_oauth_token; then
    echo "Authentication failed. Exiting."
    return 1
  fi
  
  local token=$(cat "$TOKEN_FILE")
  echo "Successfully authenticated to Cloud Foundry"
  
  # Rest of the function will be added in subsequent steps
  echo "Authentication flow complete. Ready to proceed with HDFS app testing."
}

# If called directly, run the test
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  test_hdfs_app
fi
