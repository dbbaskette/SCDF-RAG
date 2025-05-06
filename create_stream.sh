#!/bin/bash
#
# create_stream.sh (REST API version, step-by-step)
#
# This script automates SCDF stream creation using only REST API calls.
# Use --test to run individual steps interactively.

# Ensure K8S_NAMESPACE is set, default to 'scdf' if not
K8S_NAMESPACE=${K8S_NAMESPACE:-scdf}

# ----------------------------------------------------------------------
# SCDF Platform Deployer Properties for RabbitMQ (Kubernetes)
# ----------------------------------------------------------------------
#
# To set RabbitMQ connection properties globally for all apps deployed via SCDF
# on Kubernetes, use the Platform Deployer model. This ensures all apps inherit
# these settings by default (no need to specify at deploy-time).
#
# 1. In the SCDF UI:
#    - Go to "Platforms" (left nav)
#    - Click your Kubernetes platform (e.g., 'kubernetes')
#    - Click "Edit"
#    - Add the following under "Global Deployer Properties":
#      spring.rabbitmq.host=scdf-rabbitmq
#      spring.rabbitmq.port=5672
#      spring.rabbitmq.username=user
#      spring.rabbitmq.password=bitnami
#    - Save and re-deploy your stream apps.
#
# 2. Alternatively, via the SCDF REST API:
#    curl -X POST "$SCDF_API_URL/platforms/kubernetes" \
#      -H 'Content-Type: application/json' \
#      -d '{"name":"kubernetes","type":"kubernetes","description":"K8s deployer","options":{"spring.rabbitmq.host":"scdf-rabbitmq","spring.rabbitmq.port":"5672","spring.rabbitmq.username":"user","spring.rabbitmq.password":"bitnami"}}'
#
# ----------------------------------------------------------------------
# Cloud Foundry Platform Deployer Properties (for future use)
# ----------------------------------------------------------------------
#
# When you add a Cloud Foundry platform to SCDF, set the same properties in the
# "Global Deployer Properties" for the Cloud Foundry platform. This ensures all
# apps deployed to CF inherit these settings by default.
#
# Example (in SCDF UI):
#   spring.rabbitmq.host=cf-rabbit-host
#   spring.rabbitmq.port=5672
#   spring.rabbitmq.username=cf-user
#   spring.rabbitmq.password=cf-password
#
# Or via the API (replace values as needed):
#   curl -X POST "$SCDF_API_URL/platforms/cloudfoundry" \
#     -H 'Content-Type: application/json' \
#     -d '{"name":"cloudfoundry","type":"cloudfoundry","description":"CF deployer","options":{"spring.rabbitmq.host":"cf-rabbit-host","spring.rabbitmq.port":"5672","spring.rabbitmq.username":"cf-user","spring.rabbitmq.password":"cf-password"}}'
#
# ----------------------------------------------------------------------

set -euo pipefail

# Check for jq at script launch
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: The 'jq' command is required but not installed. Please install jq and rerun this script." >&2
  exit 1
fi

# Always source shared environment variables first, regardless of mode
if [ -f ./scdf_env.properties ]; then
  source ./scdf_env.properties
else
  echo "scdf_env.properties not found! Exiting." >&2
  exit 1
fi

# Initialize optional deploy props variable to prevent unbound errors
EXTRA_DEPLOY_PROPS=""

# Source stream-specific overrides if present
if [ -f ./create_stream.properties ]; then
  source ./create_stream.properties
else
  echo "create_stream.properties not found! Exiting." >&2
  exit 1
fi

# Initialize APP_NAMES array from create_stream.properties (app_name_1, app_name_2, ...)
APP_NAMES=()
i=1
while true; do
  var_name="APP_NAME_$i"
  if [[ -z "${!var_name-}" ]]; then
    break
  fi
  APP_NAMES+=("${!var_name}")
  ((i++))
done

LOGDIR="$(pwd)/logs"
mkdir -p "$LOGDIR"
LOGFILE="create-stream.log"

# Log header for visual separation
{
  echo -e "\n\n\n"
  echo "#############################################################"
  echo "#   CREATE STREAM SCRIPT LOG   |   $(date '+%Y-%m-%d %H:%M:%S')   #"
  echo "#############################################################"
} >> "$LOGFILE"

# Use SCDF_SERVER_URL from env, not SCDF_URI from create_stream.properties
SCDF_API_URL=${SCDF_SERVER_URL:-http://localhost:30080}

# Ensure APP_NAMES and APP_IMAGES are always initialized, even if empty
APP_IMAGES=(${APP_IMAGES[@]:-})

# Always use Maven URIs for registration when APPS_PROPS_FILE_MAVEN is set
if [[ -n "$APPS_PROPS_FILE_MAVEN" ]]; then
  APPS_PROPS_FILE="$APPS_PROPS_FILE_MAVEN"
else
  APPS_PROPS_FILE="$APPS_PROPS_FILE_DOCKER"
fi

# Always define S3_APP_URI, LOG_APP_URI with fallback to empty string
S3_APP_URI=${S3_APP_URI:-$(grep '^source.s3=' "$APPS_PROPS_FILE" | cut -d'=' -f2- 2>/dev/null || echo '')}
LOG_APP_URI=${LOG_APP_URI:-$(grep '^sink.log=' "$APPS_PROPS_FILE" | cut -d'=' -f2- 2>/dev/null || echo '')}

# Function to always set S3_ACCESS_KEY and S3_SECRET_KEY from Kubernetes
set_minio_creds() {
  S3_ACCESS_KEY=$(kubectl get secret minio -n scdf -o jsonpath='{.data.root-user}' | base64 --decode 2>/dev/null || echo '')
  S3_SECRET_KEY=$(kubectl get secret minio -n scdf -o jsonpath='{.data.root-password}' | base64 --decode 2>/dev/null || echo '')
  export S3_ACCESS_KEY
  export S3_SECRET_KEY
}

# Helper to build JSON from comma-separated key=value pairs, skipping empty values
build_json_from_props() {
  local props="$1"
  local json=""
  local first=1
  # If props is empty, output {} and return
  if [[ -z "$props" ]]; then
    echo "{}"
    return
  fi
  IFS=',' read -ra PAIRS <<< "$props"
  for pair in "${PAIRS[@]}"; do
    key="${pair%%=*}"
    val="${pair#*=}"
    if [[ -n "$key" && -n "$val" ]]; then
      if [[ $first -eq 1 ]]; then
        json="\"$key\":\"$val\""
        first=0
      else
        json+=",\"$key\":\"$val\""
      fi
    fi
  done
  echo "DEBUG: build_json_from_props output: {$json}" >&2
  echo "{$json}"
}

# Improved: Robustly extract all errors/warnings from possibly multiple JSON objects in a response
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


# --- Step Functions ---

step_destroy_stream() {
  echo "[STEP] Destroy stream if exists"
  # Undeploy stream deployment if it exists
  DEPLOY_STATUS=$(curl -s "$SCDF_API_URL/streams/deployments/$STREAM_NAME")
  if [[ "$DEPLOY_STATUS" != *"not found"* ]]; then
    RESPONSE=$(curl -s -X DELETE "$SCDF_API_URL/streams/deployments/$STREAM_NAME" | tee -a "$LOGFILE")
    echo "Stream $STREAM_NAME undeployed."
  fi
  # Delete stream definition if it exists
  DEF_STATUS=$(curl -s "$SCDF_API_URL/streams/definitions/$STREAM_NAME")
  if [[ "$DEF_STATUS" != *"not found"* ]]; then
    RESPONSE=$(curl -s -X DELETE "$SCDF_API_URL/streams/definitions/$STREAM_NAME" | tee -a "$LOGFILE")
    echo "Stream $STREAM_NAME definition deleted."
  else
    echo "Stream $STREAM_NAME does not exist or could not be detected. No destroy needed."
  fi
  # Clean up orphaned deployments and pods matching the stream name (robust, no jq errors)
  echo "Checking for orphaned Kubernetes deployments and pods for stream $STREAM_NAME..."
  for dep in $(kubectl get deployments -n "$K8S_NAMESPACE" --no-headers -o custom-columns=":metadata.name" | grep "$STREAM_NAME" || true); do
    echo "Deleting orphaned deployment: $dep"
    kubectl delete deployment "$dep" -n "$K8S_NAMESPACE" || true
  done
  for pod in $(kubectl get pods -n "$K8S_NAMESPACE" --no-headers -o custom-columns=":metadata.name" | grep "$STREAM_NAME" || true); do
    echo "Deleting orphaned pod: $pod"
    kubectl delete pod "$pod" -n "$K8S_NAMESPACE" || true
  done

}

step_register_processor_apps() {
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

step_unregister_processor_apps() {
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

step_register_default_apps() {
  echo "[STEP] Register default apps (source:s3, sink:log) using Maven URIs"
  set_minio_creds
  echo "MinIO credentials fetched."
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

step_create_stream_definition() {
  echo "[STEP] Create stream definition"
  # Set both input-in-0 and input bindings and group for pdf-preprocessor
  STREAM_DEF="s3 \
    --s3.common.endpoint-url=$S3_ENDPOINT \
    --s3.common.path-style-access=true \
    --s3.supplier.local-dir=/tmp/test \
    --s3.supplier.remote-dir=$S3_BUCKET \
    --cloud.aws.credentials.accessKey=$S3_ACCESS_KEY \
    --cloud.aws.credentials.secretKey=$S3_SECRET_KEY \
    --cloud.aws.region.static=$S3_REGION \
    --cloud.aws.stack.auto=false \
    --spring.cloud.config.enabled=false \
    --s3.supplier.file-transfer-mode=$S3_FILE_TRANSFER_MODE \
    | pdf-preprocessor \
    | log"
  echo "DEBUG: Submitting stream definition:"
  echo "$STREAM_DEF"
#    --file.consumer.mode=ref \



  RESPONSE=$(curl -s -X POST "$SCDF_API_URL/streams/definitions" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d "name=$STREAM_NAME&definition=$STREAM_DEF" | tee -a "$LOGFILE")
  echo "Stream definition created: $STREAM_DEF"

  # Only run debug queries if creation appears successful
  if [[ "$RESPONSE" != *"errors"* ]]; then
    echo "DEBUG: S3 app options after registration:"
    curl -s "$SCDF_API_URL/apps/source/s3/options" | jq .
    echo "DEBUG: Stream deployment manifest after deployment:"
    curl -s "$SCDF_API_URL/streams/deployments/$STREAM_NAME" | jq .
  else
    echo "DEBUG: Stream definition creation failed, skipping manifest queries."
  fi
}

step_deploy_stream() {
  echo "[STEP] Deploy stream"
  set_minio_creds

  DEPLOY_PROPS="app.s3.spring.cloud.stream.bindings.output.destination=s3-to-pdf"
  DEPLOY_PROPS+=",app.s3.spring.cloud.stream.bindings.output.group=rag-pipeline"
  DEPLOY_PROPS+=",app.s3.spring.cloud.stream.bindings.supplier-out-0.destination=s3-to-pdf"
  DEPLOY_PROPS+=",app.s3.logging.level.org.springframework.cloud.stream=DEBUG"
  DEPLOY_PROPS+=",app.s3.logging.level.org.springframework.integration=DEBUG"
  DEPLOY_PROPS+=",app.s3.logging.level.org.springframework.cloud.stream.binder.rabbit=DEBUG"
  DEPLOY_PROPS+=",app.s3.logging.level.org.springframework.cloud.stream.app.s3.source=DEBUG"
  DEPLOY_PROPS+=",app.s3.logging.level.com.amazonaws=DEBUG"
  DEPLOY_PROPS+=",app.s3.logging.level.org.springframework.integration.aws=DEBUG"
  DEPLOY_PROPS+=",app.s3.logging.level.org.springframework.integration.file=DEBUG"
  DEPLOY_PROPS+=",app.pdf-preprocessor.spring.cloud.stream.bindings.input-in-0.destination=s3-to-pdf"
  DEPLOY_PROPS+=",app.pdf-preprocessor.spring.cloud.stream.bindings.input-in-0.group=rag-pipeline"
  DEPLOY_PROPS+=",app.pdf-preprocessor.spring.cloud.stream.bindings.input.destination=s3-to-pdf"
  DEPLOY_PROPS+=",app.pdf-preprocessor.spring.cloud.stream.bindings.input.group=rag-pipeline"
  DEPLOY_PROPS+=",app.pdf-preprocessor.spring.cloud.stream.bindings.output.destination=pdf-to-log"
  DEPLOY_PROPS+=",app.log.spring.cloud.stream.bindings.input.destination=pdf-to-log"
  if [[ -n "$EXTRA_DEPLOY_PROPS" ]]; then
    DEPLOY_PROPS+=",$EXTRA_DEPLOY_PROPS"
  fi
  echo "DEBUG: Final DEPLOY_PROPS : $DEPLOY_PROPS"
  # Print each deploy property on its own line for readability
  echo "DEBUG: Deploy properties list:"
  IFS=',' read -ra props <<< "$DEPLOY_PROPS"
  for kv in "${props[@]}"; do
    if [[ -n "$kv" ]]; then
      echo "  $kv"
    fi
  done
  unset IFS
  # Convert DEPLOY_PROPS to comma-separated for JSON helper
  DEPLOY_PROPS_COMMA="$DEPLOY_PROPS"
  DEPLOY_JSON=$(build_json_from_props "$DEPLOY_PROPS_COMMA")
  echo "DEBUG: DEPLOY_JSON for verification: $DEPLOY_JSON"
  RESPONSE=$(curl -s -X POST "$SCDF_API_URL/streams/deployments/$STREAM_NAME" \
    -H 'Content-Type: application/json' \
    -d "$DEPLOY_JSON")
  echo "DEBUG: Deploy API response: $RESPONSE"
  if [[ "$RESPONSE" == *"error"* || "$RESPONSE" == *"Exception"* ]]; then
    echo "ERROR: Stream deployment failed!"
  fi
  echo "Stream $STREAM_NAME deployed with properties: $DEPLOY_PROPS"
}
 
view_stream() {
  echo "[VIEW] Stream definition and status: $STREAM_NAME"
  curl -s "$SCDF_API_URL/streams/definitions/$STREAM_NAME" | jq . || echo "stream not found"
  echo
  echo "[VIEW] Stream deployment status: $STREAM_NAME"
  curl -s "$SCDF_API_URL/streams/deployments/$STREAM_NAME" | jq . || echo "deployment not found"
}

view_processor_apps() {
  echo "[VIEW] Processor apps registration and status -all pages:"
  # Get the total number of pages for /apps
  PAGE_INFO=$(curl -s "$SCDF_API_URL/apps?page=0&size=20")
  TOTAL_PAGES=$(echo "$PAGE_INFO" | jq -r '.page.totalPages')
  if [[ -z "$TOTAL_PAGES" || "$TOTAL_PAGES" == "null" ]]; then
    TOTAL_PAGES=1
  fi
  for ((page=0; page<TOTAL_PAGES; page++)); do
    echo "--- Page $page ---"
    curl -s "$SCDF_API_URL/apps?page=$page&size=20" | jq -c '._embedded.appRegistrationResourceList[] | select(.type=="processor") | {name,type,uri,version}'
  done
  echo
  i=1
  while true; do
    var_name="APP_NAME_$i"
    app_name="${!var_name-}"
    if [[ -z "$app_name" ]]; then
      break
    fi
    echo "--- Processor: $app_name ---"
    curl -s "$SCDF_API_URL/apps/processor/$app_name" | jq . || echo "not registered"
    echo "  [Options/Defaults for $app_name]:"
    curl -s "$SCDF_API_URL/apps/processor/$app_name/options" | jq . || echo "  no defaults set"
    echo
    ((i++))
  done
}

view_default_apps() {
  set_minio_creds
  echo "[VIEW] Default apps S3 source, log sink registration and status:"
  echo "Defined default app variables:"
  echo "  S3_APP_URI=${S3_APP_URI:-unset}"
  echo "  S3_ENDPOINT=${S3_ENDPOINT:-unset}"
  echo "  S3_ACCESS_KEY=${S3_ACCESS_KEY:-unset}"
  echo "  S3_SECRET_KEY=${S3_SECRET_KEY:-unset}"
  echo "  S3_BUCKET=${S3_BUCKET:-unset}"
  echo "  S3_REGION=${S3_REGION:-unset}"
  echo "  LOG_APP_URI=${LOG_APP_URI:-unset}"
  echo "  LOG_EXPRESSION=${LOG_EXPRESSION:-unset}"
  echo "  RABBIT_HOST=${RABBIT_HOST:-unset}"
  echo "  RABBIT_PORT=${RABBIT_PORT:-unset}"
  echo "  RABBITMQ_USER=${RABBITMQ_USER:-unset}"
  echo "  RABBITMQ_PASSWORD=${RABBITMQ_PASSWORD:-unset}"
  echo
  echo "--- S3 Source App Registration ---"
  curl -s "$SCDF_API_URL/apps/source/s3" | jq . || echo "S3 source not registered"
  echo "  Options/Defaults for S3:"
  curl -s "$SCDF_API_URL/apps/source/s3/options" | jq . || echo "  no defaults set"
  echo
  echo "--- Log Sink App Registration ---"
  curl -s "$SCDF_API_URL/apps/sink/log" | jq . || echo "log sink not registered"
  echo "  Options/Defaults for Log:"
  curl -s "$SCDF_API_URL/apps/sink/log/options" | jq . || echo "  no defaults set"
  echo
}

# Normal (non-test) execution: sequentially run all steps
step_destroy_stream
step_unregister_processor_apps
step_register_processor_apps
step_register_default_apps
step_create_stream_definition
step_deploy_stream
view_stream
