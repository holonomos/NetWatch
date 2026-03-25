#!/usr/bin/env bash
# ==========================================================================
# install-metallb.sh — Install MetalLB load balancer on the k3s cluster
# ==========================================================================
# Installs MetalLB via Helm and applies BGP configuration from host.
# MetalLB speakers on server VMs peer with leaf switches to announce
# service IPs (10.100.0.0/24) as /32 routes via BGP.
#
# Prerequisites:
#   - k3s cluster running with Cilium CNI
#   - kubectl configured on host (setup-host-kubectl.sh)
#   - helm installed on host
#   - Host route for 10.0.0.0/8 via bastion (make routes)
#
# Run from host: bash scripts/k3s/install-metallb.sh
# ==========================================================================
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
METALLB_CONFIG="$PROJECT_ROOT/config/metallb/metallb-config.yaml"
KUBECONFIG_FILE="${HOME}/.kube/netwatch-config"

# Use NetWatch kubeconfig
export KUBECONFIG="$KUBECONFIG_FILE"

echo "========================================"
echo " NetWatch: MetalLB Installation"
echo "========================================"

# Verify cluster access
echo "  Verifying cluster access..."
kubectl get nodes &>/dev/null || {
    echo "ERROR: kubectl can't reach cluster"
    echo "  Run: make k3s-init && bash scripts/k3s/setup-host-kubectl.sh"
    exit 1
}

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$PROJECT_ROOT/repo/versions.env"

# Use local chart if available, otherwise pull from repo
CHART_PATH="$PROJECT_ROOT/artifacts/metallb-${METALLB_VERSION}.tgz"
if [ -f "$CHART_PATH" ]; then
    CHART_REF="$CHART_PATH"
    echo "  Using local chart: $CHART_PATH"
else
    echo "  Local chart not found, adding Helm repo..."
    helm repo add metallb https://metallb.github.io/metallb 2>/dev/null || true
    helm repo update 2>/dev/null
    CHART_REF="metallb/metallb"
fi

# Check if already installed
if helm status metallb -n metallb-system &>/dev/null; then
    echo "  MetalLB is already installed"
    kubectl get pods -n metallb-system
else
    echo "  Installing MetalLB v${METALLB_VERSION}..."
    helm install metallb "$CHART_REF" \
        --version "${METALLB_VERSION}" \
        --namespace metallb-system \
        --create-namespace \
        --wait \
        --timeout 300s
fi

# Wait for controller
echo "  Waiting for MetalLB controller..."
kubectl wait --namespace metallb-system \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=120s 2>/dev/null || echo "  (still starting — may need a moment)"

# Apply BGP configuration
echo "  Applying BGP configuration..."
kubectl apply -f "$METALLB_CONFIG"

echo ""
echo "=== MetalLB Installed ==="
kubectl get pods -n metallb-system 2>/dev/null
echo ""
echo "  IP pool:  10.100.0.0/24"
echo "  BGP peers: leaf switches (per rack)"
echo ""
echo "  Test it:"
echo "    kubectl create deployment nginx --image=nginx"
echo "    kubectl expose deployment nginx --type=LoadBalancer --port=80"
echo "    kubectl get svc nginx  # wait for EXTERNAL-IP"
echo "    curl http://<EXTERNAL-IP>"
