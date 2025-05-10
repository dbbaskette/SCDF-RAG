#!/bin/bash
# test_new_embedproc_pipeline.sh - Test stream: s3 | textProc | embedProc | pgcopy
# Usage: test_new_embedproc_pipeline

test_new_embedproc_pipeline() {
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
  DEPLOY_PROPS+=",app.embedProc.spring.ai.ollama.embedding.model=${SPRING_AI_OLLAMA_EMBEDDING_MODEL}"
  DEPLOY_PROPS+=",app.embedProc.spring.ai.ollama.base-url=${SPRING_AI_OLLAMA_BASE_URL}"
 
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
  DEPLOY_PROPS+=",app.pgcopy.logging.level.org.springframework.cloud.stream.binder.rabbit=INFO"
  DEPLOY_PROPS+=",app.pgcopy.logging.level.org.springframework.integration.handler.LoggingHandler=DEBUG"
  DEPLOY_PROPS+=",app.pgcopy.logging.level.org.springframework.messaging=DEBUG"
  DEPLOY_PROPS+=",app.pgcopy.logging.level.org.springframework.integration=DEBUG"
  DEPLOY_PROPS+=",app.pgcopy.logging.level.org.springframework.cloud.stream=DEBUG"

  
  
  DEPLOY_JSON=$(build_json_from_props "$DEPLOY_PROPS")
  echo "DEPLOY_JSON for $TEST_STREAM_NAME: $DEPLOY_JSON" >> "$LOGFILE"
  # Deploy the test stream with processor environment variables and spring.profiles.active=scdf
  curl -s -X POST "$SCDF_API_URL/streams/deployments/$TEST_STREAM_NAME" \
    -H 'Content-Type: application/json' \
    -d "$DEPLOY_JSON" > /dev/null
  echo "[TEST-TEXTPROC] Test stream deployed. To test, add a file to your configured S3 bucket and check the pgcopy sink output."
}
