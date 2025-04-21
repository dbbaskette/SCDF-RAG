#!/bin/bash

set -e

LOGFILE="install_scdf_k8s.log"
exec > >(tee "$LOGFILE") 2>&1

NAMESPACE=scdf

# Helper for log file output only
log() { echo "$1"; }
# Helper for minimal user-facing step output
step() { echo -e "\033[1;34m$1\033[0m" >&2; }
# Helper for user-facing errors
err() { echo -e "\033[1;31m$1\033[0m" >&2; }

# Kill any process using a given port
kill_port() {
  local PORT=$1
  PID=$(lsof -ti tcp:$PORT)
  if [[ -n "$PID" ]]; then
    step "Port $PORT in use, killing process $PID."
    kill $PID
    sleep 1
  fi
}

step "[0/7] Cleaning up previous Spring Cloud Data Flow installs..."
log "[0/7] Cleaning up previous Spring Cloud Data Flow installs..."
helm uninstall scdf --namespace "$NAMESPACE" >> "$LOGFILE" 2>&1 || true
helm uninstall scdf-rabbitmq --namespace "$NAMESPACE" >> "$LOGFILE" 2>&1 || true

if kubectl get namespace "$NAMESPACE" >> "$LOGFILE" 2>&1; then
  kubectl delete namespace "$NAMESPACE" >> "$LOGFILE" 2>&1
  log "Waiting for namespace '$NAMESPACE' to terminate..."
  while kubectl get namespace "$NAMESPACE" >> "$LOGFILE" 2>&1; do sleep 2; done
fi

kubectl create namespace "$NAMESPACE" >> "$LOGFILE" 2>&1

# --- Prerequisite Checks ---
command -v kubectl >> "$LOGFILE" 2>&1 || { err "kubectl is required but not installed. Aborting."; exit 1; }
command -v helm >> "$LOGFILE" 2>&1 || { err "helm is required but not installed. Aborting."; exit 1; }

if ! kubectl cluster-info >> "$LOGFILE" 2>&1; then
  err "No Kubernetes cluster detected. Please start your cluster in Docker Desktop and try again."
  exit 1
fi

CURRENT_CONTEXT=$(kubectl config current-context)
if [[ "$CURRENT_CONTEXT" != "docker-desktop" ]]; then
  step "[Warning] Current kubectl context is '$CURRENT_CONTEXT', not 'docker-desktop'. If this is your Docker Desktop cluster or another local cluster, you may proceed."
fi

step "[1/7] Adding Helm repos..."
helm repo add bitnami https://charts.bitnami.com/bitnami >> "$LOGFILE" 2>&1 || true
helm repo update >> "$LOGFILE" 2>&1

step "[2/7] Installing RabbitMQ..."
helm upgrade --install scdf-rabbitmq bitnami/rabbitmq \
  --namespace "$NAMESPACE" \
  --set auth.username=user \
  --set auth.password=bitnami \
  --set auth.erlangCookie=secretcookie \
  --set persistence.enabled=false \
  --set service.type=NodePort \
  --set service.nodePorts.amqp=30672 \
  --set service.nodePorts.manager=31672 >> "$LOGFILE" 2>&1

kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=scdf-rabbitmq -n "$NAMESPACE" --timeout=300s >> "$LOGFILE" 2>&1

step "[3/7] Installing Spring Cloud Data Flow (includes Skipper)..."
helm upgrade --install scdf oci://registry-1.docker.io/bitnamicharts/spring-cloud-dataflow \
  --namespace "$NAMESPACE" \
  --set rabbitmq.enabled=false \
  --set rabbitmq.host=scdf-rabbitmq \
  --set rabbitmq.username=user \
  --set rabbitmq.password=bitnami \
  --set server.service.type=NodePort \
  --set server.service.nodePort=30080 >> "$LOGFILE" 2>&1

# Wait for SCDF server pod to be running and ready (by name)
wait_for_ready() {
  local NAME_SUBSTR=$1
  local TIMEOUT=${2:-300} # seconds
  local ELAPSED=0
  local INTERVAL=5
  local POD=""
  while (( ELAPSED < TIMEOUT )); do
    POD=$(kubectl get pods -n "$NAMESPACE" --no-headers | grep "$NAME_SUBSTR" | awk '{print $1}')
    if [[ -n "$POD" ]]; then
      PHASE=$(kubectl get pod "$POD" -n "$NAMESPACE" -o jsonpath="{.status.phase}")
      READY=$(kubectl get pod "$POD" -n "$NAMESPACE" -o jsonpath="{.status.containerStatuses[*].ready}")
      echo "Polling pod: $POD | Phase: $PHASE | Ready: $READY (Expect: Phase=Running, Ready=true)" >> "$LOGFILE"
      if [[ "$PHASE" == "Running" && "$READY" == *"true"* ]]; then
        step "$NAME_SUBSTR pod '$POD' is running and ready."
        return 0
      fi
    else
      echo "Polling: No pod found with name containing '$NAME_SUBSTR' (Expect: Phase=Running, Ready=true)" >> "$LOGFILE"
    fi
    sleep $INTERVAL
    ((ELAPSED+=INTERVAL))
  done
  err "Timeout: Pod with name containing '$NAME_SUBSTR' did not become ready after $TIMEOUT seconds."
  kubectl get pods -n "$NAMESPACE" >> "$LOGFILE" 2>&1
  exit 1
}

step "[4/7] Waiting for Spring Cloud Data Flow server and Skipper pods to be ready..."
wait_for_ready scdf-spring-cloud-dataflow-server 300
wait_for_ready scdf-spring-cloud-dataflow-skipper 300

cat <<EOF

--- Management URLs and Credentials ---
SCDF Dashboard:    http://127.0.0.1:30080/dashboard
RabbitMQ MGMT UI:  http://127.0.0.1:31672 (user/bitnami)
RabbitMQ AMQP:     localhost:30672 (user/bitnami)
Namespace:         $NAMESPACE
To stop services, delete the namespace or uninstall the Helm releases.
EOF

step "\nSpring Cloud Data Flow is fully installed and all management interfaces are exposed as NodePorts!"

step "[5/7] Importing default Spring Cloud Data Flow applications..."

SCDF_SHELL_JAR="scdf-shell.jar"
SCDF_SERVER_URL="http://localhost:30080/api"
DEFAULT_APPS_URI="https://dataflow.spring.io/rabbitmq-maven-latest"

if [ ! -f "$SCDF_SHELL_JAR" ]; then
  step "Downloading Spring Cloud Data Flow Shell..."
  wget -qO "$SCDF_SHELL_JAR" https://repo.spring.io/release/org/springframework/cloud/spring-cloud-dataflow-shell/2.11.2/spring-cloud-dataflow-shell-2.11.2.jar
fi

# Wait for SCDF REST API to be available (use /about for health check)
step "Waiting for SCDF REST API to be available..."
for i in {1..30}; do
  if curl -sSf "http://localhost:30080/about" > /dev/null; then
    step "SCDF REST API is available."
    break
  fi
  sleep 4
done

# Import default applications
step "Importing default applications from $DEFAULT_APPS_URI ..."
IMPORT_OUTPUT=$(java -jar "$SCDF_SHELL_JAR" --dataflow.uri=$SCDF_SERVER_URL --shell.command="app import --uri $DEFAULT_APPS_URI" 2>&1)
echo "$IMPORT_OUTPUT" >> "$LOGFILE"
echo "$IMPORT_OUTPUT" | grep -i 'error\|fail' && err "ERROR: Failed to import default applications. See $LOGFILE for details."
step "Default applications import complete."

step "[6/7] Spring Cloud Data Flow installation complete."
