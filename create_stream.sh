#!/bin/bash
# Source environment setup and credentials functions
source "$(dirname "$0")/functions/env_setup.sh"
# Source app registration functions
source "$(dirname "$0")/functions/app_registration.sh"
# Source test pipeline functions
source "$(dirname "$0")/functions/test_textproc_pipeline.sh"
source "$(dirname "$0")/functions/test_new_embedproc_pipeline.sh"
# Source stream destroy step
source "$(dirname "$0")/functions/step_destroy_stream.sh"
# Source utility functions
source "$(dirname \"$0\")/functions/utilities.sh"
# Source viewer functions
source "$(dirname \"$0\")/functions/viewers.sh"
# Source menu function
source "$(dirname \"$0\")/functions/menu.sh"
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


if [[ "$1" == "--test" ]]; then
  while true; do
    show_menu
    read -r choice
    case $choice in
      t1)
        test_s3_source
        ;;
      t2)
        test_textproc_pipeline
        ;;
      t3)
        test_new_embedproc_pipeline
        ;;
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
