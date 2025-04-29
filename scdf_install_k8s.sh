#!/bin/bash
# scdf_install_k8s.sh: Installs SCDF on Kubernetes
# Usage: ./scdf_install_k8s.sh > logs/scdf_install_k8s.log 2>&1

# --- Step Counter (must be set before any function uses it) ---
# Set STEP_TOTAL to the number of step_major calls in this script (do NOT include step 0)
STEP_TOTAL=$(grep -c '^\s*step_major ' "$0")
STEP_COUNTER=0

# --- Prerequisite Checks (Step 0 of N) ---
printf -v STEP_0_FMT "\033[1;32m[0/%d] Checking prerequisites (kubectl, helm, yq) ...\033[0m" "$STEP_TOTAL"
echo -e "$STEP_0_FMT"
REQUIRED_TOOLS=(kubectl helm yq)
MISSING_TOOLS=()
for tool in "${REQUIRED_TOOLS[@]}"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    MISSING_TOOLS+=("$tool")
  fi
done
if [ ${#MISSING_TOOLS[@]} -ne 0 ]; then
  echo "[ERROR] The following required tools are missing: ${MISSING_TOOLS[*]}" >&2
  echo "Please install them before running this script. See README.md for instructions." >&2
  exit 1
fi

# --- Logging Setup ---
LOGDIR="$(pwd)/logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/scdf_install_k8s.log"

# --- Source environment variables ---
if [ -f "./scdf_env.properties" ]; then
  set -o allexport
  source ./scdf_env.properties
  set +o allexport
else
  echo "[ERROR] scdf_env.properties not found! Please create it or check the path." >&2
  exit 1
fi

# Set default SCDF Shell JAR location and download URL if not set
: "${SHELL_JAR:=spring-cloud-dataflow-shell.jar}"
: "${SHELL_URL:=https://repo1.maven.org/maven2/org/springframework/cloud/spring-cloud-dataflow-shell/2.11.1/spring-cloud-dataflow-shell-2.11.1.jar}"

# --- Namespace Setup ---
NAMESPACE="${NAMESPACE:-scdf}"
POSTGRES_RELEASE_NAME="${POSTGRES_RELEASE_NAME:-scdf-postgres}"

# --- Utility Functions ---
# Print an informational message to log file only (does not increment step counter)
step_minor() {
  echo "    [INFO] $1" >>"$LOGFILE"
}
# Print a cyan status message to log file only
status() {
  echo "    [STATUS] $1" >>"$LOGFILE"
}
# Print a completion message in [N/TOTAL] format, to terminal and log
step_done() {
  echo -e "\033[1;36m[$STEP_COUNTER/$STEP_TOTAL] COMPLETE: $STEP_LAST\033[0m" >&2
  # echo "[$STEP_COUNTER/$STEP_TOTAL] COMPLETE: $STEP_LAST" >>"$LOGFILE"
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
      LABEL_SELECTOR="app.kubernetes.io/instance=scdf,app.kubernetes.io/component=server"
    # SCDF skipper
    elif [[ "$NAME_SUBSTR" == "scdf-spring-cloud-dataflow-skipper" ]]; then
      LABEL_SELECTOR="app.kubernetes.io/instance=scdf,app.kubernetes.io/component=skipper"
    else
      LABEL_SELECTOR="app.kubernetes.io/instance=$NAME_SUBSTR"
    fi
  fi
  echo "[DEBUG] wait_for_ready: NAME_SUBSTR=$NAME_SUBSTR, TIMEOUT=$TIMEOUT, LABEL_SELECTOR=$LABEL_SELECTOR" >>"$LOGFILE"
  DEBUG_PRINTED=0
  for ((i=0; i<TIMEOUT; i++)); do
    if [ $DEBUG_PRINTED -eq 0 ]; then
      echo "[DEBUG] kubectl get pods -n $NAMESPACE -l $LABEL_SELECTOR -o jsonpath='{.items[0].metadata.name}'" >>"$LOGFILE"
      echo "[DEBUG] kubectl get pods -n $NAMESPACE -l $LABEL_SELECTOR -o jsonpath='{.items[0].status.containerStatuses[0].ready}'" >>"$LOGFILE"
      echo "[DEBUG] kubectl get pods -n $NAMESPACE -l $LABEL_SELECTOR -o jsonpath='{.items[0].status.phase}'" >>"$LOGFILE"
      DEBUG_PRINTED=1
    fi
    POD=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    READY=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)
    PHASE=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
    if [ -z "$POD" ]; then
      status "Waiting for pod matching label '$LABEL_SELECTOR' to appear... ($i/$TIMEOUT)"
      sleep 1
      continue
    fi
    status "Waiting for pod '$POD': phase=$PHASE, ready=$READY ($i/$TIMEOUT)"
    [[ "$PHASE" == "Running" && "$READY" == true ]] && return 0
    sleep 1
  done
  err "Pod matching label '$LABEL_SELECTOR' not ready after $TIMEOUT seconds."
  echo "[ERROR] Pod matching label '$LABEL_SELECTOR' not ready after $TIMEOUT seconds." >>"$LOGFILE"
  return 1
}

# Download the SCDF Shell JAR if not present
# Usage: download_shell_jar
# Ensures $SHELL_JAR exists
download_shell_jar() {
  if [[ ! -f "$SHELL_JAR" ]]; then
    step_minor "Downloading SCDF Shell JAR..."
    curl -fsSL -o "$SHELL_JAR" "$SHELL_URL" >>"$LOGFILE" 2>&1 || { err "Failed to download SCDF Shell JAR"; exit 1; }
    step_done "SCDF Shell JAR downloaded."
  else
    step_minor "SCDF Shell JAR already present."
    step_done "SCDF Shell JAR already present."
  fi
}

# Register all default apps as Maven artifacts
# Usage: register_default_apps_maven
register_default_apps_maven() {
  step_minor "Registering all default apps as Maven artifacts..."
  local failed=0
  while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ || -z "$line" || "$line" == *":jar:metadata"* ]] && continue
    key="${line%%=*}"
    uri="${line#*=}"
    type="${key%%.*}"
    name="${key#*.}"
    [[ "$uri" != maven:* ]] && continue
    REG_URL="$SCDF_SERVER_URL/apps/$type/$name"
    step_minor "Registering $type:$name -> $uri"
    echo "[register_default_apps_maven] Registering $type:$name -> $uri ($REG_URL)" >>"$LOGFILE"
    REG_OUTPUT=$(curl -s -w "\n%{http_code}" -X POST "$REG_URL" -d "uri=$uri" 2>&1)
    HTTP_CODE=$(echo "$REG_OUTPUT" | tail -n1)
    BODY=$(echo "$REG_OUTPUT" | sed '$d')
    echo "[register_default_apps_maven] Response: HTTP $HTTP_CODE, Body: $BODY" >>"$LOGFILE"
    echo "$type.$name=$uri -> $HTTP_CODE" >> "$LOGFILE"
    if [[ "$HTTP_CODE" != "201" ]]; then
      err "Failed to register $type:$name ($HTTP_CODE)."
      echo "[register_default_apps_maven] Failed to register $type:$name ($HTTP_CODE). Body: $BODY" >>"$LOGFILE"
      echo -e "\033[1;31m[REGISTRATION ERROR] $type:$name ($HTTP_CODE): $BODY\033[0m" >&2
      failed=1
    fi
  done < "$APPS_PROPS_FILE_MAVEN"
  step_done "Default Maven applications registration complete."
  echo "[register_default_apps_maven] Registration process complete." >>"$LOGFILE"
  if [ $failed -eq 1 ]; then
    echo -e "\033[1;31mSome or all Maven app registrations failed. See $LOGFILE for details.\033[0m" >&2
  fi
}

# Print management URLs
print_management_urls() {
  {
    echo "--- Management URLs and Credentials ---"
    echo "SCDF Dashboard:    http://127.0.0.1:30080/dashboard"
    echo "RabbitMQ MGMT UI:  http://127.0.0.1:$RABBITMQ_NODEPORT_MANAGER [$RABBITMQ_USER/$RABBITMQ_PASSWORD]"
    echo "RabbitMQ AMQP:     localhost:$RABBITMQ_NODEPORT_AMQP [$RABBITMQ_USER/$RABBITMQ_PASSWORD]"
    echo "PostgreSQL:        localhost:$POSTGRES_NODEPORT [$POSTGRES_USER/$POSTGRES_PASSWORD, DB: $POSTGRES_DB]"
    echo "Ollama (nomic):    http://ollama-nomic.$NAMESPACE.svc.cluster.local:11434 [internal K8s]"
    echo "Ollama (nomic, local): http://127.0.0.1:11434 [if port-forwarded]"
    MINIO_USER=$(kubectl get secret --namespace $NAMESPACE $MINIO_RELEASE -o jsonpath="{.data.root-user}" | base64 --decode 2>/dev/null)
    MINIO_PASS=$(kubectl get secret --namespace $NAMESPACE $MINIO_RELEASE -o jsonpath="{.data.root-password}" | base64 --decode 2>/dev/null)
    if [[ -n "$MINIO_USER" && -n "$MINIO_PASS" ]]; then
      echo "MinIO Credentials [Bitnami Helm chart default]:"
      echo "  Access Key: $MINIO_USER"
      echo "  Secret Key: $MINIO_PASS"
    fi
    echo "MinIO MGMT Console: http://127.0.0.1:${MINIO_CONSOLE_PORT}"
    echo "Namespace:         $NAMESPACE"
    echo "To stop services, delete the namespace or uninstall the Helm releases."
    echo "---"
    echo "Nomic Model Info:  Model 'nomic-embed-text' is available via the Ollama API."
    echo "  Example embedding endpoint: POST /api/embeddings to http://ollama-nomic.$NAMESPACE.svc.cluster.local:11434"
  } | tee -a "$LOGFILE"
}

# --- Constants and Flags ---
SKIP_INSTALL=0
INSTALL_MODELS_ONLY=0
PRINT_URLS_ONLY=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-install)
      SKIP_INSTALL=1
      shift
      ;;
    --models-only)
      INSTALL_MODELS_ONLY=1
      shift
      ;;
    --print-urls)
      PRINT_URLS_ONLY=1
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# --- Print URLs Only Mode ---
if [[ $PRINT_URLS_ONLY -eq 1 ]]; then
  print_management_urls
  exit 0
fi

# --- Main Install Logic ---
if [[ $INSTALL_MODELS_ONLY -eq 1 ]]; then
  # Only deploy the Ollama model service, skip cleanup and all other steps
  step_major "Creating namespace..."
  echo "[DEBUG] kubectl create namespace $NAMESPACE" >>"$LOGFILE"
  kubectl create namespace "$NAMESPACE" 2>/dev/null || true
  step_done "Namespace created."
  step_major "Deploying Ollama nomic-embed-text model as a Kubernetes service and waiting for pod to be ready..."
  kubectl apply -f ollama-nomic.yaml -n "$NAMESPACE" >>"$LOGFILE" 2>&1
  wait_for_ready ollama-nomic 120
  step_done "Ollama nomic-embed-text model deployed and ready."
  exit 0
fi

# --- Full install: cleanup and all services ---
step_major "Cleaning up previous SCDF installs..."
echo "[DEBUG] helm uninstall scdf --namespace $NAMESPACE" >>"$LOGFILE"
helm uninstall scdf --namespace "$NAMESPACE" >>"$LOGFILE" 2>&1 || true
echo "[DEBUG] helm uninstall scdf-rabbitmq --namespace $NAMESPACE" >>"$LOGFILE"
helm uninstall scdf-rabbitmq --namespace "$NAMESPACE" >>"$LOGFILE" 2>&1
step_done "Previous SCDF installs cleaned up."

# Wait for deployments to be deleted
step_major "Waiting for SCDF and RabbitMQ deployments to be deleted..."
for dep in scdf scdf-rabbitmq; do
  for i in {1..30}; do
    echo "[DEBUG] kubectl get deployment $dep -n $NAMESPACE" >>"$LOGFILE"
    if ! kubectl get deployment "$dep" -n "$NAMESPACE" &>/dev/null; then
      status "$dep deployment deleted."
      break
    fi
    echo "[INFO] Waiting for $dep deployment to be deleted... [${i}/30]" >>"$LOGFILE"
    sleep 2
  done
done
step_done "SCDF and RabbitMQ deployments deleted."

step_major "Deleting namespace..."
echo "[DEBUG] kubectl delete namespace $NAMESPACE" >>"$LOGFILE"
kubectl delete namespace "$NAMESPACE" >>"$LOGFILE" 2>&1 || true
for i in {1..60}; do
  echo "[DEBUG] kubectl get namespace $NAMESPACE" >>"$LOGFILE"
  if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    status "Namespace $NAMESPACE deleted."
    step_done "Namespace deleted."
    break
  fi
  echo "[INFO] Waiting for namespace $NAMESPACE to be deleted... [${i}/60]" >>"$LOGFILE"
  sleep 2
done

step_major "Creating namespace..."
echo "[DEBUG] kubectl create namespace $NAMESPACE" >>"$LOGFILE"
kubectl create namespace "$NAMESPACE" >>"$LOGFILE" 2>&1 || true
step_done "Namespace created."

# --- Ollama with nomic-embed-text (K8s) ---
step_major "Deploying Ollama nomic-embed-text model as a Kubernetes service and waiting for pod to be ready..."
kubectl apply -f ollama-nomic.yaml -n "$NAMESPACE" >>"$LOGFILE" 2>&1
wait_for_ready ollama-nomic 120
step_done "Ollama nomic-embed-text model deployed and ready."

echo "[INFO] Running full install steps..." >>"$LOGFILE"

# --- Helm Repo and RabbitMQ ---
step_major "Adding/updating Helm repo..."
echo "[DEBUG] helm repo add bitnami https://charts.bitnami.com/bitnami" >>"$LOGFILE"
helm repo add bitnami https://charts.bitnami.com/bitnami >>"$LOGFILE" 2>&1 || true
echo "[DEBUG] helm repo update" >>"$LOGFILE"
helm repo update >>"$LOGFILE" 2>&1
step_done "Helm repo added/updated."

step_major "Installing RabbitMQ and waiting for pod to be ready..."
helm upgrade --install "$RABBITMQ_RELEASE_NAME" bitnami/rabbitmq \
  --namespace "$NAMESPACE" \
  --set auth.username="$RABBITMQ_USER" \
  --set auth.password="$RABBITMQ_PASSWORD" \
  --set auth.erlangCookie="$RABBITMQ_ERLANG_COOKIE" \
  --set persistence.enabled=false \
  --set service.type=NodePort \
  --set service.nodePorts.amqp="$RABBITMQ_NODEPORT_AMQP" \
  --set service.nodePorts.manager="$RABBITMQ_NODEPORT_MANAGER" \
  >>"$LOGFILE" 2>&1 || true
wait_for_ready rabbitmq 300
step_done "RabbitMQ installed and ready."

# --- PostgreSQL with pgvector ---
step_major "Installing PostgreSQL with pgvector extension via Helm and waiting for pod to be ready..."

# Variable sanity check for required PostgreSQL variables
REQUIRED_VARS=(POSTGRES_RELEASE_NAME POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB POSTGRES_IMAGE_TAG POSTGRES_NODEPORT)
MISSING=()
for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var}" ]]; then
    MISSING+=("$var")
  fi
done
if (( ${#MISSING[@]} > 0 )); then
  echo "[ERROR] The following required PostgreSQL variables are missing or empty:" >>"$LOGFILE"
  for var in "${MISSING[@]}"; do
    echo "  $var='${!var}'" >>"$LOGFILE"
  done
  exit 1
fi

# Create ConfigMap for pgvector init script (idempotent)
kubectl create configmap pgvector-init-script \
  --from-literal=init.sql="CREATE EXTENSION IF NOT EXISTS vector;" \
  -n "$NAMESPACE" 2>>"$LOGFILE" 1>>"$LOGFILE" || kubectl create configmap pgvector-init-script \
  --from-literal=init.sql="CREATE EXTENSION IF NOT EXISTS vector;" \
  -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - 2>>"$LOGFILE" 1>>"$LOGFILE"

helm repo add bitnami https://charts.bitnami.com/bitnami >>"$LOGFILE" 2>&1 || true
helm repo update >>"$LOGFILE" 2>&1

# Helm dry-run for debugging
helm upgrade --install "$POSTGRES_RELEASE_NAME" bitnami/postgresql \
  --namespace "$NAMESPACE" \
  --set postgresqlUsername="$POSTGRES_USER" \
  --set postgresqlPassword="$POSTGRES_PASSWORD" \
  --set postgresqlDatabase="$POSTGRES_DB" \
  --set primary.initdb.scriptsConfigMap=pgvector-init-script \
  --set image.tag="$POSTGRES_IMAGE_TAG" \
  --set service.type=NodePort \
  --set service.nodePorts.postgresql="$POSTGRES_NODEPORT" \
  --debug --dry-run >>"$LOGFILE" 2>&1

# Actual install with error handling
helm upgrade --install "$POSTGRES_RELEASE_NAME" bitnami/postgresql \
  --namespace "$NAMESPACE" \
  --values resources/scdf-values.yaml \
  --set postgresqlUsername="$POSTGRES_USER" \
  --set postgresqlPassword="$POSTGRES_PASSWORD" \
  --set postgresqlDatabase="$POSTGRES_DB" \
  --set primary.initdb.scriptsConfigMap=pgvector-init-script \
  --set image.tag="$POSTGRES_IMAGE_TAG" \
  --set service.type=NodePort \
  --set service.nodePorts.postgresql="$POSTGRES_NODEPORT" \
  >>"$LOGFILE" 2>&1 || true
wait_for_ready postgresql 300
step_done "PostgreSQL with pgvector installed and ready."

# --- SCDF Install: Install and Wait for Server and Skipper ---
step_major "Installing Spring Cloud Data Flow (includes Skipper and MariaDB), and waiting for pods to be ready..."
: "${SCDF_SERVER_PORT:=30080}"
SCDF_SERVER_URL="http://localhost:$SCDF_SERVER_PORT"
export SCDF_SERVER_URL
helm upgrade --install scdf oci://registry-1.docker.io/bitnamicharts/spring-cloud-dataflow \
  --namespace "$NAMESPACE" \
  --values resources/scdf-values.yaml \
  --set rabbitmq.enabled=false \
  --set rabbitmq.host=scdf-rabbitmq \
  --set rabbitmq.username=user \
  --set rabbitmq.password=bitnami \
  --set server.service.type=NodePort \
  --set server.service.nodePort="$SCDF_SERVER_PORT" >>"$LOGFILE" 2>&1
wait_for_ready scdf-spring-cloud-dataflow-server 300
wait_for_ready scdf-spring-cloud-dataflow-skipper 300
step_done "Spring Cloud Data Flow and Skipper installed and ready."

# --- SCDF Shell ---
echo "[DEBUG] About to download_shell_jar" >>"$LOGFILE"
download_shell_jar

# --- Register Default Apps as Maven Artifacts ---
echo "[DEBUG] About to register_default_apps_maven" >>"$LOGFILE"
register_default_apps_maven >>"$LOGFILE" 2>&1

# --- Post-Install Verification and Management Steps ---
step_major "Querying registered apps for verification..."
curl -s "$SCDF_SERVER_URL/apps" > registered_apps.json
cat registered_apps.json >>"$LOGFILE"
step_done "Registered apps have been logged to registered_apps.json and $LOGFILE."

# --- MinIO Install ---
install_minio() {
  step_major "Installing MinIO S3-compatible storage..."
  step_minor "Cleaning up old MinIO PVC and PV if they exist..."
  echo "[DEBUG] kubectl delete pvc $MINIO_PVC -n $NAMESPACE --ignore-not-found" >>"$LOGFILE"
  kubectl delete pvc $MINIO_PVC -n $NAMESPACE --ignore-not-found >>"$LOGFILE" 2>&1
  echo "[DEBUG] kubectl delete pv minio-pv --ignore-not-found" >>"$LOGFILE"
  kubectl delete pv minio-pv --ignore-not-found >>"$LOGFILE" 2>&1

  step_minor "Applying MinIO PersistentVolume and PersistentVolumeClaim YAML..."
  mkdir -p resources
  SOURCE_DOCS_DIR="${MINIO_SOURCE_DIR:-$(pwd)/sourceDocs}"
  mkdir -p "$SOURCE_DOCS_DIR"
  cat > resources/minio-pv-pvc.yaml <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: minio-pv
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteOnce
  hostPath:
    path: $SOURCE_DOCS_DIR
  storageClassName: hostpath
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $MINIO_PVC
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  volumeName: minio-pv
EOF
  echo "[DEBUG] kubectl apply -f resources/minio-pv-pvc.yaml" >>"$LOGFILE"
  kubectl apply -f resources/minio-pv-pvc.yaml >>"$LOGFILE" 2>&1

  step_minor "Adding Bitnami Helm repo and updating..."
  echo "[DEBUG] helm repo add bitnami https://charts.bitnami.com/bitnami" >>"$LOGFILE"
  helm repo add bitnami https://charts.bitnami.com/bitnami >>"$LOGFILE" 2>&1 || true
  echo "[DEBUG] helm repo update" >>"$LOGFILE"
  helm repo update >>"$LOGFILE" 2>&1

  step_minor "Installing MinIO via Helm using static hostPath PV..."
  echo "[DEBUG] helm upgrade --install $MINIO_RELEASE bitnami/minio --namespace $NAMESPACE --set persistence.existingClaim=$MINIO_PVC --set mode=standalone --set resources.requests.memory=512Mi --set resources.requests.cpu=250m --set service.type=NodePort --set service.nodePorts.api=$MINIO_API_PORT --set service.nodePorts.console=$MINIO_CONSOLE_PORT" >>"$LOGFILE"
  helm upgrade --install $MINIO_RELEASE bitnami/minio \
    --namespace $NAMESPACE \
    --set persistence.existingClaim=$MINIO_PVC \
    --set mode=standalone \
    --set resources.requests.memory=512Mi \
    --set resources.requests.cpu=250m \
    --set service.type=NodePort \
    --set service.nodePorts.api=$MINIO_API_PORT \
    --set service.nodePorts.console=$MINIO_CONSOLE_PORT >>"$LOGFILE" 2>&1

  step_minor "Waiting for MinIO pod to be ready..."
  echo "[DEBUG] wait_for_ready minio 300" >>"$LOGFILE"
  wait_for_ready minio 300
  # Print MinIO management (console) address
  # macOS does not support 'hostname -I', so use 'ipconfig getifaddr' for primary interface
  if [[ "$(uname)" == "Darwin" ]]; then
    MINIO_HOST_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)
  else
    MINIO_HOST_IP=$(hostname -I | awk '{print $1}')
  fi
  MINIO_MGMT_URL="http://$MINIO_HOST_IP:${MINIO_CONSOLE_PORT}"
  echo "MinIO Management Console: $MINIO_MGMT_URL" >>"$LOGFILE"
  step_done "MinIO installation complete."
}
install_minio

# --- Print Management URLs ---
print_management_urls

exit 0

# --- END CLEANUP ---
