#!/bin/bash
# utilities.sh - Utility/helper functions for SCDF automation scripts

# Converts a comma-separated properties string into a JSON object string.
build_json_from_props() {
  local props_str="$1"
  local json_output=""
  local first_pair=true

  # Clean the input string: 
  # 1. Remove leading/trailing whitespace and any leading/trailing commas.
  # 2. Normalize space around internal commas (e.g., "key1=val1 , key2=val2" -> "key1=val1,key2=val2").
  props_str=$(echo -n "$props_str" | \
              sed -e 's/^[[:space:]]*,*[[:space:]]*//' \
                  -e 's/[[:space:]]*,*[[:space:]]*$//' \
                  -e 's/[[:space:]]*,[[:space:]]*/,/g')

  # Save and change IFS to split by comma
  local old_ifs="$IFS"
  IFS=','
  # word splitting is desired here
  # shellcheck disable=SC2206
  local pairs_array=($props_str) # Split by comma
  IFS="$old_ifs" # Restore IFS

  for pair in "${pairs_array[@]}"; do
    # Split pair by the first '='
    local key="${pair%%=*}"
    local value="${pair#*=}"

    # If no '=' was in 'pair', then key=pair and value=pair.
    # If 'key' is identical to 'value' here, it means no '=' was found,
    # or the value was empty (key=).
    if [[ "$key" == "$value" ]]; then
      if [[ "$pair" == *"="* ]]; then # Case: key= (empty value)
        value=""
      else # Case: no equals sign at all, treat as key with empty string value
           # or skip. For JSON, an empty string value is valid.
        value="" 
      fi
    fi
    
    # Trim ALL leading/trailing whitespace (spaces, tabs, newlines, CRs) from key and value
    # Using POSIX-compliant sed for trimming
    key=$(echo -n "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    value=$(echo -n "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    # Skip if key is empty after trimming
    if [[ -z "$key" ]]; then
      continue
    fi

    # JSON escape the key (primarily for " and \)
    local escaped_key="${key//\\/\\\\}" # \ -> \\
    escaped_key="${escaped_key//\"/\\\"}" # " -> \"
    # Newlines/CRs in keys are highly unlikely after trimming, but if any persisted:
    escaped_key="${escaped_key//$'\n'/\\n}" 
    escaped_key="${escaped_key//$'\r'/\\r}"

    # JSON escape the value (primarily for ", \, newlines, CRs)
    local escaped_value="${value//\\/\\\\}" # \ -> \\
    escaped_value="${escaped_value//\"/\\\"}" # " -> \"
    escaped_value="${escaped_value//$'\n'/\\n}" # literal newline -> \n string
    escaped_value="${escaped_value//$'\r'/\\r}" # literal CR -> \r string

    if ! "$first_pair"; then
      json_output+=","
    fi
    json_output+="\"$escaped_key\":\"$escaped_value\""
    first_pair=false
  done

  echo -n "{$json_output}"
}

# Parses SCDF REST API responses for embedded errors and warnings, even if
# multiple JSON objects are returned. Logs all error and warning messages
# to the log file and prints them to the terminal for visibility.
extract_and_log_api_messages() {
  local RESPONSE="$1"
  local LOGFILE="$2"
  # Ensure jq is available or provide a non-jq alternative if necessary for this function
  if ! command -v jq >/dev/null 2>&1; then
    echo "WARNING: jq command not found. Cannot extract detailed API error messages." | tee -a "$LOGFILE"
    echo "Raw API Response: $RESPONSE" | tee -a "$LOGFILE" # Log raw response if jq isn't there
    return
  fi

  echo "$RESPONSE" | awk 'BEGIN{RS="}{"; ORS=""} {if(NR>1) print "}{"; print $0}' | while read -r obj; do
    # Ensure obj is a valid JSON object before passing to jq
    local current_obj=""
    if [[ "$obj" =~ ^\{.*\}$ ]]; then # Basic check if it looks like a JSON object
        current_obj="$obj"
    elif [[ "$obj" =~ ^\{ ]]; then
        current_obj="$obj}"
    elif [[ "$obj" =~ \}$ ]]; then
        current_obj="{$obj"
    else
        current_obj="{$obj}" # Best guess
    fi
    
    # Check if current_obj is parseable JSON, otherwise skip jq processing
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