#!/bin/bash

# ------------------------------------------------------------------------------
# MinIO Installation Script for SCDF on Kubernetes
# ------------------------------------------------------------------------------
# This script installs MinIO with a static PersistentVolume and PersistentVolumeClaim
# using hostPath storage mapped to a dynamically determined sourceDocs directory.
# It ensures any previous MinIO PVC/PV are deleted, applies the YAML, and installs
# MinIO via Helm using the pre-created PVC. No storageClass is set in the Helm command
# to avoid dynamic provisioning conflicts.
#
# Usage:
#   chmod +x minio_install_scdf.sh
#   ./minio_install_scdf.sh
#
# Requirements:
#   - 'scdf' namespace must exist
#   - kubectl, helm, and access to a running Kubernetes cluster
#   - Bitnami MinIO Helm chart repo
#   - Directory for sourceDocs exists on the host (determined by $MINIO_SOURCE_DIR or defaults to ./sourceDocs)
#
# Steps performed:
#   1. Cleanup any existing MinIO PVC/PV
#   2. Apply static PV/PVC YAML
#   3. Install/upgrade MinIO via Helm (using the PVC)
#   4. Wait for MinIO pod to be ready
#   5. Print MinIO URLs
# ------------------------------------------------------------------------------

# minio_install_scdf.sh
# Purpose: Deploy a MinIO S3-compatible server in the existing 'scdf' namespace on a Kubernetes cluster,
#          using a static PersistentVolume and PersistentVolumeClaim, mapping the hostPath to a dynamically determined sourceDocs directory.
#
# Requirements:
#   - 'scdf' namespace must already exist in the cluster.
#   - 'kubectl' and 'helm' must be installed and configured to access your cluster.
#   - Docker Desktop for Mac/Windows or any cluster with a static hostpath provisioner.
#
# Usage:
#   chmod +x minio_install_scdf.sh
#   ./minio_install_scdf.sh

LOGDIR="$(pwd)/logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/minio_install_scdf.log"
NAMESPACE="scdf"
MINIO_RELEASE="minio"
MINIO_PVC="minio-pvc"

# --- Utility Functions ---
step() {
  echo -e "\033[1;32m$1\033[0m" >&2
  echo "[STEP] $1" >>"$LOGFILE"
}
err() { echo -e "\033[1;31m$1\033[0m" >&2; }

# Wait for a Kubernetes pod to be ready (from install_scdf_k8s.sh) with better diagnostics
wait_for_ready() {
  local NAME_SUBSTR=$1
  local TIMEOUT=${2:-300}
  local ELAPSED=0
  local INTERVAL=5
  local WARNED=0
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
      elif [[ "$PHASE" == "Pending" && $WARNED -eq 0 && $ELAPSED -ge 60 ]]; then
        step "Warning: Pod '$POD' is still Pending after $ELAPSED seconds. Check PVC status or node resources."
        WARNED=1
      fi
    fi
    sleep $INTERVAL
    ((ELAPSED+=INTERVAL))
  done
  err "Timed out waiting for pod with name containing '$NAME_SUBSTR' to be ready."
  echo "[wait_for_ready] Timed out waiting for pod with name containing '$NAME_SUBSTR' to be ready." >>"$LOGFILE"
  if [[ -n "$POD" ]]; then
    step "Dumping describe and events for pod $POD to log file for diagnostics."
    kubectl describe pod "$POD" -n "$NAMESPACE" >>"$LOGFILE" 2>&1
    kubectl get events -n "$NAMESPACE" --sort-by=.metadata.creationTimestamp >>"$LOGFILE" 2>&1
  fi
  exit 1
}

step "[0/5] Checking for existing MinIO install and cleaning up if found..."
# Delete port-forward if running
if [[ -f "$LOGDIR/minio_port_forward.pid" ]]; then
  OLD_PID=$(cat "$LOGDIR/minio_port_forward.pid")
  if ps -p $OLD_PID > /dev/null; then
    step "Killing existing MinIO port-forward (PID: $OLD_PID)"
    kill $OLD_PID >>"$LOGFILE" 2>&1
  fi
  rm -f "$LOGDIR/minio_port_forward.pid"
fi
# Delete existing Helm release if present
if helm status $MINIO_RELEASE -n $NAMESPACE >>"$LOGFILE" 2>&1; then
  step "Deleting existing MinIO Helm release..."
  helm uninstall $MINIO_RELEASE -n $NAMESPACE >>"$LOGFILE" 2>&1
fi
# Delete existing PVC if present
if kubectl get pvc $MINIO_PVC -n $NAMESPACE >>"$LOGFILE" 2>&1; then
  step "Deleting existing PersistentVolumeClaim..."
  kubectl delete pvc $MINIO_PVC -n $NAMESPACE >>"$LOGFILE" 2>&1
fi

# Determine source docs directory dynamically
if [[ -n "$MINIO_SOURCE_DIR" ]]; then
  SOURCE_DOCS_DIR="$MINIO_SOURCE_DIR"
else
  SOURCE_DOCS_DIR="$(pwd)/sourceDocs"
fi

# Ensure the source docs directory exists
mkdir -p "$SOURCE_DOCS_DIR"

# Ensure the resources directory exists
mkdir -p resources

# Write the PV/PVC YAML with the chosen hostPath into the resources directory
cat > resources/minio-pv-pvc.yaml <<EOF
# ------------------------------------------------------------------------------
# MinIO PersistentVolume and PersistentVolumeClaim for Static hostPath Storage
# ------------------------------------------------------------------------------
# This YAML is auto-generated by minio_install_scdf.sh.
# The PV uses hostPath mapped to: $SOURCE_DOCS_DIR
# ------------------------------------------------------------------------------
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
#  storageClassName: hostpath (removed for static binding)
EOF

step "[1/5] Cleaning up old MinIO PVC and PV (if they exist)..."
kubectl delete pvc minio-pvc -n $NAMESPACE --ignore-not-found >>"$LOGFILE" 2>&1
kubectl delete pv minio-pv --ignore-not-found >>"$LOGFILE" 2>&1

step "Verifying PVCs and PVs are deleted..."
kubectl get pvc -n $NAMESPACE >>"$LOGFILE" 2>&1
kubectl get pv >>"$LOGFILE" 2>&1

step "Applying MinIO PersistentVolume and PersistentVolumeClaim YAML..."
kubectl apply -f resources/minio-pv-pvc.yaml >>"$LOGFILE" 2>&1

step "Checking MinIO PVC status after creation..."
kubectl describe pvc minio-pvc -n $NAMESPACE >>"$LOGFILE" 2>&1

step "[2/5] Adding Bitnami Helm repo and updating..."
helm repo add bitnami https://charts.bitnami.com/bitnami >>"$LOGFILE" 2>&1
helm repo update >>"$LOGFILE" 2>&1

step "[3/5] Installing MinIO via Helm (using static hostPath PV)..."
MINIO_API_PORT=30900
MINIO_CONSOLE_PORT=30901
helm upgrade --install $MINIO_RELEASE bitnami/minio \
  --namespace $NAMESPACE \
  --set persistence.existingClaim=$MINIO_PVC \
  --set mode=standalone \
  --set resources.requests.memory=512Mi \
  --set resources.requests.cpu=250m \
  --set service.type=NodePort \
  --set service.nodePorts.api=$MINIO_API_PORT \
  --set service.nodePorts.console=$MINIO_CONSOLE_PORT >>"$LOGFILE" 2>&1

step "[4/5] Waiting for MinIO pod to be ready..."
wait_for_ready minio 300

step "[5/5] MinIO is available on the following URLs:"
echo "  S3 API:      http://localhost:$MINIO_API_PORT"
echo "  MinIO Console: http://localhost:$MINIO_CONSOLE_PORT"
echo
# Display Bitnami MinIO credentials
MINIO_USER=$(kubectl get secret --namespace $NAMESPACE minio -o jsonpath="{.data.root-user}" | base64 --decode)
MINIO_PASS=$(kubectl get secret --namespace $NAMESPACE minio -o jsonpath="{.data.root-password}" | base64 --decode)
echo "MinIO Credentials (Bitnami Helm chart default):"
echo "  Access Key: $MINIO_USER"
echo "  Secret Key: $MINIO_PASS"
echo
