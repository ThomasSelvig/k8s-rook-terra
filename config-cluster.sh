#!/usr/bin/env bash

TMP_DIR="$(mktemp -d)"
ROOT_DIR="$(pwd)"
trap 'rm -rf "$TMPDIR"' EXIT

# Function to wait for a resource to be ready
wait_for_resource() {
  local RESOURCE_TYPE=$1
  local RESOURCE_LABEL=$2
  local NAMESPACE=$3
  local TIMEOUT=$4
  local STATUS=${5:-"Running"}

  echo "Waiting for $RESOURCE_TYPE with label $RESOURCE_LABEL in namespace $NAMESPACE to be $STATUS (timeout $TIMEOUT)..."
  kubectl wait --for=condition=Ready $RESOURCE_TYPE -l $RESOURCE_LABEL -n $NAMESPACE --timeout=$TIMEOUT

  # Additional verification
  local READY=$(kubectl get $RESOURCE_TYPE -l $RESOURCE_LABEL -n $NAMESPACE -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
  if [ "$READY" != "$STATUS" ] && [ "$READY" != "Running" ]; then
    echo "Resource is not ready yet. Current status: $READY. Waiting additional time..."
    sleep 10
  fi

  echo "$RESOURCE_TYPE with label $RESOURCE_LABEL is now ready!"
}

# ROOK
if [ ! -d "$TMP_DIR/rook" ]; then
  git clone --single-branch --branch v1.17.0 https://github.com/rook/rook.git "$TMP_DIR/rook" --depth 1
fi
cd "$TMP_DIR/rook/deploy/examples"
kubectl create -f crds.yaml -f common.yaml -f operator.yaml -n rook-ceph

echo "Waiting for rook-ceph-operator to be running..."
# Wait for operator pod to be ready
wait_for_resource "pod" "app=rook-ceph-operator" "rook-ceph" "5m"

# create a cluster
echo "Creating Ceph cluster..."
kubectl create -f cluster.yaml -n rook-ceph || true

# Wait for cluster to be created and OSD pods to be ready
echo "Waiting for Ceph OSDs to be ready (this may take several minutes)..."
wait_for_resource "pod" "app=rook-ceph-osd" "rook-ceph" "10m"

# Wait specifically for the manager pod as it's needed for dashboard
echo "Waiting for Ceph manager to be ready..."
wait_for_resource "pod" "app=rook-ceph-mgr" "rook-ceph" "5m"

# Create the toolbox for debugging
echo "Creating Ceph toolbox..."
kubectl create -f toolbox.yaml -n rook-ceph || true
wait_for_resource "pod" "app=rook-ceph-tools" "rook-ceph" "3m"

# Verify Ceph status using the toolbox
echo "Verifying Ceph cluster health..."
# Try up to 5 times to get a healthy cluster status
for i in {1..10}; do
  HEALTH_STATUS=$(kubectl -n rook-ceph exec -it $(kubectl -n rook-ceph get pod -l "app=rook-ceph-tools" -o jsonpath='{.items[0].metadata.name}') -- ceph status -f json | jq -r .health.status 2>/dev/null || echo "HEALTH_ERR")

  if [ "$HEALTH_STATUS" = "HEALTH_OK" ]; then
    echo "Ceph cluster is healthy!"
    break
  else
    echo "Ceph cluster health status: $HEALTH_STATUS. Attempt $i of 10. Waiting..."
    sleep 30
  fi

  if [ $i -eq 10 ] && [ "$HEALTH_STATUS" != "HEALTH_OK" ]; then
    echo "Warning: Ceph cluster is not reporting healthy status after multiple attempts."
    echo "Current status:"
    kubectl -n rook-ceph exec -it $(kubectl -n rook-ceph get pod -l "app=rook-ceph-tools" -o jsonpath='{.items[0].metadata.name}') -- ceph status
    echo "Continuing anyway, but you may need to troubleshoot later."
  fi
done


# create a pool for the filesystem
echo "Creating filesystem..."
kubectl create -f filesystem.yaml -n rook-ceph || true

# Wait for MDS pods to be ready
echo "Waiting for filesystem MDS pods to be ready..."
wait_for_resource "pod" "app=rook-ceph-mds" "rook-ceph" "5m"

# Create storage class
echo "Creating storage class..."
kubectl create -f csi/cephfs/storageclass.yaml -n rook-ceph || true

# Verify filesystem is ready
echo "Verifying filesystem status..."
FS_STATUS=$(kubectl -n rook-ceph exec -it $(kubectl -n rook-ceph get pod -l "app=rook-ceph-tools" -o jsonpath='{.items[0].metadata.name}') -- ceph fs status myfs -f json 2>/dev/null | jq -r .mdsmap.info | grep -c "active")
if [ "$FS_STATUS" -gt 0 ]; then
  echo "Filesystem 'myfs' is active!"
else
  echo "Warning: Filesystem 'myfs' may not be active yet."
fi

# Create PVC
echo "Creating persistent volume claim..."
kubectl create -f csi/cephfs/pvc.yaml -n rook-ceph || true

# Wait for PVC to be bound
echo "Waiting for PVC to be bound..."
for i in {1..10}; do
  PVC_STATUS=$(kubectl get pvc cephfs-pvc -n rook-ceph -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
  if [ "$PVC_STATUS" = "Bound" ]; then
    echo "PVC is bound!"
    break
  else
    echo "PVC status: $PVC_STATUS. Attempt $i of 10. Waiting..."
    sleep 10
  fi
done

# Create test pod
echo "Creating test pod..."
kubectl create -f csi/cephfs/pod.yaml -n rook-ceph || true

# Wait for test pod to be ready
echo "Waiting for test pod to be ready..."
wait_for_resource "pod" "app=csi-cephfs-demo-pod" "rook-ceph" "3m"

# Configure dashboard (disable SSL for easier access)
echo "Configuring Ceph dashboard..."
kubectl -n rook-ceph patch cephcluster rook-ceph --type merge -p '{"spec":{"dashboard":{"ssl":false, "enabled": true, "port": 8443}}}' || true

# MONITORING

echo "Setting up monitoring..."


# add kube-prometheus instead of prometheus-operator for monitoring.
# kube-prometheus is a collection of manifests, Grafana dashboards, and Prometheus rules that can be used to monitor Kubernetes clusters.
# It includes the Prometheus Operator, which simplifies the deployment and management of Prometheus instances on Kubernetes.
# It also includes a set of pre-configured Grafana dashboards and Prometheus rules for monitoring Kubernetes components and workloads.

git clone https://github.com/prometheus-operator/kube-prometheus --depth=1 "$TMP_DIR/kube-prometheus"
kubectl apply --server-side -f "$TMP_DIR/kube-prometheus/manifests/setup"
sleep 10
kubectl wait \
  --for condition=Established \
  --all CustomResourceDefinition \
  --namespace=monitoring
kubectl apply -f "$TMP_DIR/kube-prometheus/manifests/"

# echo "Installing prometheus-operator..."
# kubectl apply doesn't work with the bundle.yaml, so use create
# kubectl create -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.57.0/bundle.yaml

# Wait for operator to be ready before creating custom resources
echo "Waiting for prometheus-operator to be ready..."
# wait_for_resource "pod" "app.kubernetes.io/name=prometheus-operator" "default" "5m"
wait_for_resource "pod" "app.kubernetes.io/name=prometheus-operator" "monitoring" "5m"

# Wait a bit for CRDs to be ready
sleep 10

# Apply Rook monitoring resources
cd monitoring

# Create Rook-Ceph ServiceMonitor
echo "Creating ServiceMonitor..."
kubectl apply -f service-monitor.yaml
kubectl apply -f exporter-service-monitor.yaml

# Create Prometheus instance
echo "Creating Prometheus instance..."
kubectl apply -f prometheus.yaml
kubectl apply -f prometheus-service.yaml

# clear namespace
# kubectl config set-context --current --namespace default

# Wait for Prometheus pod to be ready
echo "Waiting for Prometheus pod to be ready..."
wait_for_resource "pod" "app=prometheus" "rook-ceph" "5m"
# kubectl wait --for=condition=Ready pod -l app=prometheus -n rook-ceph --timeout=5m || true

# enable CSI capabilities
kubectl create namespace snapshot-controller
# Install CRDs for volume snapshots
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.2.1/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.2.1/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.2.1/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml
# Install snapshot controller and RBAC rules
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.2.1/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.2.1/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml
kubectl kustomize https://github.com/kubernetes-csi/external-snapshotter/deploy/kubernetes/csi-snapshotter | kubectl create -f -
# enable ceph to snapshot. allows ceph-rook to be a CSI provisioner for kasten
kubectl apply -f "$ROOT_DIR/cephfs-snapshot-class.yaml"
kubectl apply -f "$ROOT_DIR/cephfs-snapshot-class-rbd.yaml"

# Setup backup with Kasten
wget https://repository.veeam.com/keys/RPM-KASTEN -O "$TMP_DIR/RPM-KASTEN"
helm repo add kasten https://charts.kasten.io/
kubectl create namespace kasten-io
helm install k10 kasten/k10 --namespace=kasten-io --verify --keyring="$TMP_DIR/RPM-KASTEN"
# kasten ends up not fully starting, so don't wait for it. the dashboard works when port worwarding anyway

# install loki for centralized logging
helm upgrade --install loki grafana/loki-stack

for (( i = 0; i < 15; i++ )); do
  echo
done

echo -e "Installation completed!\n"
PROMETHEUS_IP=$(kubectl -n rook-ceph -o jsonpath={.status.hostIP} get pod prometheus-rook-prometheus-0)
if [ -n "$PROMETHEUS_IP" ]; then
  echo "Rook-Prometheus should be accessible at http://$PROMETHEUS_IP:30900"
else
  echo "Could not determine Rook Prometheus IP. Check if the pod is running with: kubectl get pods -n rook-ceph -l app=prometheus"
fi
echo "run ./port_forward_kasten.sh to access the Kasten dashboard"
echo "run ./port_forward_cephdash.sh to access the Ceph dashboard"
echo "run ./port_forward_monitoring.sh to access the monitoring kube-prometheus dashboard"
