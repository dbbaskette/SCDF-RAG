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
Usage: $0 [--menu] [--help|-?] [--debug] [--env <environment>]

Enhanced SCDF RAG Stream Pipeline Manager

Options:
  --menu     Launch interactive menu for stream management
  --help     Show this help message and exit
  --debug    Enable debug logging
  --env      Specify the environment to use from config.yaml (e.g., 'production')
  -?         Show this help message and exit

Features:
  - Comprehensive error handling with proper exit codes
  - Retry logic for network operations
  - Timeout handling for long-running operations
  - Centralized logging with timestamps
  - Tool validation at startup
  - Centralized YAML configuration with environment support

If no arguments are given, the script will run the full process (delete, register, create, deploy).

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
            --menu)
                export MENU_MODE=true
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
main_init() {
    log_info "=== SCDF RAG Stream Manager Started ===" "INIT"
    log_info "Script: $0" "INIT"
    log_info "PID: $$" "INIT"
    log_info "User: $(whoami)" "INIT"
    log_info "Working directory: $(pwd)" "INIT"
    log_info "Log file: $LOG_FILE" "INIT"
    
    parse_arguments "$@"
    validate_required_tools
    
    # Source required function libraries with error checking
    local required_libs="env_setup.sh config.sh auth.sh rag_apps.sh rag_streams.sh"
    for lib in $required_libs; do
        local lib_path="$FUNCS_DIR/$lib"
        if [ ! -f "$lib_path" ]; then
            handle_error $EXIT_VALIDATION_ERROR "Required library not found: $lib_path" "INIT"
        fi
        
        if ! source "$lib_path"; then
            handle_error $EXIT_VALIDATION_ERROR "Failed to load library: $lib" "INIT"
        fi
    done
    
    # Load configuration
    if ! load_configuration "$CONFIG_FILE" "${SCRIPT_ENV:-default}"; then
        handle_error $EXIT_VALIDATION_ERROR "Configuration failed to load. Please check config.yaml." "INIT"
    fi
    
    # Set global variables from config
    SCDF_CF_URL=$(get_config "scdf.url")
    SCDF_TOKEN_URL=$(get_config "scdf.token_url")

    log_success "Initialization completed successfully" "INIT"
}

# Enhanced authentication with retry logic
get_auth_token() {
    local context="AUTH"
    log_info "Authenticating with SCDF..." "$context"
    
    if [ -f "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ]; then
        token=$(cat "$TOKEN_FILE")
        log_debug "Found existing token file" "$context"
        
        if execute_with_retry 2 1 10 curl_with_retry "$SCDF_CF_URL/about" \
            -H "Authorization: Bearer $token" \
            -H "Accept: application/json" \
            -o /dev/null; then
            export token
            log_success "Existing token is valid" "$context"
            return 0
        else
            log_warn "Existing token is invalid or expired" "$context"
        fi
    fi
    
    log_info "Please login to Cloud Foundry for SCDF access" "$context"
    if ! get_oauth_token; then
        handle_error $EXIT_AUTH_FAILED "Authentication failed" "$context"
    fi
    
    token=$(cat "$TOKEN_FILE")
    export token
    log_success "Authentication completed successfully" "$context"
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
    log_info "Deleting stream '$STREAM_NAME'" "$context"
    
    if ! rag_delete_stream "$STREAM_NAME" "$token" "$SCDF_CF_URL"; then
        log_error "Failed to delete stream '$STREAM_NAME'" "$context"
        return $EXIT_GENERAL_ERROR
    fi
    
    log_success "Stream '$STREAM_NAME' deleted successfully" "$context"
}

create_stream() {
    local context="STREAM"
    log_info "Creating and deploying stream '$STREAM_NAME'" "$context"
    
    log_info "Step 1: Deleting existing stream if present" "$context"
    delete_stream || log_warn "Failed to delete existing stream (may not exist)" "$context"
    
    sleep 2
    
    log_info "Step 2: Creating new stream" "$context"
    local stream_def="hdfsWatcher | textProc | embedProc | log"
    if ! rag_create_stream "$STREAM_NAME" "$stream_def" "$token" "$SCDF_CF_URL"; then
        handle_error $EXIT_GENERAL_ERROR "Failed to create stream '$STREAM_NAME'" "$context"
    fi
    
    log_success "Stream '$STREAM_NAME' created and deployed successfully" "$context"
}

create_stream_definition() {
    local context="STREAM"
    log_info "Creating stream definition for '$STREAM_NAME'" "$context"
    
    local stream_def="hdfsWatcher | textProc | embedProc | log"
    if ! rag_create_stream_definition "$STREAM_NAME" "$stream_def" "$token" "$SCDF_CF_URL"; then
        handle_error $EXIT_GENERAL_ERROR "Failed to create stream definition '$STREAM_NAME'" "$context"
    fi
    
    log_success "Stream definition '$STREAM_NAME' created successfully" "$context"
}

deploy_stream() {
    local context="STREAM"
    log_info "Deploying stream '$STREAM_NAME'" "$context"
    
    if ! rag_deploy_stream "$STREAM_NAME" "$token" "$SCDF_CF_URL"; then
        handle_error $EXIT_GENERAL_ERROR "Failed to deploy stream '$STREAM_NAME'" "$context"
    fi
    
    log_success "Stream '$STREAM_NAME' deployed successfully" "$context"
}

# Enhanced full process with comprehensive error handling
full_process() {
    local context="PROCESS"
    log_info "Starting full process for stream '$STREAM_NAME'" "$context"
    
    log_info "[STEP 1] Deleting stream if it exists..." "$context"
    delete_stream || log_warn "Failed to delete existing stream (may not exist)" "$context"
    sleep 2
    
    log_info "[STEP 2] Unregistering custom apps..." "$context"
    if ! unregister_custom_apps "$token" "$SCDF_CF_URL"; then
        log_warn "Failed to unregister some custom apps" "$context"
    fi
    sleep 2
    
    log_info "[STEP 3] Registering custom apps..." "$context"
    if ! register_custom_apps "$token" "$SCDF_CF_URL"; then
        handle_error $EXIT_GENERAL_ERROR "Failed to register custom apps" "$context"
    fi
    sleep 2
    
    log_info "[STEP 4] Creating stream definition..." "$context"
    create_stream_definition
    sleep 2
    
    log_info "[STEP 5] Deploying stream..." "$context"
    deploy_stream
    
    log_success "[COMPLETE] Full process finished successfully" "$context"
}

# Enhanced menu with error handling
main_menu() {
    local context="MENU"
    log_info "Starting interactive menu" "$context"
    
    while true; do
        echo >&2
        echo "SCDF rag-stream Pipeline Manager" >&2
        echo "1) View custom apps" >&2
        echo "2) Unregister and register custom apps (refresh)" >&2
        echo "3) Register custom apps" >&2
        echo "4) Unregister custom apps" >&2
        echo "5) Delete stream" >&2
        echo "6) Create stream definition only" >&2
        echo "7) Deploy stream only" >&2
        echo "8) Create and deploy stream (combined)" >&2
        echo "9) Full process (register, delete, create+deploy)" >&2
        echo "10) Show stream status" >&2
        echo "q) Quit" >&2
        
        read -p "Choose an option: " choice
        
        case "$choice" in
            1)
                log_info "Viewing custom apps" "$context"
                view_custom_apps "$token" "$SCDF_CF_URL" || log_error "Failed to view custom apps" "$context"
                ;;
            2)
                log_info "Refreshing custom apps" "$context"
                if unregister_custom_apps "$token" "$SCDF_CF_URL"; then
                    register_custom_apps "$token" "$SCDF_CF_URL" || log_error "Failed to register custom apps" "$context"
                else
                    log_error "Failed to unregister custom apps" "$context"
                fi
                ;;
            3)
                log_info "Registering custom apps" "$context"
                register_custom_apps "$token" "$SCDF_CF_URL" || log_error "Failed to register custom apps" "$context"
                ;;
            4)
                log_info "Unregistering custom apps" "$context"
                unregister_custom_apps "$token" "$SCDF_CF_URL" || log_error "Failed to unregister custom apps" "$context"
                ;;
            5)
                delete_stream || log_error "Failed to delete stream" "$context"
                ;;
            6)
                create_stream_definition || log_error "Failed to create stream definition" "$context"
                ;;
            7)
                deploy_stream || log_error "Failed to deploy stream" "$context"
                ;;
            8)
                create_stream || log_error "Failed to create and deploy stream" "$context"
                ;;
            9)
                full_process || log_error "Full process failed" "$context"
                ;;
            10)
                log_info "Showing stream status" "$context"
                rag_show_stream_status "$STREAM_NAME" "$token" "$SCDF_CF_URL" || log_error "Failed to show stream status" "$context"
                ;;
            q|Q)
                log_info "Exiting interactive menu" "$context"
                exit $EXIT_SUCCESS
                ;;
            *)
                log_error "Invalid option: $choice" "$context"
                ;;
        esac
    done
}

# Initialize and run
main_init "$@"
get_scdf_url
get_auth_token

# Run the appropriate mode
if [ "${MENU_MODE:-false}" = "true" ]; then
    log_info "Starting interactive menu mode" "MAIN"
    main_menu
else
    log_info "Starting full process mode" "MAIN"
    full_process
fi

log_success "Script execution completed successfully" "MAIN"
