#!/bin/bash
# rag_streams.sh - Modular SCDF stream management

# Deletes a stream by name
rag_delete_stream() {
  local stream_name="$1"
  local token="$2"
  local scdf_url="$3"
  local resp
  echo "Deleting stream: $stream_name"
  resp=$(curl -s -k -X DELETE -H "Authorization: Bearer $token" "$scdf_url/streams/definitions/$stream_name")
  # Parse and show feedback
  if echo "$resp" | jq -e '._embedded.errors' >/dev/null 2>&1; then
    local msg
    msg=$(echo "$resp" | jq -r '._embedded.errors[]?.message')
    echo "[ERROR] Stream '$stream_name' NOT deleted: $msg"
    return 1
  elif echo "$resp" | jq -e '.message' >/dev/null 2>&1 && [[ $(echo "$resp" | jq -r '.message') != "null" ]]; then
    # Some SCDFs return a top-level 'message' for success
    local msg
    msg=$(echo "$resp" | jq -r '.message')
    echo "[SUCCESS] $msg"
    return 0
  else
    echo "[SUCCESS] Stream '$stream_name' deleted (or did not exist)."
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
  local resp
  resp=$(curl -s -k -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/x-www-form-urlencoded;charset=UTF-8" \
    -d "name=${stream_name}&definition=${encoded_dsl}&description=Created+via+API" \
    "$scdf_url/streams/definitions")
  # Parse and show feedback
  if echo "$resp" | jq -e '._embedded.errors' >/dev/null 2>&1; then
    local msg
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
  local deploy_props_file="rag-stream.deploy"
  local deploy_props_str
  local deploy_props_json
  if [[ -f "$deploy_props_file" ]]; then
    # Convert key=value lines to comma-separated string
    deploy_props_str=$(grep -v '^#' "$deploy_props_file" | grep -v '^$' | paste -sd, -)
    # Use build_json_from_props from utilities.sh
    if ! type build_json_from_props &>/dev/null; then
      source "$(dirname "$BASH_SOURCE")/utilities.sh"
    fi
    deploy_props_json=$(build_json_from_props "$deploy_props_str")
    echo "Loaded deploy properties from $deploy_props_file:"
    echo "$deploy_props_json" | jq -r 'to_entries[] | "  \(.key): \(.value)"'

  else
    echo "No deploy properties file ($deploy_props_file) found. Proceeding without extra properties."
    deploy_props_json="{}"
  fi
  echo "Deploying stream: $stream_name"
  local resp
  resp=$(curl -s -k -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$deploy_props_json" \
    "$scdf_url/streams/deployments/$stream_name")
  # Parse and show feedback
  if echo "$resp" | jq -e '._embedded.errors' >/dev/null 2>&1; then
    local msg
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
  echo -e "\n========== SCDF rag-stream Pipeline =========="
  echo "Fetching status for stream: $stream_name"
  local resp
  resp=$(curl -s -k -H "Authorization: Bearer $token" "$scdf_url/streams/deployments/$stream_name")
  if [[ -z "$resp" || "$resp" == "null" ]]; then
    echo "[ERROR] No deployment status found for stream '$stream_name'."
    return 1
  fi
  local stream_status
  stream_status=$(echo "$resp" | jq -r '.state // .status // "unknown"')
  echo -e "\nStream: $stream_name"
  echo "Status: $stream_status"
  echo -e "\nApp Statuses:"
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
    local runtime_resp
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
