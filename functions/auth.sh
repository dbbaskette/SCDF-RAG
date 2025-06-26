#!/bin/bash
# auth.sh - Provides get_oauth_token for rag-stream.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
TOKEN_FILE="$SCRIPT_DIR/../.cf_token"
CLIENT_ID_FILE="$SCRIPT_DIR/../.cf_client_id"

# Loads env setup if not already loaded
. "$SCRIPT_DIR/env_setup.sh"

get_oauth_token() {
  echo "=== SCDF Authentication ==="

  # Check for existing valid token first
  if [[ -f "$TOKEN_FILE" && -s "$TOKEN_FILE" ]]; then
    token=$(cat "$TOKEN_FILE")
    if [[ -n "$token" && -n "$SCDF_CF_URL" ]]; then
      http_code=$(curl -s -k -w "%{http_code}" -H "Authorization: Bearer $token" "$SCDF_CF_URL/about" -o /dev/null)
      if [[ "$http_code" == "200" ]]; then
        echo "Using existing valid token from $TOKEN_FILE"
        export token
        return 0
      fi
    fi
  fi

  echo "No valid token found, or existing token failed validation."
  read -rp "SCDF Client ID: " SCDF_CLIENT_ID
  read -rsp "SCDF Client Secret: " SCDF_CLIENT_SECRET; echo
  if [[ -z "$SCDF_TOKEN_URL" ]]; then
    read -rp "SCDF Token URL (e.g. https://login.sys.tas-ndc.kuhn-labs.com/oauth/token): " SCDF_TOKEN_URL
  fi

  # Request token using client_credentials grant
  response=$(curl -s -k -X POST "$SCDF_TOKEN_URL" \
    -d "grant_type=client_credentials" \
    -d "client_id=$SCDF_CLIENT_ID" \
    -d "client_secret=$SCDF_CLIENT_SECRET")

  token=$(echo "$response" | jq -r '.access_token')
  if [[ -n "$token" && "$token" != "null" ]]; then
    echo "$token" > "$TOKEN_FILE"
    echo "$SCDF_CLIENT_ID" > "$CLIENT_ID_FILE"
    export token
    echo "Authentication successful. Token stored."
    return 0
  else
    echo "Authentication failed: $response" >&2
    return 1
  fi
}

