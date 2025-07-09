#!/bin/bash
# auth.sh - Enhanced OAuth token management for rag-stream.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
TOKEN_FILE="$SCRIPT_DIR/../.cf_token"
CLIENT_ID_FILE="$SCRIPT_DIR/../.cf_client_id"

# Loads env setup if not already loaded
. "$SCRIPT_DIR/env_setup.sh"

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

# Enhanced curl wrapper for auth
auth_curl_with_retry() {
    url="$1"
    shift
    context="AUTH_API"
    max_retries=3
    delay=2
    
    for attempt in $(seq 1 $max_retries); do
        log_debug "Auth API call attempt $attempt: $url" "$context"
        
        if curl -s --max-time 30 --connect-timeout 10 --fail-with-body "$@" "$url"; then
            log_debug "Auth API call succeeded on attempt $attempt" "$context"
            return 0
        fi
        
        exit_code=$?
        log_warn "Auth API call attempt $attempt failed with exit code $exit_code" "$context"
        
        if [[ $attempt -lt $max_retries ]]; then
            log_info "Retrying in ${delay}s..." "$context"
            sleep $delay
            delay=$((delay * 2))
        fi
    done
    
    log_error "Auth API call failed after $max_retries attempts" "$context"
    return 1
}

get_oauth_token() {
    local context="OAUTH"
    
    if [[ -f "$TOKEN_FILE" && -s "$TOKEN_FILE" ]]; then
        token=$(cat "$TOKEN_FILE")
        if [[ -n "$token" && -n "$SCDF_CF_URL" ]]; then
            # Use enhanced curl with retry for token validation
            if auth_curl_with_retry "$SCDF_CF_URL/about" \
                -H "Authorization: Bearer $token" \
                -H "Accept: application/json" \
                -w "%{http_code}" \
                -o /dev/null | grep -q "200"; then
                
                log_success "Using existing valid token" "$context"
                export token
                return 0
            else
                log_warn "Existing token is invalid or expired" "$context"
            fi
        fi
    fi

    log_info "Requesting new authentication" "$context"
    
    # Validate required parameters
    local SCDF_CLIENT_ID SCDF_CLIENT_SECRET
    
    while [ -z "$SCDF_CLIENT_ID" ]; do
        read -p "SCDF Client ID: " SCDF_CLIENT_ID
        if [ -z "$SCDF_CLIENT_ID" ]; then
            log_error "Client ID cannot be empty" "$context"
        fi
    done
    
    while [[ -z "$SCDF_CLIENT_SECRET" ]]; do
        read -rsp "SCDF Client Secret: " SCDF_CLIENT_SECRET
        echo
        if [[ -z "$SCDF_CLIENT_SECRET" ]]; then
            log_error "Client Secret cannot be empty" "$context"
        fi
    done
    
    if [[ -z "$SCDF_TOKEN_URL" ]]; then
        while [[ -z "$SCDF_TOKEN_URL" ]]; do
            read -p "SCDF Token URL (e.g. https://login.sys.example.com/oauth/token): " SCDF_TOKEN_URL
            if [[ ! "$SCDF_TOKEN_URL" =~ ^https?://[^[:space:]]+$ ]]; then
                log_error "Invalid token URL format. Please enter a valid HTTP/HTTPS URL." "$context"
                SCDF_TOKEN_URL=""
            fi
        done
    fi
    
    # Save client ID for future use
    echo "$SCDF_CLIENT_ID" > "$CLIENT_ID_FILE"
    
    # Request token with retry logic
    local max_retries=3
    local delay=2
    
    for attempt in $(seq 1 $max_retries); do
        log_debug "Token request attempt $attempt" "$context"
        
        if token_response=$(auth_curl_with_retry "$SCDF_TOKEN_URL" \
            -X POST \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "grant_type=client_credentials" \
            -d "client_id=$SCDF_CLIENT_ID" \
            -d "client_secret=$SCDF_CLIENT_SECRET"); then
            
            # Extract token from response
            if new_token=$(echo "$token_response" | jq -r '.access_token // empty'); then
                if [[ -n "$new_token" && "$new_token" != "null" ]]; then
                    # Save token to file
                    echo "$new_token" > "$TOKEN_FILE"
                    chmod 600 "$TOKEN_FILE"
                    
                    log_success "Authentication successful" "$context"
                    export token="$new_token"
                    return 0
                else
                    log_error "No access token in response" "$context"
                fi
            else
                log_error "Failed to parse token response" "$context"
            fi
        fi
        
        if [ $attempt -lt $max_retries ]; then
            log_info "Retrying in ${delay}s..." "$context"
            sleep $delay
            delay=$((delay * 2))
        fi
    done
    
    log_error "Authentication failed after $max_retries attempts" "$context"
    return 1
}

