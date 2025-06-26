#!/bin/bash
# rag-stream.sh - Simple menu-driven SCDF pipeline manager for rag-stream

if [[ "$1" == "--help" || "$1" == "-?" ]]; then
  echo "Usage: $0 [--menu] [--help|-?]"
  echo
  echo "Options:"
  echo "  --menu     Launch interactive menu for stream management."
  echo "  --help     Show this help message and exit."
  echo "  -?         Show this help message and exit."
  echo
  echo "If no arguments are given, the script will run the full process (delete, register, create, deploy)."
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
FUNCS_DIR="$SCRIPT_DIR/functions"
SCDF_CONFIG_FILE="$SCRIPT_DIR/.scdf_config"
TOKEN_FILE="$SCRIPT_DIR/.cf_token"
CLIENT_ID_FILE="$SCRIPT_DIR/.cf_client_id"
STREAM_NAME="rag-stream"

. "$FUNCS_DIR/env_setup.sh"

# Prompt for SCDF URL and Token URL if not stored
get_scdf_url() {
  if [[ -f "$SCDF_CONFIG_FILE" ]]; then
    source "$SCDF_CONFIG_FILE"
  fi
  if [[ -z "$SCDF_CF_URL" ]]; then
    read -rp "Enter your SCDF URL (e.g. https://dataflow.example.com): " SCDF_CF_URL
  fi
  if [[ -z "$SCDF_TOKEN_URL" ]]; then
    read -rp "Enter your SCDF Token URL (e.g. https://login.sys.tas-ndc.kuhn-labs.com/oauth/token): " SCDF_TOKEN_URL
  fi
  # Write both to config file
  echo "SCDF_CF_URL=$SCDF_CF_URL" > "$SCDF_CONFIG_FILE"
  echo "SCDF_TOKEN_URL=$SCDF_TOKEN_URL" >> "$SCDF_CONFIG_FILE"
  export SCDF_CF_URL
  export SCDF_TOKEN_URL
}

# Source authentication functions
. "$FUNCS_DIR/auth.sh"

# Authenticate and store token
get_auth_token() {
  if [[ -f "$TOKEN_FILE" && -s "$TOKEN_FILE" ]]; then
    token=$(cat "$TOKEN_FILE")
    http_code=$(curl -s -k -w "%{http_code}" -H "Authorization: Bearer $token" "$SCDF_CF_URL/about" -o /dev/null)
    if [[ "$http_code" == "200" ]]; then
      export token
      return 0
    fi
  fi
  echo "Please login to Cloud Foundry for SCDF access."
  get_oauth_token || { echo "Authentication failed." >&2; exit 1; }
  token=$(cat "$TOKEN_FILE")
  export token
}

# Wait for stream to reach a desired status
wait_for_stream_status() {
  local name="$1"
  local desired_status="$2"
  local max_attempts=30
  local attempt=1
  while (( attempt <= max_attempts )); do
    status=$(curl -s -k -H "Authorization: Bearer $token" "$SCDF_CF_URL/streams/deployments/$name" | jq -r '.status' 2>/dev/null)
    if [[ "$status" == "$desired_status" ]]; then
      echo "Stream '$name' reached status: $desired_status"
      return 0
    fi
    echo "Waiting for stream '$name' to reach status '$desired_status' (current: $status)..."
    sleep 5
    ((attempt++))
  done
  echo "Timeout waiting for stream '$name' to reach status '$desired_status'" >&2
  return 1
}

. "$FUNCS_DIR/rag_apps.sh"
. "$FUNCS_DIR/rag_streams.sh"



delete_stream() {
  rag_delete_stream "$STREAM_NAME" "$token" "$SCDF_CF_URL"
}

create_stream() {
  echo "Deleting stream if it exists..."
  delete_stream
  sleep 2
  # Use the same stream definition as create_stream_definition
  local stream_def="hdfsWatcher | textProc | embedProc | log"
  rag_create_stream "$STREAM_NAME" "$stream_def" "$token" "$SCDF_CF_URL"
}

full_process() {
  echo "[STEP 1] Deleting stream if it exists..."
  delete_stream
  sleep 2
  echo "[STEP 2] Unregistering custom apps..."
  unregister_custom_apps "$token" "$SCDF_CF_URL"
  sleep 2
  echo "[STEP 3] Registering custom apps..."
  register_custom_apps "$token" "$SCDF_CF_URL"
  sleep 2
  echo "[STEP 4] Creating stream definition..."
  create_stream_definition
  sleep 2
  echo "[STEP 5] Deploying stream..."
  deploy_stream
  echo "[COMPLETE] Full process finished."
}

main_menu() {
  while true; do
    echo
    echo "SCDF rag-stream Pipeline Manager"
    echo "1) View custom apps"
    echo "2) Unregister and register custom apps (refresh)"
    echo "3) Register custom apps"
    echo "4) Unregister custom apps"
    echo "5) Delete stream"
    echo "6) Create stream definition only"
    echo "7) Deploy stream only"
    echo "8) Create and deploy stream (combined)"
    echo "9) Full process (register, delete, create+deploy)"
    echo "10) Show stream status"
    echo "q) Quit"
    read -rp "Choose an option: " choice
    case "$choice" in
      1) view_custom_apps "$token" "$SCDF_CF_URL" ;;
      2) unregister_custom_apps "$token" "$SCDF_CF_URL" && register_custom_apps "$token" "$SCDF_CF_URL" ;;
      3) register_custom_apps "$token" "$SCDF_CF_URL" ;;
      4) unregister_custom_apps "$token" "$SCDF_CF_URL" ;;
      5) delete_stream ;;
      6) create_stream_definition ;;
      7) deploy_stream ;;
      8) create_stream ;;
      9) full_process ;;
      10) rag_show_stream_status "$STREAM_NAME" "$token" "$SCDF_CF_URL" ;;
      q) echo "Exiting."; exit 0 ;;
      *) echo "Invalid option." ;;
    esac
  done
}

# New menu handlers for granular stream management
create_stream_definition() {
  # Define stream with proper app types
  # hdfsWatcher: source, textProc/embedProc: processors, log: sink
  local stream_def="hdfsWatcher | textProc | embedProc | log"
  rag_create_stream_definition "$STREAM_NAME" "$stream_def" "$token" "$SCDF_CF_URL"
}

deploy_stream() {
  rag_deploy_stream "$STREAM_NAME" "$token" "$SCDF_CF_URL"
}


get_scdf_url
get_auth_token

if [[ "$1" == "--help" || "$1" == "-?" ]]; then
  echo "Usage: $0 [--menu] [--help|-?]"
  echo
  echo "Options:"
  echo "  --menu     Launch interactive menu for stream management."
  echo "  --help     Show this help message and exit."
  echo "  -?         Show this help message and exit."
  echo
  echo "If no arguments are given, the script will run the full process (delete, register, create, deploy)."
  exit 0
fi

if [[ "$1" == "--menu" ]]; then
  main_menu
else
  full_process
fi
