#!/bin/bash
# rag_streams.sh - Enhanced modular SCDF stream management

# Import logging functions if they exist
if declare -f log_info >/dev/null 2>&1; then
    LOGGING_AVAILABLE=true
else
    LOGGING_AVAILABLE=false
    # Fallback logging functions
    log_info() { echo "[INFO] $1" >&2; }
    log_error() { echo "[ERROR] $1" >&2; }
    log_success() { echo "[SUCCESS] $1" >&2; }
    log_warn() { echo "[WARN] $1" >&2; }
    log_debug() { echo "[DEBUG] $1" >&2; }
fi

# Enhanced curl wrapper for streams
stream_curl_with_retry() {
    local url="$1"
    shift
    local curl_args=("$@")
    local context="STREAM_API"
    local max_retries=3
    local delay=2
    
    for attempt in $(seq 1 $max_retries); do
        log_debug "Stream API call attempt $attempt: $url" "$context"
        
        if curl -s --max-time 30 --connect-timeout 10 --fail-with-body "${curl_args[@]}" "$url"; then
            log_debug "Stream API call succeeded on attempt $attempt" "$context"
            return 0
        fi
        
        local exit_code=$?
        log_warn "Stream API call attempt $attempt failed with exit code $exit_code" "$context"
        
        if [[ $attempt -lt $max_retries ]]; then
            log_info "Retrying in ${delay}s..." "$context"
            sleep $delay
            delay=$((delay * 2))
        fi
    done
    
    log_error "Stream API call failed after $max_retries attempts" "$context"
    return 1
}

# Installs Hadoop HDFS into local Kubernetes (calls resources/hdfs.yaml)
rag_install_hdfs_k8s() {
  echo "[INFO] Installing Hadoop HDFS into local Kubernetes..."
  if ! kubectl version --request-timeout=5s >/dev/null 2>&1; then
    echo "[ERROR] Unable to connect to Kubernetes cluster with kubectl. Is your cluster running and kubeconfig set?"
    return 1
  fi
  if [[ ! -f resources/hdfs.yaml ]]; then
    echo "[ERROR] resources/hdfs.yaml not found. Cannot deploy HDFS."
    return 1
  fi
  kubectl delete -f resources/hdfs.yaml --ignore-not-found
  kubectl apply -f resources/hdfs.yaml || { echo "[ERROR] Failed to apply HDFS YAML."; return 1; }
  echo "[INFO] Waiting for HDFS pods to be ready..."
  # Wait for all pods with 'hdfs' in the name to be ready (timeout 180s)
  for i in {1..36}; do
    ready=$(kubectl get pods -l app=hdfs -o json 2>/dev/null | jq -r '.items[] | select(.status.phase=="Running") | .metadata.name' | wc -l)
    total=$(kubectl get pods -l app=hdfs -o json 2>/dev/null | jq -r '.items | length')
    if [[ "$ready" -ge 1 && "$ready" -eq "$total" ]]; then
      echo "[SUCCESS] HDFS deployed and all pods are running."
      return 0
    fi
    sleep 5
  done
  echo "[ERROR] Timed out waiting for HDFS pods to be ready."
  return 1
}

# Enhanced stream deletion with error handling
rag_delete_stream() {
  local stream_name="$1"
  local token="$2"
  local scdf_url="$3"
  local context="DELETE_STREAM"
  
  if [[ -z "$stream_name" || -z "$token" || -z "$scdf_url" ]]; then
      log_error "Missing required parameters for stream deletion" "$context"
      return 1
  fi
  
  log_info "Deleting stream: $stream_name" "$context"
  
  # First check if the stream exists
  local check_resp
  check_resp=$(curl -s -k -H "Authorization: Bearer $token" "$scdf_url/streams/definitions/$stream_name")
  
  if [[ -z "$check_resp" || "$check_resp" == "null" ]] || echo "$check_resp" | jq -e '._embedded.errors' >/dev/null 2>&1; then
      log_debug "Stream '$stream_name' does not exist, skipping deletion" "$context"
      return 0
  fi
  
  # Stream exists, proceed with deletion
  resp=$(curl -s -k -X DELETE \
      -H "Authorization: Bearer $token" \
      -H "Accept: application/json" \
      "$scdf_url/streams/definitions/$stream_name")
  
  local curl_exit=$?
  if [[ $curl_exit -ne 0 ]]; then
      log_error "Network error during stream deletion (exit code: $curl_exit)" "$context"
      return 1
  fi
  
  # Parse and show feedback
  if echo "$resp" | jq -e '._embedded.errors' >/dev/null 2>&1; then
    msg=$(echo "$resp" | jq -r '._embedded.errors[]?.message')
      log_error "Stream '$stream_name' NOT deleted: $msg" "$context"
    return 1
  elif echo "$resp" | jq -e '.message' >/dev/null 2>&1 && [[ $(echo "$resp" | jq -r '.message') != "null" ]]; then
    # Some SCDFs return a top-level 'message' for success
    msg=$(echo "$resp" | jq -r '.message')
      log_success "$msg" "$context"
    return 0
  else
      log_success "Stream '$stream_name' deleted successfully" "$context"
    return 0
  fi
}

# Creates a stream definition (does NOT deploy)
rag_create_stream_definition() {
  local stream_name="$1"
  local stream_def="$2"
  local token="$3"
  local scdf_url="$4"
  local encoded_dsl
  # URL-encode the DSL
  if ! encoded_dsl=$(jq -rn --arg dsl "$stream_def" '$dsl | @uri'); then
    echo "Error: Failed to encode DSL definition" >&2
    return 1
  fi
  echo "Creating stream definition: $stream_name"
  resp=$(curl -s -k -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/x-www-form-urlencoded;charset=UTF-8" \
    -d "name=${stream_name}&definition=${encoded_dsl}&description=Created+via+API" \
    "$scdf_url/streams/definitions")
  # Parse and show feedback
  if echo "$resp" | jq -e '._embedded.errors' >/dev/null 2>&1; then
    msg=$(echo "$resp" | jq -r '._embedded.errors[]?.message')
    echo "[ERROR] Stream definition NOT created: $msg"
    return 1
  else
    echo "[SUCCESS] Stream definition '$stream_name' created."
    return 0
  fi
}

# Deploys an existing stream definition
rag_deploy_stream() {
  local stream_name="$1"
  local token="$2"
  local scdf_url="$3"
  
  # Check if configuration is loaded
  if [ "$CONFIG_LOADED" != "true" ]; then
      log_error "Configuration not loaded. Call load_configuration first." "DEPLOY_STREAM"
      return 1
  fi
  
  echo "Deploying stream: $stream_name"
  
  # Build deployment properties JSON from config
  local deploy_props_json="{}"
  local context="DEPLOY_STREAM"
  
  # Get deployment properties using the specialized function
  local props
  if props=$(get_deployment_properties "${CONFIG_ENVIRONMENT:-default}"); then
      log_info "Using deployment properties from config.yaml:" "$context"
      
      # Show the properties being used
      echo "$props" | while IFS= read -r line; do
          if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
              local key="${BASH_REMATCH[1]}"
              local value="${BASH_REMATCH[2]}"
              if [ -n "$key" ]; then
                  echo "  $key=$value"
              fi
          fi
      done
      
      # Convert properties to JSON using jq
      local temp_file
      temp_file=$(mktemp)
      echo "$props" > "$temp_file"
      
      # Build JSON object using jq
      # Use POSIX-compatible awk to split only on the first equals sign
      deploy_props_json=$(awk '{split($0, arr, "="); key=arr[1]; value=substr($0, index($0,"=")+1); print key "=" value}' "$temp_file" | \
          jq -R -s 'split("\n") | map(select(length > 0)) | map(split("=")) | map({key: .[0], value: (.[1:] | join("="))}) | from_entries')
      
      rm -f "$temp_file"
      
      if [ -z "$deploy_props_json" ] || [ "$deploy_props_json" = "null" ]; then
          log_debug "No valid properties found, using empty deployment config" "$context"
          deploy_props_json="{}"
      fi
  else
      log_warn "No deployment properties found in config.yaml. Proceeding with defaults." "$context"
    deploy_props_json="{}"
  fi
  
  resp=$(curl -s -k -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$deploy_props_json" \
    "$scdf_url/streams/deployments/$stream_name")
  # Parse and show feedback
  if echo "$resp" | jq -e '._embedded.errors' >/dev/null 2>&1; then
    msg=$(echo "$resp" | jq -r '._embedded.errors[]?.message')
    echo "[ERROR] Stream '$stream_name' NOT deployed: $msg"
    return 1
  else
    echo "[SUCCESS] Stream '$stream_name' deployed."
    return 0
  fi
}

# Show stream and app status
rag_show_stream_status() {
  local stream_name="$1"
  local token="$2"
  local scdf_url="$3"
  
  echo "Stream: $stream_name"
  resp=$(curl -s -k -H "Authorization: Bearer $token" "$scdf_url/streams/deployments/$stream_name")
  if [[ -z "$resp" || "$resp" == "null" ]]; then
    echo "[ERROR] No deployment status found for stream '$stream_name'."
    return 1
  fi
  stream_status=$(echo "$resp" | jq -r '.state // .status // "unknown"')
  echo "Status: $stream_status"
  
  echo "App Statuses:"
  printf "%-18s %-12s %-10s\n" "App Name" "Type" "Status"
  echo "---------------------------------------------"
  local found=0
  # Try appStatuses
  if echo "$resp" | jq -e '.appStatuses.appStatusList' >/dev/null 2>&1; then
    found=1
    echo "$resp" | jq -r '.appStatuses.appStatusList[] | [.name, .type, .state] | @tsv' | while IFS=$'\t' read -r name type state; do
      printf "%-18s %-12s %-10s\n" "$name" "$type" "$state"
    done
  # Try applications
  elif echo "$resp" | jq -e '.applications' >/dev/null 2>&1; then
    found=1
    echo "$resp" | jq -r '.applications[] | [.name, "unknown", (.state // .status // "unknown")] | @tsv' | while IFS=$'\t' read -r name type state; do
      printf "%-18s %-12s %-10s\n" "$name" "$type" "$state"
    done
  fi
  # If neither, try runtime/apps for more details
  if [[ $found -eq 0 ]]; then
    runtime_resp=$(curl -s -k -H "Authorization: Bearer $token" "$scdf_url/runtime/apps")
    # App type lookup (portable for Bash v3)
    if echo "$runtime_resp" | jq -e '._embedded.appStatusResourceList' >/dev/null 2>&1; then
      echo "$runtime_resp" | jq -r '._embedded.appStatusResourceList[] | [.name, .state] | @tsv' | while IFS=$'\t' read -r name state; do
        case "$name" in
          hdfsWatcher) type="source" ;;
          textProc)    type="processor" ;;
          embedProc)   type="processor" ;;
          log)         type="sink" ;;
          *)           type="unknown" ;;
        esac
        printf "%-18s %-12s %-10s\n" "$name" "$type" "$state"
      done
    elif echo "$runtime_resp" | jq -e '.content' >/dev/null 2>&1; then
      echo "$runtime_resp" | jq -r --arg stream "$stream_name" '.content[] | select(.deploymentId | test($stream)) | [.name, .type, .state] | @tsv' | while IFS=$'\t' read -r name type state; do
        printf "%-18s %-12s %-10s\n" "$name" "$type" "$state"
      done
    else
      echo "[No app status details available]"
    fi
  fi
  echo "---------------------------------------------"
}

# Combined: create definition and deploy
rag_create_stream() {
  local stream_name="$1"
  local stream_def="$2"
  local token="$3"
  local scdf_url="$4"
  # Use form-urlencoded for both steps
  rag_create_stream_definition "$stream_name" "$stream_def" "$token" "$scdf_url"
  rag_deploy_stream "$stream_name" "$token" "$scdf_url"
}
