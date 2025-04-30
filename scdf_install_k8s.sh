#!/bin/bash
# scdf_install_k8s.sh: Installs SCDF on Kubernetes
# Usage: ./scdf_install_k8s.sh > logs/scdf_install_k8s.log 2>&1

# Source environment variables from scdf_env.properties
if [ -f "$(dirname "$0")/scdf_env.properties" ]; then
  set -a
  . "$(dirname "$0")/scdf_env.properties"
  set +a
fi

# --- Generate SCDF values file from environment variables (external PostgreSQL, chart-managed RabbitMQ) ---
cat > resources/scdf-values.yaml <<EOF
skipper:
  env:
    - name: MAVEN_LOCAL_REPO
      value: /dataflow-maven-repo
    - name: JAVA_OPTS
      value: "-Duser.home=/dataflow-maven-repo -Dmaven.repo.local=/dataflow-maven-repo"
  extraVolumeMounts:
    - name: maven-repo
      mountPath: /dataflow-maven-repo
  extraVolumes:
    - name: maven-repo
      emptyDir: {}
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
networkPolicy:
  enabled: false
EOF

# --- Step Counter (must be set before any function uses it) ---
# Set STEP_TOTAL to the number of step_major calls in this script (do NOT include step 0)
STEP_TOTAL=$(grep -c '^[[:space:]]*step_major ' "$0")
STEP_COUNTER=0

# --- Logging Setup ---
LOGDIR="$(pwd)/logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/scdf_install_k8s.log"

# --- Namespace Setup ---
NAMESPACE="${NAMESPACE:-scdf}"
POSTGRES_RELEASE_NAME="${POSTGRES_RELEASE_NAME:-scdf-postgresql}"
RABBITMQ_RELEASE_NAME="${RABBITMQ_RELEASE_NAME:-scdf-rabbitmq}"

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
  echo -e "\033[1;36m[$STEP_COUNTER/$STEP_TOTAL] COMPLETE: $STEP_LAST\033[0m"
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

# --- Namespace Utility ---
ensure_namespace() {
  if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "[INFO] Creating namespace $NAMESPACE..." | tee -a "$LOGFILE"
    kubectl create namespace "$NAMESPACE" >>"$LOGFILE" 2>&1
  else
    echo "[INFO] Namespace $NAMESPACE already exists, skipping creation." >>"$LOGFILE"
  fi
}

# --- Cleanup Previous Install ---
cleanup_previous_install() {
  step_major "Cleaning up previous SCDF install (Helm releases, PVCs, PVs, and namespace)"
  # Delete Helm releases
  helm uninstall "$POSTGRES_RELEASE_NAME" -n "$NAMESPACE" >>"$LOGFILE" 2>&1 || true
  helm uninstall "$MINIO_RELEASE" -n "$NAMESPACE" >>"$LOGFILE" 2>&1 || true
  helm uninstall scdf -n "$NAMESPACE" >>"$LOGFILE" 2>&1 || true

  # Delete PVCs in the namespace
  step_minor "Deleting all PersistentVolumeClaims in namespace $NAMESPACE..."
  kubectl get pvc -n "$NAMESPACE" --no-headers | awk '{print $1}' | xargs -r -n1 kubectl delete pvc -n "$NAMESPACE" >>"$LOGFILE" 2>&1

  # Delete PVs that are Released or Bound to deleted PVCs (including MinIO PV)
  step_minor "Deleting orphaned PersistentVolumes (including MinIO PV if present)..."
  for pv in $(kubectl get pv --no-headers | awk '{print $1}'); do
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

# --- Install PostgreSQL as a standalone function ---
install_postgresql() {
  ensure_namespace
  if is_release_installed "$POSTGRES_RELEASE_NAME" "$NAMESPACE"; then
    step_minor "PostgreSQL already installed. Skipping."
    return 0
  fi
  step_major "Install PostgreSQL"
  helm upgrade --install "$POSTGRES_RELEASE_NAME" bitnami/postgresql \
    --namespace "$NAMESPACE" \
    --set auth.username="$POSTGRES_USER" \
    --set auth.password="$POSTGRES_PASSWORD" \
    --set auth.database="$POSTGRES_DB" \
    --set image.tag="$POSTGRES_IMAGE_TAG" \
    --set service.type=NodePort \
    --set service.nodePort="$POSTGRES_NODEPORT" \
    --wait
  wait_for_ready postgresql 300
}

# --- SCDF Install ---
install_scdf() {
  ensure_namespace
  install_postgresql
  step_major "Installing Spring Cloud Data Flow (includes Skipper, chart-managed RabbitMQ), and waiting for pods to be ready..."
  : "${SCDF_SERVER_PORT:=$SCDF_SERVER_PORT}"
  SCDF_SERVER_URL="http://localhost:$SCDF_SERVER_PORT"
  export SCDF_SERVER_URL
  helm upgrade --install scdf oci://registry-1.docker.io/bitnamicharts/spring-cloud-dataflow \
    --namespace "$NAMESPACE" \
    --values resources/scdf-values.yaml \
    --set server.service.type=NodePort \
    --set server.service.nodePort="$SCDF_SERVER_PORT" >>"$LOGFILE" 2>&1
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
  echo "3) Install Spring Cloud Data Flow (includes Skipper, chart-managed RabbitMQ)"
  echo "4) Download SCDF Shell JAR"
  echo "5) Display the Management URLs"
  echo "q) Exit"
  echo -n "Select a step to run [1-5, q to quit]: "
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
        install_scdf
        ;;
      4)
        download_shell_jar
        ;;
      5)
        print_management_urls
        ;;
      q|Q)
        echo "Exiting."
        exit 0
        ;;
      *)
        echo "Invalid option. Please select 1-5 or q to quit."
        ;;
    esac
    echo
    echo "--- Step complete. Return to menu. ---"
  done
  exit 0
fi

# --- Full Install Flow ---
cleanup_previous_install
install_scdf
download_shell_jar
print_management_urls

exit 0
