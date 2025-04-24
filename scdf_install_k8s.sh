#!/bin/bash
# scdf_install_k8s.sh: Installs SCDF on Kubernetes
# Usage: ./scdf_install_k8s.sh > logs/scdf_install_k8s.log 2>&1

# --- Source master properties ---
if [ -f ./scdf_env.properties ]; then
  source ./scdf_env.properties
else
  echo "scdf_env.properties not found! Exiting."
  exit 1
fi

# scdf_install_k8s.sh
# Streamlined installer for Spring Cloud Data Flow (SCDF) on Kubernetes with RabbitMQ and MariaDB.
# - Exposes management interfaces via NodePort
# - Registers default RabbitMQ apps as Docker images via REST API
# - Logs all operations to logs/scdf_install_k8s.log

# --- Constants ---
LOGDIR="$(pwd)/logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/scdf_install_k8s.log"
NAMESPACE="scdf"
DEFAULT_DOCKER_APPS_URI="https://dataflow.spring.io/rabbitmq-docker-latest"
DOCKER_APPS_FILE="apps-docker.properties"
SCDF_SERVER_URL="http://localhost:30080"
SHELL_JAR="spring-cloud-dataflow-shell.jar"
SHELL_URL="https://repo.maven.apache.org/maven2/org/springframework/cloud/spring-cloud-dataflow-shell/2.11.5/spring-cloud-dataflow-shell-2.11.5.jar"

# --- Step Counter (must be set before any function uses it) ---
STEP_COUNTER=0
STEP_TOTAL=13  # Adjusted to match the number of major steps

# --- Utility Functions ---
# Print a step message in [N/TOTAL] format, to terminal and log (only for major steps)
step_major() {
  STEP_COUNTER=$((STEP_COUNTER+1))
  STEP_LAST="$1"
  echo -e "\033[1;32m[$STEP_COUNTER/$STEP_TOTAL] $1\033[0m" >&2
  echo "[$STEP_COUNTER/$STEP_TOTAL] $1" >>"$LOGFILE"
}
# Print an informational message to terminal and log file (does not increment step counter)
step_minor() {
  echo -e "\033[1;34m[INFO] $1\033[0m" >&2
  echo "[INFO] $1" >>"$LOGFILE"
}
# Print a cyan status message to terminal and log file, indented for clarity
status() {
  echo -e "    \033[1;34m[STATUS] $1\033[0m" >&2
  echo "    [STATUS] $1" >>"$LOGFILE"
}
# Print a completion message in [N/TOTAL] format, to terminal and log
step_done() {
  echo -e "\033[1;36m[$STEP_COUNTER/$STEP_TOTAL] COMPLETE: $STEP_LAST\033[0m" >&2
  echo "[$STEP_COUNTER/$STEP_TOTAL] COMPLETE: $STEP_LAST" >>"$LOGFILE"
}
# Print a red error message to terminal
err() { echo -e "\033[1;31m$1\033[0m" >&2; }

# Export step_done and status for subshells
export -f step_done
export -f status

# Wait for a Kubernetes pod to be ready
wait_for_ready() {
  local NAME_SUBSTR=$1
  local TIMEOUT=${2:-300}
  local ELAPSED=0
  local INTERVAL=5
  while (( ELAPSED < TIMEOUT )); do
    POD=$(kubectl get pods -n "$NAMESPACE" --no-headers | grep "$NAME_SUBSTR" | awk '{print $1}')
    echo "[wait_for_ready] Checking for pod with substring '$NAME_SUBSTR' (elapsed: $ELAPSED)" >>"$LOGFILE"
    if [[ -n "$POD" ]]; then
      PHASE=$(kubectl get pod "$POD" -n "$NAMESPACE" -o jsonpath="{.status.phase}")
      READY=$(kubectl get pod "$POD" -n "$NAMESPACE" -o jsonpath="{.status.containerStatuses[*].ready}")
      echo "[wait_for_ready] Pod: $POD, Phase: $PHASE, Ready: $READY" >>"$LOGFILE"
      if [[ "$PHASE" == "Running" && "$READY" == *"true"* ]]; then
        status "$NAME_SUBSTR pod '$POD' is running and ready."
        echo "[wait_for_ready] $NAME_SUBSTR pod '$POD' is running and ready." >>"$LOGFILE"
        return 0
      fi
    fi
    sleep $INTERVAL
    ((ELAPSED+=INTERVAL))
  done
  err "Timed out waiting for pod with name containing '$NAME_SUBSTR' to be ready."
  echo "[wait_for_ready] Timed out waiting for pod with name containing '$NAME_SUBSTR' to be ready." >>"$LOGFILE"
  exit 1
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

# Register all default apps as Docker images
# Usage: register_default_apps
register_default_apps() {
  step_minor "Downloading default Docker app list..."
  curl -fsSL "$DEFAULT_DOCKER_APPS_URI" -o "$DOCKER_APPS_FILE" >>"$LOGFILE" 2>&1 || { err "Failed to download $DEFAULT_DOCKER_APPS_URI"; echo "[register_default_apps] Failed to download $DEFAULT_DOCKER_APPS_URI" >>"$LOGFILE"; exit 1; }
  step_done "Default Docker app list downloaded."
  step_minor "Registering all default apps as Docker images..."
  local failed=0
  while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ || -z "$line" || "$line" == *":jar:metadata"* ]] && continue
    key="${line%%=*}"
    uri="${line#*=}"
    type="${key%%.*}"
    name="${key#*.}"
    [[ "$uri" != docker:* ]] && continue
    REG_URL="$SCDF_SERVER_URL/apps/$type/$name"
    step_minor "Registering $type:$name -> $uri"
    echo "[register_default_apps] Registering $type:$name -> $uri ($REG_URL)" >>"$LOGFILE"
    REG_OUTPUT=$(curl -s -w "\n%{http_code}" -X POST "$REG_URL" -d "uri=$uri" 2>&1)
    HTTP_CODE=$(echo "$REG_OUTPUT" | tail -n1)
    BODY=$(echo "$REG_OUTPUT" | sed '$d')
    echo "[register_default_apps] Response: HTTP $HTTP_CODE, Body: $BODY" >>"$LOGFILE"
    echo "$type.$name=$uri -> $HTTP_CODE" >> "$LOGFILE"
    if [[ "$HTTP_CODE" != "201" ]]; then
      err "Failed to register $type:$name ($HTTP_CODE)."
      echo "[register_default_apps] Failed to register $type:$name ($HTTP_CODE). Body: $BODY" >>"$LOGFILE"
      echo -e "\033[1;31m[REGISTRATION ERROR] $type:$name ($HTTP_CODE): $BODY\033[0m" >&2
      failed=1
    fi
  done < "$DOCKER_APPS_FILE"
  step_done "Default Docker applications registration complete."
  echo "[register_default_apps] Registration process complete." >>"$LOGFILE"
  if [ $failed -eq 1 ]; then
    echo -e "\033[1;31mSome or all app registrations failed. See $LOGFILE for details.\033[0m" >&2
  fi
}

# Print management URLs
print_management_urls() {
  echo "--- Management URLs and Credentials ---"
  echo "SCDF Dashboard:    http://127.0.0.1:30080/dashboard"
  echo "RabbitMQ MGMT UI:  http://127.0.0.1:$RABBITMQ_NODEPORT_MANAGER ($RABBITMQ_USER/$RABBITMQ_PASSWORD)"
  echo "RabbitMQ AMQP:     localhost:$RABBITMQ_NODEPORT_AMQP ($RABBITMQ_USER/$RABBITMQ_PASSWORD)"
  echo "PostgreSQL:        localhost:$POSTGRES_NODEPORT ($POSTGRES_USER/$POSTGRES_PASSWORD, DB: $POSTGRES_DB)"
  echo "Ollama (nomic):    http://ollama-nomic.$NAMESPACE.svc.cluster.local:11434 (internal K8s)"
  echo "Ollama (nomic, local): http://127.0.0.1:11434 (if port-forwarded)"
  echo "Namespace:         $NAMESPACE"
  echo "To stop services, delete the namespace or uninstall the Helm releases."
  echo "---"
  echo "Nomic Model Info:  Model 'nomic-embed-text' is available via the Ollama API."
  echo "  Example embedding endpoint: POST /api/embeddings to http://ollama-nomic.$NAMESPACE.svc.cluster.local:11434"
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
  kubectl create namespace "$NAMESPACE" 2>/dev/null || true
  step_done "Namespace created."
  step_major "Deploying Ollama (nomic-embed-text model) as a Kubernetes service..."
  kubectl apply -f ollama-nomic.yaml -n "$NAMESPACE" >>"$LOGFILE" 2>&1
  wait_for_ready ollama-nomic
  step_done "Model-only install complete."
  exit 0
fi

# --- Full install: cleanup and all services ---
step_major "Cleaning up previous SCDF installs..."
helm uninstall scdf --namespace "$NAMESPACE" >>"$LOGFILE" 2>&1 || true
helm uninstall scdf-rabbitmq --namespace "$NAMESPACE" >>"$LOGFILE" 2>&1 || true
step_done "Previous SCDF installs cleaned up."

# Wait for deployments to be deleted
step_major "Waiting for SCDF and RabbitMQ deployments to be deleted..."
for dep in scdf scdf-rabbitmq; do
  for i in {1..30}; do
    if ! kubectl get deployment "$dep" -n "$NAMESPACE" &>/dev/null; then
      status "$dep deployment deleted."
      break
    fi
    echo "[INFO] Waiting for $dep deployment to be deleted... ($i/30)" >>"$LOGFILE"
    sleep 2
  done
done
step_done "SCDF and RabbitMQ deployments deleted."

step_major "Deleting namespace..."
kubectl delete namespace "$NAMESPACE" >>"$LOGFILE" 2>&1 || true
step_done "Namespace deleted."

for i in {1..60}; do
  if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    status "Namespace $NAMESPACE deleted."
    break
  fi
  echo "[INFO] Waiting for namespace $NAMESPACE to be deleted... ($i/60)" >>"$LOGFILE"
  sleep 2
done
step_done "Namespace deleted."

step_major "Creating namespace..."
kubectl create namespace "$NAMESPACE" >>"$LOGFILE" 2>&1 || true
step_done "Namespace created."

# --- Ollama with nomic-embed-text (K8s) ---
step_major "Deploying Ollama (nomic-embed-text model) as a Kubernetes service..."
kubectl apply -f ollama-nomic.yaml -n "$NAMESPACE" >>"$LOGFILE" 2>&1
wait_for_ready ollama-nomic
step_done "Ollama (nomic-embed-text model) deployed."

echo "[INFO] Running full install steps..." >>"$LOGFILE"

# --- Helm Repo and RabbitMQ ---
step_major "Adding/updating Helm repo..."
helm repo add bitnami https://charts.bitnami.com/bitnami >>"$LOGFILE" 2>&1 || true
helm repo update >>"$LOGFILE" 2>&1
step_done "Helm repo added/updated."

step_major "Installing RabbitMQ..."
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
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance="$RABBITMQ_RELEASE_NAME" -n "$NAMESPACE" --timeout=300s >>"$LOGFILE" 2>&1 || true
step_done "RabbitMQ installed."

# --- PostgreSQL with pgvector ---
step_major "Installing PostgreSQL with pgvector extension via Helm..."

# Create ConfigMap for pgvector init script (idempotent)
kubectl create configmap pgvector-init-script \
  --from-literal=init.sql="CREATE EXTENSION IF NOT EXISTS vector;" \
  -n "$NAMESPACE" 2>>"$LOGFILE" 1>>"$LOGFILE" || kubectl create configmap pgvector-init-script \
  --from-literal=init.sql="CREATE EXTENSION IF NOT EXISTS vector;" \
  -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - 2>>"$LOGFILE" 1>>"$LOGFILE"

helm repo add bitnami https://charts.bitnami.com/bitnami >>"$LOGFILE" 2>&1
helm repo update >>"$LOGFILE" 2>&1

helm upgrade --install "$POSTGRES_RELEASE_NAME" bitnami/postgresql \
  --namespace "$NAMESPACE" \
  --set postgresqlUsername="$POSTGRES_USER" \
  --set postgresqlPassword="$POSTGRES_PASSWORD" \
  --set postgresqlDatabase="$POSTGRES_DB" \
  --set primary.initdb.scriptsConfigMap=pgvector-init-script \
  --set image.tag="$POSTGRES_IMAGE_TAG" \
  --set service.type=NodePort \
  --set service.nodePorts.postgresql="$POSTGRES_NODEPORT" \
  >>"$LOGFILE" 2>&1
wait_for_ready postgresql
step_done "PostgreSQL with pgvector installed."

# --- SCDF Install ---
step_major "Installing Spring Cloud Data Flow (includes Skipper & MariaDB)..."
helm upgrade --install scdf oci://registry-1.docker.io/bitnamicharts/spring-cloud-dataflow \
  --namespace "$NAMESPACE" \
  --set rabbitmq.enabled=false \
  --set rabbitmq.host=scdf-rabbitmq \
  --set rabbitmq.username=user \
  --set rabbitmq.password=bitnami \
  --set server.service.type=NodePort \
  --set server.service.nodePort=30080 >>"$LOGFILE" 2>&1 || true
step_done "Spring Cloud Data Flow installed."

# --- Wait for SCDF/Skipper Pods ---
step_major "Waiting for SCDF server and Skipper pods to be ready..."
wait_for_ready scdf-spring-cloud-dataflow-server 300
wait_for_ready scdf-spring-cloud-dataflow-skipper 300
step_done "SCDF server and Skipper pods are ready."

# --- SCDF Shell ---
download_shell_jar

# --- Register Default Apps as Docker Images ---
register_default_apps >>"$LOGFILE" 2>&1

# --- Delete all streams ---
step_major "Destroying all streams using SCDF shell built-in command..."
echo "stream all destroy --force" | java -jar "$SHELL_JAR" --dataflow.uri="$SCDF_SERVER_URL" >>"$LOGFILE" 2>&1
step_done "All streams destroyed."

# --- Unregister all applications ---
step_major "Unregistering all applications using SCDF shell built-in command..."
echo "app all unregister" | java -jar "$SHELL_JAR" --dataflow.uri="$SCDF_SERVER_URL" >>"$LOGFILE" 2>&1
step_done "All applications unregistered."

# --- Register Default Apps as Docker Images ---
register_default_apps >>"$LOGFILE" 2>&1

# --- Verification ---
step_major "Querying registered apps for verification..."
curl -s "$SCDF_SERVER_URL/apps" > registered_apps.json
cat registered_apps.json >>"$LOGFILE"
step_done "Registered apps have been logged to 'registered_apps.json' and '$LOGFILE'."

# --- Print Management URLs ---
print_management_urls
