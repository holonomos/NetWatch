#!/usr/bin/env bash
# ==========================================================================
# install-cilium.sh — Install Cilium CNI on the k3s cluster
# ==========================================================================
# Runs from HOST. Installs Cilium via Helm with VxLAN overlay.
#
# Cilium tunnel endpoints use server loopback IPs (10.0.4-7.x) which are
# reachable via ECMP through both leaf switches. The dual-homed underlay
# is transparent to Cilium — if one leaf dies, traffic shifts automatically.
#
# Prerequisites:
#   - k3s cluster running (make k3s-init + make k3s-join)
#   - kubectl configured on host (make k3s-kubectl)
#   - helm installed on host
#   - Host route for 10.0.0.0/8 via bastion (make routes)
#
# Run from host: bash scripts/k3s/install-cilium.sh
# ==========================================================================
set -euo pipefail

CONTROL_IP="192.168.0.3"
KUBECONFIG_FILE="${HOME}/.kube/netwatch-config"
CILIUM_WAIT_TIMEOUT="600s"
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

export KUBECONFIG="$KUBECONFIG_FILE"

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $cmd"
        exit 1
    fi
}

verify_cilium_ready() {
    local timeout="$1"
    local desired
    local ready

    echo "  Verifying Cilium DaemonSet rollout..."
    kubectl -n kube-system rollout status daemonset/cilium --timeout="$timeout"

    echo "  Verifying Cilium operator rollout..."
    kubectl -n kube-system rollout status deployment/cilium-operator --timeout="$timeout"

    desired=$(kubectl -n kube-system get daemonset cilium -o jsonpath='{.status.desiredNumberScheduled}')
    ready=$(kubectl -n kube-system get daemonset cilium -o jsonpath='{.status.numberReady}')

    if [ "$desired" -ne "$ready" ]; then
        echo "ERROR: Cilium DaemonSet is not fully ready ($ready/$desired)"
        return 1
    fi
}

preload_images_for_cilium() {
    local import_script="$PROJECT_ROOT/scripts/k3s/import-images.sh"

    if [ "${SKIP_IMAGE_IMPORT:-0}" = "1" ]; then
        echo "  SKIP_IMAGE_IMPORT=1 set, skipping image preload"
        return 0
    fi

    if [ ! -f "$import_script" ]; then
        echo "ERROR: Missing import helper: $import_script"
        exit 1
    fi

    echo "  Preloading Cilium images to all k3s nodes..."
    bash "$import_script" cilium-images.tar k3s-system-images.tar
}

echo "========================================"
echo " NetWatch: Cilium CNI Installation"
echo "========================================"

# Verify required tooling
require_cmd kubectl
require_cmd helm
if [ "${SKIP_IMAGE_IMPORT:-0}" != "1" ]; then
    require_cmd vagrant
fi

# Verify cluster access from host
echo "  Verifying cluster access..."
kubectl get nodes &>/dev/null || {
    echo "ERROR: kubectl can't reach cluster"
    echo "  Run: make k3s-init && make k3s-kubectl"
    echo "  Check: make routes (adds 10.0.0.0/8 via bastion)"
    exit 1
}

source "$PROJECT_ROOT/repo/versions.env"

preload_images_for_cilium

# Use local chart if available, otherwise pull from repo
CHART_PATH="$PROJECT_ROOT/artifacts/cilium-${CILIUM_VERSION}.tgz"
HELM_VERSION_ARG=()
if [ -f "$CHART_PATH" ]; then
    CHART_REF="$CHART_PATH"
    echo "  Using local chart: $CHART_PATH"
else
    echo "  Local chart not found; using Helm repo chart..."
    if helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1; then
        echo "  Added Helm repo: cilium"
    else
        echo "  Helm repo 'cilium' already exists (or add was skipped)"
    fi
    helm repo update cilium
    CHART_REF="cilium/cilium"
    HELM_VERSION_ARG=(--version "${CILIUM_VERSION}")
fi

echo "  Installing/upgrading Cilium v${CILIUM_VERSION}..."
helm upgrade --install cilium "$CHART_REF" \
    "${HELM_VERSION_ARG[@]}" \
    --namespace kube-system \
    --set routingMode=tunnel \
    --set tunnelProtocol=vxlan \
    --set ipam.mode=kubernetes \
    --set k8sServiceHost=${CONTROL_IP} \
    --set k8sServicePort=6443 \
    --set bpf.masquerade=true \
    --set hubble.enabled=false \
    --set operator.replicas=1 \
    --set image.useDigest=false \
    --set operator.image.useDigest=false \
    --set envoy.image.useDigest=false \
    --wait \
    --timeout "$CILIUM_WAIT_TIMEOUT"

echo ""
verify_cilium_ready "$CILIUM_WAIT_TIMEOUT"

echo ""
echo "=== Cilium Status ==="
if command -v cilium >/dev/null 2>&1; then
    if ! cilium status; then
        echo "  WARNING: cilium CLI status failed; showing pod state instead"
        kubectl -n kube-system get pods -l k8s-app=cilium
    fi
else
    kubectl -n kube-system get pods -l k8s-app=cilium
fi

echo ""
echo "=== Node Status ==="
kubectl get nodes -o wide

echo ""
echo "=== Cilium CNI Installed ==="
echo "  Tunnel mode: VxLAN"
echo "  IPAM: Kubernetes"
echo "  Masquerade: BPF"
echo "  API server: ${CONTROL_IP}:6443"
echo ""
echo "  Verify pod networking:"
echo "    kubectl run test-1 --image=busybox --overrides='{\"spec\":{\"nodeSelector\":{\"topology.kubernetes.io/zone\":\"rack-1\"}}}' -- sleep 3600"
echo "    kubectl run test-2 --image=busybox --overrides='{\"spec\":{\"nodeSelector\":{\"topology.kubernetes.io/zone\":\"rack-4\"}}}' -- sleep 3600"
echo "    kubectl exec test-1 -- ping <test-2-pod-ip>"
