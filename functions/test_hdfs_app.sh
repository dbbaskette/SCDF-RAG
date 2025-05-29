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
  local app_uri="https://github.com/dbbaskette/textProc/releases/download/v0.0.1/textProc-0.0.1-SNAPSHOT.jar"
 _reregister_app_cf_auth "processor" "textProc" "$app_uri" "$current_token" "$scdf_endpoint"
}

# --- Register embedProc App ---
register_embed_proc_app() {
  local current_token="$1"; local scdf_endpoint="$2"
  local app_uri="https://github.com/dbbaskette/embedProc/releases/download/v0.0.3/embedProc-0.0.3.jar"
  _reregister_app_cf_auth "processor" "embedProc" "$app_uri" "$current_token" "$scdf_endpoint"
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

  # Note: The build_json_from_props function handles trimming of property values.
  # If variables are used elsewhere and need explicit cleaning, it should be done there.

  # Use a cleaned stream name for SCDF operations
  local STREAM_NAME="hdfsWatcherLogTest" # This is a literal, no need to clean with tr

  echo "Successfully authenticated to Cloud Foundry (or used existing valid token)."

  local final_validation_url="$SCDF_CF_URL/about"
  echo "Verifying token with SCDF endpoint: $final_validation_url"
  local validation_code; validation_code=$(curl -s -k -w "%{http_code}" -H "Authorization: Bearer $token" "$final_validation_url" -o /dev/null)
  if [ "$validation_code" == "200" ]; then echo "Token confirmed valid. Connected to SCDF endpoint (HTTP $validation_code from $final_validation_url)."; else echo "Error: Post-authentication token validation failed (HTTP $validation_code from $final_validation_url)." >&2; return 1; fi

  if ! register_hdfs_watcher_app "$token" "$SCDF_CF_URL"; then echo "Failed to register hdfsWatcher app. Exiting." >&2; return 1; fi
  echo "hdfsWatcher app registration step completed."
  if ! register_text_proc_app "$token" "$SCDF_CF_URL"; then echo "Failed to register textProc app. Exiting." >&2; return 1; fi
  echo "textProc app registration step completed."
  
  if ! register_embed_proc_app "$token" "$SCDF_CF_URL"; then echo "Failed to register embedProc app. Exiting." >&2; return 1; fi
  echo "embedProc app registration step completed."

  # --- Stream Creation and Deployment ---
  local stream_dsl="hdfsWatcher | textProc | embedProc | log"  # Stream definition with embedProc added

  # 1. Destroy existing stream (if any) - already done by `destroy_stream` called earlier in some flows,
  # but good to ensure it's clean before creating. The `destroy_stream` in this file is robust.
  if ! destroy_stream "$STREAM_NAME" "$token" "$SCDF_CF_URL"; then
      echo "Warning: Could not fully destroy existing stream '$STREAM_NAME' during test_hdfs_app. Proceeding with caution."
  fi

  # 2. Create new stream definition using the helper function
  if ! create_stream_definition_api "$STREAM_NAME" "$stream_dsl" "$token" "$SCDF_CF_URL"; then
      echo "Failed to create stream definition for '$STREAM_NAME'. Exiting." >&2
      return 1
  fi
  echo "Stream definition '$STREAM_NAME' created."

  # 3. Prepare and deploy the stream
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
  deploy_props_array+=("app.hdfsWatcher.hdfsWatcher.pollInterval=10000")
  deploy_props_array+=("app.hdfsWatcher.spring.profiles.active=scdf")
  deploy_props_array+=("app.hdfsWatcher.spring.cloud.config.enabled=false")
  deploy_props_array+=("app.hdfsWatcher.spring.cloud.stream.bindings.output.destination=hdfswatcher-textproc")
  deploy_props_array+=("app.hdfsWatcher.spring.cloud.stream.bindings.output.group=${STREAM_NAME}")
  deploy_props_array+=("app.hdfsWatcher.logging.level.org.springframework.cloud.stream=DEBUG")
  deploy_props_array+=("app.hdfsWatcher.logging.level.org.springframework.integration=DEBUG")
  deploy_props_array+=("app.hdfsWatcher.logging.level.org.springframework.cloud.stream.binder.rabbit=DEBUG")
  deploy_props_array+=("app.hdfsWatcher.logging.level.org.springframework.cloud.stream.app.hdfsWatcher.source=DEBUG")
  deploy_props_array+=("app.hdfsWatcher.logging.level.org.apache.hadoop=DEBUG")

  # textProc processor
  deploy_props_array+=("app.textProc.spring.profiles.active=scdf")
  deploy_props_array+=("app.textProc.spring.cloud.function.definition=textProc")
  deploy_props_array+=("app.textProc.spring.cloud.stream.bindings.textProc-in-0.destination=hdfswatcher-textproc")
  deploy_props_array+=("app.textProc.spring.cloud.stream.bindings.textProc-in-0.group=${STREAM_NAME}")
  deploy_props_array+=("app.textProc.spring.cloud.stream.bindings.textProc-out-0.destination=textproc-to-embed")
  # Management and health check properties
  deploy_props_array+=("app.textProc.spring.cloud.deployer.cloudfoundry.environment.management.server.port=8081")
  deploy_props_array+=("app.textProc.spring.cloud.deployer.cloudfoundry.environment.management.endpoints.web.exposure.include=health%2Cinfo")
  deploy_props_array+=("app.textProc.spring.cloud.deployer.cloudfoundry.environment.management.endpoint.health.probes.enabled=true")
  deploy_props_array+=("app.textProc.spring.cloud.deployer.cloudfoundry.environment.management.endpoint.health.show-details=always")
  deploy_props_array+=("deployer.textProc.cloudfoundry.health-check-type=http")
  deploy_props_array+=("deployer.textProc.cloudfoundry.health-check-http-endpoint=/actuator/health")
  deploy_props_array+=("deployer.textProc.cloudfoundry.env.JBP_CONFIG_OPEN_JDK_JRE={ jre: { version: 21.+} }")
  deploy_props_array+=("deployer.textProc.cloudfoundry.health-check-timeout=180")
  deploy_props_array+=("deployer.textProc.cloudfoundry.health-check-invocation-timeout=30")
  deploy_props_array+=("deployer.textProc.cloudfoundry.startup-timeout=300")

  # embedProc processor - with explicit buildpack and resource settings
  deploy_props_array+=("app.embedProc.spring.profiles.active=scdf")
  deploy_props_array+=("app.embedProc.spring.cloud.function.definition=embedProc")
  deploy_props_array+=("app.embedProc.spring.cloud.stream.bindings.embedProc-in-0.destination=textproc-to-embedproc")
  deploy_props_array+=("app.embedProc.spring.cloud.stream.bindings.embedProc-in-0.group=${STREAM_NAME}")
  deploy_props_array+=("app.embedProc.spring.cloud.stream.bindings.embedProc-out-0.destination=embedproc-to-log")
  
  # Management and health check properties
  deploy_props_array+=("app.embedProc.spring.cloud.deployer.cloudfoundry.environment.management.server.port=8081")
  deploy_props_array+=("app.embedProc.spring.cloud.deployer.cloudfoundry.environment.management.endpoints.web.exposure.include=health%2Cinfo")
  deploy_props_array+=("app.embedProc.spring.cloud.deployer.cloudfoundry.environment.management.endpoint.health.probes.enabled=true")
  deploy_props_array+=("app.embedProc.spring.cloud.deployer.cloudfoundry.environment.management.endpoint.health.show-details=always")
  deploy_props_array+=("deployer.embedProc.cloudfoundry.health-check-type=http")
  deploy_props_array+=("deployer.embedProc.cloudfoundry.health-check-http-endpoint=/actuator/health")
  deploy_props_array+=("deployer.embedProc.cloudfoundry.env.JBP_CONFIG_OPEN_JDK_JRE={ jre: { version: 21.+} }")
  deploy_props_array+=("deployer.embedProc.cloudfoundry.health-check-timeout=180")
  deploy_props_array+=("deployer.embedProc.cloudfoundry.health-check-invocation-timeout=30")
  deploy_props_array+=("deployer.embedProc.cloudfoundry.startup-timeout=300")
  
  # Service bindings - each service needs to be a separate property
  #deploy_props_array+=("deployer.embedProc.cloudfoundry.services[0]=embed-db")
  #deploy_props_array+=("deployer.embedProc.cloudfoundry.services[1]=embed-model")
  

  # Debug logging
  deploy_props_array+=("app.embedProc.logging.level.root=DEBUG")
  deploy_props_array+=("app.embedProc.logging.level.org.springframework=DEBUG")
  deploy_props_array+=("app.embedProc.logging.level.cloudfoundry-client=DEBUG")
  # Conditionally add webhdfsUri for hdfsWatcher
  if [ -n "${HDFS_WEBHDFS_URI:-}" ]; then
    deploy_props_array+=("app.hdfsWatcher.hdfsWatcher.webhdfsUri=${HDFS_WEBHDFS_URI:-}")
  fi

  # --- Properties for log app ---
  deploy_props_array+=("app.log.spring.cloud.stream.bindings.input.destination=embedproc-to-log")
  deploy_props_array+=("app.log.spring.cloud.stream.bindings.input.group=${STREAM_NAME}")
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
  
  # 4. Deploy the stream using the helper function
  if ! deploy_stream_api "$STREAM_NAME" "$deploy_props_str" "$token" "$SCDF_CF_URL"; then
      echo "Failed to deploy stream '$STREAM_NAME'. Exiting." >&2
      return 1
  fi
  echo "Stream '$STREAM_NAME' deployment initiated."
  echo "Test stream '$STREAM_NAME' (DSL: $stream_dsl) should be deploying."
  echo "Monitor SCDF UI for status. HDFS Location (if applicable): ${HDFS_URI}${HDFS_REMOTE_DIR}"
} # Correct placement for the end of test_hdfs_app function

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  test_hdfs_app
fi