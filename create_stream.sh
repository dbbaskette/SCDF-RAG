#!/bin/bash
#
# create_stream.sh — Spring Cloud Data Flow Stream Automation (REST API version)
#
# Automates the full lifecycle of SCDF streams on Kubernetes using REST API calls.
# Key features:
#   - Registers source, processor, and sink apps (including custom Docker images)
#   - Builds and submits stream definitions (e.g. s3 | textProc | embedProc | log)
#   - Configures all deploy properties and bindings for correct message routing
#   - Supports interactive test mode for step-by-step management
#   - Fully documented for clarity and maintainability
#
# USAGE:
#   ./create_stream.sh           # Full pipeline: destroy, register, create, deploy, view
#   ./create_stream.sh --test    # Interactive menu for step-by-step stream management
#   ./create_stream.sh --test-embed  # Deploys a test stream for embedding processor verification
#
# Stream pipeline example:
#   s3 | textProc | embedProc | log
#   - s3: Reads files from MinIO/S3
#   - textProc: Processes text (https://github.com/dbbaskette/textProc)
#   - embedProc: Generates vector embeddings (https://github.com/dbbaskette/embedProc)
#   - log: Outputs results for inspection
#
# All configuration is loaded from:
#   - scdf_env.properties: Cluster-wide and SCDF platform settings
#   - create_stream.properties: Stream/app-specific settings
#
# For more details, see the README and function-level comments below.
#
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
# ----------------------------------------------------------------------
# set_minio_creds
#
# Fetches MinIO (S3) credentials from Kubernetes secrets in the 'scdf'
# namespace and exports them as environment variables for use by the
# rest of the script. Ensures that S3_ACCESS_KEY and S3_SECRET_KEY are
# always up-to-date for deployments.
# ----------------------------------------------------------------------
set_minio_creds() {
  S3_ACCESS_KEY=$(kubectl get secret minio -n scdf -o jsonpath='{.data.root-user}' | base64 --decode 2>/dev/null || echo '')
  S3_SECRET_KEY=$(kubectl get secret minio -n scdf -o jsonpath='{.data.root-password}' | base64 --decode 2>/dev/null || echo '')
  export S3_ACCESS_KEY
  export S3_SECRET_KEY
}

# ----------------------------------------------------------------------
# source_properties
#
# Loads environment and stream configuration from two properties files:
#   - scdf_env.properties: Cluster-wide and SCDF platform settings
#   - create_stream.properties: Stream-specific and app-specific settings
# Exits with error if either file is missing. Always refreshes S3 creds.
# ----------------------------------------------------------------------
source_properties() {
  if [ -f ./scdf_env.properties ]; then
    source ./scdf_env.properties
  else
    echo "scdf_env.properties not found! Exiting." >&2
    exit 1
  fi
  if [ -f ./create_stream.properties ]; then
    source ./create_stream.properties
  else
    echo "create_stream.properties not found! Exiting." >&2
    exit 1
  fi
  set_minio_creds
}

# Source properties at script start for initial setup
source_properties

# Initialize optional deploy props variable to prevent unbound errors
EXTRA_DEPLOY_PROPS=""

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
LOGFILE="$LOGDIR/create-stream.log"

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


# ----------------------------------------------------------------------
# build_json_from_props
#
# Converts a comma-separated string of key=value pairs into a JSON object
# string suitable for SCDF REST API deploy requests. Handles special case
# for deployer.textProc.kubernetes.environmentVariables, ensuring that
# environment variables are formatted as a single string with commas.
# Skips empty pairs and trims whitespace.
# ----------------------------------------------------------------------
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
    # Generalize: convert all semicolons to commas in every property value
    val="${val//;/,}"
    [[ -z "$key" ]] && continue
    if [[ $first -eq 1 ]]; then
      json="\"$key\":\"$val\""
      first=0
    else
      json+=",\"$key\":\"$val\""
    fi
  done
  # Note: All property values have semicolons converted to commas above.

  # Add the special property at the end (if present)
  if [[ -n "$k8s_env_value" ]]; then
    if [[ $first -eq 0 ]]; then
      json+=",";
    fi
    json+="\"deployer.textProc.kubernetes.environmentVariables\":\"$k8s_env_value\""
  fi

  # # echo "DEBUG: build_json_from_props output: {$json}" >&2
  echo "{$json}"
}

# ----------------------------------------------------------------------
# extract_and_log_api_messages
#
# Parses SCDF REST API responses for embedded errors and warnings, even if
# multiple JSON objects are returned. Logs all error and warning messages
# to the log file and prints them to the terminal for visibility.
# ----------------------------------------------------------------------
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


# ----------------------------------------------------------------------
# --- Step Functions ---
#
# Each step_* function implements a major stage in the SCDF stream lifecycle:
#   - step_destroy_stream: Remove any existing stream and clean up Kubernetes
#   - step_register_processor_apps: Register custom processor Docker apps
#   - step_register_default_apps: Register default source/sink apps via Maven
#   - step_create_stream_definition: Submit the stream definition to SCDF
#   - step_deploy_stream: Deploy the stream with all required deploy properties
#   - view_*: Utility functions for querying SCDF REST API
#   - test_*: Test streams for verifying S3 source, textProc, and embedding
# ----------------------------------------------------------------------

# ----------------------------------------------------------------------
# step_destroy_stream
#
# Removes any existing SCDF stream deployment and definition for $STREAM_NAME.
# Also cleans up orphaned Kubernetes deployments and pods matching the stream name.
# Ensures a clean slate before creating a new stream.
# ----------------------------------------------------------------------
step_destroy_stream() {
  source_properties
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

# ----------------------------------------------------------------------
# step_register_processor_apps
#
# Registers all custom processor apps listed in create_stream.properties
# as SCDF processor apps using their Docker image URIs. Skips any entry
# with missing name or image. Logs registration status and errors.
# ----------------------------------------------------------------------
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

# ----------------------------------------------------------------------
# step_register_default_apps
#
# Registers the default source (S3) and sink (log) apps using Maven URIs
# from the selected properties file. Also registers their options using
# build_json_from_props. Validates that all required S3 settings are present.
# ----------------------------------------------------------------------
step_register_default_apps() {
  source_properties
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

# ----------------------------------------------------------------------
# step_create_stream_definition
#
# Builds and submits the stream definition to SCDF via REST API. The stream
# definition string specifies the source, processors, and sink, along with
# all required app properties. Prints debug info and logs the result.
# ----------------------------------------------------------------------
step_create_stream_definition() {
  source_properties
  echo "[STEP] Create stream definition"
  # Set both input-in-0 and input bindings and group for pdf-preprocessor
  STREAM_DEF="s3 \
    --s3.common.endpoint-url=$S3_ENDPOINT \
    --s3.common.path-style-access=true \
    --s3.supplier.local-dir=/tmp/test \
    --s3.supplier.polling-delay=30000 \
    --s3.supplier.remote-dir=$S3_BUCKET \
    --cloud.aws.credentials.accessKey=$S3_ACCESS_KEY \
    --cloud.aws.credentials.secretKey=$S3_SECRET_KEY \
    --cloud.aws.region.static=$S3_REGION \
    --cloud.aws.stack.auto=false \
    --spring.cloud.config.enabled=false \
    --s3.supplier.file-transfer-mode=$S3_FILE_TRANSFER_MODE \
    | pdf-preprocessor \
    | embedding-processor \
    | log"
  echo "DEBUG: Submitting stream definition:"
  echo "$STREAM_DEF"
#    --file.consumer.mode=ref \



  RESPONSE=$(curl -s -X POST "$SCDF_API_URL/streams/definitions" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d "name=$STREAM_NAME&definition=$STREAM_DEF" | tee -a "$LOGFILE")
  echo "Stream definition created: $STREAM_DEF"

  # Only run debug queries if creation appears successful
  if [[ "$RESPONSE" != *"error"* || "$RESPONSE" == *"Exception"* ]]; then
    echo "DEBUG: S3 app options after registration:"
    curl -s "$SCDF_API_URL/apps/source/s3/options" | jq .
    echo "DEBUG: Stream deployment manifest after deployment:"
    curl -s "$SCDF_API_URL/streams/deployments/$STREAM_NAME" | jq .
  else
    echo "DEBUG: Stream definition creation failed, skipping manifest queries."
  fi
}

# ----------------------------------------------------------------------
# step_deploy_stream
#
# Builds the deploy properties string for the full pipeline and converts it
# to JSON using build_json_from_props. Submits the deploy request to SCDF
# via REST API. Logs the deploy JSON and result for troubleshooting.
# ----------------------------------------------------------------------
step_deploy_stream() {
  source_properties
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
  DEPLOY_PROPS+=",app.pdf-preprocessor.spring.cloud.stream.bindings.output.destination=pdf-to-pg"

  DEPLOY_PROPS+=",app.embedding-processor.spring.cloud.stream.bindings.input-in-0.destination=pdf-to-pg"
  DEPLOY_PROPS+=",app.embedding-processor.spring.cloud.stream.bindings.input-in-0.group=rag-pipeline"
  DEPLOY_PROPS+=",app.embedding-processor.spring.cloud.stream.bindings.input.destination=pdf-to-pg"
  DEPLOY_PROPS+=",app.embedding-processor.spring.cloud.stream.bindings.input.group=rag-pipeline"
  DEPLOY_PROPS+=",app.embedding-processor.spring.cloud.stream.bindings.output.destination=pg-to-log"

  DEPLOY_PROPS+=",app.log.spring.cloud.stream.bindings.input.destination=pg-to-log"
  DEPLOY_PROPS+=",app.log.spring.cloud.stream.bindings.input.group=rag-pipeline"
  DEPLOY_PROPS+=",app.log.spring.cloud.stream.bindings.input-in-0.destination=pg-to-log"
  DEPLOY_PROPS+=",app.log.spring.cloud.stream.bindings.input-in-0.group=rag-pipeline"
  DEPLOY_PROPS+=",app.log.logging.level.org.springframework.cloud.stream=DEBUG"
  DEPLOY_PROPS+=",app.log.logging.level.org.springframework.integration=DEBUG"
  DEPLOY_PROPS+=",app.log.logging.level.org.springframework.cloud.stream.binder.rabbit=DEBUG"



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
  source_properties
  echo "[VIEW] Stream definition and status: $STREAM_NAME"
  curl -s "$SCDF_API_URL/streams/definitions/$STREAM_NAME" | jq . || echo "stream not found"
  echo
  echo "[VIEW] Stream deployment status: $STREAM_NAME"
  curl -s "$SCDF_API_URL/streams/deployments/$STREAM_NAME" | jq . || echo "deployment not found"
}

view_processor_apps() {
  source_properties
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
  source_properties
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

# --- Delete S3 Source Test Stream ---
delete_test_s3_source() {
  local TEST_STREAM_NAME="test-s3-source"
  echo "[DELETE-TEST-S3-SOURCE] Deleting test stream: $TEST_STREAM_NAME"
  curl -s -X DELETE "$SCDF_API_URL/streams/deployments/$TEST_STREAM_NAME" > /dev/null
  curl -s -X DELETE "$SCDF_API_URL/streams/definitions/$TEST_STREAM_NAME" > /dev/null
  echo "[DELETE-TEST-S3-SOURCE] Test stream deleted."
}

# --- Delete textProc Pipeline Test Stream ---
delete_test_textproc_pipeline() {
  local TEST_STREAM_NAME="test-textproc-pipeline"
  echo "[DELETE-TEST-TEXTPROC] Deleting test stream: $TEST_STREAM_NAME"
  curl -s -X DELETE "$SCDF_API_URL/streams/deployments/$TEST_STREAM_NAME" > /dev/null
  curl -s -X DELETE "$SCDF_API_URL/streams/definitions/$TEST_STREAM_NAME" > /dev/null
  echo "[DELETE-TEST-TEXTPROC] Test stream deleted."
}

# --- Test S3 Source ---
test_s3_source() {
  echo "[TEST-S3-SOURCE] Creating test stream: s3 | log"
  local TEST_STREAM_NAME="test-s3-source"
  # Register S3 source and log sink apps (Maven URIs assumed)
  curl -s -X DELETE "$SCDF_API_URL/apps/source/s3" > /dev/null
  curl -s -X DELETE "$SCDF_API_URL/apps/sink/log" > /dev/null
  sleep 1
  curl -s -X POST "$SCDF_API_URL/apps/source/s3" -d "uri=docker:springcloudstream/s3-source-rabbit:3.2.1" -d "force=true"
  curl -s -X POST "$SCDF_API_URL/apps/sink/log" -d "uri=docker:springcloudstream/log-sink-rabbit:3.2.1" -d "force=true"
  # Destroy any existing test stream and wait for full deletion
  curl -s -X DELETE "$SCDF_API_URL/streams/deployments/$TEST_STREAM_NAME" > /dev/null
  curl -s -X DELETE "$SCDF_API_URL/streams/definitions/$TEST_STREAM_NAME" > /dev/null
  # Wait for deletion
  for i in {1..20}; do
    DEPLOY_STATUS=$(curl -s "$SCDF_API_URL/streams/deployments/$TEST_STREAM_NAME")
    DEF_STATUS=$(curl -s "$SCDF_API_URL/streams/definitions/$TEST_STREAM_NAME")
    if [[ "$DEPLOY_STATUS" == *"not found"* && "$DEF_STATUS" == *"not found"* ]]; then
      break
    fi
    sleep 1
  done
  # Create the test stream definition
  curl -s -X POST "$SCDF_API_URL/streams/definitions" \
    -d "name=$TEST_STREAM_NAME" \
    -d "definition=s3 | log"
  # Deploy the test stream with spring.profiles.active=scdf
  DEPLOY_PROPS="deployer.*.javaOpts=-Dspring.profiles.active=scdf"
  DEPLOY_JSON=$(build_json_from_props "$DEPLOY_PROPS")
  curl -s -X POST "$SCDF_API_URL/streams/deployments/$TEST_STREAM_NAME" \
    -H 'Content-Type: application/json' \
    -d "$DEPLOY_JSON"
  echo "[TEST-S3-SOURCE] Test stream deployed. To test, add a file to your configured S3 bucket and check the log sink output."
}


# ----------------------------------------------------------------------
# test_textproc_pipeline
#
# Creates and deploys a test stream: s3 | textProc | log. This function:
#   - Destroys any existing test-textproc-pipeline stream and processor registration
#   - Registers the textProc processor with SCDF (using the latest Docker image)
#   - Builds a stream definition connecting s3 -> textProc -> log
#   - Sets up all required deploy properties, including S3 credentials, channel bindings,
#     and logging levels for each app
#   - Converts deploy properties to JSON and deploys the stream via SCDF REST API
#   - Logs the deploy JSON and provides instructions for testing
#
# Usage: test_textproc_pipeline
# ----------------------------------------------------------------------
test_textproc_pipeline() {
  echo "[TEST-TEXTPROC] Creating test stream: s3 | textProc | embedProc | pgcopy"
  local TEST_STREAM_NAME="test-textproc-pipeline"
  # Destroy any existing test stream and definitions to ensure a clean slate
  curl -s -X DELETE "$SCDF_API_URL/streams/deployments/$TEST_STREAM_NAME" > /dev/null
  curl -s -X DELETE "$SCDF_API_URL/streams/definitions/$TEST_STREAM_NAME" > /dev/null
  # Remove any previous textProc and embedProc processor registrations
  curl -s -X DELETE "$SCDF_API_URL/apps/processor/textProc" > /dev/null
  curl -s -X DELETE "$SCDF_API_URL/apps/processor/embedProc" > /dev/null
  sleep 1
  # Register the textProc processor with the latest Docker image
  curl -s -X POST "$SCDF_API_URL/apps/processor/textProc" -d "uri=docker:dbbaskette/textproc:latest" -d "force=true"
  # Register the embedProc processor with the latest Docker image
  curl -s -X POST "$SCDF_API_URL/apps/processor/embedProc" -d "uri=docker:dbbaskette/embedproc:latest" -d "force=true"

  # Wait for the processor deregistration to propagate before proceeding
  for i in {1..20}; do
    DEF_STATUS=$(curl -s "$SCDF_API_URL/apps/processor/textProc")
    DEF_STATUS_EMBED=$(curl -s "$SCDF_API_URL/apps/processor/embedProc")
    if [[ "$DEF_STATUS" == *"not found"* && "$DEF_STATUS_EMBED" == *"not found"* ]]; then
      break
    fi
    sleep 1
  done
  # Build the test stream definition with all required S3 source properties, now using pgcopy as sink
  STREAM_DEF="s3 \
    --s3.common.endpoint-url=$S3_ENDPOINT \
    --s3.common.path-style-access=true \
    --s3.supplier.local-dir=/tmp/test \
    --s3.supplier.polling-delay=30000 \
    --s3.supplier.remote-dir=$S3_BUCKET \
    --cloud.aws.credentials.accessKey=$S3_ACCESS_KEY \
    --cloud.aws.credentials.secretKey=$S3_SECRET_KEY \
    --cloud.aws.region.static=$S3_REGION \
    --cloud.aws.stack.auto=false \
    --spring.cloud.config.enabled=false \
    --s3.supplier.file-transfer-mode=$S3_FILE_TRANSFER_MODE \
    --s3.supplier.list-only=true \
    | textProc | embedProc | pgcopy"
  curl -s -X POST "$SCDF_API_URL/streams/definitions" \
    -d "name=$TEST_STREAM_NAME" \
    -d "definition=$STREAM_DEF" > /dev/null
  # Build deploy properties string and JSON
 
  DEPLOY_PROPS="deployer.textProc.kubernetes.environmentVariables=S3_ENDPOINT=${S3_ENDPOINT};S3_ACCESS_KEY=${S3_ACCESS_KEY};S3_SECRET_KEY=${S3_SECRET_KEY}"

  # s3 source
  DEPLOY_PROPS+=",app.s3.spring.cloud.stream.bindings.output.destination=s3-to-textproc"
  DEPLOY_PROPS+=",app.s3.spring.cloud.stream.bindings.output.group=${TEST_STREAM_NAME}"
  DEPLOY_PROPS+=",app.s3.logging.level.org.springframework.cloud.stream=INFO"
  DEPLOY_PROPS+=",app.s3.logging.level.org.springframework.integration=INFO"
  DEPLOY_PROPS+=",app.s3.logging.level.org.springframework.cloud.stream.binder.rabbit=INFO"
  DEPLOY_PROPS+=",app.s3.logging.level.org.springframework.cloud.stream.app.s3.source=INFO"
  DEPLOY_PROPS+=",app.s3.logging.level.com.amazonaws=INFO"

  # textProc processor
  DEPLOY_PROPS+=",app.textProc.spring.profiles.active=scdf"
  DEPLOY_PROPS+=",app.textProc.spring.cloud.function.definition=textProc"
  DEPLOY_PROPS+=",app.textProc.spring.cloud.stream.bindings.textProc-in-0.destination=s3-to-textproc"
  DEPLOY_PROPS+=",app.textProc.spring.cloud.stream.bindings.textProc-in-0.group=${TEST_STREAM_NAME}"
  DEPLOY_PROPS+=",app.textProc.spring.cloud.stream.bindings.textProc-out-0.destination=textproc-to-embedproc"
  DEPLOY_PROPS+=",app.textProc.logging.level.org.springframework.cloud.stream=INFO"
  DEPLOY_PROPS+=",app.textProc.logging.level.org.springframework.integration=INFO"
  DEPLOY_PROPS+=",app.textProc.logging.level.org.springframework.cloud.stream.binder.rabbit=INFO"
  DEPLOY_PROPS+=",app.textProc.logging.level.org.springframework.cloud.stream.app.textProc.processor=INFO"
  DEPLOY_PROPS+=",app.textProc.logging.level.com.baskettecase.textProc=INFO"

  # embedProc processor
  DEPLOY_PROPS+=",app.embedProc.spring.profiles.active=scdf"
  DEPLOY_PROPS+=",app.embedProc.spring.cloud.function.definition=embedProc"
  DEPLOY_PROPS+=",app.embedProc.spring.cloud.stream.bindings.embedProc-in-0.destination=textproc-to-embedproc"
  DEPLOY_PROPS+=",app.embedProc.spring.cloud.stream.bindings.embedProc-in-0.group=${TEST_STREAM_NAME}"
  DEPLOY_PROPS+=",app.embedProc.spring.cloud.stream.bindings.embedProc-out-0.destination=embedproc-to-pgcopy"
  DEPLOY_PROPS+=",app.embedProc.logging.level.org.springframework.cloud.stream=INFO"
  DEPLOY_PROPS+=",app.embedProc.logging.level.org.springframework.integration=INFO"
  DEPLOY_PROPS+=",app.embedProc.logging.level.org.springframework.cloud.stream.binder.rabbit=INFO"
  DEPLOY_PROPS+=",app.embedProc.logging.level.org.springframework.cloud.stream.app.embedProc.processor=INFO"
  DEPLOY_PROPS+=",app.embedProc.logging.level.com.baskettecase.embedProc=INFO"

  # pgcopy sink
  DEPLOY_PROPS+=",app.pgcopy.spring.cloud.stream.bindings.input.destination=embedproc-to-pgcopy"
  DEPLOY_PROPS+=",app.pgcopy.spring.cloud.stream.bindings.input.group=${TEST_STREAM_NAME}"
  DEPLOY_PROPS+=",app.pgcopy.spring.datasource.url=jdbc:postgresql://${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
  DEPLOY_PROPS+=",app.pgcopy.spring.datasource.username=${POSTGRES_USER}"
  DEPLOY_PROPS+=",app.pgcopy.spring.datasource.password=${POSTGRES_PASSWORD}"
  DEPLOY_PROPS+=",app.pgcopy.pgcopy.tableName=items"
  # DEPLOY_PROPS+=",app.pgcopy.pgcopy.columns=content;embedding;metadata"
  # DEPLOY_PROPS+=",app.pgcopy.pgcopy.fields=text;embedding;metadata"
  DEPLOY_PROPS+=",app.pgcopy.pgcopy.columns=embedding"
  DEPLOY_PROPS+=",app.pgcopy.pgcopy.fields=embedding"
  DEPLOY_PROPS+=",app.pgcopy.spring.cloud.config.enabled=false"

  # pgcopy SQL-level logging
  DEPLOY_PROPS+=",app.pgcopy.spring.jpa.show-sql=true"
  DEPLOY_PROPS+=",app.pgcopy.spring.jpa.properties.hibernate.format_sql=true"
  DEPLOY_PROPS+=",app.pgcopy.logging.level.org.hibernate.SQL=DEBUG"
  DEPLOY_PROPS+=",app.pgcopy.logging.level.org.hibernate.type.descriptor.sql.BasicBinder=TRACE"
  DEPLOY_PROPS+=",app.pgcopy.logging.level.org.springframework.jdbc.core=DEBUG"
  DEPLOY_PROPS+=",app.pgcopy.logging.level.org.springframework.jdbc.datasource=DEBUG"
  DEPLOY_PROPS+=",app.pgcopy.logging.level.org.springframework.cloud.stream=INFO"
  DEPLOY_PROPS+=",app.pgcopy.logging.level.org.springframework.integration=INFO"
  DEPLOY_PROPS+=",app.pgcopy.logging.level.org.springframework.cloud.stream.binder.rabbit=INFO"
  DEPLOY_PROPS+=",app.pgcopy.logging.level.org.springframework.integration.handler.LoggingHandler=DEBUG"
  DEPLOY_PROPS+=",app.pgcopy.logging.level.org.springframework.messaging=DEBUG"

  
  
  DEPLOY_JSON=$(build_json_from_props "$DEPLOY_PROPS")
  echo "DEPLOY_JSON for $TEST_STREAM_NAME: $DEPLOY_JSON" >> "$LOGFILE"
  # Deploy the test stream with processor environment variables and spring.profiles.active=scdf
  curl -s -X POST "$SCDF_API_URL/streams/deployments/$TEST_STREAM_NAME" \
    -H 'Content-Type: application/json' \
    -d "$DEPLOY_JSON" > /dev/null
  echo "[TEST-TEXTPROC] Test stream deployed. To test, add a file to your configured S3 bucket and check the pgcopy sink output."
}

# --- Test Embed Stream ---``
if [[ "$1" == "--test-embed" ]]; then
  echo "[TEST-EMBED] Creating test stream: file source | embedding-processor | log sink"
  TEST_STREAM_NAME="test-embed-stream"
  # Register file source, embedding processor, and log sink apps
  curl -s -X DELETE "$SCDF_API_URL/apps/source/file" > /dev/null
  curl -s -X DELETE "$SCDF_API_URL/apps/processor/embedding-processor" > /dev/null
  curl -s -X DELETE "$SCDF_API_URL/apps/sink/log" > /dev/null
  sleep 1
  curl -s -X POST "$SCDF_API_URL/apps/source/file" -d "uri=docker:springcloudstream/file-source-rabbit:3.2.1" -d "force=true"
  curl -s -X POST "$SCDF_API_URL/apps/processor/embedding-processor" -d "uri=docker:dbbaskette/embedding-processor:0.0.1-SNAPSHOT" -d "force=true"
  curl -s -X POST "$SCDF_API_URL/apps/sink/log" -d "uri=docker:springcloudstream/log-sink-rabbit:3.2.1" -d "force=true"
  # Destroy any existing test stream and wait for full deletion
  curl -s -X DELETE "$SCDF_API_URL/streams/deployments/$TEST_STREAM_NAME" > /dev/null
  curl -s -X DELETE "$SCDF_API_URL/streams/definitions/$TEST_STREAM_NAME" > /dev/null
  # Wait for deletion
  for i in {1..20}; do
    DEPLOY_STATUS=$(curl -s "$SCDF_API_URL/streams/deployments/$TEST_STREAM_NAME")
    DEF_STATUS=$(curl -s "$SCDF_API_URL/streams/definitions/$TEST_STREAM_NAME")
    if [[ "$DEPLOY_STATUS" == *"not found"* && "$DEF_STATUS" == *"not found"* ]]; then
      break
    fi
    sleep 1
  done
  # Create the test stream definition
  curl -s -X POST "$SCDF_API_URL/streams/definitions" \
    -d "name=$TEST_STREAM_NAME" \
    -d "definition=file --file.directory=/tmp/test | embedding-processor | log"
  # Deploy the test stream
  curl -s -X POST "$SCDF_API_URL/streams/deployments/$TEST_STREAM_NAME"
  echo "[TEST-EMBED] Test stream deployed. To test, put a file in /tmp/test in the file source pod."
  exit 0
fi

# --- Interactive Test Mode ---
show_menu() {
  echo
  echo "SCDF Stream Creation Test Menu"
  echo "-----------------------------------"
  echo "1) Destroy stream"
  echo "2) Unregister processor apps"
  echo "3) Register processor apps"
  echo "4) Register default apps"
  echo "5) Create stream definition"
  echo "6) Deploy stream"
  echo "7) View stream status"
  echo "8) View registered processor apps"
  echo "9) View default apps"
  echo "t1) Test S3 source (s3 | log)"
  echo "t2) Test textProc pipeline (s3 | textProc | embedProc | postgres)"
  echo "q) Exit"
  echo -n "Select a step to run [1-9, t1, t2, q to quit]: "
}

if [[ "$1" == "--test" ]]; then
  while true; do
    show_menu
    read -r choice
    case $choice in
      1)
        step_destroy_stream
        ;;
      2)
        step_unregister_processor_apps
        ;;
      3)
        step_register_processor_apps
        ;;
      4)
        step_register_default_apps
        ;;
      5)
        step_create_stream_definition
        ;;
      6)
        step_deploy_stream
        ;;
      7)
        view_stream
        ;;
      8)
        view_processor_apps
        ;;
      9)
        view_default_apps
        ;;
      t1)
        test_s3_source
        ;;
      t2)
        test_textproc_pipeline
        ;;

      q|Q)
        echo "Exiting."
        exit 0
        ;;
      *)
        echo "Invalid option. Please select 1-9, t1, t2 or q to quit."
        ;;
    esac
    echo
    echo "--- Step complete. Return to menu. ---"
  done
  exit 0
fi

# Normal (non-test) execution: sequentially run all steps
step_destroy_stream
step_unregister_processor_apps
step_register_processor_apps
step_register_default_apps
step_create_stream_definition
step_deploy_stream
view_stream
