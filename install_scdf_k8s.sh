#!/bin/bash

# install_scdf_k8s.sh
# Streamlined, commented installer for Spring Cloud Data Flow on Kubernetes with RabbitMQ and MariaDB.
# - Exposes management interfaces via NodePort
# - Automatically registers default RabbitMQ apps via REST API
# - Logs all operations to install_scdf_k8s.log

set -e
LOGFILE="install_scdf_k8s.log"
NAMESPACE="scdf"
DEFAULT_APPS_URI="https://dataflow.spring.io/rabbitmq-maven-latest"
APPS_FILE="apps.properties"
SCDF_SERVER_URL="http://localhost:30080"

# Utility: print a step message
step() { echo -e "\033[1;32m$1\033[0m"; }
# Utility: print an error message
err() { echo -e "\033[1;31m$1\033[0m"; }

# Clean up any previous installs
step "[0/6] Cleaning up previous SCDF installs..."
helm uninstall scdf --namespace "$NAMESPACE" >> "$LOGFILE" 2>&1 || true
helm uninstall scdf-rabbitmq --namespace "$NAMESPACE" >> "$LOGFILE" 2>&1 || true
kubectl delete namespace "$NAMESPACE" >> "$LOGFILE" 2>&1 || true
kubectl wait --for=delete namespace/$NAMESPACE --timeout=120s >> "$LOGFILE" 2>&1 || true

# Create namespace
kubectl create namespace "$NAMESPACE" >> "$LOGFILE" 2>&1 || true

# Add/update Helm repo
step "[1/6] Adding/updating Helm repo..."
helm repo add bitnami https://charts.bitnami.com/bitnami >> "$LOGFILE" 2>&1 || true
helm repo update >> "$LOGFILE" 2>&1

# Install RabbitMQ
step "[2/6] Installing RabbitMQ..."
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

# Install SCDF (MariaDB enabled by default)
step "[3/6] Installing Spring Cloud Data Flow (includes Skipper & MariaDB)..."
helm upgrade --install scdf oci://registry-1.docker.io/bitnamicharts/spring-cloud-dataflow \
  --namespace "$NAMESPACE" \
  --set rabbitmq.enabled=false \
  --set rabbitmq.host=scdf-rabbitmq \
  --set rabbitmq.username=user \
  --set rabbitmq.password=bitnami \
  --set server.service.type=NodePort \
  --set server.service.nodePort=30080 >> "$LOGFILE" 2>&1

# Wait for SCDF server and Skipper pods to be ready
step "[4/6] Waiting for SCDF server and Skipper pods to be ready..."
wait_for_ready() {
  local NAME_SUBSTR=$1
  local TIMEOUT=${2:-300}
  local ELAPSED=0
  local INTERVAL=5
  while (( ELAPSED < TIMEOUT )); do
    POD=$(kubectl get pods -n "$NAMESPACE" --no-headers | grep "$NAME_SUBSTR" | awk '{print $1}')
    if [[ -n "$POD" ]]; then
      PHASE=$(kubectl get pod "$POD" -n "$NAMESPACE" -o jsonpath="{.status.phase}")
      READY=$(kubectl get pod "$POD" -n "$NAMESPACE" -o jsonpath="{.status.containerStatuses[*].ready}")
      if [[ "$PHASE" == "Running" && "$READY" == *"true"* ]]; then
        step "$NAME_SUBSTR pod '$POD' is running and ready."
        return 0
      fi
    fi
    sleep $INTERVAL
    ((ELAPSED+=INTERVAL))
  done
  err "Timed out waiting for pod with name containing '$NAME_SUBSTR' to be ready."
  exit 1
}
wait_for_ready scdf-spring-cloud-dataflow-server 300
wait_for_ready scdf-spring-cloud-dataflow-skipper 300

# Print management URLs
cat <<EOF
\n--- Management URLs and Credentials ---
SCDF Dashboard:    http://127.0.0.1:30080/dashboard
RabbitMQ MGMT UI:  http://127.0.0.1:31672 (user/bitnami)
RabbitMQ AMQP:     localhost:30672 (user/bitnami)
Namespace:         $NAMESPACE
To stop services, delete the namespace or uninstall the Helm releases.
EOF

step "[5/6] Registering default RabbitMQ apps in SCDF..."
# Download and register default apps
curl -fsSL "$DEFAULT_APPS_URI" -o "$APPS_FILE" || { err "Failed to download $DEFAULT_APPS_URI"; exit 1; }
while IFS= read -r line; do
  # Skip comments, blank lines, and metadata lines
  [[ "$line" =~ ^#.*$ || -z "$line" || "$line" == *":jar:metadata"* ]] && continue

  # Split on the first '='
  key="${line%%=*}"
  uri="${line#*=}"

  # Split key into type and name on the first '.'
  type="${key%%.*}"
  name="${key#*.}"

  # Only register if uri starts with maven://
  [[ "$uri" != maven://* ]] && continue

  REG_URL="$SCDF_SERVER_URL/apps/$type/$name"
  step "Registering $type:$name -> $uri"
  REG_OUTPUT=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$REG_URL" -d "uri=$uri")
  echo "$type.$name=$uri -> $REG_OUTPUT" >> "$LOGFILE"
  if [ "$REG_OUTPUT" != "201" ]; then
    err "Failed to register $type:$name ($REG_OUTPUT). See $LOGFILE for details."
  fi
done < "$APPS_FILE"
step "Default applications registration complete."

step "[6/6] Spring Cloud Data Flow installation complete."
