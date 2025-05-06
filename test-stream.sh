#!/bin/bash
# Deploys a simple 's3 | log' stream using Docker apps.
# Reads S3 config from create_stream.properties.
# Reads general config from scdf_env.properties.
# Includes s3.common.signing-algorithm property.

set -eo pipefail

# --- Configuration Files ---
ENV_PROPS_FILE="./scdf_env.properties"
STREAM_PROPS_FILE="./create_stream.properties"

# --- Static Config ---
STREAM_NAME="s3-log-test-from-props-v3" # New name
STREAM_DEF="s3 | log"
S3_SOURCE_APP_NAME="s3"
LOG_SINK_APP_NAME="log"

# Docker URIs
S3_SOURCE_DOCKER_URI="docker:springcloudstream/s3-source-rabbit:3.2.1"
LOG_SINK_DOCKER_URI="docker:springcloudstream/log-sink-rabbit:3.2.1"

# --- Prerequisites ---
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: 'jq' command is required but not installed. Please install jq (e.g., brew install jq)." >&2
    exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: 'curl' command is required but not installed." >&2
    exit 1
fi

# Source environment variables
if [ -f "$ENV_PROPS_FILE" ]; then
    set +u # Temporarily disable 'unset variable' error checking
    source "$ENV_PROPS_FILE"
    set -u # Re-enable check
else
    echo "ERROR: $ENV_PROPS_FILE not found!" >&2
    exit 1
fi

# Source stream properties
if [ -f "$STREAM_PROPS_FILE" ]; then
    set +u # Temporarily disable 'unset variable' error checking
    source "$STREAM_PROPS_FILE"
    set -u # Re-enable check
else
    echo "ERROR: $STREAM_PROPS_FILE not found!" >&2
    exit 1
fi

# Function to always set S3_ACCESS_KEY and S3_SECRET_KEY from Kubernetes
# Ensure NAMESPACE is set correctly (sourced from scdf_env.properties)
set_minio_creds() {
  echo "INFO: Fetching MinIO credentials from Kubernetes secret 'minio' in namespace '${NAMESPACE}'..."
  S3_ACCESS_KEY=$(kubectl get secret minio -n "${NAMESPACE}" -o jsonpath='{.data.root-user}' 2>/dev/null | base64 --decode | tr -d '\n\r')
  S3_SECRET_KEY=$(kubectl get secret minio -n "${NAMESPACE}" -o jsonpath='{.data.root-password}' 2>/dev/null | base64 --decode | tr -d '\n\r')

  if [[ -z "$S3_ACCESS_KEY" || -z "$S3_SECRET_KEY" ]]; then
    echo "ERROR: Failed to retrieve MinIO credentials from Kubernetes secret 'minio' in namespace '${NAMESPACE}'." >&2
    echo "INFO: Please ensure MinIO is installed and the secret exists, and kubectl is configured correctly." >&2
    exit 1
  else
    echo "INFO: MinIO credentials retrieved successfully."
    echo "DEBUG: Using credentials: S3_ACCESS_KEY=${S3_ACCESS_KEY}, S3_SECRET_KEY=${S3_SECRET_KEY}"
    # Export them just in case any part expects env vars, though we primarily use them directly
    export S3_ACCESS_KEY
    export S3_SECRET_KEY
  fi
}

# Fetch MinIO credentials before app registration or property construction
set_minio_creds

# --- Verify Required Variables ---
required_vars=( SCDF_SERVER_URL NAMESPACE S3_BUCKET S3_ENDPOINT S3_REGION S3_PATH_STYLE_ACCESS S3_POLLER_DELAY S3_SIGNING_ALGORITHM )
missing_vars=0
for var in "${required_vars[@]}"; do
    if [ -z "${!var+x}" ]; then # Check if variable is unset
        echo "ERROR: Required variable '$var' is not set (expected in $ENV_PROPS_FILE or $STREAM_PROPS_FILE)." >&2
        missing_vars=1
    fi
done
if [ $missing_vars -eq 1 ]; then
    exit 1
fi

echo "INFO: Test Stream Name: ${STREAM_NAME}"
echo "INFO: Test Stream Def:  ${STREAM_DEF}"
echo "INFO: SCDF URL:         ${SCDF_SERVER_URL}"
echo "INFO: S3 Endpoint:      ${S3_ENDPOINT}"
echo "INFO: S3 Bucket:        ${S3_BUCKET}"
echo "INFO: S3 Region:        ${S3_REGION}"
echo "INFO: S3 Path Style:    ${S3_PATH_STYLE_ACCESS}"
echo "INFO: S3 Poller Delay:  ${S3_POLLER_DELAY}"
echo "INFO: S3 Signing Algo:  ${S3_SIGNING_ALGORITHM}"
echo "---"

# --- Step 1: Verify/Register Apps ---
register_app_if_needed() {
    local type=$1 local name=$2 local uri=$3
    local props="${4:-}"
    local check_url="${SCDF_SERVER_URL}/apps/${type}/${name}"
    local reg_url="${SCDF_SERVER_URL}/apps/${type}/${name}"
    
    # Always unregister first
    echo "INFO: Unregistering ${type}/${name}..."
    curl -s -X DELETE "${check_url}" > /dev/null
    sleep 1
    
    # Register with new URI and properties
    echo "INFO: Registering ${type}/${name} with URI: ${uri}"
    local http_code
    if [[ -n "$props" ]]; then
        http_code=$(curl -s -w "%{http_code}" -o /dev/null -X POST "${reg_url}" -d "uri=${uri}" -d "force=true" -d "properties=${props}")
    else
        http_code=$(curl -s -w "%{http_code}" -o /dev/null -X POST "${reg_url}" -d "uri=${uri}" -d "force=true")
    fi
    if [[ "$http_code" == "201" || "$http_code" == "200" ]]; then 
        echo "INFO: Registration successful (HTTP ${http_code})."
    else 
        echo "ERROR: Registration failed for ${type}/${name} (HTTP ${http_code}). Aborting."
        exit 1
    fi
}

# --- Step 1: Verify/Register Apps ---
register_app_if_needed "source" "$S3_SOURCE_APP_NAME" "$S3_SOURCE_DOCKER_URI"
register_app_if_needed "sink" "$LOG_SINK_APP_NAME" "$LOG_SINK_DOCKER_URI"
echo "---"

# --- Step 2: Destroy Existing Stream ---
echo "INFO: Destroying existing stream '${STREAM_NAME}' (if any)..."
curl -s -X DELETE "${SCDF_SERVER_URL}/streams/deployments/${STREAM_NAME}" > /dev/null
curl -s -X DELETE "${SCDF_SERVER_URL}/streams/definitions/${STREAM_NAME}" > /dev/null
echo "INFO: Waiting 5 seconds for potential cleanup..."
sleep 5
echo "---"

# --- Step 3: Create Stream Definition ---
echo "INFO: Creating stream definition '${STREAM_NAME}'..."
CREATE_RESPONSE=$(curl -s -X POST "${SCDF_SERVER_URL}/streams/definitions" -d name="${STREAM_NAME}" -d definition="s3 \
    --s3.common.endpoint-url=http://minio.scdf.svc.cluster.local:9000 \
    --s3.common.path-style-access=true \
    --s3.supplier.local-dir=/tmp/test \
    --s3.supplier.remote-dir=test \
    --cloud.aws.credentials.accessKey=admin \
    --cloud.aws.credentials.secretKey=3e73Q6lFIa \
    --file.consumer.mode=ref \
    --cloud.aws.region.static=us-east-1 \
    --cloud.aws.stack.auto=false \
| log")
if ! echo "$CREATE_RESPONSE" | jq -e --arg name "$STREAM_NAME" '.name == $name' > /dev/null 2>&1; then echo "ERROR: Failed to create stream definition. Response:"; echo "$CREATE_RESPONSE" | jq .; exit 1; fi
echo "INFO: Stream definition created."
echo "$CREATE_RESPONSE" | jq .
echo "---"; sleep 2

# --- Step 4: Prepare Deployment Properties ---
echo "INFO: Skipping deployment properties; all configuration is set in the stream definition."

# --- Step 5: Deploy Stream ---
echo "INFO: Deploying stream '${STREAM_NAME}'..."
HTTP_CODE=$(curl -s -w "%{http_code}" -o deploy_response.json -X POST "${SCDF_SERVER_URL}/streams/deployments/${STREAM_NAME}")
# Handle response
if [[ "$HTTP_CODE" == "201" || "$HTTP_CODE" == "200" ]]; then
    echo "SUCCESS: Stream '${STREAM_NAME}' deployment initiated (HTTP ${HTTP_CODE})."
    echo "INFO: Monitor pod status with: kubectl get pods -n ${NAMESPACE} -l stream-name=${STREAM_NAME} -w"
    echo "INFO: Check logs of the s3 source pod: kubectl logs -f <s3-pod-name> -n ${NAMESPACE}"
    rm -f deploy_response.json
    exit 1
fi

# --- Function to debug S3 endpoint from within the running container ---
debug_s3_endpoint() {
    step_minor "Debugging S3 endpoint value inside the '$S3_SOURCE_APP_NAME' container"
    local pod_name
    local local_port=8081 # Local port for port-forwarding
    local pod_port=8080   # Default Spring Boot port
    local retries=10
    local count=0

    # Wait a bit for the pod to potentially start
    echo "Waiting up to 60 seconds for the pod to become ready..."
    kubectl wait --for=condition=ready pod -l "app=${S3_SOURCE_APP_NAME},spring.cloud.dataflow.stream.name=${STREAM_NAME}" -n "$NAMESPACE" --timeout=60s
    if [[ $? -ne 0 ]]; then
        echo "WARN: Pod did not become ready within 60 seconds. Attempting to proceed anyway."
    fi

    # Get the pod name
    pod_name=$(kubectl get pods -n "$NAMESPACE" -l "app=${S3_SOURCE_APP_NAME},spring.cloud.dataflow.stream.name=${STREAM_NAME}" -o jsonpath='{.items[0].metadata.name}')

    if [[ -z "$pod_name" ]]; then
        echo "ERROR: Could not find the pod for '$S3_SOURCE_APP_NAME' in stream '$STREAM_NAME'. Skipping debug."
        return 1
    fi

    echo "Found pod: $pod_name. Setting up port-forward..."
    kubectl port-forward -n "$NAMESPACE" "$pod_name" ${local_port}:${pod_port} &>/dev/null & # Run in background, suppress output
    local pf_pid=$!

    # Wait for port-forward to establish (give it a few seconds)
    sleep 5

    echo "Attempting to fetch S3 endpoint via Actuator..."
    local endpoint_value
    endpoint_value=$(curl --silent --max-time 10 "http://localhost:${local_port}/actuator/env/s3.common.endpoint-url" | jq -r '.property.value // "null"')

    # Clean up port-forward process
    kill $pf_pid &>/dev/null
    wait $pf_pid 2>/dev/null # Suppress killed message

    if [[ "$endpoint_value" == "null" ]] || [[ -z "$endpoint_value" ]]; then
        echo "ERROR: Failed to retrieve S3 endpoint value from Actuator. Check if Actuator is enabled and the pod is running correctly."
        echo "You might need to check pod logs: kubectl logs -n $NAMESPACE $pod_name"
        return 1
    else
        echo "*** S3 Endpoint URL reported inside container '$pod_name': $endpoint_value ***"
    fi

    return 0
}

# ====================
# Main Script Logic
# ====================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # --- Step 1: Verify/Register Apps ---
  register_app_if_needed "source" "$S3_SOURCE_APP_NAME" "$S3_SOURCE_DOCKER_URI"
  register_app_if_needed "sink" "$LOG_SINK_APP_NAME" "$LOG_SINK_DOCKER_URI"
  echo "---"

  # --- Step 2: Destroy Existing Stream ---
  echo "INFO: Destroying existing stream '${STREAM_NAME}' (if any)..."
  curl -s -X DELETE "${SCDF_SERVER_URL}/streams/deployments/${STREAM_NAME}" > /dev/null
  curl -s -X DELETE "${SCDF_SERVER_URL}/streams/definitions/${STREAM_NAME}" > /dev/null
  echo "INFO: Waiting 5 seconds for potential cleanup..."
  sleep 5
  echo "---"

  # --- Step 3: Create Stream Definition ---
  echo "INFO: Creating stream definition '${STREAM_NAME}'..."
  CREATE_RESPONSE=$(curl -s -X POST "${SCDF_SERVER_URL}/streams/definitions" -d name="${STREAM_NAME}" -d definition="s3 \
    --s3.common.endpoint-url=http://minio.scdf.svc.cluster.local:9000 \
    --s3.common.path-style-access=true \
    --s3.supplier.local-dir=/tmp/test \
    --s3.supplier.remote-dir=test \
    --cloud.aws.credentials.accessKey=admin \
    --cloud.aws.credentials.secretKey=3e73Q6lFIa \
    --file.consumer.mode=ref \
    --cloud.aws.region.static=us-east-1 \
    --cloud.aws.stack.auto=false \
| log")
  if ! echo "$CREATE_RESPONSE" | jq -e --arg name "$STREAM_NAME" '.name == $name' > /dev/null 2>&1; then echo "ERROR: Failed to create stream definition. Response:"; echo "$CREATE_RESPONSE" | jq .; exit 1; fi
  echo "INFO: Stream definition created."
  echo "$CREATE_RESPONSE" | jq .
  echo "---"; sleep 2

  # --- Step 4: Prepare Deployment Properties ---
  echo "INFO: Skipping deployment properties; all configuration is set in the stream definition."

  # --- Step 5: Deploy Stream ---
  echo "INFO: Deploying stream '${STREAM_NAME}'..."
  HTTP_CODE=$(curl -s -w "%{http_code}" -o deploy_response.json -X POST "${SCDF_SERVER_URL}/streams/deployments/${STREAM_NAME}")
  # Handle response
  if [[ "$HTTP_CODE" == "201" || "$HTTP_CODE" == "200" ]]; then
      echo "SUCCESS: Stream '${STREAM_NAME}' deployment initiated (HTTP ${HTTP_CODE})."
      echo "INFO: Monitor pod status with: kubectl get pods -n ${NAMESPACE} -l stream-name=${STREAM_NAME} -w"
      echo "INFO: Check logs of the s3 source pod: kubectl logs -f <s3-pod-name> -n ${NAMESPACE}"
      rm -f deploy_response.json
      exit 1
  fi

  # --- Step 6: Debug S3 Endpoint ---
  debug_s3_endpoint
  echo "---"

  exit 0
fi