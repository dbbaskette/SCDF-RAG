#!/bin/bash

# minio_install_scdf.sh
# Purpose: Deploy a MinIO S3-compatible server in the existing 'scdf' namespace on a Kubernetes cluster,
#          using a dynamically provisioned PersistentVolumeClaim (PVC) via the local-path StorageClass (Docker Desktop compatible).
#
# Requirements:
#   - 'scdf' namespace must already exist in the cluster.
#   - 'kubectl' and 'helm' must be installed and configured to access your cluster.
#   - Docker Desktop for Mac/Windows or any cluster with a dynamic local-path provisioner.
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

step "[0/4] Checking for existing MinIO install and cleaning up if found..."
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

step "[1/4] Creating PersistentVolumeClaim for MinIO data storage (Docker Desktop local-path)..."
cat <<EOF | kubectl apply -n $NAMESPACE -f - >>"$LOGFILE" 2>&1
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $MINIO_PVC
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: local-path
EOF

step "[2/4] Adding Bitnami Helm repo and updating..."
helm repo add bitnami https://charts.bitnami.com/bitnami >>"$LOGFILE" 2>&1
helm repo update >>"$LOGFILE" 2>&1

step "[3/4] Deploying MinIO via Helm in namespace '$NAMESPACE'..."
helm upgrade --install $MINIO_RELEASE bitnami/minio \
  --namespace $NAMESPACE \
  --set persistence.existingClaim=$MINIO_PVC \
  --set persistence.mountPath=/bitnami/minio/data \
  --set accessKey.password="minioadmin" \
  --set secretKey.password="minioadmin" \
  --set defaultBuckets="mybucket" >>"$LOGFILE" 2>&1

step "Waiting for MinIO pod to be ready before port-forwarding..."
wait_for_ready "minio"

step "[4/4] Setting up port-forward to MinIO service on localhost:9000..."
# Start port-forward in the background and log output
kubectl port-forward svc/$MINIO_RELEASE -n $NAMESPACE 9000:9000 >>"$LOGFILE" 2>&1 &
PORT_FORWARD_PID=$!
echo $PORT_FORWARD_PID > "$LOGDIR/minio_port_forward.pid"
sleep 2
if ps -p $PORT_FORWARD_PID > /dev/null; then
  step "Port-forward started (PID: $PORT_FORWARD_PID). MinIO UI available at http://localhost:9000"
else
  err "Port-forward failed to start. Check $LOGFILE for details."
fi
