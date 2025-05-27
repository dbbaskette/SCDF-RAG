#!/bin/bash
# test_hdfs_app.sh - Test HDFS app with Cloud Foundry authentication
# Usage: test_hdfs_app

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKEN_FILE="$SCRIPT_DIR/../.cf_token" # Token file will be in the parent directory of functions/

# Load environment and properties
. "$SCRIPT_DIR/env_setup.sh"
source_properties 

# Check if token is still valid
check_token_validity() {
  echo "[DEBUG check_token_validity] Inside check_token_validity function."
  echo "[DEBUG check_token_validity] TOKEN_FILE path is: $TOKEN_FILE"

  if [ ! -f "$TOKEN_FILE" ]; then
    echo "[DEBUG check_token_validity] Condition 1 FAIL: Token file '$TOKEN_FILE' does not exist."
    return 1
  fi
  echo "[DEBUG check_token_validity] Condition 1 PASS: Token file exists."

  local token
  token=$(cat "$TOKEN_FILE")
  if [ -z "$token" ]; then
    echo "[DEBUG check_token_validity] Condition 2 FAIL: Token file is empty."
    return 1
  fi
  echo "[DEBUG check_token_validity] Condition 2 PASS: Token file is not empty. Token starts with: ${token:0:20}..."

  if [ -z "${SCDF_CF_URL:-}" ]; then
    echo "[DEBUG check_token_validity] Condition 3 FAIL: SCDF_CF_URL is not set."
    return 1
  fi
  echo "[DEBUG check_token_validity] Condition 3 PASS: SCDF_CF_URL is: $SCDF_CF_URL"

  local validation_url="$SCDF_CF_URL/about"
  echo "[DEBUG check_token_validity] Attempting to validate token with curl to $validation_url ..."
  local validation_output
  local http_code
  
  temp_output_file=$(mktemp)
  http_code=$(curl -s -k -w "%{http_code}" -H "Authorization: Bearer $token" "$validation_url" -o "$temp_output_file")
  validation_output=$(cat "$temp_output_file")
  rm -f "$temp_output_file"

  echo "[DEBUG check_token_validity] curl HTTP code from $validation_url: $http_code"
  echo "[DEBUG check_token_validity] curl validation_output (first 100 chars from $validation_url): ${validation_output:0:100}"

  if [ "$http_code" == "200" ]; then
    echo "[DEBUG check_token_validity] Token validation successful (HTTP 200 from $validation_url)."
    if echo "$validation_output" | grep -q '"version"'; then # Check for "version" for informational purposes
        echo "[DEBUG check_token_validity] FYI: String '\"version\"' found in $validation_url output."
    else
        echo "[DEBUG check_token_validity] FYI: String '\"version\"' NOT found in $validation_url output."
    fi
    return 0 # Success
  else
    echo "[DEBUG check_token_validity] Condition 4 FAIL: Token validation failed for $validation_url."
    echo "[DEBUG check_token_validity] HTTP code was: $http_code. Expected 200."
    return 1 # Failure
  fi
}

# Get OAuth token from Cloud Foundry
get_oauth_token() {
  echo "=== Cloud Foundry Authentication ==="

  if check_token_validity; then 
    echo "Using existing valid token from $TOKEN_FILE"
    return 0
  fi

  echo "No valid token found. Please provide Cloud Foundry credentials (or set them in properties files):"

  if [ -z "${CF_CLIENT_ID:-}" ]; then 
    read -p "Client ID: " CF_CLIENT_ID
  fi

  if [ -z "${CF_CLIENT_SECRET:-}" ]; then
    read -s -p "Client Secret: " CF_CLIENT_SECRET
    echo
  fi
  
  TOKEN_ENDPOINT_URL="${SCDF_TOKEN_URL:-}" 

  if [ -z "$TOKEN_ENDPOINT_URL" ]; then
    echo "Error: SCDF_TOKEN_URL is not set (e.g., in create_stream.properties or scdf_env.properties). Cannot get token."
    return 1
  fi
  
  echo "Authenticating with token URL: $TOKEN_ENDPOINT_URL"

  if [ -z "$CF_CLIENT_ID" ] || [ -z "$CF_CLIENT_SECRET" ]; then
    echo "Error: Client ID and Client Secret cannot be empty. Please provide them or set them in properties."
    return 1
  fi
  
  local response
  response=$(curl -s -k -u "$CF_CLIENT_ID:$CF_CLIENT_SECRET" \
    -X POST "$TOKEN_ENDPOINT_URL" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials")

  local token
  if command -v jq >/dev/null 2>&1; then
    token=$(echo "$response" | jq -r .access_token)
  else
    token=$(echo "$response" | grep -o '"access_token":"[^"]*' | sed -n 's/"access_token":"\([^"]*\).*/\1/p')
  fi

  if [ -z "$token" ] || [ "$token" == "null" ]; then
    echo "Failed to get access token. Response: $response"
    return 1
  fi

  echo "$token" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  echo "Authentication successful. Token saved to $TOKEN_FILE"
  
  local project_root="$SCRIPT_DIR/.."
  local gitignore_file="$project_root/.gitignore"
  local token_file_entry=".cf_token"

  if [ ! -f "$gitignore_file" ]; then
    echo "$token_file_entry" > "$gitignore_file"
    echo "Created .gitignore and added $token_file_entry"
  else
    if ! grep -q -x "$token_file_entry" "$gitignore_file"; then
      echo "$token_file_entry" >> "$gitignore_file"
      echo "Added $token_file_entry to .gitignore"
    fi
  fi
  return 0
}

# Main function
test_hdfs_app() {
  if [[ "${TEST_MODE:-0}" -eq 1 ]]; then
    echo "[TEST_MODE] Skipping Cloud Foundry authentication for test_hdfs_app internal test."
    return 0
  fi

  if [ -z "${SCDF_CF_URL:-}" ]; then
    echo "Error: SCDF_CF_URL is not set (e.g., in create_stream.properties or scdf_env.properties)."
    return 1
  fi

  if ! get_oauth_token; then
    echo "Authentication failed. Exiting."
    return 1
  fi

  local token
  token=$(cat "$TOKEN_FILE") 
  echo "Successfully authenticated to Cloud Foundry (or used existing valid token)."

  local final_validation_url="$SCDF_CF_URL/about"
  echo "Validating token post-authentication by checking SCDF CF endpoint: $final_validation_url"
  
  local validation_response_code
  local final_validation_output_file=$(mktemp)
  validation_response_code=$(curl -s -k -w "%{http_code}" -H "Authorization: Bearer $token" "$final_validation_url" -o "$final_validation_output_file")
  # local final_validation_output=$(cat "$final_validation_output_file") # Uncomment if you need to inspect output
  rm -f "$final_validation_output_file"
  
  if [ "$validation_response_code" == "200" ]; then
    echo "Token is confirmed valid post-authentication. Successfully connected to SCDF CF endpoint (HTTP $validation_response_code to $final_validation_url)."
  else
    echo "Post-authentication check: Failed to validate token or connect to SCDF CF endpoint (HTTP $validation_response_code to $final_validation_url)."
    echo "This might indicate the token became invalid immediately after being fetched, or an issue with the endpoint."
    return 1
  fi

  echo "Authentication flow complete. Ready to proceed with HDFS app testing (actual HDFS test logic not yet implemented here)."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  test_hdfs_app
fi