#!/bin/bash
# utilities.sh - Utility/helper functions for SCDF automation scripts

# Converts a comma-separated properties string into a JSON object string.
# Handles special cases for Kubernetes environment variables.
# This version is more robust in handling values containing commas or quotes.
build_json_from_props() {
  local props_str="$1"
  local json=""
  local first=1

  # Remove leading/trailing commas and whitespace
  props_str="$(echo -n "$props_str" | sed 's/^[[:space:]]*,*[[:space:]]*//; s/[[:space:]]*,*[[:space:]]*$//')"

  # Use a loop to find key=value pairs
  while [[ -n "$props_str" ]]; do
    local key=""
    local val=""
    local remaining_str=""

    # Find the first '='
    local eq_pos=$(awk -v s="$props_str" 'BEGIN{print index(s,"=")}')

    if [[ "$eq_pos" -gt 1 ]]; then
      # Key is before the first '='
      key="${props_str:0:eq_pos-1}"
      # The rest is potentially the value + remaining properties
      local rest="${props_str:eq_pos}"

      # Find the start of the next property (key pattern: app., deployer., version.)
      # Look for a comma followed by one of the key prefixes
      # Using awk for more portable regex matching
      local next_key_pattern=',(app\.|deployer\.|version\.)'
      local next_key_pos=0
      # Use awk to find the starting position of the next key pattern
      # match() in awk returns the starting index (1-based) or 0 if not found.
      # RSTART is the start index, RLENGTH is the length of the match.
      local next_key_match_info=$(echo "$rest" | awk -v pat="$next_key_pattern" 'match($0, pat) {print RSTART}')

      # next_key_match_info will be 0 if no match, or the 1-based starting index of the match in $rest.
      # The match includes the leading comma, e.g., ",app.nextKey"
      if [[ "$next_key_match_info" -gt 0 ]]; then
        # Found the start of the next property
        # Value is from the start of 'rest' up to the character *before* the match (the comma).
        val="${rest:0:$((next_key_match_info - 1))}"
        # Remaining string starts from that comma.
        remaining_str="${rest:$((next_key_match_info - 1))}"
      else
        # No more properties found, the rest is the value
        val="$rest"
        remaining_str=""
      fi
    else
      # No '=' found in the remaining string, treat the whole string as key (or skip)
      key="$props_str"
      val=""
      remaining_str=""
    fi

    # Only add if key is not empty
    if [[ -n "$key" ]]; then
      [[ $first -eq 0 ]] && json+="," || first=0
      # Escape quotes and backslashes in the value for JSON
      # Use jq for robust escaping if available, otherwise a simple sed
      if command -v jq >/dev/null 2>&1; then
        # Use jq to escape the value and wrap in quotes
        local escaped_val=$(jq -R -s '.' <<< "$val" | sed 's/^"//; s/"$//') # Remove outer quotes added by jq -s '.'
        json+="\"$key\":\"$escaped_val\""
      else
        # Fallback simple escaping (less robust)
        local temp_val="${val//\\/\\\\}" # Escape backslashes
        temp_val="${temp_val//\"/\\\"}" # Escape double quotes
        # Escape newlines and carriage returns
        temp_val="${temp_val//$'\n'/\\n}"
        temp_val="${temp_val//$'\r'/\\r}"
        json+="\"$key\":\"$temp_val\"" # Use the escaped value here
      fi
    fi

    # Move to the next property
    props_str="$remaining_str"
    # Remove leading comma and whitespace for the next iteration
    props_str="$(echo -n "$props_str" | sed 's/^[[:space:]]*,*[[:space:]]*//')"
  done

  echo -n "{$json}"
}

# Parses SCDF REST API responses for embedded errors and warnings, even if
# multiple JSON objects are returned. Logs all error and warning messages
# to the log file and prints them to the terminal for visibility.
extract_and_log_api_messages() {
  local RESPONSE="$1"
  local LOGFILE="$2"
  echo "$RESPONSE" | awk 'BEGIN{RS="}{"; ORS=""} {if(NR>1) print "}{"; print $0}' | while read -r obj; do
    [[ "$obj" =~ ^\{ ]] || obj="{$obj" # Ensure it starts with {
    [[ "$obj" =~ \}$ ]] || obj="$obj}" # Ensure it ends with }
    ERRORS=$(echo "$obj" | jq -r '._embedded.errors[]?.message // empty' 2>/dev/null)
    if [[ -n "$ERRORS" ]]; then
      while IFS= read -r msg; do
        [[ -n "$msg" ]] && echo "ERROR: $msg" | tee -a "$LOGFILE"
      done <<< "$ERRORS"
    fi
    WARNINGS=$(echo "$obj" | jq -r '._embedded.warnings[]?.message // empty' 2>/dev/null)
    if [[ -n "$WARNINGS" ]]; then
      while IFS= read -r msg; do
        [[ -n "$msg" ]] && echo "WARNING: $msg" | tee -a "$LOGFILE"
      done <<< "$WARNINGS"
    fi
  done
}
