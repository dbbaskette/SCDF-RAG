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
    export CONFIG_ENVIRONMENT="$env"
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
    local env="${CONFIG_ENVIRONMENT:-default}"
    local var_name
    var_name=$(echo "CONFIG_${env}_$key" | tr '.-' '__')
    
    # Return the value of the variable, or empty string if not set
    eval echo "\${$var_name:-}"
}

# Gets deployment properties for a stream in the format expected by SCDF
# Usage: get_deployment_properties <environment>
get_deployment_properties() {
    local env="${1:-default}"
    local context="CONFIG_DEPLOY"
    
    log_debug "Extracting deployment properties for environment '$env'" "$context"
    
    # Check if the environment and deployment properties section exists
    if ! yq eval ".${env}.stream.deployment_properties" "$CONFIG_FILE" >/dev/null 2>&1; then
        log_warn "No deployment properties found for environment '$env'" "$context"
        return 1
    fi
    
    # Extract deployment properties directly from YAML in SCDF format
    # This reads the properties as they are defined in YAML (with dots)
    yq eval ".${env}.stream.deployment_properties | to_entries | .[] | .key + \"=\" + .value" "$CONFIG_FILE"
}

# Gets app definitions for registration
# Usage: get_app_definitions <environment>
get_app_definitions() {
    local env="${1:-default}"
    local context="CONFIG_APPS"
    
    log_debug "Extracting app definitions for environment '$env'" "$context"
    
    # Check if the environment and apps section exists
    if ! yq eval ".${env}.apps" "$CONFIG_FILE" >/dev/null 2>&1; then
        log_warn "No app definitions found for environment '$env'" "$context"
        return 1
    fi
    
    # Get list of app names
    yq eval ".${env}.apps | keys | .[]" "$CONFIG_FILE"
}

# Gets app metadata for a specific app
# Usage: get_app_metadata <app_name> <environment>
get_app_metadata() {
    local app_name="$1"
    local env="${2:-default}"
    local metadata_key="$3"
    
    if [ -n "$metadata_key" ]; then
        yq eval ".${env}.apps.${app_name}.${metadata_key}" "$CONFIG_FILE"
    else
        yq eval ".${env}.apps.${app_name}" "$CONFIG_FILE"
    fi
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
    
    # Create a temporary file to store the key-value pairs
    local temp_file
    temp_file=$(mktemp)
    
    # Use yq to output key-value pairs
    yq eval ".${section} | .. | select(tag != \"!!map\") | (path | join(\".\")) + \"=\" + ." "$config_file" > "$temp_file"
    
    # Read the file line by line and set variables
    while IFS="=" read -r key value; do
        if [ -n "$key" ]; then
            local var_name
            # Convert key to valid shell variable name: replace dots with underscores, hyphens with underscores
            var_name=$(echo "CONFIG_$key" | tr '.-' '__')
            export "$var_name=$value"
            log_debug "Set from file: $var_name=$value" "$context"
        fi
    done < "$temp_file"
    
    # Clean up temporary file
    rm -f "$temp_file"
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
        if [ -n "${!env_var:-}" ]; then
            local var_name
            var_name=$(echo "CONFIG_$key" | tr '.-' '__')
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