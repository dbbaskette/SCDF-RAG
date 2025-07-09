#!/bin/bash
# utilities.sh - Utility/helper functions for SCDF automation scripts

# Converts a comma-separated properties string into a JSON object string.
build_json_from_props() {
  local props_str="$1"
  local json_output=""
  local first_pair=true

  # Remove leading/trailing commas and whitespace from the whole string
  props_str=$(echo -n "$props_str" | sed -e 's/^[[:space:]]*,*[[:space:]]*//' -e 's/[[:space:]]*,*[[:space:]]*$//')

  while [[ -n "$props_str" ]]; do
    local key_part=""
    local value_part=""
    local rest_of_props="$props_str" # Work with a copy for manipulation in the loop

    # Find the first '=' to separate key from value_and_potential_next_keys
    local eq_pos
    eq_pos=$(awk -v s="$rest_of_props" 'BEGIN{print index(s,"=")}')

    if [[ "$eq_pos" -eq 0 ]]; then # No '=' found in the rest of the string
      # Treat the whole remaining string as a key with an empty value, or it's malformed.
      # This case should ideally not happen if input is well-formed key=value pairs.
      key_part="$rest_of_props"
      value_part=""
      props_str="" # Consume the rest
    else
      key_part="${rest_of_props:0:$((eq_pos-1))}"
      local value_and_onwards="${rest_of_props:$eq_pos}" # Starts with value, might contain next keys

      # Now, find where this value_part ends. It ends either at the end of the string,
      # or just before a comma that starts the next known property type.
      local next_key_delimiter_pattern=',(app\.|deployer\.|version\.)'
      # RSTART in awk is 1-based index of where the regex pat matches in $0
      local next_key_start_in_value_and_onwards
      next_key_start_in_value_and_onwards=$(echo -n "$value_and_onwards" | awk -v pat="$next_key_delimiter_pattern" 'match($0, pat) {print RSTART}')

      if [[ "$next_key_start_in_value_and_onwards" -gt 0 ]]; then
        # Found the start of the next property. Value is up to the character before that comma.
        value_part="${value_and_onwards:0:$((next_key_start_in_value_and_onwards-1))}"
        # Update props_str to be the rest, starting from the comma.
        props_str="${value_and_onwards:$((next_key_start_in_value_and_onwards-1))}"
      else
        # No such next property found, so the rest of value_and_onwards is the value.
        value_part="$value_and_onwards"
        props_str="" # All consumed
      fi
    fi

    # Trim whitespace (including newlines, tabs, spaces, CRs) from key_part and value_part
    key_part=$(echo -n "$key_part" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    value_part=$(echo -n "$value_part" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    if [[ -n "$key_part" ]]; then # Only add if key is not empty after trimming
      if ! "$first_pair"; then
        json_output+=","
      fi

      # JSON escape the key
      local escaped_key="${key_part//\\/\\\\}"   # \ -> \\
      escaped_key="${escaped_key//\"/\\\"}"     # " -> \"
      escaped_key="${escaped_key//$'\n'/\\n}"   # literal newline -> \n
      escaped_key="${escaped_key//$'\r'/\\r}"   # literal CR -> \r

      # JSON escape the value
      local escaped_value="${value_part//\\/\\\\}" # \ -> \\
      escaped_value="${escaped_value//\"/\\\"}"   # " -> \"
      escaped_value="${escaped_value//$'\n'/\\n}" # literal newline -> \n
      escaped_value="${escaped_value//$'\r'/\\r}" # literal CR -> \r
      
      json_output+="\"$escaped_key\":\"$escaped_value\""
      first_pair=false
    fi
    
    # Prepare props_str for the next iteration: remove leading comma and whitespace
    if [[ -n "$props_str" ]]; then
      props_str=$(echo -n "$props_str" | sed -e 's/^[[:space:]]*,[[:space:]]*//')
    fi
  done

  echo -n "{$json_output}"
}

# Parses SCDF REST API responses for embedded errors and warnings... (rest of the function as before)
extract_and_log_api_messages() {
  local RESPONSE="$1"
  local LOGFILE="$2"
  if ! command -v jq >/dev/null 2>&1; then
    echo "WARNING: jq command not found. Cannot extract detailed API error messages." | tee -a "$LOGFILE"
    echo "Raw API Response: $RESPONSE" | tee -a "$LOGFILE" 
    return
  fi

  echo "$RESPONSE" | awk 'BEGIN{RS="}{"; ORS=""} {if(NR>1) print "}{"; print $0}' | while read -r obj; do
    local current_obj=""
    if [[ "$obj" =~ ^\{.*\}$ ]]; then 
        current_obj="$obj"
    elif [[ "$obj" =~ ^\{ ]]; then
        current_obj="$obj}"
    elif [[ "$obj" =~ \}$ ]]; then
        current_obj="{$obj"
    else
        current_obj="{$obj}" 
    fi
    
    if ! echo "$current_obj" | jq empty > /dev/null 2>&1; then
        echo "WARNING: Encountered non-JSON segment in API response: $current_obj" | tee -a "$LOGFILE"
        continue
    fi

    ERRORS=$(echo "$current_obj" | jq -r '._embedded.errors[]?.message // empty' 2>/dev/null)
    if [[ -n "$ERRORS" ]]; then
      while IFS= read -r msg; do
        [[ -n "$msg" ]] && echo "ERROR: $msg" | tee -a "$LOGFILE"
      done <<< "$ERRORS"
    fi
    WARNINGS=$(echo "$current_obj" | jq -r '._embedded.warnings[]?.message // empty' 2>/dev/null)
    if [[ -n "$WARNINGS" ]]; then
      while IFS= read -r msg; do
        [[ -n "$msg" ]] && echo "WARNING: $msg" | tee -a "$LOGFILE"
      done <<< "$WARNINGS"
    fi
  done
}

# Deploy a stream with custom properties
# Usage: deploy_stream_with_properties <stream_name> <properties_string> <token> <scdf_url>
deploy_stream_with_properties() {
  local stream_name="$1"
  local properties_string="$2"
  local token="$3"
  local scdf_url="$4"
  local context="DEPLOY_WITH_PROPS"
  
  # Convert properties string to JSON
  local deploy_props_json
  if ! deploy_props_json=$(build_json_from_props "$properties_string"); then
    log_error "Failed to convert properties to JSON" "$context"
    return 1
  fi
  
  # Deploy the stream with properties
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
    log_error "Stream '$stream_name' NOT deployed: $msg" "$context"
    return 1
  else
    log_success "Stream '$stream_name' deployed with custom properties" "$context"
    return 0
  fi
}

# Scales the number of instances for a specific app in a stream
# Usage: scale_stream_instances <stream_name> <app_name> <instance_count> <token> <scdf_url>
scale_stream_instances() {
  local stream_name="$1"
  local app_name="$2"
  local instance_count="$3"
  local token="$4"
  local scdf_url="$5"
  local context="SCALE"
  
  # Get current deployment properties
  local current_props
  if ! current_props=$(curl -s -k -H "Authorization: Bearer $token" "$scdf_url/streams/deployments/$stream_name"); then
    log_error "Failed to get current deployment properties for stream: $stream_name" "$context"
    return 1
  fi
  
  # Extract current deployment properties
  local deploy_props
  if echo "$current_props" | jq -e '.deploymentProperties' >/dev/null 2>&1; then
    deploy_props=$(echo "$current_props" | jq -r '.deploymentProperties | to_entries | map("\(.key)=\(.value)") | join("\n")')
  else
    deploy_props=""
  fi
  
  # Add or update the instance count property
  local new_props="$deploy_props"
  if [[ -n "$deploy_props" ]]; then
    new_props="$deploy_props"$'\n'"deployer.$app_name.count=$instance_count"
  else
    new_props="deployer.$app_name.count=$instance_count"
  fi
  
  # Deploy with updated properties
  if deploy_stream_with_properties "$stream_name" "$new_props" "$token" "$scdf_url"; then
    log_success "Successfully scaled $app_name to $instance_count instances" "$context"
    return 0
  else
    log_error "Failed to scale $app_name to $instance_count instances" "$context"
    return 1
  fi
}

# Gets the current instance counts for all apps in a stream
# Usage: get_stream_instance_counts <stream_name> <token> <scdf_url>
get_stream_instance_counts() {
  local stream_name="$1"
  local token="$2"
  local scdf_url="$3"
  local context="INSTANCE_COUNT"
  
  local resp
  if ! resp=$(curl -s -k -H "Authorization: Bearer $token" "$scdf_url/streams/deployments/$stream_name"); then
    log_error "Failed to get deployment status for stream: $stream_name" "$context"
    return 1
  fi
  
  # Extract deployment properties
  local deploy_props
  if echo "$resp" | jq -e '.deploymentProperties' >/dev/null 2>&1; then
    deploy_props=$(echo "$resp" | jq -r '.deploymentProperties | to_entries | map("\(.key)=\(.value)") | join("\n")')
  else
    deploy_props=""
  fi
  
  # Parse instance counts from deployment properties
  echo "$deploy_props" | grep "^deployer\..*\.count=" | while IFS='=' read -r key value; do
    local app_name=$(echo "$key" | sed 's/^deployer\.\(.*\)\.count$/\1/')
    echo "$app_name: $value"
  done
}