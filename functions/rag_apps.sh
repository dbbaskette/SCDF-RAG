#!/bin/bash
# rag_apps.sh - Enhanced register/unregister custom apps for rag-stream

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
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

# Enhanced curl wrapper for apps
app_curl_with_retry() {
    local url="$1"
    shift
    local curl_args=("$@")
    local context="APP_API"
    local max_retries=3
    local delay=2
    
    for attempt in $(seq 1 $max_retries); do
        log_debug "API call attempt $attempt: $url" "$context"
        
        # Capture response regardless of HTTP status code
        local response
        if response=$(curl -s --max-time 30 --connect-timeout 10 "${curl_args[@]}" "$url" 2>/dev/null); then
            log_debug "API call succeeded on attempt $attempt" "$context"
            echo "$response"
            return 0
        fi
        
        local exit_code=$?
        log_warn "API call attempt $attempt failed with exit code $exit_code" "$context"
        
        if [ $attempt -lt $max_retries ]; then
            log_info "Retrying in ${delay}s..." "$context"
            sleep $delay
            delay=$((delay * 2))
        fi
    done
    
    log_error "API call failed after $max_retries attempts" "$context"
    return 1
}

register_hdfs_watcher_app() {
    local token="$1"
    local scdf_url="$2"
    local context="HDFS_WATCHER"
  local uri="https://github.com/dbbaskette/hdfsWatcher/releases/download/v0.2.0/hdfsWatcher-0.2.0.jar"
    
    log_info "Registering hdfsWatcher app" "$context"
    log_debug "URI: $uri" "$context"
    
    resp=$(app_curl_with_retry "$scdf_url/apps/source/hdfsWatcher" \
        -X POST \
    -H "Authorization: Bearer $token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "uri=$uri")
    
    local curl_exit=$?
    if [ $curl_exit -ne 0 ]; then
        log_error "Network error during hdfsWatcher registration (exit code: $curl_exit)" "$context"
        return 1
    fi
    
  if echo "$resp" | jq -e '._embedded.errors' >/dev/null 2>&1; then
    msg=$(echo "$resp" | jq -r '._embedded.errors[]?.message')
        log_error "hdfsWatcher registration failed: $msg" "$context"
    return 1
  else
        log_success "hdfsWatcher registered successfully" "$context"
    return 0
  fi
}

register_text_proc_app() {
  local token="$1"; local scdf_url="$2"
  local uri="https://github.com/dbbaskette/textProc/releases/download/v0.0.6/textProc-0.0.6-SNAPSHOT.jar"
  resp=$(curl -s -k -X POST "$scdf_url/apps/processor/textProc" \
    -H "Authorization: Bearer $token" \
    -d "uri=$uri" \
    -H "Content-Type: application/x-www-form-urlencoded")
  if echo "$resp" | jq -e '._embedded.errors' >/dev/null 2>&1; then
    msg=$(echo "$resp" | jq -r '._embedded.errors[]?.message')
    echo "[ERROR] textProc registration failed: $msg"
    return 1
  else
    echo "[SUCCESS] textProc registered."
    return 0
  fi
}

register_embed_proc_app() {
  local token="$1"; local scdf_url="$2"
  local uri="https://github.com/dbbaskette/embedProc/releases/download/v0.0.3/embedProc-0.0.3.jar"
  resp=$(curl -s -k -X POST "$scdf_url/apps/processor/embedProc" \
    -H "Authorization: Bearer $token" \
    -d "uri=$uri" \
    -H "Content-Type: application/x-www-form-urlencoded")
  if echo "$resp" | jq -e '._embedded.errors' >/dev/null 2>&1; then
    msg=$(echo "$resp" | jq -r '._embedded.errors[]?.message')
    echo "[ERROR] embedProc registration failed: $msg"
    return 1
  else
    echo "[SUCCESS] embedProc registered."
    return 0
  fi
}

unregister_hdfs_watcher_app() {
  local token="$1"; local scdf_url="$2"
  resp=$(curl -s -k -X DELETE "$scdf_url/apps/source/hdfsWatcher" \
    -H "Authorization: Bearer $token")
  if echo "$resp" | jq -e '._embedded.errors' >/dev/null 2>&1; then
    msg=$(echo "$resp" | jq -r '._embedded.errors[]?.message')
    echo "[ERROR] hdfsWatcher unregistration failed: $msg"
    return 1
  else
    echo "[SUCCESS] hdfsWatcher unregistered."
    return 0
  fi
}

unregister_text_proc_app() {
  local token="$1"; local scdf_url="$2"
  resp=$(curl -s -k -X DELETE "$scdf_url/apps/processor/textProc" \
    -H "Authorization: Bearer $token")
  if echo "$resp" | jq -e '._embedded.errors' >/dev/null 2>&1; then
    msg=$(echo "$resp" | jq -r '._embedded.errors[]?.message')
    echo "[ERROR] textProc unregistration failed: $msg"
    return 1
  else
    echo "[SUCCESS] textProc unregistered."
    return 0
  fi
}

unregister_embed_proc_app() {
  local token="$1"; local scdf_url="$2"
  resp=$(curl -s -k -X DELETE "$scdf_url/apps/processor/embedProc" \
    -H "Authorization: Bearer $token")
  if echo "$resp" | jq -e '._embedded.errors' >/dev/null 2>&1; then
    msg=$(echo "$resp" | jq -r '._embedded.errors[]?.message')
    echo "[ERROR] embedProc unregistration failed: $msg"
    return 1
  else
    echo "[SUCCESS] embedProc unregistered."
    return 0
  fi
}

register_custom_apps() {
    local token="$1"
    local scdf_url="$2"
    local context="REGISTER_APPS"
    
    # Check if configuration is loaded
    if [ "$CONFIG_LOADED" != "true" ]; then
        log_error "Configuration not loaded. Call load_configuration first." "$context"
        return 1
    fi
    
    local success_count=0
    local error_count=0
    local skip_count=0
    
    # Get app names dynamically from config
    local app_names
    if ! app_names=$(get_app_definitions "${CONFIG_ENVIRONMENT:-default}"); then
        log_error "Failed to get app definitions from configuration" "$context"
        return 1
    fi
    
    for app_name in $app_names; do
        local app_type=$(get_app_metadata "$app_name" "${CONFIG_ENVIRONMENT:-default}" "type")
        local github_url=$(get_app_metadata "$app_name" "${CONFIG_ENVIRONMENT:-default}" "github_url")
        
        if [ -z "$app_type" ] || [ -z "$github_url" ]; then
            log_warn "Missing configuration for $app_name, skipping" "$context"
            ((skip_count++))
            continue
        fi
        
        # Extract owner/repo from URL with validation
        if echo "$github_url" | grep -E 'github.com/([^/]+)/([^/]+)' >/dev/null; then
            local owner=$(echo "$github_url" | sed -nE 's|.*github.com/([^/]+)/([^/]+).*|\1|p')
            local repo=$(echo "$github_url" | sed -nE 's|.*github.com/([^/]+)/([^/]+).*|\2|p')
            
            # Query latest release from GitHub API with retry
            local api_url="https://api.github.com/repos/$owner/$repo/releases/latest"
            
            if ! release_json=$(app_curl_with_retry "$api_url" -H "Accept: application/vnd.github.v3+json"); then
                log_error "Failed to fetch release information for $owner/$repo" "$context"
                ((error_count++))
                continue
            fi
            
            jar_url=$(echo "$release_json" | jq -r '.assets[] | select(.name | test("\\.jar$") and (test("SNAPSHOT") | not)) | .browser_download_url' | head -n1)
            version=$(echo "$release_json" | jq -r '.tag_name // .name // "unknown"')
            
            # Fallback: allow SNAPSHOT jar if no release jar
            if [ -z "$jar_url" ]; then
                jar_url=$(echo "$release_json" | jq -r '.assets[] | select(.name | test("\\.jar$")) | .browser_download_url' | head -n1)
            fi
            
            if [ -z "$jar_url" ]; then
                log_error "No JAR asset found for $owner/$repo latest release" "$context"
                ((error_count++))
                continue
            fi
            
            # Register the app with retry logic
            resp=$(app_curl_with_retry "$scdf_url/apps/$app_type/$app_name" \
                -X POST \
                -H "Authorization: Bearer $token" \
                -H "Content-Type: application/x-www-form-urlencoded" \
                -d "uri=$jar_url")
                
            local curl_exit=$?
            if [ $curl_exit -ne 0 ]; then
                log_error "Network error during app registration" "$context"
                ((error_count++))
                continue
            fi
            
            if echo "$resp" | jq -e '._embedded.errors' >/dev/null 2>&1; then
                msg=$(echo "$resp" | jq -r '._embedded.errors[]?.message')
                if echo "$msg" | grep -q "already registered as"; then
                    reg_url=$(echo "$msg" | sed -nE "s/.*already registered as (.*)/\1/p")
                    if [ "$jar_url" = "$reg_url" ]; then
                        log_debug "App $app_name is up to date" "$context"
                        ((success_count++))
                    else
                        log_warn "App $app_name registered with different URL: $reg_url" "$context"
                        ((skip_count++))
                    fi
                else
                    log_error "App registration failed: $msg" "$context"
                    ((error_count++))
                fi
            else
                log_success "App $app_name registered successfully" "$context"
                ((success_count++))
            fi
        else
            log_error "Invalid GitHub URL format: $github_url" "$context"
            ((error_count++))
        fi
    done
    
    # Summary
    if [ $error_count -gt 0 ]; then
        log_warn "App registration: $success_count successful, $error_count failed, $skip_count skipped" "$context"
        return 1
    else
        log_success "App registration: $success_count successful, $skip_count skipped" "$context"
        return 0
    fi
}


unregister_custom_apps() {
  unregister_hdfs_watcher_app "$1" "$2"
  unregister_text_proc_app "$1" "$2"
  unregister_embed_proc_app "$1" "$2"
}

view_custom_apps() {
  local token="$1"; local scdf_url="$2"
  for app in "source/hdfsWatcher" "processor/textProc" "processor/embedProc"; do
    echo
    echo "==== $app ===="
    curl -s -k -H "Authorization: Bearer $token" "$scdf_url/apps/$app" | jq '{name: .name, type: .type, uri: .uri, version: .version}'
  done
}
