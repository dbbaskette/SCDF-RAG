#!/usr/bin/env bash
set -euo pipefail

# create_stream.sh
# Destroys, unregisters, re-registers, and deploys the PDF preprocessor stream in SCDF.
# - Logs all operations to logs/create_stream.log

LOGDIR="$(pwd)/logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/create_stream.log"

# --- User Configurable Variables ---
STREAM_NAME="rag-pipeline"
PDF_DIR="$(pwd)/sourceDocs"
APP_NAME="pdf-preprocessor"
APP_IMAGE="dbbaskette/pdf-preprocessor:0.0.1-SNAPSHOT"
SHELL_JAR="spring-cloud-dataflow-shell.jar"
SCDF_URI="http://localhost:30080"
SCDF_CMD="java -jar $SHELL_JAR --dataflow.uri=$SCDF_URI"

# --- Utility Functions ---
step() {
  echo -e "\033[1;32m$1\033[0m"
  echo "[STEP] $1" >>"$LOGFILE"
}

# --- Ensure SCDF Shell present ---
if [[ ! -f "$SHELL_JAR" ]]; then
  echo "ERROR: SCDF Shell JAR not found. Please run install_scdf_k8s.sh first."
  exit 1
fi

# --- Destroy stream if exists ---
step "Destroying stream: $STREAM_NAME (if exists)"
echo "stream destroy --name $STREAM_NAME" | $SCDF_CMD >>"$LOGFILE" 2>&1 || true
for i in {1..15}; do
  if ! echo "stream list" | $SCDF_CMD | grep -q "$STREAM_NAME"; then
    break
  fi
  step "Waiting for stream $STREAM_NAME to be destroyed..."
  sleep 2
done

# --- Unregister the app if it exists ---
step "Unregistering processor $APP_NAME (if exists)"
echo "app unregister --type processor --name $APP_NAME" | $SCDF_CMD >>"$LOGFILE" 2>&1 || true

# --- Register pdf-preprocessor app as Docker image ---
REGISTER_CMD="app register --type processor --name $APP_NAME --uri docker://$APP_IMAGE"
step "Registering app: $REGISTER_CMD"
register_output=$(echo "$REGISTER_CMD" | $SCDF_CMD 2>&1)
echo "$register_output" >>"$LOGFILE"
if ! echo "$register_output" | grep -q 'Successfully registered'; then
  echo "ERROR: App registration failed!"
  exit 1
fi

# --- Verify app registration ---
step "Verifying app registration for $APP_NAME:"
app_info_output=$(echo "app info $APP_NAME processor" | $SCDF_CMD 2>&1)
echo "$app_info_output" >>"$LOGFILE"
if ! echo "$app_info_output" | grep -q "$APP_IMAGE"; then
  echo "ERROR: App $APP_NAME was not registered correctly!"
  exit 1
fi

# --- Create and deploy the stream ---
definition="file --file.consumer.directory=$PDF_DIR --file.consumer.filename-pattern=*.pdf | $APP_NAME | log"
DEPLOY_PROPS="app.file.spring.rabbitmq.host=scdf-rabbitmq,app.file.spring.rabbitmq.port=5672,app.file.spring.rabbitmq.username=user,app.file.spring.rabbitmq.password=bitnami,app.$APP_NAME.kubernetes.probe.liveness.path=/actuator/health,app.$APP_NAME.kubernetes.probe.readiness.path=/actuator/health,app.$APP_NAME.kubernetes.probe.startup.path=/actuator/health,app.$APP_NAME.spring.rabbitmq.host=scdf-rabbitmq,app.$APP_NAME.spring.rabbitmq.port=5672,app.$APP_NAME.spring.rabbitmq.username=user,app.$APP_NAME.spring.rabbitmq.password=bitnami,app.log.spring.rabbitmq.host=scdf-rabbitmq,app.log.spring.rabbitmq.port=5672,app.log.spring.rabbitmq.username=user,app.log.spring.rabbitmq.password=bitnami"

step "Creating stream: $STREAM_NAME"
create_output=$(echo "stream create $STREAM_NAME --definition \"$definition\"" | $SCDF_CMD 2>&1)
echo "$create_output" >>"$LOGFILE"
if ! echo "$create_output" | grep -q 'Created new stream'; then
  echo "ERROR: Stream creation failed!"
  exit 1
fi

step "Deploying stream: $STREAM_NAME with deployment properties"
deploy_output=$(echo "stream deploy $STREAM_NAME --properties \"$DEPLOY_PROPS\"" | $SCDF_CMD 2>&1)
echo "$deploy_output" >>"$LOGFILE"

step "Waiting for deployment"
sleep 5

step "Stream status:"
stream_status=$(echo "stream info $STREAM_NAME" | $SCDF_CMD 2>&1)
echo "$stream_status" >>"$LOGFILE"
if echo "$stream_status" | grep -q "Status: DEPLOYED"; then
  echo "Stream '$STREAM_NAME' deployed. Monitoring directory: $PDF_DIR"
elif echo "$stream_status" | grep -q "Status: DEPLOYING"; then
  echo "Stream '$STREAM_NAME' is deploying. It may take a moment to become fully available."
else
  echo "WARNING: Stream $STREAM_NAME is not deployed."
fi
