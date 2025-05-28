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
    return 0
  else
    echo "Error registering $app_type app '$app_name': HTTP $response_code." >&2; echo "Response body: $response_body" >&2; return 1;
  fi
}

# --- Register textProc App ---
register_text_proc_app() {
  local current_token="$1"; local scdf_endpoint="$2"; local app_type="processor"; local app_name="textProc"
  local app_uri="https://github.com/dbbaskette/textProc/releases/download/v0.0.1/textProc-0.0.1-SNAPSHOT.jar"; local force_registration="true"
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
  # URL encode the definition
  local encoded_dsl_definition
  if command -v jq >/dev/null 2>&1; then
    encoded_dsl_definition=$(jq -sRr @uri <<< "$dsl_definition")
  else
    # Basic URL encoding (may not cover all edge cases like jq's @uri)
    encoded_dsl_definition=$(echo -n "$dsl_definition" | awk 'BEGIN {
        while ((getline > 0) == 1) {
            for (i=1; i<=length($0); ++i) {
                c = substr($0, i, 1)
                if (c ~ /[a-zA-Z0-9._~-]/) {
                    printf "%s", c
                } else {
                    printf "%%%02X", ord(c)
                }
            }
        }
    }')
  fi

  response_code=$(curl -s -k -w "%{http_code}" -X POST \
    -H "Authorization: Bearer $current_token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "name=${stream_name}" \
    --data-urlencode "definition=${dsl_definition}" \
    --data-urlencode "description=Test HDFS Watcher to Log stream" \
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
  --data-binary "$deploy_json" \
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

  # Clean potentially problematic variables of trailing newlines/carriage returns
  # It's good practice to clean variables that might come from files or complex assignments.
  # Use a temporary variable for cleaning to avoid modifying the original if it's needed elsewhere
  local clean_HDFS_USER="$(echo -n "${HDFS_USER}" | tr -d '\n\r')"
  local clean_HDFS_URI="$(echo -n "${HDFS_URI}" | tr -d '\n\r')"
  local clean_HDFS_REMOTE_DIR="$(echo -n "${HDFS_REMOTE_DIR}" | tr -d '\n\r')"
  local clean_HDFSWATCHER_PSEUDOOP="$(echo -n "${HDFSWATCHER_PSEUDOOP}" | tr -d '\n\r')"
  local clean_HDFSWATCHER_LOCAL_STORAGE_PATH="$(echo -n "${HDFSWATCHER_LOCAL_STORAGE_PATH}" | tr -d '\n\r')"
  local clean_HDFSWATCHER_OUTPUT_STREAM_NAME="$(echo -n "${HDFSWATCHER_OUTPUT_STREAM_NAME}" | tr -d '\n\r')"
  local clean_HDFS_WEBHDFS_URI="$(echo -n "${HDFS_WEBHDFS_URI:-}" | tr -d '\n\r')" # Handle optional

  # Use a cleaned stream name for SCDF operations
  local STREAM_NAME="hdfsWatcherLogTest"
  local clean_STREAM_NAME="$(echo -n "${STREAM_NAME}" | tr -d '\n\r')"

  echo "Successfully authenticated to Cloud Foundry (or used existing valid token)."

  local final_validation_url="$SCDF_CF_URL/about"
  echo "Verifying token with SCDF endpoint: $final_validation_url"
  local validation_code; validation_code=$(curl -s -k -w "%{http_code}" -H "Authorization: Bearer $token" "$final_validation_url" -o /dev/null)
  if [ "$validation_code" == "200" ]; then echo "Token confirmed valid. Connected to SCDF endpoint (HTTP $validation_code from $final_validation_url)."; else echo "Error: Post-authentication token validation failed (HTTP $validation_code from $final_validation_url)." >&2; return 1; fi

  if ! register_hdfs_watcher_app "$token" "$SCDF_CF_URL"; then echo "Failed to register hdfsWatcher app. Exiting." >&2; return 1; fi
  echo "hdfsWatcher app registration step completed."
  if ! register_text_proc_app "$token" "$SCDF_CF_URL"; then echo "Failed to register textProc app. Exiting." >&2; return 1; fi
  echo "textProc app registration step completed."

  # --- Stream Creation and Deployment ---
  local stream_dsl="hdfsWatcher | textProc | log"  # Renamed from STREAM_DEF for clarity

  # 1. Destroy existing stream (if any) - already done by `destroy_stream` called earlier in some flows,
  # but good to ensure it's clean before creating. The `destroy_stream` in this file is robust.
  if ! destroy_stream "$clean_STREAM_NAME" "$token" "$SCDF_CF_URL"; then
      echo "Warning: Could not fully destroy existing stream '$STREAM_NAME' during test_hdfs_app. Proceeding with caution."
  fi

  # 2. Create new stream definition using the helper function
  if ! create_stream_definition_api "$clean_STREAM_NAME" "$stream_dsl" "$token" "$SCDF_CF_URL"; then
      echo "Failed to create stream definition for '$clean_STREAM_NAME'. Exiting." >&2
      return 1
  fi
  echo "Stream definition '$STREAM_NAME' created."

  # 3. Prepare and deploy the stream
  DEPLOY_PROPS=""
  # DEPLOY_PROPS+=",deployer.hadoop-hdfs.kubernetes.environmentVariables=HADOOP_USER_NAME=hdfs"
  # DEPLOY_PROPS+=",app.hadoop-hdfs.hadoop.security.authentication=simple"
  # DEPLOY_PROPS+=",app.hadoop-hdfs.hadoop.security.authorization=false"
  DEPLOY_PROPS+=",app.hdfsWatcher.hdfsUser=${HDFS_USER}"
  DEPLOY_PROPS+=",app.hdfsWatcher.hdfsUri=${HDFS_URI}"
  DEPLOY_PROPS+=",app.hdfsWatcher.hdfsPath=${HDFS_REMOTE_DIR}"
  DEPLOY_PROPS+=",app.hdfsWatcher.hdfsWatcher.pseudoop=${HDFSWATCHER_PSEUDOOP}"
  # Set Java version for buildpack configuration (Cloud Foundry)
  #DEPLOY_PROPS+=",deployer.hdfsWatcher.cloudfoundry.environmentVariables.JBP_CONFIG_OPEN_JDK_JRE={jre: { version: 21.+ }}"
  DEPLOY_PROPS+=",deployer.hdfsWatcher.cloudfoundry.env.JBP_CONFIG_OPEN_JDK_JRE={ jre: { version: 21.+ } }"

  # Ensure a writable temporary path for Cloud Foundry for this test stream
  DEPLOY_PROPS+=",app.hdfsWatcher.hdfsWatcher.local-storage-path=${HDFSWATCHER_LOCAL_STORAGE_PATH}"
  DEPLOY_PROPS+=",app.hdfsWatcher.hdfsWatcher.pollInterval=10000" # Assuming this literal is clean
  DEPLOY_PROPS+=",app.hdfsWatcher.spring.profiles.active=scdf"  
  DEPLOY_PROPS+=",app.hdfsWatcher.spring.cloud.config.enabled=false"  
  DEPLOY_PROPS+=",app.hdfsWatcher.spring.cloud.stream.bindings.output.destination=hdfswatcher-textproc"
  DEPLOY_PROPS+=",app.hdfsWatcher.spring.cloud.stream.bindings.output.group=${STREAM_NAME}"
  DEPLOY_PROPS+=",app.hdfsWatcher.logging.level.org.springframework.cloud.stream=DEBUG"
  DEPLOY_PROPS+=",app.hdfsWatcher.logging.level.org.springframework.integration=DEBUG"
  DEPLOY_PROPS+=",app.hdfsWatcher.logging.level.org.springframework.cloud.stream.binder.rabbit=DEBUG"
  DEPLOY_PROPS+=",app.hdfsWatcher.logging.level.org.springframework.cloud.stream.app.hdfsWatcher.source=DEBUG"
  DEPLOY_PROPS+=",app.hdfsWatcher.logging.level.org.apache.hadoop=DEBUG"

  # textProc processor
  DEPLOY_PROPS+=",app.textProc.spring.profiles.active=scdf"
  DEPLOY_PROPS+=",app.textProc.spring.cloud.function.definition=textProc"
  DEPLOY_PROPS+=",app.textProc.spring.cloud.stream.bindings.textProc-in-0.destination=hdfswatcher-textproc"
  DEPLOY_PROPS+=",app.textProc.spring.cloud.stream.bindings.textProc-in-0.group=${STREAM_NAME}"
  DEPLOY_PROPS+=",app.textProc.spring.cloud.stream.bindings.textProc-out-0.destination=textproc-to-log"
  DEPLOY_PROPS+=",app.textProc.cloudfoundry.health-check-type=process"

  DEPLOY_PROPS+=",deployer.textProc.cloudfoundry.env.JBP_CONFIG_OPEN_JDK_JRE={ jre: { version: 21.+ } }"


  # Conditionally add webhdfsUri for hdfsWatcher
  if [ -n "${HDFS_WEBHDFS_URI:-}" ]; then
    DEPLOY_PROPS+=",app.hdfsWatcher.hdfsWatcher.webhdfsUri=${clean_HDFS_WEBHDFS_URI}"
  fi
  # Cloud Foundry Java 17 environment variable for hdfsWatcher
  #DEPLOY_PROPS+=",deployer.hdfsWatcher.cloudfoundry.environmentVariables=JBP_CONFIG_OPEN_JDK_JRE={\\\"jre\\\":{\\\"version\\\":\\\"17.+\\\"}}"

  # --- Properties for log app ---
  DEPLOY_PROPS+=",app.log.spring.cloud.stream.bindings.input.destination=textproc-to-log"
  DEPLOY_PROPS+=",app.log.spring.cloud.stream.bindings.input.group=${STREAM_NAME}"
  DEPLOY_PROPS+=",app.log.logging.level.root=INFO" # Assuming this literal is clean

  # Aggressively clean the entire DEPLOY_PROPS string of newlines and carriage returns
  DEPLOY_PROPS="$(echo -n "$DEPLOY_PROPS" | tr -d '\n\r')"

  # Debug: Output the constructed DEPLOY_PROPS string
  echo "[DEBUG] Constructed DEPLOY_PROPS string: $DEPLOY_PROPS"
  
  # 4. Deploy the stream using the helper function
  if ! deploy_stream_api "$STREAM_NAME" "$DEPLOY_PROPS" "$token" "$SCDF_CF_URL"; then
      echo "Failed to deploy stream '$STREAM_NAME'. Exiting." >&2
      return 1
  fi
  echo "Stream '$STREAM_NAME' deployment initiated."
  echo "Test stream '$STREAM_NAME' (DSL: $stream_dsl) should be deploying."
  echo "Monitor SCDF UI for status. HDFS Location (if applicable): ${clean_HDFS_URI}${clean_HDFS_REMOTE_DIR}"
} # Correct placement for the end of test_hdfs_app function

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  test_hdfs_app
fi