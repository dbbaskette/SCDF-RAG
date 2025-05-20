#!/bin/bash
# app_registration.sh - App registration and deregistration functions for SCDF automation

# Registers all custom processor apps listed in create_stream.properties
step_register_processor_apps() {
  source_properties
  echo "[STEP] Register processor apps (Docker)"
  i=1
  while true; do
    var_name="APP_NAME_$i"
    image_var="APP_IMAGE_$i"
    app_name="${!var_name-}"
    app_image="${!image_var-}"
    if [[ -z "$app_name" && -z "$app_image" ]]; then
      break
    fi
    if [[ -z "$app_name" || -z "$app_image" ]]; then
      echo "WARNING: Skipping registration for index $i due to missing name or image: name='$app_name', image='$app_image'"
      ((i++))
      continue
    fi
    echo "Registering processor app $app_name with Docker image $app_image"
    RESPONSE=$(curl -s -X POST "$SCDF_API_URL/apps/processor/$app_name?uri=docker://$app_image" | tee -a "$LOGFILE")
    APP_JSON=$(curl -s "$SCDF_API_URL/apps/processor/$app_name")
    ERR_MSG=$(echo "$APP_JSON" | jq -r '._embedded.errors[]?.message // empty')
    if [[ -n "$ERR_MSG" ]]; then
      echo "ERROR: $ERR_MSG" | tee -a "$LOGFILE"
    else
      echo "Processor app $app_name registered successfully."
    fi
    ((i++))
  done
}


# Unregisters all custom processor apps
step_unregister_processor_apps() {
  source_properties
  echo "[STEP] Unregister processor apps if present"
  for idx in "${!APP_NAMES[@]}"; do
    name="${APP_NAMES[$idx]}"
    APP_JSON=$(curl -s "$SCDF_API_URL/apps/processor/$name")
    if [[ "$APP_JSON" != *"not found"* ]]; then
      RESPONSE=$(curl -s -X DELETE "$SCDF_API_URL/apps/processor/$name" | tee -a "$LOGFILE")
      echo "Processor app $name unregistered."
    else
      echo "Processor app $name not registered. No unregister needed."
    fi
  done
}


# Registers the default source (S3) and sink (log) apps using Maven URIs
step_register_default_apps() {
  source_properties
  echo "[STEP] Register default apps (source:s3, sink:log) using Maven URIs"
  # set_minio_creds removed; should only be called by default_s3_stream
  # Validate required S3 variables
  local missing=0
  for var in S3_APP_URI S3_ENDPOINT S3_ACCESS_KEY S3_SECRET_KEY S3_BUCKET S3_REGION; do
    if [[ -z "${!var}" ]]; then
      echo "ERROR: $var is unset!"
      missing=1
    fi
  done
  if [[ $missing -eq 1 ]]; then
    echo "ERROR: Missing required S3 variables. Aborting registration."
    return 1
  fi
  # Use Maven URIs from properties file for registration
  S3_MAVEN_URI=$(grep '^source.s3=' "$APPS_PROPS_FILE" | cut -d'=' -f2-)
  LOG_MAVEN_URI=$(grep '^sink.log=' "$APPS_PROPS_FILE" | cut -d'=' -f2-)
  echo "DEBUG: Using APPS_PROPS_FILE=$APPS_PROPS_FILE"
  echo "DEBUG: S3_MAVEN_URI=$S3_MAVEN_URI"
  echo "DEBUG: LOG_MAVEN_URI=$LOG_MAVEN_URI"
  if [[ -z "$S3_MAVEN_URI" || -z "$LOG_MAVEN_URI" ]]; then
    echo "ERROR: Maven URIs for S3 or Log app not found in $APPS_PROPS_FILE."
    return 1
  fi
  # Only set S3 logging properties for registration/options
  S3_PROPS=""
  echo "DEBUG: Final S3_PROPS (registration/options): $S3_PROPS"
  RESPONSE=$(curl -s -X POST "$SCDF_API_URL/apps/source/s3?uri=$S3_MAVEN_URI" | tee -a "$LOGFILE")
  APP_JSON=$(curl -s "$SCDF_API_URL/apps/source/s3")
  ERR_MSG=$(echo "$APP_JSON" | jq -r '._embedded.errors[]?.message // empty')
  if [[ -n "$ERR_MSG" ]]; then
    echo "ERROR: $ERR_MSG" | tee -a "$LOGFILE"
  else
    echo "S3 source app registered successfully."
  fi
  JSON_PAYLOAD=$(build_json_from_props "$S3_PROPS")
  echo "Registering S3 options with payload: $JSON_PAYLOAD"
  if [[ "$JSON_PAYLOAD" == "{}" ]]; then
    echo "ERROR: No S3 properties set. Skipping options registration."
  else
    RESPONSE=$(curl -s -X POST "$SCDF_API_URL/apps/source/s3/options?uri=$S3_MAVEN_URI" \
      -H 'Content-Type: application/json' \
      -d "$JSON_PAYLOAD" | tee -a "$LOGFILE")
    echo "S3 source app options set."
  fi
  RESPONSE=$(curl -s -X POST "$SCDF_API_URL/apps/sink/log?uri=$LOG_MAVEN_URI" | tee -a "$LOGFILE")
  APP_JSON=$(curl -s "$SCDF_API_URL/apps/sink/log")
  ERR_MSG=$(echo "$APP_JSON" | jq -r '._embedded.errors[]?.message // empty')
  if [[ -n "$ERR_MSG" ]]; then
    echo "ERROR: $ERR_MSG" | tee -a "$LOGFILE"
  else
    echo "Log sink app registered successfully."
  fi
  LOG_PROPS="logging.level.org.springframework.integration.aws=${LOG_LEVEL_SI_AWS:-INFO},logging.level.org.springframework.integration.file=${LOG_LEVEL_SI_FILE:-INFO},logging.level.com.amazonaws=${LOG_LEVEL_AWS_SDK:-INFO},logging.level.org.springframework.cloud.stream.app.s3.source=${LOG_LEVEL_S3_SOURCE:-INFO},log.log.expression=$LOG_EXPRESSION"
  JSON_PAYLOAD=$(build_json_from_props "$LOG_PROPS")
  echo "Registering log sink options with payload: $JSON_PAYLOAD"
  if [[ "$JSON_PAYLOAD" == "{}" ]]; then
    echo "ERROR: No log sink properties set. Skipping options registration."
  else
    RESPONSE=$(curl -s -X POST "$SCDF_API_URL/apps/sink/log/options?uri=$LOG_MAVEN_URI" \
      -H 'Content-Type: application/json' \
      -d "$JSON_PAYLOAD" | tee -a "$LOGFILE")
    echo "Log sink app options set."
  fi
}

