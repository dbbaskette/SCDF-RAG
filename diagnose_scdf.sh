#!/bin/bash
#
# diagnose_scdf.sh: Diagnostic script for SCDF deployment issues
# Place this script in the SCDF-RAG project directory.
# Usage: ./diagnose_scdf.sh

set -euo pipefail

# --- Configuration ---
ENV_PROPS_FILE="./scdf_env.properties"
STREAM_TO_DEBUG="rag-pipeline" # Your problematic stream name
APP_TO_DEBUG="s3"             # The Maven app causing issues in the stream

# --- Helper Functions ---
print_header() {
  echo ""
  echo "-----------------------------------------------------------------------"
  echo " $1"
  echo "-----------------------------------------------------------------------"
}

check_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: Required command '$1' not found. Please install it." >&2
    exit 1
  fi
}

# --- Pre-checks ---
check_command kubectl
check_command curl
check_command jq

if [ ! -f "$ENV_PROPS_FILE" ]; then
  echo "ERROR: Environment properties file not found at '$ENV_PROPS_FILE'" >&2
  exit 1
fi

# Source environment variables (adjust path if needed)
# shellcheck source=./scdf_env.properties
source "$ENV_PROPS_FILE"
echo "INFO: Loaded environment variables from $ENV_PROPS_FILE"
echo "INFO: Using SCDF Server URL: ${SCDF_SERVER_URL}"
echo "INFO: Using Kubernetes Namespace: ${NAMESPACE}"
echo ""

# --- Diagnostic Steps ---

# 1. Verify App Registration
check_app_registration() {
  print_header "[Step 1] Checking App Registration ('${APP_TO_DEBUG}' source)"
  local url="${SCDF_SERVER_URL}/apps/source/${APP_TO_DEBUG}"
  echo "INFO: Querying SCDF API: $url"
  local response
  response=$(curl -s "$url")

  if echo "$response" | jq empty > /dev/null 2>&1; then
    echo "$response" | jq .
    echo ""
    local uri
    uri=$(echo "$response" | jq -r '.uri // empty')
    local default_version
    default_version=$(echo "$response" | jq -r '.defaultVersion // empty')

    echo "ASSERTION CHECK:"
    if [[ "$uri" == maven://* ]]; then
      echo "  [PASS] URI starts with 'maven://': $uri"
    else
      echo "  [FAIL] URI does not start with 'maven://' or is missing: $uri"
    fi
    if [[ "$default_version" == "true" ]]; then
      echo "  [PASS] Default version is true."
    else
      echo "  [FAIL] Default version is not true: $default_version"
    fi
  else
    echo "ERROR: Failed to parse JSON response from SCDF or app not found."
    echo "Raw response: $response"
  fi
  read -n 1 -s -r -p "Press any key to continue to the next step..."
  echo
}

# 2. Inspect Kubernetes Platform Configuration
check_platform_config() {
  print_header "[Step 2] Checking Kubernetes Platform Configuration"
  local platform_name="default"
  local url="${SCDF_SERVER_URL}/platforms/${platform_name}"
  echo "INFO: Querying SCDF API: $url (trying platform '${platform_name}' first)"
  local response
  response=$(curl -s "$url")

  # Check if the response indicates an error or is empty, then try 'kubernetes'
  if echo "$response" | jq -e '._embedded.errors // empty' > /dev/null 2>&1 || [[ -z "$response" ]]; then
    platform_name="kubernetes" # Fallback platform name
    url="${SCDF_SERVER_URL}/platforms/${platform_name}"
    echo "INFO: Platform 'default' not found or error, trying '${platform_name}': $url"
    response=$(curl -s "$url")
  fi

  # Check if the final response is valid JSON and doesn't contain errors
  if echo "$response" | jq empty > /dev/null 2>&1 && ! echo "$response" | jq -e '._embedded.errors // empty' > /dev/null 2>&1; then
      echo "INFO: Found configuration for platform '${platform_name}':"
      echo "$response" | jq .
      echo ""
      echo "CHECK: Look for a 'maven' block within 'options' or properties like 'imagePullerTaskLauncher', 'thinJar', 'containerImageFormat', 'buildResources'."
      echo "       These control how Maven artifacts are deployed."
  else
      echo "ERROR: Could not retrieve valid configuration for platform 'default' or 'kubernetes'."
      echo "Raw response for platform '${platform_name}': $response"
  fi
  read -n 1 -s -r -p "Press any key to continue to the next step..."
  echo
}

# 3. Deploy a Minimal Maven-Only Test Stream
deploy_test_maven_stream() {
  print_header "[Step 3] Deploying Test Maven-Only Stream (s3 | log)"
  local test_stream_name="diag-s3-log"
  local test_stream_def="s3 | log" # Assumes s3 source and log sink are registered via Maven

  echo "INFO: This step tests if *any* Maven-based stream can deploy."
  echo "      Stream Name: ${test_stream_name}"
  echo "      Definition:  ${test_stream_def}"
  echo ""
  echo "INFO: Destroying previous test stream (if any)..."
  # Silence errors, just try to delete
  curl -s -X DELETE "${SCDF_SERVER_URL}/streams/deployments/${test_stream_name}" > /dev/null
  curl -s -X DELETE "${SCDF_SERVER_URL}/streams/definitions/${test_stream_name}" > /dev/null
  echo "INFO: Waiting 5 seconds for potential cleanup..."
  sleep 5

  echo "INFO: Creating definition..."
  local create_response
  create_response=$(curl -s -X POST "${SCDF_SERVER_URL}/streams/definitions" \
    -d name="${test_stream_name}" -d definition="${test_stream_def}")
  # Check if response contains the stream name, indicating success
  if ! echo "$create_response" | jq -e --arg name "$test_stream_name" '.name == $name' > /dev/null 2>&1; then
     echo "ERROR: Failed to create stream definition. Response:"
     echo "$create_response" | jq .
     echo "Skipping deployment."
     read -n 1 -s -r -p "Press any key to continue..."
     echo
     return 1 # Indicate failure
  fi
  echo "$create_response" | jq .
  sleep 2

  echo "INFO: Deploying stream (using platform defaults)..."
  local deploy_response
  deploy_response=$(curl -s -X POST "${SCDF_SERVER_URL}/streams/deployments/${test_stream_name}" \
    -H 'Content-Type: application/json' \
    -d '{}') # Deploy with empty properties, relying on platform config
  echo "$deploy_response" | jq .
  echo ""
  echo "ACTION REQUIRED:"
  echo " --> Monitor pod status in another terminal using:"
  echo "       kubectl get pods -n ${NAMESPACE} -l stream-name=${test_stream_name} -w"
  echo " --> Wait until pods are Running/Completed or enter a failed state (e.g., ImagePullBackOff, ErrImagePull)."
  echo " --> If pods fail with image errors, it confirms a general Maven deployment issue."
  echo ""
  read -n 1 -s -r -p "Press any key once you have observed the test stream deployment status..."
  echo
  return 0 # Indicate success (or at least initiated)
}

# 4. Check Skipper Logs During Problematic Stream Deployment
get_skipper_logs() {
  print_header "[Step 4] Checking Skipper Logs During '${STREAM_TO_DEBUG}' Deployment"
  echo "INFO: Finding Skipper pod..."
  local skipper_pod
  # Try to get the running skipper pod name
  skipper_pod=$(kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/instance=scdf,app.kubernetes.io/component=skipper" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -z "$skipper_pod" ]]; then
    echo "ERROR: Could not find a running Skipper pod in namespace ${NAMESPACE}."
    echo "       Skipping Skipper log check."
    read -n 1 -s -r -p "Press any key to continue..."
    echo
    return
  fi

  echo "INFO: Found Skipper pod: ${skipper_pod}"
  echo ""
  echo "ACTION REQUIRED:"
  echo " 1. This script will now start tailing logs from Skipper."
  echo " 2. WHILE THE LOGS ARE BEING TAILED (in this terminal):"
  echo "    Go to another terminal or the SCDF UI and deploy your problematic stream: '${STREAM_TO_DEBUG}'."
  echo "    (e.g., run './create_stream.sh' if it deploys '${STREAM_TO_DEBUG}')"
  echo " 3. Watch the logs here for errors related to '${STREAM_TO_DEBUG}', app '${APP_TO_DEBUG}', Maven resolution, or Kubernetes deployment creation."
  echo " 4. Press Ctrl+C in THIS terminal when you are finished observing the logs."
  echo ""
  read -n 1 -s -r -p "Press any key to start tailing Skipper logs..."
  echo

  # Tail the logs - this will run until user presses Ctrl+C
  kubectl logs -f -n "${NAMESPACE}" "${skipper_pod}"

  # Script resumes here after Ctrl+C is pressed
  echo ""
  echo "INFO: Stopped tailing Skipper logs."
  read -n 1 -s -r -p "Press any key to continue to the next step..."
  echo
}

# 5. Describe the Failing Pod
describe_failing_pod() {
  print_header "[Step 5] Describing Failing Pod for '${STREAM_TO_DEBUG}-${APP_TO_DEBUG}'"
  echo "INFO: After attempting to deploy '${STREAM_TO_DEBUG}', a pod for the '${APP_TO_DEBUG}' component might have been created but failed."
  echo ""
  echo "ACTION REQUIRED:"
  echo " 1. List pods related to the stream in another terminal:"
  echo "       kubectl get pods -n ${NAMESPACE} | grep ${STREAM_TO_DEBUG}-${APP_TO_DEBUG}"
  echo " 2. Identify the specific pod name that is in a failed state (e.g., ErrImagePull, ImagePullBackOff, CrashLoopBackOff, ContainerCreating)."
  echo " 3. If you found a failing pod, run the following command in another terminal,"
  echo "    replacing <pod-name> with the actual name you found:"
  echo ""
  echo "       kubectl describe pod -n ${NAMESPACE} <pod-name>"
  echo ""
  echo " 4. Examine the output, especially:"
  echo "    - The 'Image:' field under 'Containers' (Is it the incorrect Maven coordinate like '//org...'?)"
  echo "    - The 'Events:' section at the bottom (Look for 'Failed to pull image', 'Invalid image name', etc.)"
  echo ""
  read -n 1 -s -r -p "Press any key when you are ready to finish the script..."
  echo
}

# --- Main Execution ---
check_app_registration
check_platform_config
if deploy_test_maven_stream; then
    # Only proceed if test stream deployment was initiated successfully
    get_skipper_logs
    describe_failing_pod
else
    echo "WARN: Skipping log checks and pod description because test stream failed to deploy."
fi


print_header "Diagnostic Script Finished"
echo "Review the output of each step and the results of the manual checks (logs, describe pod)."
echo "This information should help pinpoint the configuration issue with Maven artifact deployment."

exit 0
