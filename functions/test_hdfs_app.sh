#!/bin/bash
# test_hdfs_app.sh - Test HDFS app with Cloud Foundry authentication and app registration
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
    if echo "$validation_output" | grep -q '"version"'; then 
        echo "[DEBUG check_token_validity] FYI: String '\"version\"' found in $validation_url output."
    else
        echo "[DEBUG check_token_validity] FYI: String '\"version\"' NOT found in $validation_url output."
    fi
    return 0 
  else
    echo "[DEBUG check_token_validity] Condition 4 FAIL: Token validation failed for $validation_url."
    echo "[DEBUG check_token_validity] HTTP code was: $http_code. Expected 200."
    return 1 
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

# Function to check if an app is already registered (specific to this script)
is_app_registered_in_test_script() {
  local app_type="$1"
  local app_name="$2" # Expects "hdfsWatcher"
  local current_token="$3"
  local scdf_endpoint="$4"

  echo "[DEBUG is_app_registered_in_test_script] Checking if $app_type app '$app_name' is registered at $scdf_endpoint."
  local response_code
  response_code=$(curl -s -k -w "%{http_code}" -H "Authorization: Bearer $current_token" \
    "${scdf_endpoint}/apps/${app_type}/${app_name}" -o /dev/null)

  if [ "$response_code" == "200" ]; then
    echo "[DEBUG is_app_registered_in_test_script] App '$app_name' of type '$app_type' is already registered (HTTP 200)."
    return 0 # True, app is registered
  elif [ "$response_code" == "404" ]; then
    echo "[DEBUG is_app_registered_in_test_script] App '$app_name' of type '$app_type' is NOT registered (HTTP 404)."
    return 1 # False, app is not registered
  else
    echo "[DEBUG is_app_registered_in_test_script] Error checking app '$app_name': HTTP $response_code. Assuming not registered or error."
    return 1 # Error or other non-200, treat as not registered for safety
  fi
}

# Function to register the hdfsWatcher app
register_hdfs_watcher_app() {
  local current_token="$1" 
  local scdf_endpoint="$2" 

  local app_type="source"
  local app_name="hdfsWatcher" # Corrected to hdfsWatcher (camelCase)
  local app_uri="https://github.com/dbbaskette/hdfsWatcher/releases/download/v0.2.0/hdfsWatcher-0.2.0.jar"
  local force_registration="true" 

  echo "--- ${app_name} App Registration ---" # Updated echo

  # Check if the app is already registered
  if is_app_registered_in_test_script "$app_type" "$app_name" "$current_token" "$scdf_endpoint"; then
    echo "[INFO] $app_type app '$app_name' is already registered. Deleting it first..."
    local delete_response_code
    delete_response_code=$(curl -s -k -w "%{http_code}" -X DELETE \
      -H "Authorization: Bearer $current_token" \
      "${scdf_endpoint}/apps/${app_type}/${app_name}" -o /dev/null)

    if [ "$delete_response_code" == "200" ]; then
      echo "[INFO] Successfully sent DELETE request for $app_type app '$app_name' (HTTP $delete_response_code)."
      echo -n "[INFO] Waiting for app '$app_name' to be unregistered..."
      local wait_time=0
      local max_wait_time=30 # seconds
      while is_app_registered_in_test_script "$app_type" "$app_name" "$current_token" "$scdf_endpoint"; do
        if [ "$wait_time" -ge "$max_wait_time" ]; then
          echo ""
          echo "[WARN] Timed out waiting for app '$app_name' to be unregistered. Proceeding with registration attempt anyway."
          break
        fi
        echo -n "."
        sleep 2
        wait_time=$((wait_time + 2))
      done
      if [ "$wait_time" -lt "$max_wait_time" ]; then
         echo " Unregistered."
      fi
    else
      echo "[WARN] Failed to delete $app_type app '$app_name' (HTTP $delete_response_code). Will attempt registration anyway."
    fi
  else
    echo "[INFO] $app_type app '$app_name' is not currently registered. Proceeding with new registration."
  fi


  echo "Registering $app_type app '$app_name' from URI: $app_uri"
  local data="uri=${app_uri}&force=${force_registration}"
  
  local response_body_file
  response_body_file=$(mktemp)
  local response_code
  response_code=$(curl -s -k -w "%{http_code}" -X POST \
    -H "Authorization: Bearer $current_token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "$data" \
    "${scdf_endpoint}/apps/${app_type}/${app_name}" -o "$response_body_file") # Using app_name "hdfsWatcher"
  
  local response_body
  response_body=$(cat "$response_body_file")
  rm -f "$response_body_file"

  if [ "$response_code" == "201" ] || [ "$response_code" == "200" ]; then # 200 can also mean success for updates
    echo "Successfully registered $app_type app '$app_name' (HTTP $response_code)."
    echo -n "[INFO] Verifying app '$app_name' registration status..."
    local verify_wait_time=0
    local max_verify_wait_time=30 # seconds
    while ! is_app_registered_in_test_script "$app_type" "$app_name" "$current_token" "$scdf_endpoint"; do
        if [ "$verify_wait_time" -ge "$max_verify_wait_time" ]; then
            echo ""
            echo "[WARN] Timed out waiting for app '$app_name' to become queryable after registration."
            # Even if timed out, the initial registration might have been okay.
            return 0 # Consider it a success if the POST was 201/200
        fi
        echo -n "."
        sleep 2
        verify_wait_time=$((verify_wait_time + 2))
    done
    echo " Verified."
    return 0
  else
    echo "Error registering $app_type app '$app_name': HTTP $response_code."
    echo "Response body: $response_body"
    return 1
  fi
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
  local validation_response_code_post_auth 
  local post_auth_output_file=$(mktemp)
  validation_response_code_post_auth=$(curl -s -k -w "%{http_code}" -H "Authorization: Bearer $token" "$final_validation_url" -o "$post_auth_output_file")
  rm -f "$post_auth_output_file"
  
  if [ "$validation_response_code_post_auth" == "200" ]; then
    echo "Token is confirmed valid post-authentication. Successfully connected to SCDF CF endpoint (HTTP $validation_response_code_post_auth to $final_validation_url)."
  else
    echo "Post-authentication check: Failed to validate token or connect to SCDF CF endpoint (HTTP $validation_response_code_post_auth to $final_validation_url)."
    return 1
  fi

  if ! register_hdfs_watcher_app "$token" "$SCDF_CF_URL"; then # Corrected: was register_hdfs_watcher_app
    echo "Failed to register hdfsWatcher app. Please check logs." # Corrected: was hdfsWatcher
    return 1 
  fi
  echo "hdfsWatcher app registration step completed." # Corrected: was hdfsWatcher

  echo "Authentication and app registration flow complete. Ready to proceed with HDFS app testing (actual HDFS test logic not yet implemented here)."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  test_hdfs_app
fi