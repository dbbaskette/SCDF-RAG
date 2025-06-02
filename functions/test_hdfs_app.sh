#!/bin/bash
# test_hdfs_app.sh - Test HDFS app with CF auth, app registration, and stream deployment.
# Usage: test_hdfs_app

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKEN_FILE="$SCRIPT_DIR/../.cf_token" 

# Source common environment setup and properties loader
. "$SCRIPT_DIR/env_setup.sh"
source_properties # Loads scdf_env.properties and create_stream.properties

# Source utilities for functions like build_json_from_props
. "$SCRIPT_DIR/utilities.sh"


# --- Utility Functions (Token, App Registration) ---
check_token_validity() {
  local CLIENT_ID_FILE="$SCRIPT_DIR/../.cf_client_id"
  
  # Try to load client ID from file if not set
  if [ -z "${CF_CLIENT_ID:-}" ] && [ -f "$CLIENT_ID_FILE" ]; then
    CF_CLIENT_ID=$(cat "$CLIENT_ID_FILE" 2>/dev/null)
    if [ -n "$CF_CLIENT_ID" ]; then
      echo "Using stored client ID: $CF_CLIENT_ID" >&2
    fi
  fi
  
  if [ ! -f "$TOKEN_FILE" ]; then 
    echo "Token file not found" >&2
    return 1
  fi
  
  local token
  token=$(cat "$TOKEN_FILE" 2>/dev/null)
  
  if [ -z "$token" ]; then 
    echo "Token file is empty" >&2
    return 1
  fi
  
  if [ -z "${SCDF_CF_URL:-}" ]; then 
    echo "Error: SCDF_CF_URL is not set for token validation." >&2
    return 1
  fi
  
  # First try the SCDF about endpoint
  local validation_url="$SCDF_CF_URL/about"
  local http_code
  http_code=$(curl -s -k -w "%{http_code}" -H "Authorization: Bearer $token" "$validation_url" -o /dev/null --connect-timeout 5 --max-time 10) || {
    echo "Failed to validate token with SCDF endpoint (connection error)" >&2
    return 1
  }
  
  if [ "$http_code" -eq 200 ]; then 
    echo "Token is valid" >&2
    return 0
  fi
  
  # If SCDF endpoint fails, try UAA directly if we have a token endpoint
  if [ -n "${SCDF_TOKEN_URL:-}" ]; then
    local uaa_validation_url="${SCDF_TOKEN_URL%/token}"
    if [[ "$uaa_validation_url" == */uaa ]]; then
      uaa_validation_url="${uaa_validation_url}/userinfo"
      http_code=$(curl -s -k -w "%{http_code}" -H "Authorization: Bearer $token" "$uaa_validation_url" -o /dev/null --connect-timeout 5 --max-time 10) || {
        echo "Failed to validate token with UAA endpoint (connection error)" >&2
        return 1
      }
      
      if [ "$http_code" -eq 200 ]; then
        echo "Token is valid (validated with UAA)" >&2
        return 0
      fi
    fi
  fi
  
  echo "Token validation failed with HTTP $http_code" >&2
  return 1
}

get_oauth_token() {
  echo "=== Cloud Foundry Authentication ==="
  
  # Define client ID file path
  local CLIENT_ID_FILE="$SCRIPT_DIR/../.cf_client_id"
  
  # Check for existing valid token first
  if check_token_validity; then 
    echo "Using existing valid token from $TOKEN_FILE"
    # Load client ID from file if not set
    if [ -z "${CF_CLIENT_ID:-}" ] && [ -f "$CLIENT_ID_FILE" ]; then
      CF_CLIENT_ID=$(cat "$CLIENT_ID_FILE" 2>/dev/null)
      echo "Using stored client ID: $CF_CLIENT_ID"
    fi
    return 0 
  fi
  
  echo "No valid token found, or existing token failed validation. Obtaining new token."
  echo "Please provide Cloud Foundry credentials (or set them in properties files):"
  
  # Try to load client ID from file if not set
  if [ -z "${CF_CLIENT_ID:-}" ] && [ -f "$CLIENT_ID_FILE" ]; then
    CF_CLIENT_ID=$(cat "$CLIENT_ID_FILE" 2>/dev/null)
    echo "Using stored client ID: $CF_CLIENT_ID"
  fi
  
  # Prompt for client ID if still not set
  if [ -z "${CF_CLIENT_ID:-}" ]; then 
    read -p "Client ID: " CF_CLIENT_ID
    # Save client ID for future use
    if [ -n "$CF_CLIENT_ID" ]; then
      echo "$CF_CLIENT_ID" > "$CLIENT_ID_FILE"
      chmod 600 "$CLIENT_ID_FILE"
      echo "Client ID saved to $CLIENT_ID_FILE"
    fi
  fi
  
  # Always prompt for secret (not stored)
  if [ -z "${CF_CLIENT_SECRET:-}" ]; then 
    read -s -p "Client Secret: " CF_CLIENT_SECRET
    echo # Newline after password prompt
  fi
  
  TOKEN_ENDPOINT_URL="${SCDF_TOKEN_URL:-}"
  if [ -z "$TOKEN_ENDPOINT_URL" ]; then 
    echo "Error: SCDF_TOKEN_URL not set." >&2
    return 1 
  fi
  
  echo "Authenticating with token URL: $TOKEN_ENDPOINT_URL"
  if [ -z "$CF_CLIENT_ID" ] || [ -z "$CF_CLIENT_SECRET" ]; then 
    echo "Error: Client ID/Secret empty." >&2
    return 1 
  fi
  
  local response
  response=$(curl -s -k -u "$CF_CLIENT_ID:$CF_CLIENT_SECRET" -X POST "$TOKEN_ENDPOINT_URL" \
    -H "Content-Type: application/x-www-form-urlencoded" -d "grant_type=client_credentials")
    
  local token
  if command -v jq >/dev/null 2>&1; then 
    token=$(echo "$response" | jq -r .access_token)
  else 
    token=$(echo "$response" | grep -o '"access_token":"[^"]*' | sed -n 's/"access_token":"\([^"]*\).*/\1/p')
  fi
  
  if [ -z "$token" ] || [ "$token" == "null" ]; then 
    echo "Failed to get new access token. Response: $response" >&2
    return 1 
  fi
  
  # Save token to file
  echo "$token" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  echo "Authentication successful. New token saved to $TOKEN_FILE"
  
  # Ensure .gitignore contains both files
  local project_root="$SCRIPT_DIR/.."
  local gitignore_file="$project_root/.gitignore"
  local token_file_entry=".cf_token"
  local client_id_entry=".cf_client_id"
  
  for entry in "$token_file_entry" "$client_id_entry"; do
    if [ ! -f "$gitignore_file" ] || ! grep -q -x "$entry" "$gitignore_file"; then
      echo "$entry" >> "$gitignore_file"
      echo "Added $entry to .gitignore"
    fi
  done
  
  return 0
}

_is_app_registered_cf() {
  local app_type="$1"; local app_name="$2"; local current_token="$3"; local scdf_endpoint="$4"
  local response_code; response_code=$(curl -s -k -w "%{http_code}" -H "Authorization: Bearer $current_token" "${scdf_endpoint}/apps/${app_type}/${app_name}" -o /dev/null)
  if [ "$response_code" == "200" ]; then return 0; elif [ "$response_code" == "404" ]; then return 1; else return 1; fi
}

_reregister_app_cf_auth() {
  local app_type="$1"
  local app_name="$2"
  local app_uri="$3"
  local current_token="$4"
  local scdf_endpoint="$5"
  local force_registration="true"
  echo "--- ${app_name} App Registration ---"

  # Check if the app is already registered
  if _is_app_registered_cf "$app_type" "$app_name" "$current_token" "$scdf_endpoint"; then
    echo "[INFO] $app_type app '$app_name' is already registered. Attempting to delete it..."
    
    # First, try to undeploy any streams using this app
    local streams_response
    streams_response=$(curl -s -k -H "Authorization: Bearer $current_token" "${scdf_endpoint}/streams/definitions?page=0&size=1000")
    local stream_names
    stream_names=$(echo "$streams_response" | grep -o '"name":"[^"]*' | cut -d'"' -f4)
    
    local app_in_use=false
    for stream in $stream_names; do
      local stream_def
      stream_def=$(curl -s -k -H "Authorization: Bearer $current_token" "${scdf_endpoint}/streams/definitions/${stream}")
      if echo "$stream_def" | grep -q "$app_name"; then
        echo "[INFO] Found stream '$stream' using app '$app_name'. Destroying stream..."
        if ! destroy_stream "$stream" "$current_token" "$scdf_endpoint"; then
          echo "[WARN] Failed to destroy stream '$stream' using app '$app_name'"
          app_in_use=true
        fi
      fi
    done
    
    if [ "$app_in_use" = true ]; then
      echo "[WARN] App '$app_name' is still in use by some streams. Force registration will be attempted."
    fi
    
    # Now try to delete the app
    local delete_response_code
    delete_response_code=$(curl -s -k -w "%{http_code}" -X DELETE \
      -H "Authorization: Bearer $current_token" \
      "${scdf_endpoint}/apps/${app_type}/${app_name}" -o /dev/null)

    if [ "$delete_response_code" == "200" ]; then
      echo "[INFO] Successfully sent DELETE request for $app_type app '$app_name' (HTTP $delete_response_code)."
      echo -n "[INFO] Waiting for app '$app_name' to be unregistered..."
      local wait_time=0
      local max_wait_time=30 # seconds
      while _is_app_registered_cf "$app_type" "$app_name" "$current_token" "$scdf_endpoint"; do
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
  local data="uri=${app_uri}&force=${force_registration}"; local response_body_file; response_body_file=$(mktemp); local response_code
  response_code=$(curl -s -k -w "%{http_code}" -X POST -H "Authorization: Bearer $current_token" -H "Content-Type: application/x-www-form-urlencoded" -d "$data" "${scdf_endpoint}/apps/${app_type}/${app_name}" -o "$response_body_file")
  local response_body; response_body=$(cat "$response_body_file"); rm -f "$response_body_file"
  if [ "$response_code" == "201" ] || [ "$response_code" == "200" ]; then # 200 can also mean success for updates/force
    echo "Successfully registered $app_type app '$app_name' (HTTP $response_code)."
    return 0
  else
    echo "Error registering $app_type app '$app_name': HTTP $response_code." >&2; echo "Response body: $response_body" >&2; return 1;
  fi
}

register_hdfs_watcher_app() {
  local current_token="$1"; local scdf_endpoint="$2"
  local app_uri="https://github.com/dbbaskette/hdfsWatcher/releases/download/v0.2.0/hdfsWatcher-0.2.0.jar"
  _reregister_app_cf_auth "source" "hdfsWatcher" "$app_uri" "$current_token" "$scdf_endpoint"
}

# --- Register textProc App ---
register_text_proc_app() {
  local current_token="$1"; local scdf_endpoint="$2"
  local app_uri="https://github.com/dbbaskette/textProc/releases/download/v0.0.6/textProc-0.0.6-SNAPSHOT.jar"
  _reregister_app_cf_auth "processor" "textProc" "$app_uri" "$current_token" "$scdf_endpoint"
}

# --- Register embedProc App ---
register_embed_proc_app() {
  local current_token="$1"; local scdf_endpoint="$2"
  local app_uri="https://github.com/dbbaskette/embedProc/releases/download/v0.0.3/embedProc-0.0.3.jar"
  _reregister_app_cf_auth "processor" "embedProc" "$app_uri" "$current_token" "$scdf_endpoint"
}

# --- Utility Functions ---
# Function to retry a command with exponential backoff
# Usage: with_retry <max_attempts> <sleep_seconds> <command>
with_retry() {
  local max_attempts=$1
  local sleep_seconds=$2
  local attempt=1
  shift 2
  
  while [ $attempt -le $max_attempts ]; do
    echo "Attempt $attempt of $max_attempts: $@"
    if "$@"; then
      return 0
    fi
    
    attempt=$((attempt + 1))
    if [ $attempt -le $max_attempts ]; then
      echo "Attempt failed. Waiting $sleep_seconds seconds before retry..."
      sleep $sleep_seconds
      sleep_seconds=$((sleep_seconds * 2))  # Exponential backoff
    fi
  done
  
  echo "All $max_attempts attempts failed"
  return 1
}

# Function to check if a stream exists with detailed debug output
stream_exists() {
  local stream_name="$1"
  local token="$2"
  local scdf_endpoint="${3%/}"  # Remove trailing slash if present
  
  # Debug output
  echo "[DEBUG] Checking if stream '$stream_name' exists at $scdf_endpoint..." >&2
  
  # First, check if we can connect to the SCDF server
  local health_check
  health_check=$(curl -s -k -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $token" \
    "${scdf_endpoint}/about" 2>/dev/null)
  
  if [[ "$health_check" != "200" ]]; then
    echo "[ERROR] Cannot connect to SCDF server at $scdf_endpoint/about (HTTP $health_check)" >&2
    return 1
  fi
  
  # Try to get the specific stream first (more efficient if it exists)
  local stream_response
  stream_response=$(curl -s -k -X GET \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/json" \
    "${scdf_endpoint}/streams/definitions/${stream_name}" 2>/dev/null)
  
  # Check if we got a valid response (200 or 404)
  if [[ $? -eq 0 ]]; then
    if [[ "$stream_response" == *"$stream_name"* ]]; then
      echo "[DEBUG] Stream '$stream_name' exists (found via direct lookup)." >&2
      return 0
    fi
  fi
  
  # If direct lookup fails, try listing all streams (fallback)
  echo "[DEBUG] Stream not found via direct lookup, trying to list all streams..." >&2
  local list_response
  list_response=$(curl -s -k -X GET \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/json" \
    "${scdf_endpoint}/streams/definitions?page=0&size=1000" 2>/dev/null)
  
  if [[ $? -ne 0 ]]; then
    echo "[ERROR] Failed to list streams from SCDF server" >&2
    return 1
  fi
  
  # Check if the response contains the stream name
  if echo "$list_response" | jq -e --arg name "$stream_name" '.content[] | select(.name == $name)' >/dev/null 2>&1; then
    echo "[DEBUG] Stream '$stream_name' exists (found in stream list)." >&2
    return 0
  fi
  
  # Check deployment status as a last resort
  echo "[DEBUG] Stream not found in list, checking deployment status..." >&2
  local status_response
  status_response=$(curl -s -k -X GET \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/json" \
    "${scdf_endpoint}/streams/deployments/${stream_name}" 2>/dev/null)
  
  if [[ $? -eq 0 && -n "$status_response" ]]; then
    if echo "$status_response" | jq -e '.name' >/dev/null 2>&1; then
      echo "[DEBUG] Stream '$stream_name' exists (found via deployment status)." >&2
      return 0
    fi
  fi
  
  echo "[DEBUG] Stream '$stream_name' does not exist or cannot be verified." >&2
  return 1
}

destroy_stream() {
  local stream_name="$1"
  local current_token="$2"
  local scdf_endpoint="$3"
  local max_retries=3
  local retry_delay=5
  local overall_success=0
  
  echo -e "\n=== Destroying Stream: $stream_name ==="
  
  # Check if stream exists first with better error handling
  echo "Checking if stream '$stream_name' exists..."
  if ! stream_exists "$stream_name" "$current_token" "$scdf_endpoint"; then
    echo "Info: Stream '$stream_name' does not exist or cannot be verified, nothing to destroy."
    return 0
  fi
  
  # Undeploy the stream with retries and better error handling
  echo "Undeploying stream '$stream_name'..."
  local undeploy_success=0
  
  for ((i=1; i<=max_retries; i++)); do
    echo "Attempt $i/$max_retries: Undeploying stream..."
    local status
    status=$(curl -s -k -X DELETE \
      -H "Authorization: Bearer $current_token" \
      -o /dev/null \
      -w "%{http_code}" \
      "${scdf_endpoint}/streams/deployments/${stream_name}")
    
    if [[ "$status" == "200" || "$status" == "404" ]]; then
      echo "Stream '$stream_name' undeployed successfully (HTTP $status)."
      undeploy_success=1
      break
    else
      echo "Attempt $i failed with HTTP $status. Retrying in $retry_delay seconds..."
      sleep $retry_delay
    fi
  done
  
  if [[ $undeploy_success -eq 0 ]]; then
    echo "Warning: Failed to undeploy stream '$stream_name' after $max_retries attempts." >&2
    overall_success=1
  fi
  
  # Give SCDF time to process the undeployment
  echo "Waiting for stream to be fully undeployed..."
  sleep 10
  
  # Delete the stream definition with retries
  echo "Deleting stream definition '$stream_name'..."
  local delete_success=0
  
  for ((i=1; i<=max_retries; i++)); do
    echo "Attempt $i/$max_retries: Deleting stream definition..."
    local status
    status=$(curl -s -k -X DELETE \
      -H "Authorization: Bearer $current_token" \
      -o /dev/null \
      -w "%{http_code}" \
      "${scdf_endpoint}/streams/definitions/${stream_name}")
    
    if [[ "$status" == "200" || "$status" == "404" ]]; then
      echo "Stream definition '$stream_name' deleted successfully (HTTP $status)."
      delete_success=1
      break
    else
      echo "Attempt $i failed with HTTP $status. Retrying in $retry_delay seconds..."
      sleep $retry_delay
    fi
  done
  
  if [[ $delete_success -eq 0 ]]; then
    echo "Warning: Failed to delete stream definition '$stream_name' after $max_retries attempts." >&2
    overall_success=1
  fi
  
  # Verify stream is gone, but don't fail if it's still there
  if stream_exists "$stream_name" "$current_token" "$scdf_endpoint"; then
    echo "Warning: Stream '$stream_name' still exists after deletion attempt. This may be expected if the stream is in a failed state." >&2
    overall_success=1
  else
    echo "Stream '$stream_name' successfully removed from SCDF."
  fi
  
  if [[ $overall_success -eq 0 ]]; then
    echo "Stream cleanup completed successfully for '$stream_name'."
  else
    echo "Warning: Some issues occurred during stream cleanup for '$stream_name'." >&2
  fi
  
  return $overall_success
}

create_stream_definition_api() {
  local stream_name="$1"
  local dsl_definition="$2"
  local current_token="$3"
  local scdf_endpoint="$4"
  local max_retries=3
  local retry_delay=5
  
  echo -e "\n=== Creating Stream Definition: $stream_name ==="
  echo "Definition DSL: $dsl_definition"
  
  # Check if stream already exists
  if stream_exists "$stream_name" "$current_token" "$scdf_endpoint"; then
    echo "Error: A stream with name '$stream_name' already exists." >&2
    return 1
  fi
  
  # URL-encode the DSL definition
  local encoded_dsl
  if ! encoded_dsl=$(jq -rn --arg dsl "$dsl_definition" '$dsl | @uri'); then
    echo "Error: Failed to encode DSL definition" >&2
    return 1
  fi
  
  local response
  local http_code
  local response_body
  
  # Try creating the stream definition with retries
  with_retry $max_retries $retry_delay \
    curl -s -k -w "\n%{http_code}" -X POST \
    -H "Content-Type: application/x-www-form-urlencoded;charset=UTF-8" \
    -H "Authorization: Bearer $current_token" \
    -d "name=${stream_name}&definition=${encoded_dsl}&description=Created+via+API" \
    "${scdf_endpoint}/streams/definitions" | \
    {
      response=$(cat)
      http_code=$(echo "$response" | tail -n1)
      response_body=$(echo "$response" | sed '$d')
      
      if [ "$http_code" -eq 201 ]; then
        echo "Stream definition '$stream_name' created successfully."
        echo "Response: $response_body"
        return 0
      else
        echo "Error creating stream definition '$stream_name': HTTP $http_code" >&2
        echo "Response: $response_body" >&2
        return 1
      fi
    } || {
      echo "Failed to create stream definition after $max_retries attempts." >&2
      return 1
    }
}

deploy_stream_api() {
  local stream_name="$1"
  local current_token="$2"
  local scdf_endpoint="$3"
  local properties_json="$4"
  local max_retries=3
  local retry_delay=10  # Longer delay for deployment operations
  
  echo -e "\n=== Deploying Stream: $stream_name ==="
  echo "Deployment Properties: $properties_json"
  
  # Verify the stream exists before attempting to deploy
  if ! stream_exists "$stream_name" "$current_token" "$scdf_endpoint"; then
    echo "Error: Cannot deploy stream '$stream_name' - stream definition not found." >&2
    return 1
  fi
  
  local response
  local http_code
  local response_body
  
  # Try deploying the stream with retries
  with_retry $max_retries $retry_delay \
    curl -s -k -w "\n%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $current_token" \
    -d "$properties_json" \
    "${scdf_endpoint}/streams/deployments/${stream_name}" | \
    {
      response=$(cat)
      http_code=$(echo "$response" | tail -n1)
      response_body=$(echo "$response" | sed '$d')
      
      if [ "$http_code" -eq 200 ]; then
        echo "Stream '$stream_name' deployment initiated successfully."
        echo "Response: $response_body"
        
        # Verify deployment status
        echo "Verifying deployment status..."
        local status_attempts=0
        local max_status_attempts=10
        local status_interval=5
        
        while [ $status_attempts -lt $max_status_attempts ]; do
          sleep $status_interval
          local status_response
          status_response=$(curl -s -k -H "Authorization: Bearer $current_token" \
            "${scdf_endpoint}/streams/deployments/${stream_name}")
          
          local status
          status=$(echo "$status_response" | jq -r '.deploymentProperties."deployer.*.cloudfoundry.status" // empty')
          
          if [ "$status" == "deployed" ]; then
            echo "Stream '$stream_name' is now deployed and running."
            return 0
          elif [ "$status" == "error" ] || [ "$status" == "failed" ]; then
            echo "Error: Stream deployment failed with status: $status" >&2
            echo "Status response: $status_response" >&2
            return 1
          fi
          
          status_attempts=$((status_attempts + 1))
          echo "Deployment in progress (attempt $status_attempts/$max_status_attempts), current status: ${status:-unknown}"
        done
        
        echo "Warning: Deployment status verification timed out. The stream might still be deploying." >&2
        return 0
      else
        echo "Error deploying stream '$stream_name': HTTP $http_code" >&2
        echo "Response: $response_body" >&2
        return 1
      fi
    } || {
      echo "Failed to deploy stream after $max_retries attempts." >&2
      return 1
    }
}


# --- Main test_hdfs_app Function ---
test_hdfs_app() {
  if [[ "${TEST_MODE:-0}" -eq 1 ]]; then
    echo "[TEST_MODE] Skipping Cloud Foundry authentication for test_hdfs_app internal test."
    return 0
  fi

  # Critical variable checks
  if [ -z "${SCDF_CF_URL:-}" ]; then echo "Error: SCDF_CF_URL is not set." >&2; return 1; fi
  if [ -z "${SCDF_TOKEN_URL:-}" ]; then echo "Error: SCDF_TOKEN_URL is not set." >&2; return 1; fi
  
  # Check for HDFS variables and other required properties
  if [ -z "${HDFS_USER:-}" ]; then echo "Error: HDFS_USER is not set." >&2; return 1; fi
  if [ -z "${HDFS_URI:-}" ]; then echo "Error: HDFS_URI is not set." >&2; return 1; fi
  if [ -z "${HDFS_REMOTE_DIR:-}" ]; then echo "Error: HDFS_REMOTE_DIR is not set." >&2; return 1; fi
  if [ -z "${HDFSWATCHER_PSEUDOOP:-}" ]; then echo "Error: HDFSWATCHER_PSEUDOOP is not set." >&2; return 1; fi
  if [ -z "${HDFSWATCHER_LOCAL_STORAGE_PATH:-}" ]; then echo "Error: HDFSWATCHER_LOCAL_STORAGE_PATH is not set." >&2; return 1; fi
  if [ -z "${HDFSWATCHER_OUTPUT_STREAM_NAME:-}" ]; then echo "Error: HDFSWATCHER_OUTPUT_STREAM_NAME is not set." >&2; return 1; fi
  # HDFS_WEBHDFS_URI is optional, so no check here. Poll interval has a default.

  if ! get_oauth_token; then echo "Authentication failed. Exiting." >&2; return 1; fi

  local token; token=$(cat "$TOKEN_FILE") 

  # Note: The build_json_from_props function handles trimming of property values.
  # If variables are used elsewhere and need explicit cleaning, it should be done there.

  # Use stream name from properties
  local STREAM_NAME="rag-pipeline" # Using the stream name from create_stream.properties

  echo "Successfully authenticated to Cloud Foundry (or used existing valid token)."

  local final_validation_url="$SCDF_CF_URL/about"
  echo "Verifying token with SCDF endpoint: $final_validation_url"
  local validation_code; validation_code=$(curl -s -k -w "%{http_code}" -H "Authorization: Bearer $token" "$final_validation_url" -o /dev/null)
  if [ "$validation_code" == "200" ]; then echo "Token confirmed valid. Connected to SCDF endpoint (HTTP $validation_code from $final_validation_url)."; else echo "Error: Post-authentication token validation failed (HTTP $validation_code from $final_validation_url)." >&2; return 1; fi

  # --- Register Apps ---
  echo -e "\n--- Registering Apps ---"
  
  # Register apps using the existing registration functions
  echo -e "\n--- hdfsWatcher App Registration ---"
  if ! register_hdfs_watcher_app "$token" "$SCDF_CF_URL"; then
    echo "Failed to register hdfsWatcher app. Exiting." >&2
    return 1
  fi
  
  echo -e "\n--- textProc App Registration ---"
  if ! register_text_proc_app "$token" "$SCDF_CF_URL"; then
    echo "Failed to register textProc app. Exiting." >&2
    return 1
  fi
  
  echo -e "\n--- embedProc App Registration ---"
  if ! register_embed_proc_app "$token" "$SCDF_CF_URL"; then
    echo "Failed to register embedProc app. Exiting." >&2
    return 1
  fi
  
  # Only register log app if it's not already registered
  echo -e "\n--- Log App Check ---"
  local log_check_url="${SCDF_CF_URL}/apps/sink/log"
  local http_code
  http_code=$(curl -s -k -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $token" \
    "$log_check_url")
    
  if [ "$http_code" -ne 200 ]; then
    echo "Log app not found. Registering log app..."
    if ! curl -k -X POST "${SCDF_CF_URL}/apps/sink/log" \
      -H "Authorization: Bearer $token" \
      -d "uri=${LOG_APP_URI}" \
      -H "Content-Type: application/x-www-form-urlencoded"; then
      echo "Warning: Failed to register log app, but continuing..."
    fi
  else
    echo "Log app is already registered. Skipping registration."
  fi
  
  # --- Stream Creation and Deployment ---
  local stream_dsl="hdfsWatcher | textProc | embedProc | log"  # Stream definition with embedProc added

  # 1. Destroy existing stream (if any) - already done by `destroy_stream` called earlier in some flows,
  # but good to ensure it's clean before creating. The `destroy_stream` in this file is robust.
  if ! destroy_stream "$STREAM_NAME" "$token" "$SCDF_CF_URL"; then
      echo "Warning: Could not fully destroy existing stream '$STREAM_NAME' during test_hdfs_app. Proceeding with caution."
  fi

  # 2. Create new stream definition using the helper function with retries
  local create_attempt=1
  local max_create_attempts=3
  local create_delay=5
  local stream_created=0
  
  while [ $create_attempt -le $max_create_attempts ]; do
    echo "Attempt $create_attempt to create stream definition..."
    
    if create_stream_definition_api "$STREAM_NAME" "$stream_dsl" "$token" "$SCDF_CF_URL"; then
      echo "Stream definition '$STREAM_NAME' created successfully."
      stream_created=1
      break
    fi
    
    if [ $create_attempt -lt $max_create_attempts ]; then
      echo "Waiting $create_delay seconds before retry..."
      sleep $create_delay
      create_attempt=$((create_attempt + 1))
      create_delay=$((create_delay * 2))  # Exponential backoff
    else
      echo "Error: Failed to create stream definition after $max_create_attempts attempts." >&2
      return 1
    fi
  done
  
  if [ $stream_created -eq 0 ]; then
    echo "Error: Failed to create stream definition." >&2
    return 1
  fi
  
  # Verify the stream exists with retries
  echo "Verifying stream definition exists..."
  local verify_attempt=1
  local max_verify_attempts=5
  local verify_delay=5
  local stream_verified=0
  
  while [ $verify_attempt -le $max_verify_attempts ]; do
    if stream_exists "$STREAM_NAME" "$token" "$SCDF_CF_URL"; then
      echo "Stream definition verified successfully."
      stream_verified=1
      break
    else
      echo "Stream definition not yet available (attempt $verify_attempt/$max_verify_attempts)..."
      sleep $verify_delay
      verify_attempt=$((verify_attempt + 1))
    fi
  done
  
  if [ $stream_verified -eq 0 ]; then
    echo "Warning: Stream definition not found after $max_verify_attempts verification attempts." >&2
    echo "This might indicate an issue with the SCDF server. Will attempt to continue..." >&2
  fi
  
  # Add a small delay to ensure the stream is fully registered
  echo "Waiting for stream to be fully registered..."
  sleep 5

  # 3. Prepare and deploy the stream with retries
  # Even if verification failed, we'll try to deploy as the stream might exist but verification is failing
  local deploy_props_array=()
  # deploy_props_array+=("deployer.hadoop-hdfs.kubernetes.environmentVariables=HADOOP_USER_NAME=hdfs") # Example if needed
  # deploy_props_array+=("app.hadoop-hdfs.hadoop.security.authentication=simple") # Example if needed
  # deploy_props_array+=("app.hadoop-hdfs.hadoop.security.authorization=false") # Example if needed
  deploy_props_array+=("app.hdfsWatcher.hdfsUser=${HDFS_USER}")
  deploy_props_array+=("app.hdfsWatcher.hdfsUri=${HDFS_URI}")
  deploy_props_array+=("app.hdfsWatcher.hdfsPath=${HDFS_REMOTE_DIR}")
  deploy_props_array+=("app.hdfsWatcher.hdfsWatcher.pseudoop=${HDFSWATCHER_PSEUDOOP}")
  deploy_props_array+=("deployer.hdfsWatcher.cloudfoundry.env.JBP_CONFIG_OPEN_JDK_JRE={ jre: { version: 21.+ } }")
  deploy_props_array+=("app.hdfsWatcher.hdfsWatcher.local-storage-path=${HDFSWATCHER_LOCAL_STORAGE_PATH}")
  deploy_props_array+=("app.hdfsWatcher.hdfsWatcher.pollInterval=5000")
  deploy_props_array+=("app.hdfsWatcher.spring.profiles.active=scdf")
  deploy_props_array+=("app.hdfsWatcher.spring.cloud.config.enabled=false")
  deploy_props_array+=("app.hdfsWatcher.spring.cloud.stream.bindings.output.destination=hdfswatcher-textproc")
  deploy_props_array+=("app.hdfsWatcher.logging.level.org.springframework.cloud.stream=DEBUG")
  deploy_props_array+=("app.hdfsWatcher.logging.level.org.springframework.integration=DEBUG")
  deploy_props_array+=("app.hdfsWatcher.logging.level.org.springframework.cloud.stream.binder.rabbit=DEBUG")
  deploy_props_array+=("app.hdfsWatcher.logging.level.org.springframework.cloud.stream.app.hdfsWatcher.source=DEBUG")
  deploy_props_array+=("app.hdfsWatcher.logging.level.org.apache.hadoop=DEBUG")

  deploy_props_array+=("app.textProc.spring.profiles.active=scdf")
  deploy_props_array+=("app.textProc.spring.cloud.function.definition=textProc")
  deploy_props_array+=("app.textProc.spring.cloud.stream.bindings.textProc-in-0.destination=hdfswatcher-textproc")
  deploy_props_array+=("app.textProc.spring.cloud.stream.bindings.textProc-in-0.group=${STREAM_NAME}")
  deploy_props_array+=("app.textProc.spring.cloud.stream.bindings.textProc-out-0.destination=textproc-to-embedproc")

  
  # Health check and deployment settings
  deploy_props_array+=("deployer.textProc.cloudfoundry.health-check-type=http")
  deploy_props_array+=("deployer.textProc.cloudfoundry.health-check-http-endpoint=/actuator/health")
  deploy_props_array+=("deployer.textProc.cloudfoundry.env.JBP_CONFIG_OPEN_JDK_JRE={ jre: { version: 21.+} }")
  deploy_props_array+=("deployer.textProc.cloudfoundry.startup-timeout=600")  # 10 minutes
  deploy_props_array+=("deployer.textProc.memory=2G")  # Increased memory
  deploy_props_array+=("deployer.textProc.cloudfoundry.health-check-timeout=120")  # Health check timeout
  
  # Server and web UI configuration
  deploy_props_array+=("app.textProc.server.port=8080")
  deploy_props_array+=("app.textProc.server.address=0.0.0.0")
  
  # Management and Actuator configuration
  # Explicitly disable separate management port to run on main server port
  deploy_props_array+=("app.textProc.management.server.port=-1")  # Disables separate management port
  deploy_props_array+=("app.textProc.management.endpoints.web.base-path=/actuator")
  deploy_props_array+=("app.textProc.management.endpoints.web.exposure.include=health,info,env,metrics,httptrace,prometheus")
  deploy_props_array+=("app.textProc.management.endpoint.health.show-details=always")
  deploy_props_array+=("app.textProc.management.endpoint.health.show-components=always")
  deploy_props_array+=("app.textProc.management.endpoint.health.probes.enabled=true")
  deploy_props_array+=("app.textProc.management.endpoints.web.path-mapping.health=health")
  
  # Logging configuration
  deploy_props_array+=("app.textProc.logging.level.root=INFO")
  deploy_props_array+=("app.textProc.logging.level.org.springframework=INFO")
  deploy_props_array+=("app.textProc.logging.level.com.example=DEBUG")
  
  # Web interface configuration
  deploy_props_array+=("app.textProc.spring.web.resources.static-locations=classpath:/static/,classpath:/public/")
  deploy_props_array+=("app.textProc.spring.mvc.static-path-pattern=/**")


  # embedProc processor - with explicit buildpack and resource settings
  deploy_props_array+=("app.embedProc.spring.profiles.active=scdf")
  deploy_props_array+=("app.embedProc.spring.cloud.function.definition=embedProc")
  deploy_props_array+=("app.embedProc.spring.cloud.stream.bindings.embedProc-in-0.destination=textproc-embedproc")
  deploy_props_array+=("app.embedProc.spring.cloud.stream.bindings.embedProc-in-0.group=${STREAM_NAME}")
  deploy_props_array+=("app.embedProc.spring.cloud.stream.bindings.embedProc-out-0.destination=embedproc-log")
  
  # Minimal management configuration with process health check
  deploy_props_array+=("deployer.embedProc.cloudfoundry.health-check-type=process")
  deploy_props_array+=("deployer.embedProc.cloudfoundry.env.JBP_CONFIG_OPEN_JDK_JRE={ jre: { version: 21.+} }")
  deploy_props_array+=("deployer.embedProc.cloudfoundry.startup-timeout=300")
  deploy_props_array+=("app.embedProc.management.endpoints.web.exposure.include=health")
  deploy_props_array+=("app.embedProc.management.endpoint.health.show-details=always")
  deploy_props_array+=("app.embedProc.management.metrics.enabled=false")
  deploy_props_array+=("app.embedProc.logging.level.root=INFO")

  
  # Service bindings - using YAML array syntax
  deploy_props_array+=("deployer.embedProc.cloudfoundry.services=embed-model,embed-db")

  deploy_props_array+=("app.embedProc.logging.level.org.springframework=DEBUG")
  deploy_props_array+=("app.embedProc.logging.level.cloudfoundry-client=DEBUG")
  # Conditionally add webhdfsUri for hdfsWatcher
  if [ -n "${HDFS_WEBHDFS_URI:-}" ]; then
    deploy_props_array+=("app.hdfsWatcher.hdfsWatcher.webhdfsUri=${HDFS_WEBHDFS_URI:-}")
  fi

  # --- Properties for log app ---
  deploy_props_array+=("app.log.spring.cloud.stream.bindings.input.destination=embedproc-log")
  deploy_props_array+=("app.log.spring.cloud.stream.bindings.input.group=${STREAM_NAME}")
  deploy_props_array+=("app.log.management.metrics.enabled=false")
  deploy_props_array+=("app.log.logging.level.root=INFO")

  # Use a pipe as a temporary delimiter to handle values with commas
  local IFS='|'
  local deploy_props_str="${deploy_props_array[*]}"
  # Replace the pipe with a comma in the final string
  deploy_props_str="${deploy_props_str//|/,}"

  # The build_json_from_props function handles trimming and proper JSON conversion.
  # The individual variable cleaning (e.g., clean_HDFS_USER) should ensure values are clean.

  # Debug: Output the constructed DEPLOY_PROPS string
  echo "[DEBUG] Constructed DEPLOY_PROPS string: $deploy_props_str"
  
  # 4. Deploy the stream with retry logic
  local max_retries=2
  local attempt=0
  local success=0
  local last_error=""
  
  # Deploy the stream with retries
  local max_deploy_attempts=3
  local deploy_attempt=1
  local deploy_delay=10
  local deployment_success=0
  
  while [ $deploy_attempt -le $max_deploy_attempts ]; do
    echo -e "\n=== Deployment Attempt $deploy_attempt/$max_deploy_attempts ==="
    
    # Only get a new token if we don't have a valid one
    if [ -z "$token" ] || ! check_token_validity; then
      echo "No valid token found or token expired. Refreshing token..." >&2
      if ! get_oauth_token; then
        last_error="Failed to obtain authentication token"
        echo "$last_error" >&2
        deploy_attempt=$((deploy_attempt + 1))
        continue
      fi
      
      # Read the new token from file
      token=$(cat "$TOKEN_FILE" 2>/dev/null)
      if [ -z "$token" ]; then
        last_error="Failed to read token from file"
        echo "$last_error" >&2
        deploy_attempt=$((deploy_attempt + 1))
        continue
      fi
    fi
    
    local stream_verified=0
    
    # Verify stream exists before deploying
    if ! stream_exists "$STREAM_NAME" "$token" "$SCDF_CF_URL"; then
      echo "Warning: Stream '$STREAM_NAME' not found via direct check. Attempting to recreate..."
      
      # Try to recreate the stream definition
      if ! create_stream_definition_api "$STREAM_NAME" "$stream_dsl" "$token" "$SCDF_CF_URL"; then
        echo "Warning: Failed to recreate stream definition. It might already exist."
        # Continue anyway - the stream might exist but verification is failing
      fi
      
      # Give it some time to register
      echo "Waiting for stream to be registered..."
      sleep 5
    else
      stream_verified=1
    fi
    
    # Convert array to comma-separated string for the API
    local deploy_props_str
    deploy_props_str=$(IFS=,; echo "${deploy_props_array[*]}")
    
    # Attempt deployment regardless of verification status
    echo "Attempting to deploy stream '$STREAM_NAME'..."
    if deploy_stream_api "$STREAM_NAME" "$deploy_props_str" "$token" "$SCDF_CF_URL"; then
      echo -e "\n=== Stream '$STREAM_NAME' deployment initiated successfully ==="
      deployment_success=1
      break
    else
      echo "Deployment attempt $deploy_attempt failed."
      
      if [ $deploy_attempt -lt $max_deploy_attempts ]; then
        echo "Waiting $deploy_delay seconds before retry..."
        sleep $deploy_delay
        deploy_attempt=$((deploy_attempt + 1))
        deploy_delay=$((deploy_delay * 2))  # Exponential backoff
      else
        echo "Error: Failed to deploy stream after $max_deploy_attempts attempts." >&2
        
        # If we couldn't verify the stream but it might exist, try forcing deployment
        if [ $stream_verified -eq 0 ]; then
          echo "Note: Stream verification failed but trying forced deployment..."
          if curl -s -k -X POST -H "Authorization: Bearer $token" \
             -H "Content-Type: application/json" \
             -d "$deploy_props_str" \
             "${SCDF_CF_URL}/streams/deployments/${STREAM_NAME}"; then
            echo "Forced deployment of '${STREAM_NAME}' completed."
            deployment_success=1
            break
          fi
        fi
        
        return 1
      fi
    fi
  done
  
  if [ $deployment_success -eq 0 ]; then
    echo "Error: Deployment failed after all retry attempts." >&2
    return 1
  fi
  echo "Test stream '$STREAM_NAME' (DSL: $stream_dsl) should be deploying."
  echo "Monitor SCDF UI for status. HDFS Location (if applicable): ${HDFS_URI}${HDFS_REMOTE_DIR}"
} # Correct placement for the end of test_hdfs_app function

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  test_hdfs_app
fi