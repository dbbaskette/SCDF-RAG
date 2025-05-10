#!/bin/bash
# step_destroy_stream.sh - Removes any existing SCDF stream deployment and definition for $STREAM_NAME.
# Also cleans up orphaned Kubernetes deployments and pods matching the stream name.
# Ensures a clean slate before creating a new stream.

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
    echo "Stream $STREAM_NAME definition not found. No delete needed."
  fi
  # Optionally, clean up orphaned K8s resources (if needed)
  # kubectl delete deployment,svc,pod -l stream=$STREAM_NAME -n $K8S_NAMESPACE 2>/dev/null || true
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
