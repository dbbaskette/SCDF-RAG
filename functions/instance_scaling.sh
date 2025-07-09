#!/bin/bash
# instance_scaling.sh - Example script for controlling instance counts
# This script demonstrates how to use the new deployment properties
# for scaling textProc and embedProc instances

# Source the main script to get access to all functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../rag-stream.sh"

# Override the argument parsing to avoid conflicts
unset -f parse_arguments

# Example function to deploy with custom instance counts
deploy_with_custom_instances() {
    local textproc_instances="${1:-1}"
    local embedproc_instances="${2:-1}"
    local environment="${3:-default}"
    local context="CUSTOM_DEPLOY"
    
    log_info "Deploying stream with custom instance counts:" "$context"
    log_info "  textProc instances: $textproc_instances" "$context"
    log_info "  embedProc instances: $embedproc_instances" "$context"
    log_info "  Environment: $environment" "$context"
    
    # Load configuration for the specified environment
    if ! load_configuration "$CONFIG_FILE" "$environment"; then
        log_error "Failed to load configuration for environment: $environment" "$context"
        return 1
    fi
    
    # Get the stream name and definition
    local stream_name
    stream_name=$(get_config "stream.name")
    local stream_def
    stream_def=$(get_config "stream.definition")
    
    # Get authentication token
    local token
    if ! token=$(get_oauth_token); then
        log_error "Failed to get authentication token" "$context"
        return 1
    fi
    
    # Get SCDF URL
    local scdf_url
    scdf_url=$(get_config "scdf.url")
    
    # Create temporary deployment properties with custom instance counts
    local temp_props
    temp_props=$(get_deployment_properties "$environment")
    
    # Add or override instance counts
    temp_props=$(echo "$temp_props" | grep -v "deployer.textProc.count\|deployer.embedProc.count")
    temp_props="$temp_props
deployer.textProc.count=$textproc_instances
deployer.embedProc.count=$embedproc_instances"
    
    # Create and deploy the stream
    if rag_create_stream_definition "$stream_name" "$stream_def" "$token" "$scdf_url"; then
        log_success "Stream definition created successfully" "$context"
        
        # Deploy with custom properties
        if rag_deploy_stream "$stream_name" "$token" "$scdf_url"; then
            log_success "Stream deployed with custom instance counts" "$context"
            return 0
        else
            log_error "Failed to deploy stream" "$context"
            return 1
        fi
    else
        log_error "Failed to create stream definition" "$context"
        return 1
    fi
}

# Example function to scale existing stream instances
scale_existing_stream() {
    local stream_name="${1:-rag-stream}"
    local textproc_instances="${2:-1}"
    local embedproc_instances="${3:-1}"
    local context="SCALE_EXISTING"
    
    log_info "Scaling existing stream: $stream_name" "$context"
    log_info "  textProc instances: $textproc_instances" "$context"
    log_info "  embedProc instances: $embedproc_instances" "$context"
    
    # Get authentication token
    local token
    if ! token=$(get_oauth_token); then
        log_error "Failed to get authentication token" "$context"
        return 1
    fi
    
    # Get SCDF URL
    local scdf_url
    scdf_url=$(get_config "scdf.url")
    
    # Scale textProc instances
    if scale_stream_instances "$stream_name" "textProc" "$textproc_instances" "$token" "$scdf_url"; then
        log_success "Successfully scaled textProc to $textproc_instances instances" "$context"
    else
        log_error "Failed to scale textProc instances" "$context"
        return 1
    fi
    
    # Scale embedProc instances
    if scale_stream_instances "$stream_name" "embedProc" "$embedproc_instances" "$token" "$scdf_url"; then
        log_success "Successfully scaled embedProc to $embedproc_instances instances" "$context"
    else
        log_error "Failed to scale embedProc instances" "$context"
        return 1
    fi
    
    # Show current instance counts
    get_stream_instance_counts "$stream_name" "$token" "$scdf_url"
}

# Example function to show current deployment properties
show_deployment_properties() {
    local environment="${1:-default}"
    local context="SHOW_PROPS"
    
    log_info "Showing deployment properties for environment: $environment" "$context"
    
    # Load configuration
    if ! load_configuration "$CONFIG_FILE" "$environment"; then
        log_error "Failed to load configuration" "$context"
        return 1
    fi
    
    # Get deployment properties
    local props
    if props=$(get_deployment_properties "$environment"); then
        echo -e "\nDeployment properties for environment '$environment':"
        echo "=================================================="
        echo "$props" | while IFS="=" read -r key value; do
            if [ -n "$key" ]; then
                echo "  $key=$value"
            fi
        done
        echo "=================================================="
    else
        log_warn "No deployment properties found for environment: $environment" "$context"
    fi
}

# Main function to demonstrate usage
main() {
    local action="${1:-help}"
    local textproc_instances="${2:-1}"
    local embedproc_instances="${3:-1}"
    local environment="${4:-default}"
    local stream_name="${5:-rag-stream}"
    
    case "$action" in
        "deploy")
            deploy_with_custom_instances "$textproc_instances" "$embedproc_instances" "$environment"
            ;;
        "scale")
            scale_existing_stream "$stream_name" "$textproc_instances" "$embedproc_instances"
            ;;
        "show")
            show_deployment_properties "$environment"
            ;;
        "help"|*)
            echo "Usage: $0 <action> [textproc_instances] [embedproc_instances] [environment] [stream_name]"
            echo ""
            echo "Actions:"
            echo "  deploy  - Deploy a new stream with custom instance counts"
            echo "  scale   - Scale an existing stream's instance counts"
            echo "  show    - Show current deployment properties"
            echo "  help    - Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0 deploy 2 3 production    # Deploy with 2 textProc, 3 embedProc instances"
            echo "  $0 scale 4 2                # Scale existing stream to 4 textProc, 2 embedProc"
            echo "  $0 show production          # Show deployment properties for production"
            ;;
    esac
}

# If this script is run directly, execute main function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 