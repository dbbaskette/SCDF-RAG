#!/bin/bash
# utilities.sh - Utility/helper functions for SCDF automation scripts

# Converts a comma-separated properties string into a JSON object string.
# Handles special cases for Kubernetes environment variables.
build_json_from_props() {
  local props="$1"
  local json=""
  local first=1

  # Special handling for deployer.textProc.kubernetes.environmentVariables
  local k8s_env_key="deployer.textProc.kubernetes.environmentVariables="
  local k8s_env_value=""
  if [[ "$props" == *"$k8s_env_key"* ]]; then
    # Extract the value for the special key (everything after the key)
    k8s_env_value="${props#*${k8s_env_key}}"
    # If there are other properties after, cut at the next comma
    if [[ "$k8s_env_value" == *,* ]]; then
      k8s_env_value="${k8s_env_value%%,*}"
    fi
    # Remove the special property from the original string
    props="${props/${k8s_env_key}${k8s_env_value}/}"
    # Remove any leading or trailing commas
    props="${props#,}"
    props="${props%,}"
    # Replace ; and | with , in the env value
    k8s_env_value="${k8s_env_value//[;|]/,}"
  fi

  # Now process the remaining properties (split at commas)
  IFS=',' read -ra PAIRS <<< "$props"
  for pair in "${PAIRS[@]}"; do
    # Skip empty
    [[ -z "$pair" ]] && continue
    key="${pair%%=*}"
    val="${pair#*=}"
    # Remove possible surrounding spaces
    key="$(echo -n "$key" | xargs)"
    val="$(echo -n "$val" | xargs)"
    # Only add if key is not empty
    if [[ -n "$key" ]]; then
      [[ $first -eq 0 ]] && json+="," || first=0
      json+="\"$key\":\"$val\""
    fi
  done

  # Add the special env key if present
  if [[ -n "$k8s_env_value" ]]; then
    [[ $first -eq 0 ]] && json+="," || first=0
    json+="\"deployer.textProc.kubernetes.environmentVariables\":\"$k8s_env_value\""
  fi

  echo -n "{$json}"
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