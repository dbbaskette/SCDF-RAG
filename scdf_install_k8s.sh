#!/bin/bash
# scdf_install_k8s.sh: Installs SCDF on Kubernetes
# Usage: ./scdf_install_k8s.sh > logs/scdf_install_k8s.log 2>&1

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

# --- Utility Functions ---
# Print a green step message to terminal and log file
step() {
  echo -e "\033[1;32m$1\033[0m" >&2
  echo "[STEP] $1" >>"$LOGFILE"
}
# Print a red error message to terminal
err() { echo -e "\033[1;31m$1\033[0m" >&2; }

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
        step "$NAME_SUBSTR pod '$POD' is running and ready."
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
    step "[5/6] Downloading SCDF Shell JAR..."
    curl -fsSL -o "$SHELL_JAR" "$SHELL_URL" >>"$LOGFILE" 2>&1 || { err "Failed to download SCDF Shell JAR"; exit 1; }
  else
    step "[5/6] SCDF Shell JAR already present."
  fi
}

# Register all default apps as Docker images
# Usage: register_default_apps
register_default_apps() {
  step "[6/6] Downloading default Docker app list..."
  curl -fsSL "$DEFAULT_DOCKER_APPS_URI" -o "$DOCKER_APPS_FILE" >>"$LOGFILE" 2>&1 || { err "Failed to download $DEFAULT_DOCKER_APPS_URI"; echo "[register_default_apps] Failed to download $DEFAULT_DOCKER_APPS_URI" >>"$LOGFILE"; exit 1; }
  step "[6/6] Registering all default apps as Docker images..."
  local failed=0
  while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ || -z "$line" || "$line" == *":jar:metadata"* ]] && continue
    key="${line%%=*}"
    uri="${line#*=}"
    type="${key%%.*}"
    name="${key#*.}"
    [[ "$uri" != docker:* ]] && continue
    REG_URL="$SCDF_SERVER_URL/apps/$type/$name"
    step "Registering $type:$name -> $uri"
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
  step "Default Docker applications registration complete."
  echo "[register_default_apps] Registration process complete." >>"$LOGFILE"
  if [ $failed -eq 1 ]; then
    echo -e "\033[1;31mSome or all app registrations failed. See $LOGFILE for details.\033[0m" >&2
  fi
}

# Print management URLs
print_management_urls() {
  cat <<EOF
--- Management URLs and Credentials ---
SCDF Dashboard:    http://127.0.0.1:30080/dashboard
RabbitMQ MGMT UI:  http://127.0.0.1:31672 (user/bitnami)
RabbitMQ AMQP:     localhost:30672 (user/bitnami)
Namespace:         $NAMESPACE
To stop services, delete the namespace or uninstall the Helm releases.
EOF
}

# --- Constants and Flags ---
SKIP_INSTALL=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-install)
      SKIP_INSTALL=1
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# --- Main Execution Flow ---
if [[ $SKIP_INSTALL -eq 0 ]]; then
  # --- Cleanup and Setup Namespace ---
  step "[0/6] Cleaning up previous SCDF installs..."
  helm uninstall scdf --namespace "$NAMESPACE" >>"$LOGFILE" 2>&1 || true
  helm uninstall scdf-rabbitmq --namespace "$NAMESPACE" >>"$LOGFILE" 2>&1 || true

  # Wait for deployments to be deleted
  step "Waiting for SCDF and RabbitMQ deployments to be deleted..."
  for dep in scdf scdf-rabbitmq; do
    for i in {1..30}; do
      if ! kubectl get deployment "$dep" -n "$NAMESPACE" &>/dev/null; then
        step "$dep deployment deleted."
        break
      fi
      step "Waiting for $dep deployment to be deleted... ($i/30)"
      sleep 2
    done
  done

  kubectl delete namespace "$NAMESPACE" >>"$LOGFILE" 2>&1 || true
  for i in {1..60}; do
    if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
      step "Namespace $NAMESPACE deleted."
      break
    fi
    step "Waiting for namespace $NAMESPACE to be deleted... ($i/60)"
    sleep 2
  done

  kubectl create namespace "$NAMESPACE" >>"$LOGFILE" 2>&1 || true

  echo "[INFO] Running full install steps..."
  # --- Helm Repo and RabbitMQ ---
  step "[1/6] Adding/updating Helm repo..."
  helm repo add bitnami https://charts.bitnami.com/bitnami >>"$LOGFILE" 2>&1 || true
  helm repo update >>"$LOGFILE" 2>&1

  step "[2/6] Installing RabbitMQ..."
  helm upgrade --install scdf-rabbitmq bitnami/rabbitmq \
    --namespace "$NAMESPACE" \
    --set auth.username=user \
    --set auth.password=bitnami \
    --set auth.erlangCookie=secretcookie \
    --set persistence.enabled=false \
    --set service.type=NodePort \
    --set service.nodePorts.amqp=30672 \
    --set service.nodePorts.manager=31672 >>"$LOGFILE" 2>&1 || true
  kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=scdf-rabbitmq -n "$NAMESPACE" --timeout=300s >>"$LOGFILE" 2>&1 || true

  # --- SCDF Install ---
  step "[3/6] Installing Spring Cloud Data Flow (includes Skipper & MariaDB)..."
  helm upgrade --install scdf oci://registry-1.docker.io/bitnamicharts/spring-cloud-dataflow \
    --namespace "$NAMESPACE" \
    --set rabbitmq.enabled=false \
    --set rabbitmq.host=scdf-rabbitmq \
    --set rabbitmq.username=user \
    --set rabbitmq.password=bitnami \
    --set server.service.type=NodePort \
    --set server.service.nodePort=30080 >>"$LOGFILE" 2>&1 || true

  # --- Wait for SCDF/Skipper Pods ---
  step "Waiting for SCDF server and Skipper pods to be ready..."
  wait_for_ready scdf-spring-cloud-dataflow-server 300
  wait_for_ready scdf-spring-cloud-dataflow-skipper 300
  step "SCDF server and Skipper pods are ready. Proceeding to app registration."

  # --- SCDF Shell ---
  download_shell_jar

  # --- Register Default Apps as Docker Images ---
  register_default_apps >>"$LOGFILE" 2>&1
else
  echo "[INFO] Skipping install steps, starting with app/app registration reset."
  download_shell_jar >>"$LOGFILE" 2>&1

  # --- Delete all streams ---
  step "Destroying all streams using SCDF shell built-in command..."
  echo "stream all destroy --force" | java -jar "$SHELL_JAR" --dataflow.uri="$SCDF_SERVER_URL" >>"$LOGFILE" 2>&1

  # --- Unregister all applications ---
  step "Unregistering all applications using SCDF shell built-in command..."
  echo "app all unregister" | java -jar "$SHELL_JAR" --dataflow.uri="$SCDF_SERVER_URL" >>"$LOGFILE" 2>&1

  # --- Register Default Apps as Docker Images ---
  register_default_apps >>"$LOGFILE" 2>&1
fi

# --- Verification ---
step "Querying registered apps for verification..."
curl -s "$SCDF_SERVER_URL/apps" > registered_apps.json
cat registered_apps.json >>"$LOGFILE"
step "Registered apps have been logged to 'registered_apps.json' and '$LOGFILE'."

# --- Print Management URLs ---
print_management_urls

step "Spring Cloud Data Flow installation complete."
