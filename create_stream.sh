#!/bin/bash
set -euo pipefail

# Load properties
if [[ -f create_stream.properties ]]; then
  set -o allexport
  source create_stream.properties
  set +o allexport
else
  echo "ERROR: create_stream.properties not found!"
  exit 1
fi

# Destroy stream if it exists
if echo "stream info $STREAM_NAME" | $SCDF_CMD 2>&1 | grep -v 'does not exist' | grep -q "$STREAM_NAME"; then
  echo "Destroying existing stream $STREAM_NAME..."
  echo "stream destroy $STREAM_NAME" | $SCDF_CMD
  sleep 3
fi

# Create the stream: s3 source to log sink
STREAM_DEF="s3 | log"
echo "Creating stream: $STREAM_NAME"
echo "stream create $STREAM_NAME \"$STREAM_DEF\"" | $SCDF_CMD

echo "Stream created."

# Dynamically fetch MinIO S3 credentials from Kubernetes secret (do NOT use properties file)
S3_ACCESS_KEY=$(kubectl get secret minio -n scdf -o jsonpath='{.data.root-user}' | base64 --decode 2>/dev/null || echo 'minio')
S3_SECRET_KEY=$(kubectl get secret minio -n scdf -o jsonpath='{.data.root-password}' | base64 --decode 2>/dev/null || echo 'minio123')

# Build S3 deployment properties as a single line (using app.* for RabbitMQ settings, log levels, and log app expression)
DEPLOY_PROPS="app.s3.s3.common.endpoint-url=$S3_ENDPOINT,app.s3.s3.common.path-style-access=$S3_PATH_STYLE_ACCESS,app.s3.s3.supplier.remote-dir=$S3_BUCKET,app.s3.cloud.aws.region.static=$S3_REGION,app.s3.s3.supplier.file-transfer-mode=$S3_FILE_TRANSFER_MODE,app.s3.cloud.aws.credentials.accessKey=$S3_ACCESS_KEY,app.s3.cloud.aws.credentials.secretKey=$S3_SECRET_KEY,app.s3.cloud.aws.stack.auto=$CLOUD_AWS_STACK_AUTO,app.*.spring.rabbitmq.host=$RABBIT_HOST,app.*.spring.rabbitmq.port=$RABBIT_PORT,app.*.spring.rabbitmq.username=$RABBIT_USER,app.*.spring.rabbitmq.password=$RABBIT_PASS,app.s3.logging.level.org.springframework.integration.aws=$LOG_LEVEL_SI_AWS,app.s3.logging.level.org.springframework.integration.file=$LOG_LEVEL_SI_FILE,app.s3.logging.level.com.amazonaws=$LOG_LEVEL_AWS_SDK,app.s3.logging.level.org.springframework.cloud.stream.app.s3.source=$LOG_LEVEL_S3_SOURCE,app.log.log.expression=$LOG_EXPRESSION"

# Ensure no --propertiesFile is used anywhere; only use --properties for deployment
# (SCDF_CMD should not include --propertiesFile)
# The deploy command below is correct and should be the only way properties are passed:
echo "Deploying stream: $STREAM_NAME"
echo "stream deploy $STREAM_NAME --properties \"$DEPLOY_PROPS\"" | $SCDF_CMD

echo "Stream deployed."
