#!/bin/bash
# env_setup.sh - Environment setup and credentials functions for SCDF automation

# Always set SCDF_API_URL at the top level so it's available to all functions
export SCDF_API_URL=${SCDF_SERVER_URL:-http://localhost:30080}

# Check if SCDF server is available
check_scdf_server() {
    echo "[INFO] Checking SCDF server availability at $SCDF_API_URL..."
    if ! curl -s --max-time 5 "$SCDF_API_URL/management/info" | grep -q '"version"'; then
        echo "ERROR: Unable to reach SCDF management endpoint at $SCDF_API_URL/management/info. Is SCDF installed and running?"
        return 1
    fi
    echo "[INFO] Successfully connected to SCDF server at $SCDF_API_URL"
    return 0
}

# Fetches MinIO (S3) credentials from Kubernetes secrets in the 'scdf'
# namespace and exports them as environment variables for use by the
# rest of the script. Ensures that S3_ACCESS_KEY and S3_SECRET_KEY are
# always up-to-date for deployments.
#
# NOTE: Do NOT call this function during general environment setup.
# Only call set_minio_creds from MinIO install or stream deployment code that actually needs S3 credentials.
set_minio_creds() {
  S3_ACCESS_KEY=$(kubectl get secret minio -n scdf -o jsonpath='{.data.root-user}' | base64 --decode 2>/dev/null || echo '')
  S3_SECRET_KEY=$(kubectl get secret minio -n scdf -o jsonpath='{.data.root-password}' | base64 --decode 2>/dev/null || echo '')
  export S3_ACCESS_KEY
  export S3_SECRET_KEY
}

# Loads cluster-wide and app-specific properties from configuration files.
source_properties() {
  if [[ -f "scdf_env.properties" ]]; then
    # shellcheck disable=SC1091
    source scdf_env.properties
  fi
  if [[ -f "create_stream.properties" ]]; then
    # shellcheck disable=SC1091
    source create_stream.properties
  fi
}
