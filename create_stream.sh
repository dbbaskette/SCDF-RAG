#!/bin/bash



# Set SCDF_API_URL from environment or use default
SCDF_API_URL=${SCDF_SERVER_URL:-http://localhost:30080}

# Check SCDF management endpoint before sourcing anything else
if ! curl -s --max-time 5 "$SCDF_API_URL/management/info" | grep -q '"version"'; then
  echo "ERROR: Unable to reach SCDF management endpoint at $SCDF_API_URL/management/info. Is SCDF installed and running?"
  exit 1
fi

# Source environment setup and credentials functions
echo "[INFO] Sourcing environment setup..."
source "$(dirname "$0")/functions/env_setup.sh"
echo "[INFO] Environment setup complete."

# Source app registration functions
echo "[INFO] Sourcing app registration functions..."
source "$(dirname "$0")/functions/app_registration.sh"
echo "[INFO] App registration functions loaded."

# Source default HDFS stream functions
echo "[INFO] Sourcing HDFS stream functions..."
source "$(dirname "$0")/functions/default_hdfs_stream.sh"
echo "[INFO] HDFS stream functions loaded."

# Source test HDFS app functions
echo "[INFO] Sourcing test HDFS app functions..."
source "$(dirname "$0")/functions/test_hdfs_app.sh"
echo "[INFO] Test HDFS app functions loaded."

# Source default S3 stream functions
echo "[INFO] Sourcing S3 stream functions..."
source "$(dirname "$0")/functions/default_s3_stream.sh"
echo "[INFO] S3 stream functions loaded."

# Source utility functions
echo "[INFO] Sourcing utility functions..."
source "$(dirname "$0")/functions/utilities.sh"
echo "[INFO] Utility functions loaded."

# Source viewer functions
echo "[INFO] Sourcing viewer functions..."
source "$(dirname "$0")/functions/viewers.sh"
echo "[INFO] Viewer functions loaded."

# Source menu function
echo "[INFO] Sourcing menu functions..."
source "$(dirname "$0")/functions/menu.sh"
echo "[INFO] Menu functions loaded."

#
# create_stream.sh — Spring Cloud Data Flow Stream Automation (REST API version)
#
# Automates the full lifecycle of SCDF streams on Kubernetes using REST API calls.
# Key features:
#   - Registers source, processor, and sink apps (including custom Docker images)
#   - Builds and submits stream definitions (e.g. s3 | textProc | embedProc | log)
#   - Configures all deploy properties and bindings for correct message routing
#   - Supports interactive test mode for step-by-step management
#   - Fully documented for clarity and maintainability
#
# USAGE:
#   ./create_stream.sh --stream=hdfs        # Deploys the default HDFS -> textProc -> embedProc -> log stream
#   ./create_stream.sh --stream=s3          # Deploys the default S3 -> textProc -> embedProc -> log stream
#   ./create_stream.sh --stream=test-textproc    # Deploys a test stream for text processor verification
#   ./create_stream.sh --stream=test-embedproc   # Deploys a test stream for embedding processor verification
#   ./create_stream.sh --test    # Interactive menu for step-by-step stream management
#
# If no arguments are passed, this script will print usage and exit.
# You must specify --stream=streamname (or --test for interactive mode).

#
# Default pipeline:
#   hdfs | textProc | embedProc | log
#   - hdfs: Reads files from HDFS
#   - textProc: Processes text (https://github.com/dbbaskette/textProc)
#   - embedProc: Generates vector embeddings (https://github.com/dbbaskette/embedProc)
#   - log: Outputs results for inspection
#
# All configuration is loaded from:
#   - scdf_env.properties: Cluster-wide and SCDF platform settings
#   - create_stream.properties: Stream/app-specific settings
#
# For more details, see the README and function-level comments below.
#
# Ensure K8S_NAMESPACE is set, default to 'scdf' if not
K8S_NAMESPACE=${K8S_NAMESPACE:-scdf}

# ----------------------------------------------------------------------
# SCDF Platform Deployer Properties for RabbitMQ (Kubernetes)
# ----------------------------------------------------------------------
#
# To set RabbitMQ connection properties globally for all apps deployed via SCDF
# on Kubernetes, use the Platform Deployer model. This ensures all apps inherit
# these settings by default (no need to specify at deploy-time).
#
# 1. In the SCDF UI:
#    - Go to "Platforms" (left nav)
#    - Click your Kubernetes platform (e.g., 'kubernetes')
#    - Click "Edit"
#    - Add the following under "Global Deployer Properties":
#      spring.rabbitmq.host=scdf-rabbitmq
#      spring.rabbitmq.port=5672
#      spring.rabbitmq.username=user
#      spring.rabbitmq.password=bitnami
#    - Save and re-deploy your stream apps.
#
# 2. Alternatively, via the SCDF REST API:
#    curl -X POST "$SCDF_API_URL/platforms/kubernetes" \
#      -H 'Content-Type: application/json' \
#      -d '{"name":"kubernetes","type":"kubernetes","description":"K8s deployer","options":{"spring.rabbitmq.host":"scdf-rabbitmq","spring.rabbitmq.port":"5672","spring.rabbitmq.username":"user","spring.rabbitmq.password":"bitnami"}}'
#
# ----------------------------------------------------------------------
# Cloud Foundry Platform Deployer Properties (for future use)
# ----------------------------------------------------------------------
#
# When you add a Cloud Foundry platform to SCDF, set the same properties in the
# "Global Deployer Properties" for the Cloud Foundry platform. This ensures all
# apps deployed to CF inherit these settings by default.
#
# Example (in SCDF UI):
#   spring.rabbitmq.host=cf-rabbit-host
#   spring.rabbitmq.port=5672
#   spring.rabbitmq.username=cf-user
#   spring.rabbitmq.password=cf-password
#
# Or via the API (replace values as needed):
#   curl -X POST "$SCDF_API_URL/platforms/cloudfoundry" \
#     -H 'Content-Type: application/json' \
#     -d '{"name":"cloudfoundry","type":"cloudfoundry","description":"CF deployer","options":{"spring.rabbitmq.host":"cf-rabbit-host","spring.rabbitmq.port":"5672","spring.rabbitmq.username":"cf-user","spring.rabbitmq.password":"cf-password"}}'
#
# ----------------------------------------------------------------------

set -euo pipefail

# Check for jq at script launch
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: The 'jq' command is required but not installed. Please install jq and rerun this script." >&2
  exit 1
fi


# Source properties at script start for initial setup
echo "[INFO] Loading properties..."
source_properties
echo "[INFO] Properties loaded."

# Check SCDF management endpoint before any actions
if ! curl -s --max-time 5 "$SCDF_API_URL/management/info" | grep -q '"version"'; then
  echo "ERROR: Unable to reach SCDF management endpoint at $SCDF_API_URL/management/info. Is SCDF installed and running?"
  exit 1
fi

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 --stream=STREAMNAME"
  echo "  STREAMNAME: hdfs | s3"
  echo "  Or use --test for interactive menu."
  exit 1
fi

if [[ "$1" == "--test" ]]; then
  while true; do
    show_menu
    read -r choice
    case $choice in
      s1)
        LOG_DIR="$(dirname "$0")/logs"
        LOG_FILE="$LOG_DIR/create-stream.log"
        mkdir -p "$LOG_DIR"
        touch "$LOG_FILE"
        chmod 666 "$LOG_FILE" 2>/dev/null || true
        exec > >(tee -a "$LOG_FILE") 2>&1
        echo "========== [$(date)] Option: s1 - Create and deploy default HDFS stream ==========" | tee -a "$LOG_FILE"
        default_hdfs_stream
        ;;
      s2)
        LOG_DIR="$(dirname "$0")/logs"
        LOG_FILE="$LOG_DIR/create-stream.log"
        mkdir -p "$LOG_DIR"
        touch "$LOG_FILE"
        chmod 666 "$LOG_FILE" 2>/dev/null || true
        exec > >(tee -a "$LOG_FILE") 2>&1
        echo "========== [$(date)] Option: s2 - Create and deploy default S3 stream ==========" | tee -a "$LOG_FILE"
        default_s3_stream
        ;;
      s3)
        LOG_DIR="$(dirname "$0")/logs"
        LOG_FILE="$LOG_DIR/create-stream.log"
        mkdir -p "$LOG_DIR"
        touch "$LOG_FILE"
        chmod 666 "$LOG_FILE" 2>/dev/null || true
        exec > >(tee -a "$LOG_FILE") 2>&1
        echo "========== [$(date)] Option: s3 - Create and deploy test HDFS app ==========" | tee -a "$LOG_FILE"
        test_hdfs_app
        ;;
      1)
        LOG_DIR="$(dirname "$0")/logs"
        LOG_FILE="$LOG_DIR/create-stream.log"
        mkdir -p "$LOG_DIR"
        touch "$LOG_FILE"
        chmod 666 "$LOG_FILE" 2>/dev/null || true
        exec > >(tee -a "$LOG_FILE") 2>&1
        echo "========== [$(date)] Option: 1 - Destroy stream ==========" | tee -a "$LOG_FILE"
        step_destroy_stream
        ;;
      2)
        LOG_DIR="$(dirname "$0")/logs"
        LOG_FILE="$LOG_DIR/create-stream.log"
        mkdir -p "$LOG_DIR"
        touch "$LOG_FILE"
        chmod 666 "$LOG_FILE" 2>/dev/null || true
        exec > >(tee -a "$LOG_FILE") 2>&1
        echo "========== [$(date)] Option: 2 - Unregister processor apps ==========" | tee -a "$LOG_FILE"
        step_unregister_processor_apps
        ;;
      3)
        LOG_DIR="$(dirname "$0")/logs"
        LOG_FILE="$LOG_DIR/create-stream.log"
        mkdir -p "$LOG_DIR"
        touch "$LOG_FILE"
        chmod 666 "$LOG_FILE" 2>/dev/null || true
        exec > >(tee -a "$LOG_FILE") 2>&1
        echo "========== [$(date)] Option: 3 - Register processor apps ==========" | tee -a "$LOG_FILE"
        step_register_processor_apps
        ;;
      4)
        LOG_DIR="$(dirname "$0")/logs"
        LOG_FILE="$LOG_DIR/create-stream.log"
        mkdir -p "$LOG_DIR"
        touch "$LOG_FILE"
        chmod 666 "$LOG_FILE" 2>/dev/null || true
        exec > >(tee -a "$LOG_FILE") 2>&1
        echo "========== [$(date)] Option: 4 - Register default apps ==========" | tee -a "$LOG_FILE"
        step_register_default_apps
        ;;
      5)
        LOG_DIR="$(dirname "$0")/logs"
        LOG_FILE="$LOG_DIR/create-stream.log"
        mkdir -p "$LOG_DIR"
        touch "$LOG_FILE"
        chmod 666 "$LOG_FILE" 2>/dev/null || true
        exec > >(tee -a "$LOG_FILE") 2>&1
        echo "========== [$(date)] Option: 5 - Create stream definition ==========" | tee -a "$LOG_FILE"
        step_create_stream_definition
        ;;
      6)
        LOG_DIR="$(dirname "$0")/logs"
        LOG_FILE="$LOG_DIR/create-stream.log"
        mkdir -p "$LOG_DIR"
        touch "$LOG_FILE"
        chmod 666 "$LOG_FILE" 2>/dev/null || true
        exec > >(tee -a "$LOG_FILE") 2>&1
        echo "========== [$(date)] Option: 6 - Deploy stream ==========" | tee -a "$LOG_FILE"
        step_deploy_stream
        ;;
      7)
        LOG_DIR="$(dirname "$0")/logs"
        LOG_FILE="$LOG_DIR/create-stream.log"
        mkdir -p "$LOG_DIR"
        touch "$LOG_FILE"
        chmod 666 "$LOG_FILE" 2>/dev/null || true
        exec > >(tee -a "$LOG_FILE") 2>&1
        echo "========== [$(date)] Option: 7 - View stream ==========" | tee -a "$LOG_FILE"
        view_stream
        ;;
      8)
        LOG_DIR="$(dirname "$0")/logs"
        LOG_FILE="$LOG_DIR/create-stream.log"
        mkdir -p "$LOG_DIR"
        touch "$LOG_FILE"
        chmod 666 "$LOG_FILE" 2>/dev/null || true
        exec > >(tee -a "$LOG_FILE") 2>&1
        echo "========== [$(date)] Option: 8 - View processor apps ==========" | tee -a "$LOG_FILE"
        view_processor_apps
        ;;
      9)
        LOG_DIR="$(dirname "$0")/logs"
        LOG_FILE="$LOG_DIR/create-stream.log"
        mkdir -p "$LOG_DIR"
        touch "$LOG_FILE"
        chmod 666 "$LOG_FILE" 2>/dev/null || true
        exec > >(tee -a "$LOG_FILE") 2>&1
        echo "========== [$(date)] Option: 9 - View default apps ==========" | tee -a "$LOG_FILE"
        view_default_apps
        ;;
      q|Q)
        echo "Exiting."
        exit 0
        ;;
      *)
        echo "Invalid option. Please select 1-9, s1, s2 or q to quit."
        ;;
    esac
    echo
    echo "--- Step complete. Return to menu. ---"
  done
  exit 0
fi

case "$1" in
  --stream=hdfs)
    default_hdfs_stream
    ;;
  --stream=s3)
    default_s3_stream
    ;;
  *)
    echo "ERROR: Unknown stream: $1"
    echo "Usage: $0 --stream=STREAMNAME"
    echo "  STREAMNAME: hdfs | s3"
    echo "  Or use --test for interactive menu."
    exit 1
    ;;
esac

