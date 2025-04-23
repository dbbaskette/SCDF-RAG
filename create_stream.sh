#!/bin/bash
set -euo pipefail

# ============================================================================
# create_stream.sh
# -----------------------------------------------------------------------------
# This script creates and deploys a Spring Cloud Data Flow (SCDF) stream using
# an S3/MinIO source and a log sink. It reads configuration from create_stream.properties.
#
# - S3/MinIO credentials and parameters are loaded from the properties file.
# - RabbitMQ connection details are sourced from the properties file.
# - The script prints debug info for key variables and logs actions to logs/create_stream.log.
# - All apps in the stream are configured to use the correct RabbitMQ service.
#
# Usage:
#   ./create_stream.sh
#
# Requirements:
#   - kubectl (for dynamic credential fetching, if enabled)
#   - AWS CLI (for S3/MinIO testing)
#   - spring-cloud-dataflow-shell.jar
#
# Edit create_stream.properties to change configuration.
# ============================================================================

# --- Load properties file ---
if [[ -f create_stream.properties ]]; then
  set -o allexport
  source create_stream.properties
  set +o allexport
else
  echo "ERROR: create_stream.properties not found!"
  exit 1
fi

LOGDIR="$(pwd)/logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/create_stream.log"

# --- Get MinIO credentials dynamically ---
S3_ACCESS_KEY="$(kubectl get secret minio -n scdf -o jsonpath='{.data.root-user}' | base64 --decode 2>/dev/null || echo 'minio')"
S3_SECRET_KEY="$(kubectl get secret minio -n scdf -o jsonpath='{.data.root-password}' | base64 --decode 2>/dev/null || echo 'minio123')"

# --- Print property values for debug (check for leading/trailing spaces) ---
echo "[DEBUG] S3_ENDPOINT=[$S3_ENDPOINT]"
echo "[DEBUG] S3_PREFIX=[$S3_PREFIX]"
echo "[DEBUG] S3_BUCKET=[$S3_BUCKET]"

echo "[DEBUG] RABBIT_HOST=[$RABBIT_HOST]"
echo "[DEBUG] RABBIT_PORT=[$RABBIT_PORT]"
echo "[DEBUG] RABBIT_USER=[$RABBIT_USER]"
# Do not echo RABBIT_PASS for security

# --- RabbitMQ connection properties ---
RABBIT_HOST=scdf-rabbitmq
RABBIT_PORT=5672
# Use credentials from properties file
# shellcheck disable=SC2154
# (RABBIT_USER and RABBIT_PASS are set by sourcing the properties file)

# Add RabbitMQ connection props to stream definition
RABBIT_PROPS="--spring.rabbitmq.host=$RABBIT_HOST --spring.rabbitmq.port=$RABBIT_PORT --spring.rabbitmq.username=$RABBIT_USER --spring.rabbitmq.password=$RABBIT_PASS"

# --- Create and deploy the S3-based stream (S3 source to log sink) ---
definition="$S3_APP_NAME --s3.common.endpoint-url=$S3_ENDPOINT --s3.common.path-style-access=$S3_PATH_STYLE_ACCESS --s3.supplier.remote-dir=$S3_BUCKET --s3.supplier.poller.fixed-delay=10000 --cloud.aws.region.static=$S3_REGION --cloud.aws.credentials.accessKey=$S3_ACCESS_KEY --cloud.aws.credentials.secretKey=$S3_SECRET_KEY --cloud.aws.stack.auto=$CLOUD_AWS_STACK_AUTO --outputType=application/octet-stream $RABBIT_PROPS --logging.level.org.springframework.integration.aws=$LOG_LEVEL_SI_AWS --logging.level.org.springframework.integration.file=$LOG_LEVEL_SI_FILE --logging.level.com.amazonaws=$LOG_LEVEL_AWS_SDK --logging.level.org.springframework.cloud.stream.app.s3.source=$LOG_LEVEL_S3_SOURCE | log $RABBIT_PROPS"

# Log the stream definition but redact sensitive credentials
redacted_definition="$S3_APP_NAME --s3.common.endpoint-url=$S3_ENDPOINT --s3.common.path-style-access=$S3_PATH_STYLE_ACCESS --s3.supplier.remote-dir=$S3_BUCKET --s3.supplier.poller.fixed-delay=10000 --cloud.aws.region.static=$S3_REGION --cloud.aws.credentials.accessKey=**** --cloud.aws.credentials.secretKey=**** --cloud.aws.stack.auto=$CLOUD_AWS_STACK_AUTO --outputType=application/octet-stream $RABBIT_PROPS --logging.level.org.springframework.integration.aws=$LOG_LEVEL_SI_AWS --logging.level.org.springframework.integration.file=$LOG_LEVEL_SI_FILE --logging.level.com.amazonaws=$LOG_LEVEL_AWS_SDK --logging.level.org.springframework.cloud.stream.app.s3.source=$LOG_LEVEL_S3_SOURCE | log $RABBIT_PROPS"

step() {
  echo -e "\033[1;32m$1\033[0m"
}

# --- Check if stream exists and delete if so ---
if echo "stream info $STREAM_NAME" | $SCDF_CMD 2>&1 | grep -v 'does not exist' | grep -q "$STREAM_NAME"; then
  step "Stream $STREAM_NAME already exists. Deleting..."
  echo "[LOG] Command: stream destroy $STREAM_NAME" >> "$LOGFILE"
  echo "stream destroy $STREAM_NAME" | $SCDF_CMD >> "$LOGFILE" 2>&1
  sleep 3  # Give SCDF a moment to clean up
fi

step "Creating and deploying stream: $STREAM_NAME (S3 source to log sink)"
echo "[LOG] Command: stream create $STREAM_NAME --definition \"[REDACTED] see below\" --deploy" >>"$LOGFILE"
echo -e "\n[DEBUG] Resolved stream definition (credentials redacted):" >> "$LOGFILE"
echo "$redacted_definition" >> "$LOGFILE"
echo -e "\n[DEBUG] End stream definition" >> "$LOGFILE"

raw_shell_output=$(echo "stream create $STREAM_NAME --definition \"$definition\" --deploy" | $SCDF_CMD 2>&1)
echo "$raw_shell_output" >>"$LOGFILE"
if ! echo "$raw_shell_output" | grep -Eq 'Created new stream|Deployment request submitted|Deployed stream|created and deployed'; then
  echo "ERROR: Stream creation failed!" | tee -a "$LOGFILE"
  exit 1
fi

step "Waiting for deployment"
sleep 5

step "Stream status:"
echo "[LOG] Command: stream info $STREAM_NAME" >>"$LOGFILE"
stream_status=$(echo "stream info $STREAM_NAME" | $SCDF_CMD | tee -a "$LOGFILE")
echo "$stream_status" >>"$LOGFILE"
