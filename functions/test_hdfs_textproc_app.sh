#!/bin/bash
# test_hdfs_textproc_app.sh - Stub for future implementation of the test HDFS and textProc SCDF stream


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"



. "$SCRIPT_DIR/env_setup.sh"

# Load properties (for HDFS connection, etc)
source_properties

# Fail-fast if required HDFS variables are not set
: "${HDFS_URI:?HDFS_URI not set}"
: "${HDFS_USER:?HDFS_USER not set}"
: "${HDFS_REMOTE_DIR:?HDFS_REMOTE_DIR not set}"

test_hdfs_textproc_app() {
  local STREAM_NAME="test-hdfsWatcher-textproc"
  # Check SCDF management endpoint before proceeding
  if ! curl -s --max-time 5 "$SCDF_API_URL/management/info" | grep -q '"version"'; then
    echo "ERROR: Unable to reach SCDF management endpoint at $SCDF_API_URL/management/info. Is SCDF installed and running?"
    exit 1
  fi
  echo "[TEST-HDFS-APP] Creating stream: hdfsWatcher | textProc | log (name: $STREAM_NAME)"
  # Destroy any existing pipeline and definitions to ensure a clean slate
  echo "[INFO] Deleting existing stream deployment: $STREAM_NAME"
  resp=$(curl -s -w "\n[HTTP_STATUS:%{http_code}]" -X DELETE "$SCDF_API_URL/streams/deployments/$STREAM_NAME")
  echo "$resp"

  echo "[INFO] Deleting existing stream definition: $STREAM_NAME"
  resp=$(curl -s -w "\n[HTTP_STATUS:%{http_code}]" -X DELETE "$SCDF_API_URL/streams/definitions/$STREAM_NAME")
  echo "$resp"

  # Remove any previous hdfsWatcher app registration
  echo "[INFO] Deleting previous hdfsWatcher app registration"
  resp=$(curl -s -w "\n[HTTP_STATUS:%{http_code}]" -X DELETE "$SCDF_API_URL/apps/source/hdfsWatcher")
  echo "$resp"

    # Remove any previous textProc app registration
  echo "[INFO] Deleting previous textProc app registration"
  resp=$(curl -s -w "\n[HTTP_STATUS:%{http_code}]" -X DELETE "$SCDF_API_URL/apps/processor/textProc")
  echo "$resp"

  # Wait for deregistration to propagate before re-registering (timeout after 60s)
  echo -n "[INFO] Waiting for deregistration of hdfsWatcher and textProc"
  SECONDS_WAITED=0
  TIMEOUT=60
  while (( SECONDS_WAITED < TIMEOUT )); do
    DEF_STATUS_HDFSWATCHER=$(curl -s "$SCDF_API_URL/apps/source/hdfsWatcher")
    DEF_STATUS_TEXTPROC=$(curl -s "$SCDF_API_URL/apps/processor/textProc")
    if echo "$DEF_STATUS_HDFSWATCHER" | grep -q 'could not be found' && \
       echo "$DEF_STATUS_TEXTPROC" | grep -q 'could not be found'; then
      echo " done after $SECONDS_WAITED seconds."
      break
    fi
    echo -n "."
    sleep 1
    ((SECONDS_WAITED++))
  done
  if (( SECONDS_WAITED >= TIMEOUT )); then
    echo ""
    echo "[ERROR] Timed out waiting for app deregistration after $TIMEOUT seconds. Exiting."
    exit 1
  fi

  # Register the hdfsWatcher app with the latest Docker image
  echo "[INFO] Registering hdfsWatcher app"
  resp=$(curl -s -w "\n[HTTP_STATUS:%{http_code}]" -X POST "$SCDF_API_URL/apps/source/hdfsWatcher" -d "uri=docker:dbbaskette/hdfswatcher:latest" -d "force=true")
  echo "$resp"

    # Register the textProc app with the latest Docker image
  echo "[INFO] Registering textProc app"
  resp=$(curl -s -w "\n[HTTP_STATUS:%{http_code}]" -X POST "$SCDF_API_URL/apps/processor/textProc" -d "uri=docker:dbbaskette/textproc:latest" -d "force=true")
  echo "$resp"

  # Build the pipeline definition with all required HDFS source properties, now using log as sink
  STREAM_DEF="hdfsWatcher | textProc | log"
  echo "[INFO] Creating stream definition for: $STREAM_NAME [$(date '+%Y-%m-%d %H:%M:%S')]"
  resp=$(curl -s -w "\n[HTTP_STATUS:%{http_code}]" -X POST "$SCDF_API_URL/streams/definitions" \
    -d "name=$STREAM_NAME" \
    -d "definition=$STREAM_DEF")
  echo "$(date '+%Y-%m-%d %H:%M:%S') $resp"

  # Build deploy properties string and JSON (adapted for HDFS)

  DEPLOY_PROPS=""
  DEPLOY_PROPS+=",app.hdfsWatcher.hdfswatcher.hdfsUser=$HDFS_USER"
  DEPLOY_PROPS+=",app.hdfsWatcher.hdfswatcher.hdfsUri=$HDFS_URI"
  DEPLOY_PROPS+=",app.hdfsWatcher.hdfswatcher.hdfsPath=$HDFS_REMOTE_DIR"
  DEPLOY_PROPS+=",app.hdfsWatcher.hdfswatcher.webhdfsUri=$HDFS_WEBHDFS_URI"
  DEPLOY_PROPS+=",app.hdfsWatcher.hdfswatcher.pollInterval=5000"
  DEPLOY_PROPS+=",app.hdfsWatcher.spring.profiles.active=scdf"  
  DEPLOY_PROPS+=",app.hdfsWatcher.spring.cloud.config.enabled=false"  
  #DEPLOY_PROPS+=",app.hdfsWatcher.spring.cloud.function.definition=hdfsSupplier"

  DEPLOY_PROPS+=",app.hdfsWatcher.spring.cloud.stream.bindings.output.destination=hdfsWatcher-to-textproc"
  DEPLOY_PROPS+=",app.hdfsWatcher.spring.cloud.stream.bindings.output.group=${STREAM_NAME}"
  DEPLOY_PROPS+=",app.hdfsWatcher.logging.level.org.springframework.cloud.stream=DEBUG"
  DEPLOY_PROPS+=",app.hdfsWatcher.logging.level.org.springframework.integration=DEBUG"
  DEPLOY_PROPS+=",app.hdfsWatcher.logging.level.org.springframework.cloud.stream.binder.rabbit=DEBUG"
  DEPLOY_PROPS+=",app.hdfsWatcher.logging.level.org.springframework.cloud.stream.app.hdfsWatcher.source=DEBUG"
  DEPLOY_PROPS+=",app.hdfsWatcher.logging.level.org.apache.hadoop=DEBUG"

 # textProc processor
  DEPLOY_PROPS+=",app.textProc.spring.profiles.active=scdf"
  DEPLOY_PROPS+=",app.textProc.spring.cloud.function.definition=textProc"
  DEPLOY_PROPS+=",app.textProc.spring.cloud.stream.bindings.textProc-in-0.destination=hdfsWatcher-to-textproc"
  DEPLOY_PROPS+=",app.textProc.spring.cloud.stream.bindings.textProc-in-0.group=${STREAM_NAME}"
  DEPLOY_PROPS+=",app.textProc.spring.cloud.stream.bindings.textProc-out-0.destination=textproc-to-log"
  DEPLOY_PROPS+=",app.textProc.logging.level.org.springframework.cloud.stream=INFO"
  DEPLOY_PROPS+=",app.textProc.logging.level.org.springframework.integration=INFO"
  DEPLOY_PROPS+=",app.textProc.logging.level.org.springframework.cloud.stream.binder.rabbit=INFO"
  DEPLOY_PROPS+=",app.textProc.logging.level.org.springframework.cloud.stream.app.textProc.processor=INFO"
  DEPLOY_PROPS+=",app.textProc.logging.level.com.baskettecase.textProc=INFO"
  

  DEPLOY_PROPS+=",app.log.spring.cloud.stream.bindings.input.destination=textproc-to-log"
  DEPLOY_PROPS+=",app.log.spring.cloud.stream.bindings.input.group=${STREAM_NAME}"
  DEPLOY_PROPS+=",app.log.spring.cloud.config.enabled=false"  


  # Debug output for key variables
  echo "[DEBUG] HDFS_USER: $HDFS_USER"
  echo "[DEBUG] HDFS_URI: $HDFS_URI"
  echo "[DEBUG] HDFS_REMOTE_DIR: $HDFS_REMOTE_DIR"
  echo "[DEBUG] STREAM_NAME: $STREAM_NAME"
  echo "[DEBUG] DEPLOY_PROPS: $DEPLOY_PROPS"

  # Deploy the stream
  echo "[INFO] Deploying stream: $STREAM_NAME [$(date '+%Y-%m-%d %H:%M:%S')]"
  DEPLOY_JSON=$(build_json_from_props "$DEPLOY_PROPS")
  resp=$(curl -s -w "\n[HTTP_STATUS:%{http_code}]" -X POST \
    -H "Content-Type: application/json" \
    "$SCDF_API_URL/streams/deployments/$STREAM_NAME" \
    -d "$DEPLOY_JSON")
  echo "$(date '+%Y-%m-%d %H:%M:%S') $resp"
}

# If called directly, run the test
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  test_hdfs_app
fi
