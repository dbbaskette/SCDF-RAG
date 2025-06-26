#!/bin/bash
# functions/config.sh - Enhanced configuration management for rag-stream.sh

# --- Global Configuration Variables ---
# Associative array to hold all final configuration values. Bash 3.2 doesn't
# support associative arrays, so we'll simulate it with prefixed variables.
CONFIG_LOADED=false
CONFIG_FILE="${CONFIG_FILE:-config.yaml}"

# --- Core Configuration Functions ---

# Loads and parses the YAML configuration file.
# Merges the default environment with the selected environment,
# then applies any environment variable overrides.
#
# Usage: load_configuration "path/to/config.yaml" "environment_name"
load_configuration() {
    local config_file="$1"
    local env="${2:-default}"
    local context="CONFIG"

    if [ ! -f "$config_file" ]; then
        log_error "Configuration file not found: $config_file" "$context"
        log_error "Please copy 'config.template.yaml' to 'config.yaml' and configure it."
        return 1
    fi

    log_info "Loading configuration from '$config_file' for environment '$env'" "$context"

    # 1. Read default section
    _parse_and_set_vars "$config_file" "default"

    # 2. Read and merge the selected environment section (if not 'default')
    if [ "$env" != "default" ]; then
        log_debug "Merging environment: $env" "$context"
        _parse_and_set_vars "$config_file" "$env"
    fi

    # 3. Apply environment variable overrides
    _apply_env_overrides

    # 4. Validate the final configuration
    if ! _validate_configuration; then
        return 1
    fi

    CONFIG_LOADED=true
    log_success "Configuration loaded and validated successfully" "$context"
    
    if [ "${DEBUG:-false}" = "true" ]; then
        print_config
    fi
    
    return 0
}

# Retrieves a configuration value.
#
# Usage: get_config "key.subkey"
get_config() {
    local key="$1"
    local var_name
    var_name=$(echo "CONFIG_$key" | tr '.' '_')
    eval "echo \"\${$var_name}\""
}

# --- Internal Helper Functions ---

# Parses a section of the YAML file and sets the values.
# Uses `yq` to read YAML and converts keys to shell-variable-friendly format.
_parse_and_set_vars() {
    local config_file="$1"
    local section="$2"
    local context="CONFIG_PARSE"

    # Check if the section exists in the YAML file
    if ! yq eval ".${section}" "$config_file" >/dev/null 2>&1; then
        log_warn "Environment '$section' not found in config file, skipping." "$context"
        return 0
    fi
    
    # Use yq to output key-value pairs, then read them line by line
    yq eval ".${section} | .. | select(tag != \"!!map\") | (path | join(\".\")) + \"=\" + ." "$config_file" | while IFS="=" read -r key value; do
        if [ -n "$key" ]; then
            local var_name
            var_name=$(echo "CONFIG_$key" | tr '.' '_')
            export "$var_name=$value"
            log_debug "Set from file: $var_name=$value" "$context"
        fi
    done
}

# Overrides config values with environment variables.
# Maps CONFIG_key_subkey to an environment variable like SCDF_URL.
_apply_env_overrides() {
    local context="CONFIG_ENV"
    log_debug "Checking for environment variable overrides" "$context"

    # Map of config keys to environment variables
    # Format: "config.key.name:ENV_VAR_NAME"
    local env_map
    env_map="scdf.url:SCDF_URL scdf.token_url:SCDF_TOKEN_URL"
    
    for mapping in $env_map; do
        local key="${mapping%%:*}"
        local env_var="${mapping#*:}"
        
        # Check if the environment variable is set
        if [ -n "${!env_var}" ]; then
            local var_name
            var_name=$(echo "CONFIG_$key" | tr '.' '_')
            local old_value
            old_value=$(get_config "$key")
            local new_value="${!env_var}"
            
            export "$var_name=$new_value"
            log_info "Overridden by env var '$env_var': $key = $new_value (was: $old_value)" "$context"
        fi
    done
}

# Validates that all required configuration keys have values.
_validate_configuration() {
    local context="CONFIG_VALIDATE"
    local required_keys
    required_keys="scdf.url scdf.token_url stream.name stream.definition"
    local missing_keys=""

    log_info "Validating configuration..." "$context"

    for key in $required_keys; do
        if [ -z "$(get_config "$key")" ]; then
            missing_keys="$missing_keys $key"
        fi
    done

    if [ -n "$missing_keys" ]; then
        log_error "Required configuration keys are missing or empty:$missing_keys" "$context"
        return 1
    fi

    # Extra validation for URLs
    local scdf_url
    scdf_url=$(get_config "scdf.url")
    if ! echo "$scdf_url" | grep -E '^https?://' >/dev/null; then
        log_error "Invalid format for 'scdf.url': $scdf_url" "$context"
        return 1
    fi

    log_success "Configuration syntax and required keys are valid" "$context"
    return 0
}

# Prints the current configuration for debugging.
print_config() {
    local context="CONFIG_DUMP"
    log_debug "--- Start of Current Configuration ---" "$context"
    # List all variables starting with CONFIG_, format them, and print
    compgen -v CONFIG_ | while read -r var; do
        log_debug "  ${var}=${!var}" "$context"
    done
    log_debug "--- End of Current Configuration ---" "$context"
} 