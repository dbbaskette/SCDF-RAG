#!/bin/bash
#
# scdf_install_k8s.sh — Spring Cloud Data Flow Full Installer for Kubernetes
#
# Automates the full deployment of Spring Cloud Data Flow (SCDF), Skipper, RabbitMQ, PostgreSQL, MinIO, and Ollama Nomic model on any Kubernetes cluster.
# Key features:
#   - Installs all dependencies using Helm and dynamic YAML generation
#   - Step-by-step progress with robust error handling and logging
#   - Interactive test mode for running each install step independently
#   - Prints all management endpoints at the end
#   - Configurable via scdf_env.properties (cluster-wide) and resources/scdf-values.yaml
#
# USAGE:
#   ./scdf_install_k8s.sh           # Full install with minimal terminal output
#   ./scdf_install_k8s.sh --test    # Interactive menu for step-by-step install
#
# Each major step is counted using step_major/STEP_TOTAL for progress tracking.
# All logs are written to logs/scdf-install.log for troubleshooting.
#
# For more details, see the README and function-level comments below.

# Source environment variables from scdf_env.properties
if [ -f "$(dirname "$0")/scdf_env.properties" ]; then
  set -a
  . "$(dirname "$0")/scdf_env.properties"
  set +a
fi

# --- Ensure Bitnami Helm repo is added and updated ---
if ! helm repo list | grep -q '^bitnami'; then
  echo "Adding Bitnami Helm repo..."
  helm repo add bitnami https://charts.bitnami.com/bitnami
fi
helm repo update >>"$LOGFILE" 2>&1

# --- Generate SCDF values file from environment variables (external PostgreSQL, chart-managed RabbitMQ) ---
cat > resources/scdf-values.yaml <<EOF
mariadb:
  enabled: false
postgresql:
  enabled: false
externalDatabase:
  host: ${POSTGRES_RELEASE_NAME}
  port: 5432
  scheme: postgresql
  driver: ${POSTGRES_DRIVER}
  dataflow:
    database: ${POSTGRES_DB}
    username: ${POSTGRES_USER}
    password: ${POSTGRES_PASSWORD}
  skipper:
    database: ${POSTGRES_DB}
    username: ${POSTGRES_USER}
    password: ${POSTGRES_PASSWORD}
rabbitmq:
  enabled: true
  auth:
    username: ${RABBITMQ_USER}
    password: ${RABBITMQ_PASSWORD}
  service:
    type: NodePort
    nodePorts:
      amqp: ${RABBITMQ_NODEPORT_AMQP}
      manager: ${RABBITMQ_NODEPORT_MANAGER}
EOF

# --- Step Counter (must be set before any function uses it) ---
# Set STEP_TOTAL to the number of step_major calls in this script (do NOT include step 0)
STEP_TOTAL=$(grep -c '^[[:space:]]*step_major ' "$0")
STEP_COUNTER=0

# --- Logging Setup ---
LOGDIR="$(pwd)/logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/scdf-install.log"

# Log header for visual separation
{
  echo -e "\n\n\n"
  echo "#############################################################"
  echo "#   SCDF INSTALL SCRIPT LOG   |   $(date '+%Y-%m-%d %H:%M:%S')   #"
  echo "#############################################################"
} >> "$LOGFILE"

# --- Namespace Setup ---
NAMESPACE="${NAMESPACE:-scdf}"
POSTGRES_RELEASE_NAME="${POSTGRES_RELEASE_NAME:-scdf-postgresql}"
RABBITMQ_RELEASE_NAME="${RABBITMQ_RELEASE_NAME:-scdf-rabbitmq}"
MINIO_RELEASE="${MINIO_RELEASE:-scdf-minio}"
MINIO_PV="${MINIO_PV:-scdf-minio-pv}"
MINIO_PVC="${MINIO_PVC:-scdf-minio-pvc}"
POSTGRES_NODEPORT="${POSTGRES_NODEPORT:-30432}"
RABBITMQ_NODEPORT_AMQP="${RABBITMQ_NODEPORT_AMQP:-30672}"
RABBITMQ_NODEPORT_MANAGER="${RABBITMQ_NODEPORT_MANAGER:-31672}"
SCDF_SERVER_PORT="${SCDF_SERVER_PORT:-30080}"
SKIPPER_PORT="${SKIPPER_PORT:-30081}"
MINIO_API_PORT="${MINIO_API_PORT:-30900}"
MINIO_CONSOLE_PORT="${MINIO_CONSOLE_PORT:-30901}"
OLLAMA_NODEPORT="${OLLAMA_NODEPORT:-31434}"

# --- Utility Functions ---
# Print an informational message to log file only, indented (does not increment step counter)
step_minor() {
  echo "      [INFO] $1" >>"$LOGFILE"
}
# Print a cyan status message to log file only, indented
status() {
  echo "      [STATUS] $1" >>"$LOGFILE"
}
# Print a completion message in [N/TOTAL] format, to terminal and log
step_done() {
  # Print a completion message in [N/TOTAL] format, to terminal and log
  if [[ -n "$STEP_LAST" ]]; then
    echo -e "\033[1;36m[$STEP_COUNTER/$STEP_TOTAL] COMPLETE: $STEP_LAST\033[0m"
    echo "[$STEP_COUNTER/$STEP_TOTAL] COMPLETE: $STEP_LAST" >>"$LOGFILE"
    STEP_LAST=""
  fi
}
# Print a red error message to terminal
err() { echo -e "\033[1;31m$1\033[0m" >&2; }

step_major() {
  STEP_COUNTER=$((STEP_COUNTER+1))
  STEP_LAST="$1"
  echo -e "\033[1;32m[$STEP_COUNTER/$STEP_TOTAL] $1\033[0m" >&2
  echo "[$STEP_COUNTER/$STEP_TOTAL] $1" >>"$LOGFILE"
}

# Wait for a Kubernetes pod to be ready
# Usage: wait_for_ready <name_substr> [timeout] [label_selector]
wait_for_ready() {
  NAME_SUBSTR="$1"
  TIMEOUT="${2:-120}"
  LABEL_SELECTOR="$3"
  if [ -z "$LABEL_SELECTOR" ]; then
    # Special case for ollama-nomic
    if [[ "$NAME_SUBSTR" == "ollama-nomic" ]]; then
      LABEL_SELECTOR="app=ollama-nomic"
    # PostgreSQL Helm chart
    elif [[ "$NAME_SUBSTR" == "postgresql" ]]; then
      LABEL_SELECTOR="app.kubernetes.io/instance=scdf-postgresql"
    # RabbitMQ Helm chart
    elif [[ "$NAME_SUBSTR" == "rabbitmq" ]]; then
      LABEL_SELECTOR="app.kubernetes.io/instance=scdf-rabbitmq"
    # SCDF server
    elif [[ "$NAME_SUBSTR" == "scdf-spring-cloud-dataflow-server" ]]; then
      LABEL_SELECTOR="app.kubernetes.io/component=server"
    # SCDF skipper
    elif [[ "$NAME_SUBSTR" == "scdf-spring-cloud-dataflow-skipper" ]]; then
      LABEL_SELECTOR="app.kubernetes.io/component=skipper"
    fi
  fi

  for ((i=0; i<TIMEOUT; i++)); do
    pod=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" --no-headers 2>>"$LOGFILE" | awk '/Running|Pending|ContainerCreating/ {print $1; exit}')
    if [[ -z "$pod" ]]; then
      sleep 1
      continue
    fi
    phase=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>>"$LOGFILE")
    ready=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].ready}' 2>>"$LOGFILE")
    if [[ "$phase" == "Running" && "$ready" == "true" ]]; then
      break
    fi
    # Only log status, don't print to terminal
    status "Waiting for pod '$pod': phase=$phase, ready=$ready ($i/$TIMEOUT)"
    sleep 1
  done
}

# Download the SCDF Shell JAR if not present
# Usage: download_shell_jar
# Ensures $SHELL_JAR exists
download_shell_jar() {
  step_major "Downloading SCDF Shell JAR"
  if [[ ! -f "$SHELL_JAR" ]]; then
    step_minor "Downloading SCDF Shell JAR..."
    curl -fsSL -o "$SHELL_JAR" "$SHELL_URL" >>"$LOGFILE" 2>&1 || { err "Failed to download SCDF Shell JAR"; exit 1; }
    step_done "SCDF Shell JAR downloaded."
  else
    step_minor "SCDF Shell JAR already present."
    step_done "SCDF Shell JAR already present."
  fi
}

# Register all default apps as Docker images
# Usage: register_default_apps_docker
register_default_apps_docker() {
  step_major "Registering default apps as Docker images (RabbitMQ)"
  local failed=0
  local success=0
  local total=0

  # Download the official SCDF docker app properties for RabbitMQ
  local DOCKER_PROPS_URL="https://dataflow.spring.io/rabbitmq-docker-latest"
  local TMP_PROPS_FILE="/tmp/scdf-docker-apps.properties"
  curl -fsSL -o "$TMP_PROPS_FILE" "$DOCKER_PROPS_URL" || { echo "Failed to download Docker app properties." >&2; return 1; }

  while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    key="${line%%=*}"
    uri="${line#*=}"
    type="${key%%.*}"
    name="${key#*.}"
    [[ "$uri" != docker:* ]] && continue
    REG_URL="$SCDF_SERVER_URL/apps/$type/$name"
    total=$((total+1))
    REG_OUTPUT=$(curl -s -w "\n%{http_code}" -X POST "$REG_URL" -d "uri=$uri" 2>&1)
    HTTP_CODE=$(echo "$REG_OUTPUT" | tail -n1)
    BODY=$(echo "$REG_OUTPUT" | sed '$d')
    if [[ "$HTTP_CODE" == "201" ]]; then
      echo "[REGISTER OK] $type:$name -> $uri (HTTP $HTTP_CODE)" >>"$LOGFILE"
      success=$((success+1))
    else
      echo "[REGISTER FAIL] $type:$name -> $uri (HTTP $HTTP_CODE): $BODY" >>"$LOGFILE"
      failed=1
    fi
  done < "$TMP_PROPS_FILE"

  echo "[REGISTER SUMMARY] Total: $total, Success: $success, Failed: $((total-success))" >>"$LOGFILE"
  if [ $failed -eq 1 ]; then
    echo -e "\033[1;31mSome or all Docker app registrations failed. See $LOGFILE for details.\033[0m" >&2
  else
    step_done "All Docker apps registered successfully."
  fi
}

# Print management URLs
print_management_urls() {
  # Print and save credentials to creds.txt, terminal, and logs (identical output)
  CREDS_FILE="$(pwd)/creds.txt"
  {
    echo "# SCDF Deployment Credentials (generated $(date))"
    echo "---"
    echo "[PostgreSQL]"
    echo "Host: $EXTERNAL_HOSTNAME:$POSTGRES_NODEPORT"
    echo "User: $POSTGRES_USER"
    echo "Password: $POSTGRES_PASSWORD"
    echo "Database: $POSTGRES_DB"
    echo "---"
    echo "[RabbitMQ]"
    echo "AMQP: $EXTERNAL_HOSTNAME:$RABBITMQ_NODEPORT_AMQP"
    echo "Manager UI: $EXTERNAL_HOSTNAME:$RABBITMQ_NODEPORT_MANAGER"
    echo "User: $RABBITMQ_USER"
    echo "Password: $RABBITMQ_PASSWORD"
    echo "---"
    if [[ "$STORAGE_BACKEND" == "hdfs" ]]; then
      echo "[HDFS]"
      echo "NameNode (RPC): $EXTERNAL_HOSTNAME:31900 (external), hdfs-namenode.scdf.svc.cluster.local:9000 (internal)"
      echo "DataNode (default): internal only, see container docs"
      echo "WebHDFS UI: $EXTERNAL_HOSTNAME:31570 (external), hdfs-namenode.scdf.svc.cluster.local:50070 (internal)"
      echo "(No credentials required by default for mdouchement/hdfs)"
      echo "---"
    else
      if kubectl get secret minio -n "$NAMESPACE" >/dev/null 2>&1; then
        MINIO_USER=$(kubectl get secret minio -n "$NAMESPACE" -o jsonpath='{.data.root-user}' | base64 --decode 2>/dev/null || echo '')
        MINIO_PASS=$(kubectl get secret minio -n "$NAMESPACE" -o jsonpath='{.data.root-password}' | base64 --decode 2>/dev/null || echo '')
      else
        MINIO_USER="<not installed>"
        MINIO_PASS="<not installed>"
      fi
      echo "[MinIO S3]"
      echo "API: $EXTERNAL_HOSTNAME:$MINIO_API_PORT"
      echo "Console: $EXTERNAL_HOSTNAME:$MINIO_CONSOLE_PORT"
      echo "User: $MINIO_USER"
      echo "Password: $MINIO_PASS"
      echo "---"
    fi
    echo "[Ollama]"
    echo "API (phi3 and nomic-embed-text): $EXTERNAL_HOSTNAME:$OLLAMA_NODEPORT (service: ollama)"
    echo "---"
    echo "[SCDF Dashboard]"
    echo "URL: http://$EXTERNAL_HOSTNAME:$SCDF_SERVER_PORT/dashboard"
    echo "---"
    echo "[Kubernetes Namespace]"
    echo "Namespace: $NAMESPACE"
    echo "---"
    echo "--- Management URLs and Credentials ---"
    echo "SCDF Dashboard:    http://$EXTERNAL_HOSTNAME:$SCDF_SERVER_PORT/dashboard"
    if [[ "$STORAGE_BACKEND" == "hdfs" ]]; then
      echo "HDFS Web UI:       http://$EXTERNAL_HOSTNAME:31570"
    else
      echo "MinIO MGMT Console: http://$EXTERNAL_HOSTNAME:${MINIO_CONSOLE_PORT}"
      echo "  Access Key: $MINIO_USER"
      echo "  Secret Key: $MINIO_PASS"
    fi
    echo "MinIO MGMT Console: http://$EXTERNAL_HOSTNAME:${MINIO_CONSOLE_PORT}"
    echo "Namespace:         $NAMESPACE"
    echo "---"
    echo "Credentials have also been written to creds.txt in the project root."

    echo "To stop services, delete the namespace or uninstall the Helm releases."
    echo "---"
  } | tee "$CREDS_FILE" | tee -a "$LOGFILE"
}

# --- Namespace Utility ---
ensure_namespace() {
{{ ... }}
  if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    step_minor "Creating namespace $NAMESPACE..."
    kubectl create namespace "$NAMESPACE" >>"$LOGFILE" 2>&1
  else
    echo "      [INFO] Namespace $NAMESPACE already exists, skipping creation." >>"$LOGFILE"
  fi
}

# --- Cleanup Previous Install ---
cleanup_previous_install() {
  step_major "Cleaning up previous SCDF install (Helm releases, PVCs, PVs, and namespace)"
  # Delete Helm releases
  helm uninstall "$POSTGRES_RELEASE_NAME" -n "$NAMESPACE" >>"$LOGFILE" 2>&1 || true
  helm uninstall "$RABBITMQ_RELEASE_NAME" -n "$NAMESPACE" >>"$LOGFILE" 2>&1 || true
  helm uninstall "$MINIO_RELEASE" -n "$NAMESPACE" >>"$LOGFILE" 2>&1 || true
  helm uninstall scdf -n "$NAMESPACE" >>"$LOGFILE" 2>&1 || true

  # Delete PVCs in the namespace
  step_minor "Deleting all PersistentVolumeClaims in namespace $NAMESPACE..."
  kubectl get pvc -n "$NAMESPACE" --no-headers 2>>"$LOGFILE" | awk '{print $1}' | xargs -r -n1 kubectl delete pvc -n "$NAMESPACE" >>"$LOGFILE" 2>&1

  # Delete PVs that are Released or Bound to deleted PVCs (including MinIO PV)
  step_minor "Deleting orphaned PersistentVolumes (including MinIO PV if present)..."
  for pv in $(kubectl get pv --no-headers 2>>"$LOGFILE" | awk '{print $1}'); do
    status=$(kubectl get pv "$pv" -o jsonpath='{.status.phase}')
    claim=$(kubectl get pv "$pv" -o jsonpath='{.spec.claimRef.namespace}')/$(kubectl get pv "$pv" -o jsonpath='{.spec.claimRef.name}')
    if [[ "$status" == "Released" || "$claim" == "$NAMESPACE/" || "$claim" == "$NAMESPACE/" ]]; then
      kubectl delete pv "$pv" >>"$LOGFILE" 2>&1 || true
    fi
  done

  # Delete namespace (will also delete any remaining resources)
  kubectl delete namespace "$NAMESPACE" --ignore-not-found >>"$LOGFILE" 2>&1 || true

  # Wait for namespace deletion to complete
  for i in {1..60}; do
    echo "[DEBUG] kubectl get namespace $NAMESPACE" >>"$LOGFILE"
    if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
      status "Namespace $NAMESPACE deleted."
      break
    fi
    echo "[INFO] Waiting for namespace $NAMESPACE to be deleted... [${i}/60]" >>"$LOGFILE"
    sleep 2
  done
  step_done "Cleanup complete."
}

# --- Helper function to check if a Helm release exists in the namespace ---
is_release_installed() {
  local release_name="$1"
  local namespace="$2"
  helm status "$release_name" --namespace "$namespace" >/dev/null 2>&1
}

# --- Helper function to check for pgvector extension in PostgreSQL ---
check_pgvector_extension() {
  echo "Checking for pgvector extension in PostgreSQL..." >>"$LOGFILE"
  POSTGRES_POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/instance=$POSTGRES_RELEASE_NAME,app.kubernetes.io/component=primary -o jsonpath="{.items[0].metadata.name}")
  # Use the postgres superuser for extension check/install
  SUPERUSER=postgres
  SUPERPASS=$POSTGRES_SUPERUSER_PASSWORD
  # Wait for PostgreSQL to be ready for SQL connections
  for i in {1..10}; do
    kubectl exec -n "$NAMESPACE" "$POSTGRES_POD" -- \
      bash -c "PGPASSWORD=$SUPERPASS psql -U $SUPERUSER -d $POSTGRES_DB -c '\l'" >>"$LOGFILE" 2>&1 && break
    echo "Waiting for PostgreSQL to accept connections... ($i/10)" >>"$LOGFILE"
    sleep 5
  done
  RESULT=$(kubectl exec -n "$NAMESPACE" "$POSTGRES_POD" -- bash -c "PGPASSWORD=$SUPERPASS psql -U $SUPERUSER -d $POSTGRES_DB -tAc \"SELECT extname FROM pg_extension WHERE extname = 'vector';\"")
  if [[ "$RESULT" == "vector" ]]; then
    echo "pgvector extension is INSTALLED." >>"$LOGFILE"
  else
    echo "pgvector extension is NOT installed! Attempting to install..." >>"$LOGFILE"
    kubectl exec -n "$NAMESPACE" "$POSTGRES_POD" -- bash -c "PGPASSWORD=$SUPERPASS psql -U $SUPERUSER -d $POSTGRES_DB -c \"CREATE EXTENSION IF NOT EXISTS vector;\"" >>"$LOGFILE"
    # Re-check after install
    RESULT2=$(kubectl exec -n "$NAMESPACE" "$POSTGRES_POD" -- bash -c "PGPASSWORD=$SUPERPASS psql -U $SUPERUSER -d $POSTGRES_DB -tAc \"SELECT extname FROM pg_extension WHERE extname = 'vector';\"")
    if [[ "$RESULT2" == "vector" ]]; then
      echo "pgvector extension has been INSTALLED successfully." >>"$LOGFILE"
    else
      echo "FAILED to install pgvector extension!" >>"$LOGFILE"
    fi
  fi
  echo "pgvector extension check complete." >>"$LOGFILE"
}

# --- Install PostgreSQL as a standalone function ---
install_postgresql() {
  ensure_namespace
  if is_release_installed "$POSTGRES_RELEASE_NAME" "$NAMESPACE"; then
    step_minor "PostgreSQL already installed. Skipping."
    check_pgvector_extension
    return 0
  fi
  step_major "Install PostgreSQL"
  helm upgrade --install "$POSTGRES_RELEASE_NAME" bitnami/postgresql \
    --namespace "$NAMESPACE" \
    --set auth.username="$POSTGRES_USER" \
    --set auth.password="$POSTGRES_PASSWORD" \
    --set auth.database="$POSTGRES_DB" \
    --set auth.postgresPassword="$POSTGRES_SUPERUSER_PASSWORD" \
    --set image.repository=bitnami/postgresql \
    --set image.tag=latest \
    --set primary.service.type=NodePort \
    --set primary.service.nodePorts.postgresql=$POSTGRES_NODEPORT \
    --set service.type=NodePort \
    --set service.nodePorts.postgresql=$POSTGRES_NODEPORT \
    --set postgresql.extensions[0]=pgvector \
    --set global.security.allowInsecureImages=true \
    --wait >>"$LOGFILE" 2>&1
  wait_for_ready postgresql 300
  step_done "PostgreSQL installed and ready."
  check_pgvector_extension
}

# --- Install HDFS as a standalone function ---
install_hdfs() {
  ensure_namespace
  step_major "Reset HDFS Deployment (delete existing deployment/service)"
  kubectl delete -f resources/hdfs.yaml --ignore-not-found >>"$LOGFILE" 2>&1
  step_major "Apply HDFS YAML"
  kubectl apply -f resources/hdfs.yaml >>"$LOGFILE" 2>&1
  wait_for_ready hdfs-deployment 180
  step_done "HDFS deployed and ready."
}

# --- Install MinIO as a standalone function ---
install_minio() {
  ensure_namespace
  if is_release_installed "$MINIO_RELEASE" "$NAMESPACE"; then
    step_minor "MinIO already installed. Skipping."
    return 0
  fi
  step_major "Install MinIO"
  helm upgrade --install "$MINIO_RELEASE" bitnami/minio \
    --namespace "$NAMESPACE" \
    --set persistence.enabled=true \
    --set persistence.size=10Gi \
    --set mode=standalone \
    --set resources.requests.memory=512Mi \
    --set resources.requests.cpu=250m \
    --set service.type=NodePort \
    --set service.nodePorts.api="$MINIO_API_PORT" \
    --set service.nodePorts.console="$MINIO_CONSOLE_PORT" \
    --wait >>"$LOGFILE" 2>&1
  wait_for_ready "$MINIO_RELEASE" 300
  step_done "MinIO installed and ready."
}

# --- Deploy Ollama Multi-Model (phi3 + nomic-embed-text) ---
# Deploys a single Ollama container with both phi3 and nomic-embed-text models available via API.
# Uses resources/ollama.yaml for deployment and exposes service on NodePort 31434.
apply_ollama_models_yaml() {
  ensure_namespace
  step_major "Reset Ollama Multi-Model Deployment (delete existing deployment/service)"
  kubectl delete -f resources/ollama.yaml --ignore-not-found >>"$LOGFILE" 2>&1
  step_major "Apply Ollama Multi-Model YAML (phi3 and nomic-embed-text)"
  kubectl apply -f resources/ollama.yaml >>"$LOGFILE" 2>&1
  wait_for_ready ollama-deployment 180
  step_done "Ollama with phi3 and nomic-embed-text deployed in single container."
}

# (Removed: Ollama Phi is now included in the combined deployment)

# --- Prompt for Storage Backend ---
# Prompt user for S3 (MinIO) or HDFS backend at the start of install
prompt_storage_backend() {
  echo "Select storage backend:"
  echo "  1) S3 (MinIO)"
  echo "  2) HDFS"
  read -p "Enter choice [1-2, default 1]: " STORAGE_BACKEND_CHOICE
  case "$STORAGE_BACKEND_CHOICE" in
    2)
      STORAGE_BACKEND="hdfs"
      ;;
    *)
      STORAGE_BACKEND="s3"
      ;;
  esac
  echo "[INFO] Using storage backend: $STORAGE_BACKEND" | tee -a "$LOGFILE"
}

# --- SCDF Install ---
install_scdf() {
  ensure_namespace
  install_postgresql
  step_major "Installing Spring Cloud Data Flow (includes Skipper, chart-managed RabbitMQ), and waiting for pods to be ready..."
  # When creating or updating the Skipper service, ensure the NodePort is set to $SKIPPER_PORT
  # Example for Helm or kubectl usage:
  #   --set skipper.service.type=NodePort \
  #   --set skipper.service.nodePort=$SKIPPER_PORT
  # or in a kubectl manifest patch:
  #   nodePort: $SKIPPER_PORT
  helm upgrade --install scdf oci://registry-1.docker.io/bitnamicharts/spring-cloud-dataflow \
    --namespace "$NAMESPACE" \
    --values resources/scdf-values.yaml \
    --set server.service.type=NodePort \
    --set server.service.nodePort="$SCDF_SERVER_PORT" \
    --set skipper.service.type=NodePort \
    --set skipper.service.nodePort="$SKIPPER_PORT" \
    >>"$LOGFILE" 2>&1
  wait_for_ready scdf-spring-cloud-dataflow-server 300
  wait_for_ready scdf-spring-cloud-dataflow-skipper 300
  step_done "Spring Cloud Data Flow and Skipper installed and ready."
}

# --- Interactive Menu for --test ---
show_menu() {
  echo
  echo "SCDF Install Script Test Menu"
  echo "-----------------------------------"
  echo "1) Cleanup previous install"
  echo "2) Install PostgreSQL"
  echo "3) Install MinIO"
  echo "4) Deploy Ollama Models (nomic + phi, single container)"
  echo "6) Install Spring Cloud Data Flow (includes Skipper, chart-managed RabbitMQ)"
  echo "7) Download SCDF Shell JAR"
  echo "8) Register Default Apps (Docker)"
  echo "9) Display the Management URLs"
  echo "q) Exit"
  echo -n "Select a step to run [1-9, q to quit]: "
}

if [[ "$1" == "--test" ]]; then
  while true; do
    show_menu
    read -r choice
    case $choice in
      1)
        cleanup_previous_install
        ;;
      2)
        install_postgresql
        ;;
      3)
        install_minio
        ;;
      4)
        apply_ollama_models_yaml
        ;;
      5)
        install_scdf
        ;;
      7)
        download_shell_jar
        ;;
      8)
        register_default_apps_docker
        ;;
      9)
        print_management_urls
        ;;
      q|Q)
        echo "Exiting."
        exit 0
        ;;
      *)
        echo "Invalid option. Please select 1-9 or q to quit."
        ;;
    esac
    echo
    echo "--- Step complete. Return to menu. ---"
  done
  exit 0
fi

# --- Full Install Flow ---
prompt_storage_backend
cleanup_previous_install
install_postgresql
if [[ "$STORAGE_BACKEND" == "hdfs" ]]; then
  install_hdfs
else
  install_minio
fi
apply_ollama_models_yaml
install_scdf
download_shell_jar
register_default_apps_docker
print_management_urls

exit 0
