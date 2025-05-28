#!/bin/bash
# utilities.sh - Utility/helper functions for SCDF automation scripts

# Converts a comma-separated properties string into a JSON object string.
# Handles special cases for Kubernetes environment variables.
build_json_from_props() {
  # Input string should already be cleaned of \n and \r by the caller
  local props_str="$1"
  local json_pairs_array=() # Store "key":"value" pairs

  # The input props_str from test_hdfs_app.sh might start with a comma.
  # Remove the leading comma if it exists.
  if [[ "$props_str" == ,* ]]; then
    props_str="${props_str#*,}"
  fi

  # Use a more robust IFS for splitting, handling potential whitespace around commas
  local OLD_IFS="$IFS"
  IFS=',' read -ra PAIRS <<< "$props_str"
  IFS="$OLD_IFS"

  for pair in "${PAIRS[@]}"; do
    if [[ -z "$pair" ]]; then
      continue
    fi

    key="${pair%%=*}"
    val="${pair#*=}"

    # Keys and values should be clean of \n and \r at this point.
    # Trim only leading/trailing spaces and tabs using sed.
    key="$(echo -n "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    val="$(echo -n "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"



    # Only add if key is not empty
    if [[ -n "$key" ]]; then
      # Use jq to correctly escape the key and value for JSON.
      # jq -R inputs raw string, -s slurps all input into one string, '.' outputs it as a JSON string.
      # The output of jq -R -s '.' already includes the surrounding quotes for a JSON string.
      escaped_key=$(jq -R -s '.' <<< "$key") 
      escaped_val=$(jq -R -s '.' <<< "$val") 
      json_pairs_array+=("${escaped_key}:${escaped_val}")
    fi
  done

  local final_json_content=""
  if [ ${#json_pairs_array[@]} -gt 0 ]; then
    # Join the "key":"value" pairs with commas
    IFS=',' final_json_content="${json_pairs_array[*]}"
  fi
  echo -n "{${final_json_content}}"

}

# Parses SCDF REST API responses for embedded errors and warnings, even if
# multiple JSON objects are returned. Logs all error and warning messages
# to the log file and prints them to the terminal for visibility.
extract_and_log_api_messages() {
  local RESPONSE="$1"
  local LOGFILE="$2"
  echo "$RESPONSE" | awk 'BEGIN{RS="}{"; ORS=""} {if(NR>1) print "}{"; print $0}' | while read -r obj; do
    [[ "$obj" =~ ^\{ ]] || obj="{$obj"
    [[ "$obj" =~ \}$ ]] || obj="$obj}"
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