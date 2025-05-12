#!/bin/bash
# viewers.sh - Functions for viewing SCDF app, processor, and stream status

# View stream definition and deployment status
view_stream() {
  source_properties
  echo "[VIEW] Stream definition and status: $STREAM_NAME"
  curl -s "$SCDF_API_URL/streams/definitions/$STREAM_NAME" | jq . || echo "stream not found"
  echo
  echo "[VIEW] Stream deployment status: $STREAM_NAME"
  curl -s "$SCDF_API_URL/streams/deployments/$STREAM_NAME" | jq . || echo "deployment not found"
}

# View all processor apps, their registration, and options
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

# View default S3 source and log sink app registration and options
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
