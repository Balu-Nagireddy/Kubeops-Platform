#!/usr/bin/env bash
# setup.sh — One-command idempotent local environment setup for Enterprise Bot demo
# Requires: docker, kind, kubectl, helm

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CLUSTER_NAME="demo"
NAMESPACE="demo"
RELEASE_NAME="demo"
IMAGE_NAME="eb-demo-app:1.0.0"

echo "============================================================"
echo " Starting Enterprise Bot Demo Platform Setup"
echo "============================================================"

# 1. Create or reuse kind cluster
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "==> [1/4] Kind cluster '$CLUSTER_NAME' already exists. Reusing cluster."
else
  echo "==> [1/4] Creating kind cluster '$CLUSTER_NAME' with ingress port mappings..."
  cat <<EOF | kind create cluster --name "$CLUSTER_NAME" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
EOF
fi

# Ensure context is pointing to the cluster
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null 2>&1 || true

# 2. Install ingress-nginx controller
echo "==> [2/4] Ensuring ingress-nginx controller is deployed..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

echo "==> Waiting for ingress-nginx controller to be ready..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

# 3. Build and load docker image into kind cluster
echo "==> [3/4] Building application Docker image ($IMAGE_NAME)..."
docker build -t "$IMAGE_NAME" service/

echo "==> Loading $IMAGE_NAME into kind cluster '$CLUSTER_NAME'..."
kind load docker-image "$IMAGE_NAME" --name "$CLUSTER_NAME"

# 4. Install / upgrade Helm chart
echo "==> [4/4] Deploying Helm release '$RELEASE_NAME' into namespace '$NAMESPACE'..."
helm upgrade --install "$RELEASE_NAME" ./chart \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --set image.repository="eb-demo-app" \
  --set image.tag="1.0.0" \
  --set image.pullPolicy="IfNotPresent" \
  --wait \
  --timeout=120s

echo "============================================================"
echo " Setup complete! Service is healthy and ready."
echo " Ingress Host: http://demo.local"
echo " Verify with:  curl -H 'Host: demo.local' http://localhost/"
echo "============================================================"
