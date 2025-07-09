#!/bin/bash
# rag-stream.sh - Enhanced SCDF RAG Stream Pipeline Manager
# Manages registration, deployment, and lifecycle of Spring Cloud Data Flow streams

# Exit codes for different error conditions
EXIT_SUCCESS=0
EXIT_GENERAL_ERROR=1
EXIT_MISSING_TOOLS=2
EXIT_AUTH_FAILED=3
EXIT_NETWORK_ERROR=4
EXIT_TIMEOUT_ERROR=5
EXIT_VALIDATION_ERROR=6

# Set strict error handling (bash 3.2 compatible)
set -eu

# --- Global Script Constants ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
FUNCS_DIR="$SCRIPT_DIR/functions"
LOG_DIR="$SCRIPT_DIR/logs"
TOKEN_FILE="$SCRIPT_DIR/.cf_token"
CLIENT_ID_FILE="$SCRIPT_DIR/.cf_client_id"
STREAM_NAME="rag-stream"

# Network configuration
MAX_RETRIES=3
RETRY_DELAY=2
DEFAULT_TIMEOUT=60
API_TIMEOUT=30

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/rag-stream-$(date +%Y%m%d-%H%M%S).log"

# --- Global Script Variables ---
# Set by load_configuration() from config.sh
SCDF_CF_URL=""
SCDF_TOKEN_URL=""
CONFIG_FILE="config.yaml"

# Colors for output (only if terminal supports it)
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && tput colors >/dev/null 2>&1 && [ "$(tput colors)" -ge 8 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    PURPLE='\033[0;35m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    PURPLE=''
    NC=''
fi

# Enhanced logging functions with timestamps and context
log_message() {
    local level="$1"
    local message="$2"
    local context="${3:-}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Log to file with full context
    echo "[$timestamp] [$level] ${context:+[$context] }$message" >> "$LOG_FILE"
    
    # Also log to console with colors
    case "$level" in
        "ERROR")
            echo -e "${RED}[ERROR]${NC} $message" >&2
            ;;
        "WARN")
            echo -e "${YELLOW}[WARN]${NC} $message" >&2
            ;;
        "INFO")
            echo -e "${BLUE}[INFO]${NC} $message" >&2
            ;;
        "SUCCESS")
            echo -e "${GREEN}[SUCCESS]${NC} $message" >&2
            ;;
        "DEBUG")
            if [ "${DEBUG:-false}" = "true" ]; then
                echo -e "${PURPLE}[DEBUG]${NC} $message" >&2
            fi
            ;;
    esac
}

# Convenience logging functions
log_error() { log_message "ERROR" "$1" "${2:-}"; }
log_warn() { log_message "WARN" "$1" "${2:-}"; }
log_info() { log_message "INFO" "$1" "${2:-}"; }
log_success() { log_message "SUCCESS" "$1" "${2:-}"; }
log_debug() { log_message "DEBUG" "$1" "${2:-}"; }

# Enhanced error handling with context (bash 3.2 compatible)
handle_error() {
    local exit_code="${1:-$EXIT_GENERAL_ERROR}"
    local message="${2:-Unknown error occurred}"
    local context="${3:-}"
    
    log_error "$message" "$context"
    log_error "Error occurred in script execution" "$context"
    
    cleanup_on_exit
    exit "$exit_code"
}

# Cleanup function
cleanup_on_exit() {
    log_debug "Performing cleanup operations"
    # Add any cleanup operations here
    # Remove temporary files, reset states, etc.
}

# Set up error trapping
trap 'echo "ERROR: Script failed at line $LINENO" >&2; exit 1' ERR
trap 'cleanup_on_exit' EXIT

# Comprehensive tool validation (bash 3.2 compatible)
validate_required_tools() {
    log_info "Validating required tools..." "VALIDATION"
    
    local missing_tools=""
    local required_tools="curl jq git yq"
    
    for tool in $required_tools; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools="$missing_tools $tool"
            log_error "Required tool not found: $tool" "VALIDATION"
        else
            case "$tool" in
                "curl")
                    version=$(curl --version 2>/dev/null | head -n1 | cut -d' ' -f2 || echo "unknown")
                    ;;
                "jq")
                    version=$(jq --version 2>/dev/null || echo "unknown")
                    ;;
                "git")
                    version=$(git --version 2>/dev/null | cut -d' ' -f3 || echo "unknown")
                    ;;
                "yq")
                    version=$(yq --version 2>/dev/null | cut -d' ' -f3 || echo "unknown")
                    ;;
            esac
            # Note: version info available but not logged to avoid debug issues
        fi
    done
    if [ -n "$missing_tools" ]; then
        log_error "Missing required tools:$missing_tools" "VALIDATION"
        log_info "Please install the missing tools and try again:" "VALIDATION"
        for tool in $missing_tools; do
            case "$tool" in
                "curl")
                    log_info "  - curl: https://curl.se/download.html" "VALIDATION"
                    ;;
                "jq")
                    log_info "  - jq: https://stedolan.github.io/jq/download/" "VALIDATION"
                    ;;
                "git")
                    log_info "  - git: https://git-scm.com/downloads" "VALIDATION"
                    ;;
                "yq")
                    log_info "  - yq: https://github.com/mikefarah/yq/#install" "VALIDATION"
                    ;;
            esac
        done
        exit $EXIT_MISSING_TOOLS
    fi
    
    log_success "All required tools are available" "VALIDATION"
}

# Network operation wrapper with retry logic
execute_with_retry() {
    local max_attempts="${1:-$MAX_RETRIES}"
    local delay="${2:-$RETRY_DELAY}"
    local timeout="${3:-$API_TIMEOUT}"
    shift 3
    local context="RETRY"
    
    log_debug "Executing with retry: $*" "$context"
    log_debug "Max attempts: $max_attempts, Delay: ${delay}s, Timeout: ${timeout}s" "$context"
    
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        log_debug "Attempt $attempt of $max_attempts" "$context"
        
        if [ $timeout -gt 0 ]; then
            # Use timeout if available
            if command -v timeout >/dev/null 2>&1; then
                if timeout "$timeout" "$@"; then
                    log_debug "Command succeeded on attempt $attempt" "$context"
                    return 0
                fi
            else
                # Fallback for systems without timeout command
                if "$@"; then
                    log_debug "Command succeeded on attempt $attempt" "$context"
                    return 0
                fi
            fi
        else
            if "$@"; then
                log_debug "Command succeeded on attempt $attempt" "$context"
                return 0
            fi
        fi
        
        local exit_code=$?
        log_warn "Attempt $attempt failed with exit code $exit_code" "$context"
        
        if [ $attempt -lt $max_attempts ]; then
            log_info "Retrying in ${delay} seconds..." "$context"
            sleep "$delay"
            # Exponential backoff
            delay=$((delay * 2))
        fi
        
        ((attempt++))
    done
    
    log_error "Command failed after $max_attempts attempts" "$context"
    return $EXIT_NETWORK_ERROR
}

# Enhanced curl wrapper with timeout and retry
curl_with_retry() {
    local url="$1"
    shift
    
    execute_with_retry "$MAX_RETRIES" "$RETRY_DELAY" "$API_TIMEOUT" \
        curl -s --max-time "$API_TIMEOUT" --connect-timeout 10 \
        --retry 0 --fail-with-body \
        "$@" "$url"
}

# Wait for operation with timeout
wait_with_timeout() {
    local operation_name="$1"
    local check_function="$2"
    local timeout="${3:-$DEFAULT_TIMEOUT}"
    local interval="${4:-5}"
    local context="WAIT"
    
    log_info "Waiting for $operation_name (timeout: ${timeout}s)" "$context"
    
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if $check_function; then
            log_success "$operation_name completed successfully" "$context"
            return 0
        fi
        
        log_debug "Still waiting for $operation_name (${elapsed}s elapsed)" "$context"
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    
    log_error "$operation_name timed out after ${timeout}s" "$context"
    return $EXIT_TIMEOUT_ERROR
}

# Enhanced help function
show_help() {
    cat << EOF
Usage: $0 [--no-prompt] [--tests] [--help|-?] [--debug] [--env <environment>]

Enhanced SCDF RAG Stream Pipeline Manager

Options:
  --no-prompt Run full process automatically without interactive menu
  --tests     Launch testing menu with different pipeline configurations
  --help      Show this help message and exit
  --debug     Enable debug logging
  --env       Specify the environment to use from config.yaml (e.g., 'production')
  -?          Show this help message and exit

Features:
  - Comprehensive error handling with proper exit codes
  - Retry logic for network operations
  - Timeout handling for long-running operations
  - Centralized logging with timestamps
  - Tool validation at startup
  - Centralized YAML configuration with environment support
  - Interactive menu (default behavior)
  - Dedicated testing menu with different pipeline configurations

Default behavior: Interactive menu for stream management operations.
Use --no-prompt to run the full automated process (delete, register, create, deploy).
Use --tests to access testing menu with different pipeline configurations.

Logs are saved to: $LOG_FILE

Exit Codes:
  0 - Success
  1 - General error
  2 - Missing required tools
  3 - Authentication failed
  4 - Network error
  5 - Timeout error
  6 - Validation error

EOF
}

# Enhanced argument parsing
parse_arguments() {
    while [ $# -gt 0 ]; do
        case $1 in
            --help|-\?)
                show_help
                exit $EXIT_SUCCESS
                ;;
            --debug)
                export DEBUG=true
                log_info "Debug mode enabled"
                ;;
            --env)
                if [ -n "$2" ]; then
                    export SCRIPT_ENV="$2"
                    shift
                else
                    log_error "Error: --env requires a non-empty environment name"
                    exit $EXIT_VALIDATION_ERROR
                fi
                ;;
            --no-prompt)
                export NO_PROMPT_MODE=true
                ;;
            --tests)
                export TESTS_MODE=true
                ;;
            # Legacy support for --menu (now default, so we just ignore it)
            --menu)
                log_debug "Menu mode is now the default behavior"
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit $EXIT_VALIDATION_ERROR
                ;;
        esac
        shift
    done
}

# Main initialization
main() {
    # Source required function libraries
    source "$FUNCS_DIR/env_setup.sh"
    source "$FUNCS_DIR/config.sh"
    source "$FUNCS_DIR/auth.sh"
    source "$FUNCS_DIR/rag_apps.sh"
    source "$FUNCS_DIR/rag_streams.sh"
    source "$FUNCS_DIR/utilities.sh"
    
    # Parse arguments first
    parse_arguments "$@"
    
    # Load configuration
    if ! load_configuration "$CONFIG_FILE" "${SCRIPT_ENV:-default}"; then
        handle_error $EXIT_VALIDATION_ERROR "Failed to load configuration"
    fi
    
    # Set global variables from configuration
    SCDF_CF_URL=$(get_config "scdf.url")
    SCDF_TOKEN_URL=$(get_config "scdf.token_url")
    STREAM_NAME=$(get_config "stream.name")
    
    # Validate tools
    if ! validate_required_tools; then
        handle_error $EXIT_MISSING_TOOLS "Required tools not found"
    fi
    
    # Get authentication token
    if ! get_oauth_token; then
        handle_error $EXIT_AUTH_FAILED "Authentication failed"
    fi
    
    # Export token for use in functions
    export token
    
    # Handle different execution modes
    if [ "${TESTS_MODE:-false}" = "true" ]; then
        test_menu
    elif [ "${NO_PROMPT_MODE:-false}" = "true" ]; then
        full_process
    else
        main_menu
    fi
}

# Enhanced authentication with retry logic
get_auth_token() {
    # This function is now redundant - we call get_oauth_token directly
    get_oauth_token
}

# Helper function for checking stream status
_check_stream_status() {
    local name="$1"
    local desired_status="$2"
    local context="STREAM"
    
    status=$(curl_with_retry "$SCDF_CF_URL/streams/deployments/$name" \
        -H "Authorization: Bearer $token" \
        -H "Accept: application/json" | jq -r '.status // .state // "unknown"' 2>/dev/null)
    
    log_debug "Current status: $status" "$context"
    
    if [ "$status" = "$desired_status" ]; then
      return 0
    else
        return 1
    fi
}

# Enhanced wait for stream status with timeout
wait_for_stream_status() {
  local name="$1"
  local desired_status="$2"
    local timeout="${3:-$DEFAULT_TIMEOUT}"
    local context="STREAM"
    
    log_info "Waiting for stream '$name' to reach status '$desired_status'" "$context"
    
    local elapsed=0
    local interval=5
    
    while [ $elapsed -lt $timeout ]; do
        if _check_stream_status "$name" "$desired_status"; then
            log_success "Stream '$name' reached status: $desired_status" "$context"
      return 0
    fi
        
        log_debug "Still waiting for stream status (${elapsed}s elapsed)" "$context"
        sleep $interval
        elapsed=$((elapsed + interval))
  done
    
    log_error "Stream '$name' did not reach status '$desired_status' within ${timeout}s" "$context"
    return $EXIT_TIMEOUT_ERROR
}

# Enhanced stream operations with error handling
delete_stream() {
    local context="STREAM"
    local stream_name="${1:-$STREAM_NAME}"
    
    if ! rag_delete_stream "$stream_name" "$token" "$SCDF_CF_URL"; then
        log_error "Failed to delete stream '$stream_name'" "$context"
        return $EXIT_GENERAL_ERROR
    fi
    
    return 0
}

create_stream() {
    local context="STREAM"
    local stream_name="${1:-$STREAM_NAME}"
    local stream_def="${2:-$(get_stream_definition)}"
    log_info "Creating and deploying stream '$stream_name'" "$context"
    
    # Clean up existing stream if present
    delete_stream "$stream_name" || log_debug "No existing stream to clean up" "$context"
    
    sleep 2
    
    log_info "Creating new stream" "$context"
    if ! rag_create_stream "$stream_name" "$stream_def" "$token" "$SCDF_CF_URL"; then
        handle_error $EXIT_GENERAL_ERROR "Failed to create stream '$stream_name'" "$context"
    fi
    
    log_success "Stream '$stream_name' created and deployed successfully" "$context"
}

create_stream_definition() {
    local context="STREAM"
    local stream_name="${1:-$STREAM_NAME}"
    local stream_def="${2:-$(get_stream_definition)}"
    log_info "Creating stream definition for '$stream_name'" "$context"
    
    if ! rag_create_stream_definition "$stream_name" "$stream_def" "$token" "$SCDF_CF_URL"; then
        handle_error $EXIT_GENERAL_ERROR "Failed to create stream definition '$stream_name'" "$context"
    fi
    
    log_success "Stream definition '$stream_name' created successfully" "$context"
}

deploy_stream() {
    local context="STREAM"
    local stream_name="${1:-$STREAM_NAME}"
    log_info "Deploying stream '$stream_name'" "$context"
    
    if ! rag_deploy_stream "$stream_name" "$token" "$SCDF_CF_URL"; then
        handle_error $EXIT_GENERAL_ERROR "Failed to deploy stream '$stream_name'" "$context"
    fi
    
    log_success "Stream '$stream_name' deployed successfully" "$context"
}

# Helper function to get the appropriate stream definition
get_stream_definition() {
    if [ "${TEST_HDFS_MODE:-false}" = "true" ]; then
        echo "hdfsWatcher | log"
    else
        echo "hdfsWatcher | textProc | embedProc | log"
    fi
}

# Helper function to get the appropriate stream name
get_stream_name() {
    if [ "${TEST_HDFS_MODE:-false}" = "true" ]; then
        echo "test-hdfs-stream"
    else
        echo "$STREAM_NAME"
    fi
}

# Test menu for different pipeline configurations
test_menu() {
    local context="TEST_MENU"
    
  while true; do
        echo >&2
        echo "SCDF Pipeline Testing Menu" >&2
        echo "1) Test HDFS (cleanup & deploy hdfsWatcher -> log)" >&2
        echo "2) Test TextProc (cleanup & deploy hdfsWatcher -> textProc -> log)" >&2
        echo "3) Cleanup all test streams" >&2
        echo "b) Back to main menu" >&2
        echo "q) Quit" >&2
        
        read -p "Choose a test option: " choice
        
    case "$choice" in
            1)
                test_hdfs_process || log_error "Test HDFS process failed" "$context"
                ;;
            2)
                test_textproc_process || log_error "Test TextProc process failed" "$context"
                ;;
            3)
                cleanup_all_test_streams || log_error "Test cleanup failed" "$context"
                ;;
            b|B)
                return 0
                ;;
            q|Q)
                exit $EXIT_SUCCESS
                ;;
            *)
                log_error "Invalid option: $choice" "$context"
                ;;
    esac
  done
}

# Test HDFS specific functions
test_hdfs_process() {
    local test_stream_name="test-hdfs-stream"
    local context="TEST_HDFS"
    
    log_info "Testing HDFS pipeline: $test_stream_name" "$context"
    
    # Cleanup existing test stream
    rag_delete_stream "$test_stream_name" "$token" "$SCDF_CF_URL" || log_debug "No existing test stream to clean up" "$context"
    
    # Create simple HDFS -> log stream
    local stream_def="hdfsWatcher --hdfs.namenode=hdfs.scdf.svc.cluster.local:9000 --hdfs.path=/data/input | log"
    
    if rag_create_stream "$test_stream_name" "$stream_def" "$token" "$SCDF_CF_URL"; then
        log_success "Test HDFS stream created and deployed successfully" "$context"
        log_info "This allows testing HDFS connectivity without text processing components" "$context"
        return 0
    else
        log_error "Failed to create test HDFS stream" "$context"
        return 1
    fi
}

test_textproc_process() {
    local test_stream_name="test-textproc-stream"
    local context="TEST_TEXTPROC"
    
    log_info "Testing TextProc pipeline: $test_stream_name" "$context"
    
    # Cleanup existing test stream
    rag_delete_stream "$test_stream_name" "$token" "$SCDF_CF_URL" || log_debug "No existing test stream to clean up" "$context"
    
    # Create HDFS -> textProc -> log stream
    local stream_def="hdfsWatcher --hdfs.namenode=hdfs.scdf.svc.cluster.local:9000 --hdfs.path=/data/input | textProc | log"
    
    if rag_create_stream "$test_stream_name" "$stream_def" "$token" "$SCDF_CF_URL"; then
        log_success "Test TextProc stream created and deployed successfully" "$context"
        log_info "This allows testing HDFS connectivity and text processing without embedding" "$context"
        log_info "Monitor the logs to verify file processing and text extraction" "$context"
        return 0
    else
        log_error "Failed to create test TextProc stream" "$context"
        return 1
    fi
}

# Register a single app by name
register_single_app() {
    local app_name="$1"
    local token="$2"
    local scdf_url="$3"
    local context="REGISTER_SINGLE_APP"
    
    log_info "Registering single app: $app_name" "$context"
    
    # Check if configuration is loaded
    if [ "$CONFIG_LOADED" != "true" ]; then
        log_error "Configuration not loaded. Call load_configuration first." "$context"
        return 1
    fi
    
    local app_context="${context}_$(echo "$app_name" | tr '[:lower:]' '[:upper:]')"
    
    local app_type=$(get_app_metadata "$app_name" "${CONFIG_ENVIRONMENT:-default}" "type")
    local github_url=$(get_app_metadata "$app_name" "${CONFIG_ENVIRONMENT:-default}" "github_url")
    
    if [ -z "$app_type" ] || [ -z "$github_url" ]; then
        log_error "Missing configuration for $app_name (type: $app_type, github_url: $github_url)" "$app_context"
        return 1
    fi
    
    # Extract owner/repo from URL with validation
    if echo "$github_url" | grep -E 'github.com/([^/]+)/([^/]+)' >/dev/null; then
        local owner=$(echo "$github_url" | sed -nE 's|.*github.com/([^/]+)/([^/]+).*|\1|p')
        local repo=$(echo "$github_url" | sed -nE 's|.*github.com/([^/]+)/([^/]+).*|\2|p')
        log_debug "GitHub repository: $owner/$repo" "$app_context"
        
        # Query latest release from GitHub API with retry
        local api_url="https://api.github.com/repos/$owner/$repo/releases/latest"
        log_debug "Fetching release info from: $api_url" "$app_context"
        
        if ! release_json=$(curl_with_retry "$api_url" -H "Accept: application/vnd.github.v3+json"); then
            log_error "Failed to fetch release information for $owner/$repo" "$app_context"
            return 1
        fi
        
        jar_url=$(echo "$release_json" | jq -r '.assets[] | select(.name | test("\\.jar$") and (test("SNAPSHOT") | not)) | .browser_download_url' | head -n1)
        version=$(echo "$release_json" | jq -r '.tag_name // .name // "unknown"')
        
        # Fallback: allow SNAPSHOT jar if no release jar
        if [ -z "$jar_url" ]; then
            log_debug "No release JAR found, trying SNAPSHOT" "$app_context"
            jar_url=$(echo "$release_json" | jq -r '.assets[] | select(.name | test("\\.jar$")) | .browser_download_url' | head -n1)
        fi
        
        if [ -z "$jar_url" ]; then
            log_error "No JAR asset found for $owner/$repo latest release" "$app_context"
            return 1
        fi
        
        log_info "Found JAR: $jar_url (version: $version)" "$app_context"
        
        # Register the app with retry logic
        resp=$(curl_with_retry "$scdf_url/apps/$app_type/$app_name" \
            -X POST \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "uri=$jar_url")
            
        if echo "$resp" | jq -e '._embedded.errors' >/dev/null 2>&1; then
            msg=$(echo "$resp" | jq -r '._embedded.errors[]?.message')
            if echo "$msg" | grep -q "already registered as"; then
                reg_url=$(echo "$msg" | sed -nE "s/.*already registered as (.*)/\1/p")
                log_info "App already registered at $reg_url" "$app_context"
                if [ "$jar_url" = "$reg_url" ]; then
                    log_success "App $app_name is up to date" "$app_context"
                    return 0
                else
                    log_warn "App $app_name registered with different URL: $reg_url" "$app_context"
                    return 0
                fi
            else
                log_error "App registration failed: $msg" "$app_context"
                return 1
            fi
        else
            log_success "App $app_name registered successfully" "$app_context"
            return 0
        fi
    else
        log_error "Invalid GitHub URL format: $github_url" "$app_context"
        return 1
    fi
}

# Enhanced full process with comprehensive error handling
full_process() {
    local context="FULL_PROCESS"
    
    log_info "Running full process for stream '$STREAM_NAME'" "$context"
    
    # Step 1: Delete existing stream first
    delete_stream "$STREAM_NAME" || log_debug "No existing stream to clean up" "$context"
    
    # Step 2: Unregister and register custom apps
    log_info "Refreshing custom apps..." "$context"
    if unregister_custom_apps "$token" "$SCDF_CF_URL"; then
        if register_custom_apps "$token" "$SCDF_CF_URL"; then
            log_success "Custom apps refreshed successfully" "$context"
        else
            log_error "Failed to register custom apps" "$context"
            return 1
        fi
    else
        log_error "Failed to unregister custom apps" "$context"
        return 1
    fi
    
    # Step 3: Create and deploy new stream
    log_info "Creating and deploying new stream..." "$context"
    if create_stream; then
        log_success "Full process completed successfully" "$context"
        return 0
    else
        log_error "Failed to create and deploy stream" "$context"
        return 1
    fi
}

# Enhanced menu with error handling
main_menu() {
    local context="MENU"
    
    while true; do
        echo >&2
        echo "SCDF rag-stream Pipeline Manager" >&2
        echo "1) View custom apps" >&2
        echo "2) Unregister and register custom apps (refresh)" >&2
        echo "3) Delete stream" >&2
        echo "4) Create stream definition only" >&2
        echo "5) Deploy stream only" >&2
        echo "6) Create and deploy stream (combined)" >&2
        echo "7) Full process (register, delete, create+deploy)" >&2
        echo "8) Show stream status" >&2
        echo "t) Launch testing menu" >&2
        echo "q) Quit" >&2
        
        read -p "Choose an option: " choice
        
        case "$choice" in
            1)
                view_custom_apps "$token" "$SCDF_CF_URL" || log_error "Failed to view custom apps" "$context"
                ;;
            2)
                if unregister_custom_apps "$token" "$SCDF_CF_URL"; then
                    register_custom_apps "$token" "$SCDF_CF_URL" || log_error "Failed to register custom apps" "$context"
                else
                    log_error "Failed to unregister custom apps" "$context"
                fi
                ;;
            3)
                delete_stream || log_error "Failed to delete stream" "$context"
                ;;
            4)
                create_stream_definition || log_error "Failed to create stream definition" "$context"
                ;;
            5)
                deploy_stream || log_error "Failed to deploy stream" "$context"
                ;;
            6)
                create_stream || log_error "Failed to create and deploy stream" "$context"
                ;;
            7)
                full_process || log_error "Full process failed" "$context"
                ;;
            8)
                echo >&2
                echo "Which stream status would you like to see?" >&2
                echo "1) Regular RAG stream" >&2
                echo "2) Test HDFS stream" >&2
                echo "3) Test TextProc stream" >&2
                echo "4) All streams" >&2
                read -p "Choose stream [1-4]: " stream_choice
                
                case "$stream_choice" in
                    1)
                        rag_show_stream_status "$STREAM_NAME" "$token" "$SCDF_CF_URL" || log_error "Failed to show stream status for $STREAM_NAME" "$context"
                        ;;
                    2)
                        rag_show_stream_status "test-hdfs-stream" "$token" "$SCDF_CF_URL" || log_error "Failed to show stream status for test-hdfs-stream" "$context"
                        ;;
                    3)
                        rag_show_stream_status "test-textproc-stream" "$token" "$SCDF_CF_URL" || log_error "Failed to show stream status for test-textproc-stream" "$context"
                        ;;
                    4)
                        echo >&2
                        echo "=== Regular RAG Stream ===" >&2
                        rag_show_stream_status "$STREAM_NAME" "$token" "$SCDF_CF_URL" || log_error "Failed to show stream status for $STREAM_NAME" "$context"
                        echo >&2
                        echo "=== Test HDFS Stream ===" >&2
                        rag_show_stream_status "test-hdfs-stream" "$token" "$SCDF_CF_URL" || log_error "Failed to show stream status for test-hdfs-stream" "$context"
                        echo >&2
                        echo "=== Test TextProc Stream ===" >&2
                        rag_show_stream_status "test-textproc-stream" "$token" "$SCDF_CF_URL" || log_error "Failed to show stream status for test-textproc-stream" "$context"
                        ;;
                    *)
                        log_error "Invalid stream choice: $stream_choice" "$context"
                        ;;
                esac
                ;;
            t|T)
                test_menu
                ;;
            q|Q)
                exit $EXIT_SUCCESS
                ;;
            *)
                log_error "Invalid option: $choice" "$context"
                ;;
        esac
    done
}

# Cleanup all test streams
cleanup_all_test_streams() {
    local context="CLEANUP_TESTS"
    
    for test_stream in "test-hdfs-stream" "test-textproc-stream"; do
        rag_delete_stream "$test_stream" "$token" "$SCDF_CF_URL" || log_debug "No existing $test_stream to clean up" "$context"
    done
    
    log_success "Test cleanup completed" "$context"
    return 0
}

# Initialize and run
main "$@"
