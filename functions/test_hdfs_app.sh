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
  # ... (previous implementation from last update)
  if [ ! -f "$TOKEN_FILE" ]; then return 1; fi
  local token; token=$(cat "$TOKEN_FILE"); if [ -z "$token" ]; then return 1; fi
  if [ -z "${SCDF_CF_URL:-}" ]; then echo "Error: SCDF_CF_URL is not set for token validation." >&2; return 1; fi
  local validation_url="$SCDF_CF_URL/about"
  local http_code; http_code=$(curl -s -k -w "%{http_code}" -H "Authorization: Bearer $token" "$validation_url" -o /dev/null)
  if [ "$http_code" == "200" ]; then return 0; else return 1; fi
}

get_oauth_token() {
  # ... (previous implementation from last update)
  echo "=== Cloud Foundry Authentication ==="
  if check_token_validity; then echo "Using existing valid token from $TOKEN_FILE"; return 0; fi
  echo "No valid token found, or existing token failed validation. Obtaining new token."
  echo "Please provide Cloud Foundry credentials (or set them in properties files):"
  if [ -z "${CF_CLIENT_ID:-}" ]; then read -p "Client ID: " CF_CLIENT_ID; fi
  if [ -z "${CF_CLIENT_SECRET:-}" ]; then read -s -p "Client Secret: " CF_CLIENT_SECRET; echo; fi
  TOKEN_ENDPOINT_URL="${SCDF_TOKEN_URL:-}"; if [ -z "$TOKEN_ENDPOINT_URL" ]; then echo "Error: SCDF_TOKEN_URL not set." >&2; return 1; fi
  echo "Authenticating with token URL: $TOKEN_ENDPOINT_URL"
  if [ -z "$CF_CLIENT_ID" ] || [ -z "$CF_CLIENT_SECRET" ]; then echo "Error: Client ID/Secret empty." >&2; return 1; fi
  local response; response=$(curl -s -k -u "$CF_CLIENT_ID:$CF_CLIENT_SECRET" -X POST "$TOKEN_ENDPOINT_URL" -H "Content-Type: application/x-www-form-urlencoded" -d "grant_type=client_credentials")
  local token; if command -v jq >/dev/null 2>&1; then token=$(echo "$response" | jq -r .access_token); else token=$(echo "$response" | grep -o '"access_token":"[^"]*' | sed -n 's/"access_token":"\([^"]*\).*/\1/p'); fi
  if [ -z "$token" ] || [ "$token" == "null" ]; then echo "Failed to get new access token. Response: $response" >&2; return 1; fi
  echo "$token" > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"; echo "Authentication successful. New token saved to $TOKEN_FILE"
  local project_root="$SCRIPT_DIR/.."; local gitignore_file="$project_root/.gitignore"; local token_file_entry=".cf_token"
  if [ ! -f "$gitignore_file" ]; then echo "$token_file_entry" > "$gitignore_file"; echo "Created .gitignore and added $token_file_entry"; else if ! grep -q -x "$token_file_entry" "$gitignore_file"; then echo "$token_file_entry" >> "$gitignore_file"; echo "Added $token_file_entry to .gitignore"; fi; fi
  return 0
}

is_app_registered_in_test_script() {
  # ... (previous implementation from last update)
  local app_type="$1"; local app_name="$2"; local current_token="$3"; local scdf_endpoint="$4"
  local response_code; response_code=$(curl -s -k -w "%{http_code}" -H "Authorization: Bearer $current_token" "${scdf_endpoint}/apps/${app_type}/${app_name}" -o /dev/null)
  if [ "$response_code" == "200" ]; then return 0; elif [ "$response_code" == "404" ]; then return 1; else return 1; fi
}

register_hdfs_watcher_app() {
  # ... (previous implementation from last update, ensuring app_name is "hdfsWatcher")
  local current_token="$1"; local scdf_endpoint="$2"; local app_type="source"; local app_name="hdfsWatcher"
  local app_uri="https://github.com/dbbaskette/hdfsWatcher/releases/download/v0.2.0/hdfsWatcher-0.2.0.jar"; local force_registration="true"
  echo "--- ${app_name} App Registration ---"

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
  local data="uri=${app_uri}&force=${force_registration}"; local response_body_file; response_body_file=$(mktemp); local response_code
  response_code=$(curl -s -k -w "%{http_code}" -X POST -H "Authorization: Bearer $current_token" -H "Content-Type: application/x-www-form-urlencoded" -d "$data" "${scdf_endpoint}/apps/${app_type}/${app_name}" -o "$response_body_file")
  local response_body; response_body=$(cat "$response_body_file"); rm -f "$response_body_file"
  if [ "$response_code" == "201" ] || [ "$response_code" == "200" ]; then # 200 can also mean success for updates/force
    echo "Successfully registered $app_type app '$app_name' (HTTP $response_code)."
    # Add a brief pause or a loop to verify registration if needed, similar to the unregistration wait.
    return 0
  else
    echo "Error registering $app_type app '$app_name': HTTP $response_code." >&2; echo "Response body: $response_body" >&2; return 1;
  fi
}

# --- Stream Management Functions ---
destroy_stream() {
  local stream_name="$1"
  local current_token="$2"
  local scdf_endpoint="$3"

  echo "--- Destroying Stream: $stream_name ---"
  local deploy_response_code
  deploy_response_code=$(curl -s -k -w "%{http_code}" -X DELETE \
    -H "Authorization: Bearer $current_token" \
    "${scdf_endpoint}/streams/deployments/${stream_name}" -o /dev/null)

  if [ "$deploy_response_code" == "200" ]; then
    echo "Stream deployment '$stream_name' deleted successfully."
  elif [ "$deploy_response_code" == "404" ]; then
    echo "Info: Stream deployment '$stream_name' not found, no need to delete."
  else
    echo "Warning: Failed to delete stream deployment '$stream_name' or it didn't exist (HTTP $deploy_response_code)."
  fi

  sleep 1 # Give SCDF a moment

  local def_response_code
  def_response_code=$(curl -s -k -w "%{http_code}" -X DELETE \
    -H "Authorization: Bearer $current_token" \
    "${scdf_endpoint}/streams/definitions/${stream_name}" -o /dev/null)

  if [ "$def_response_code" == "200" ]; then
    echo "Stream definition '$stream_name' deleted successfully."
  elif [ "$def_response_code" == "404" ]; then
    echo "Info: Stream definition '$stream_name' not found, no need to delete."
  else
    echo "Warning: Failed to delete stream definition '$stream_name' or it didn't exist (HTTP $def_response_code)."
  fi
  echo "Stream destruction complete for '$stream_name'."
}

create_stream_definition_api() {
  local stream_name="$1"
  local dsl_definition="$2"
  local current_token="$3"
  local scdf_endpoint="$4"

  echo "--- Creating Stream Definition: $stream_name ---"
  echo "Definition DSL: $dsl_definition"
  
  local response_body_file
  response_body_file=$(mktemp)
  local response_code
  response_code=$(curl -s -k -w "%{http_code}" -X POST \
    -H "Authorization: Bearer $current_token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "name=${stream_name}&definition=${dsl_definition}&description=Test HDFS Watcher to Log stream" \
    "${scdf_endpoint}/streams/definitions" -o "$response_body_file")

  local response_body
  response_body=$(cat "$response_body_file")
  rm -f "$response_body_file"

  if [ "$response_code" == "201" ]; then
    echo "Stream definition '$stream_name' created successfully (HTTP $response_code)."
    return 0
  else
    echo "Error creating stream definition '$stream_name': HTTP $response_code." >&2
    echo "Response body: $response_body" >&2
    return 1
  fi
}

deploy_stream_api() {
  local stream_name="$1"
  local deployment_properties_str="$2" # Comma-separated key=value pairs
  local current_token="$3"
  local scdf_endpoint="$4"

  echo "--- Deploying Stream: $stream_name ---"
  
  local deploy_json
  if ! deploy_json=$(build_json_from_props "$deployment_properties_str"); then
      echo "Error: Failed to build JSON from properties: $deployment_properties_str" >&2
      return 1
  fi
  echo "Deployment Properties JSON: $deploy_json"

  local response_body_file
  response_body_file=$(mktemp)
  local response_code
  response_code=$(curl -s -k -w "%{http_code}" -X POST \
    -H "Authorization: Bearer $current_token" \
    -H "Content-Type: application/json" \
    -d "$deploy_json" \
    "${scdf_endpoint}/streams/deployments/${stream_name}" -o "$response_body_file")
  
  local response_body
  response_body=$(cat "$response_body_file")
  rm -f "$response_body_file"

  if [ "$response_code" == "201" ]; then
    echo "Stream '$stream_name' deployed successfully (HTTP $response_code)."
    return 0
  else
    echo "Error deploying stream '$stream_name': HTTP $response_code." >&2
    echo "Response body: $response_body" >&2
    return 1
  fi
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
  # Check for HDFS variables (needed for deployment properties)
  if [ -z "${HDFS_URI:-}" ]; then echo "Error: HDFS_URI is not set (expected in create_stream.properties or scdf_env.properties)." >&2; return 1; fi
  if [ -z "${HDFS_USER:-}" ]; then echo "Error: HDFS_USER is not set." >&2; return 1; fi
  if [ -z "${HDFS_REMOTE_DIR:-}" ]; then echo "Error: HDFS_REMOTE_DIR is not set." >&2; return 1; fi
  if [ -z "${HDFSWATCHER_PSEUDOOP:-}" ]; then echo "Error: HDFSWATCHER_PSEUDOOP is not set." >&2; return 1; fi
  if [ -z "${HDFSWATCHER_LOCAL_STORAGE_PATH:-}" ]; then echo "Error: HDFSWATCHER_LOCAL_STORAGE_PATH is not set." >&2; return 1; fi
  if [ -z "${HDFSWATCHER_OUTPUT_STREAM_NAME:-}" ]; then echo "Error: HDFSWATCHER_OUTPUT_STREAM_NAME is not set." >&2; return 1; fi


  if ! get_oauth_token; then echo "Authentication failed. Exiting." >&2; return 1; fi

  local token; token=$(cat "$TOKEN_FILE") 
  echo "Successfully authenticated to Cloud Foundry (or used existing valid token)."

  local final_validation_url="$SCDF_CF_URL/about"
  echo "Verifying token with SCDF endpoint: $final_validation_url"
  local validation_code; validation_code=$(curl -s -k -w "%{http_code}" -H "Authorization: Bearer $token" "$final_validation_url" -o /dev/null)
  if [ "$validation_code" == "200" ]; then echo "Token confirmed valid. Connected to SCDF endpoint (HTTP $validation_code from $final_validation_url)."; else echo "Error: Post-authentication token validation failed (HTTP $validation_code from $final_validation_url)." >&2; return 1; fi

  if ! register_hdfs_watcher_app "$token" "$SCDF_CF_URL"; then echo "Failed to register hdfsWatcher app. Exiting." >&2; return 1; fi
  echo "hdfsWatcher app registration step completed."

  # --- Stream Creation and Deployment ---
  local test_stream_name="hdfsWatcherLogTest"
  # Define a clean Stream DSL
  local stream_dsl="hdfsWatcher | log"
  
  # 1. Destroy existing stream (if any)
  if ! destroy_stream "$test_stream_name" "$token" "$SCDF_CF_URL"; then
      echo "Warning: Could not fully destroy existing stream '$test_stream_name'. Proceeding with caution."
  fi

  # 2. Create new stream definition
  if ! create_stream_definition_api "$test_stream_name" "$stream_dsl" "$token" "$SCDF_CF_URL"; then
      echo "Failed to create stream definition for '$test_stream_name'. Exiting." >&2
      return 1
  fi
  echo "Stream definition '$test_stream_name' created."

  # 3. Prepare and deploy the stream
  local deploy_props_list=(
    # --- Properties for hdfsWatcher app ---
    "app.hdfsWatcher.hdfswatcher.hdfsUser=${HDFS_USER}"
    "app.hdfsWatcher.hdfswatcher.hdfsUri=${HDFS_URI}"
    "app.hdfsWatcher.hdfswatcher.hdfsPath=${HDFS_REMOTE_DIR}"
    "app.hdfsWatcher.hdfswatcher.pseudoop=${HDFSWATCHER_PSEUDOOP}"
    # Ensure a writable temporary path for Cloud Foundry for this test stream
    "app.hdfsWatcher.hdfswatcher.local-storage-path=/tmp/hdfsWatcherLogTest-temp"
    "app.hdfsWatcher.hdfswatcher.pollInterval=10000"
    "app.hdfsWatcher.spring.cloud.stream.bindings.output.destination=${HDFSWATCHER_OUTPUT_STREAM_NAME}"
    "app.hdfsWatcher.spring.cloud.stream.bindings.output.group=${test_stream_name}"
    "app.hdfsWatcher.logging.level.org.springframework.cloud.stream.app.hdfs.source.HdfsSourceProperties=DEBUG"
    # Management properties (optional, SCDF often auto-configures metrics tags)
    "app.hdfsWatcher.management.endpoints.web.exposure.include=health,info,bindings"
    
    # Cloud Foundry Java 17 environment variable for hdfsWatcher
    "deployer.hdfsWatcher.cloudfoundry.environmentVariables=JBP_CONFIG_OPEN_JDK_JRE={\\\"jre\\\":{\\\"version\\\":\\\"17.+\\\"}}"
    
    # --- Properties for log app ---
    "app.log.spring.cloud.stream.bindings.input.destination=${HDFSWATCHER_OUTPUT_STREAM_NAME}"
    "app.log.spring.cloud.stream.bindings.input.group=${test_stream_name}"
    "app.log.logging.level.root=INFO"
    "app.log.management.endpoints.web.exposure.include=health,info,bindings"
  )
  # Conditionally add webhdfsUri for hdfsWatcher
  if [ -n "${HDFS_WEBHDFS_URI:-}" ]; then
    deploy_props_list+=("app.hdfsWatcher.hdfswatcher.webhdfsUri=${HDFS_WEBHDFS_URI}")
  fi
  local deployment_properties_str
  IFS=',' deployment_properties_str="${deploy_props_list[*]}"

  echo "ACTUAL DEPLOYMENT PROPERTIES: $deployment_properties_str"

  if ! deploy_stream_api "$test_stream_name" "$deployment_properties_str" "$token" "$SCDF_CF_URL"; then
      echo "Failed to deploy stream '$test_stream_name'. Exiting." >&2
      return 1
  fi
  echo "Stream '$test_stream_name' deployment initiated."
  # --- End Stream Creation and Deployment ---

  echo "Authentication, app registration, and stream deployment flow complete."
  echo "Test stream '$test_stream_name' (DSL: $stream_dsl) should be deploying."
  echo "Monitor SCDF UI for status. HDFS Location: ${HDFS_URI}${HDFS_REMOTE_DIR}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  test_hdfs_app
fi