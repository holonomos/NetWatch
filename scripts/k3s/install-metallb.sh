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

METALLB_WAIT_TIMEOUT="600s"
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
METALLB_CONFIG="$PROJECT_ROOT/config/metallb/metallb-config.yaml"
KUBECONFIG_FILE="${HOME}/.kube/netwatch-config"

# Use NetWatch kubeconfig
export KUBECONFIG="$KUBECONFIG_FILE"

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $cmd"
        exit 1
    fi
}

preload_images_for_metallb() {
    local import_script="$PROJECT_ROOT/scripts/k3s/import-images.sh"

    if [ "${SKIP_IMAGE_IMPORT:-0}" = "1" ]; then
        echo "  SKIP_IMAGE_IMPORT=1 set, skipping image preload"
        return 0
    fi

    if [ ! -f "$import_script" ]; then
        echo "ERROR: Missing import helper: $import_script"
        exit 1
    fi

    echo "  Preloading MetalLB images to all k3s nodes..."
    bash "$import_script" metallb-images.tar
}

verify_metallb_ready() {
    local timeout="$1"
    local desired
    local ready

    echo "  Verifying MetalLB controller rollout..."
    kubectl -n metallb-system rollout status deployment/metallb-controller --timeout="$timeout"

    echo "  Verifying MetalLB speaker rollout..."
    kubectl -n metallb-system rollout status daemonset/metallb-speaker --timeout="$timeout"

    desired=$(kubectl -n metallb-system get daemonset metallb-speaker -o jsonpath='{.status.desiredNumberScheduled}')
    ready=$(kubectl -n metallb-system get daemonset metallb-speaker -o jsonpath='{.status.numberReady}')
    if [ "$desired" -ne "$ready" ]; then
        echo "ERROR: MetalLB speaker DaemonSet is not fully ready ($ready/$desired)"
        return 1
    fi
}

echo "========================================"
echo " NetWatch: MetalLB Installation"
echo "========================================"

# Verify required tooling and config
require_cmd kubectl
require_cmd helm
if [ "${SKIP_IMAGE_IMPORT:-0}" != "1" ]; then
    require_cmd vagrant
fi
if [ ! -f "$METALLB_CONFIG" ]; then
    echo "ERROR: Missing MetalLB config: $METALLB_CONFIG"
    exit 1
fi

# Verify cluster access
echo "  Verifying cluster access..."
kubectl get nodes &>/dev/null || {
    echo "ERROR: kubectl can't reach cluster"
    echo "  Run: make k3s-init && bash scripts/k3s/setup-host-kubectl.sh"
    exit 1
}
source "$PROJECT_ROOT/repo/versions.env"

preload_images_for_metallb

# Use local chart if available, otherwise pull from repo
CHART_PATH="$PROJECT_ROOT/artifacts/metallb-${METALLB_VERSION}.tgz"
HELM_VERSION_ARG=()
if [ -f "$CHART_PATH" ]; then
    CHART_REF="$CHART_PATH"
    echo "  Using local chart: $CHART_PATH"
else
    echo "  Local chart not found; using Helm repo chart..."
    if helm repo add metallb https://metallb.github.io/metallb >/dev/null 2>&1; then
        echo "  Added Helm repo: metallb"
    else
        echo "  Helm repo 'metallb' already exists (or add was skipped)"
    fi
    helm repo update metallb
    CHART_REF="metallb/metallb"
    HELM_VERSION_ARG=(--version "${METALLB_VERSION}")
fi

echo "  Installing/upgrading MetalLB v${METALLB_VERSION}..."
helm upgrade --install metallb "$CHART_REF" \
    "${HELM_VERSION_ARG[@]}" \
    --namespace metallb-system \
    --create-namespace \
    --wait \
    --timeout "$METALLB_WAIT_TIMEOUT"

verify_metallb_ready "$METALLB_WAIT_TIMEOUT"

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
