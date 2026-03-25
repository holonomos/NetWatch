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

SERVER_LOOPBACK="10.0.4.1"
KUBECONFIG_FILE="${HOME}/.kube/netwatch-config"

export KUBECONFIG="$KUBECONFIG_FILE"

echo "========================================"
echo " NetWatch: Cilium CNI Installation"
echo "========================================"

# Verify cluster access from host
echo "  Verifying cluster access..."
kubectl get nodes &>/dev/null || {
    echo "ERROR: kubectl can't reach cluster"
    echo "  Run: make k3s-init && make k3s-kubectl"
    echo "  Check: make routes (adds 10.0.0.0/8 via bastion)"
    exit 1
}

# Add Cilium Helm repo
echo "  Adding Cilium Helm repo..."
helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
helm repo update 2>/dev/null

# Check if already installed
if helm status cilium -n kube-system &>/dev/null; then
    echo "  Cilium is already installed"
    cilium status 2>/dev/null || kubectl -n kube-system get pods -l k8s-app=cilium
    exit 0
fi

echo "  Installing Cilium..."
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set tunnel=vxlan \
    --set ipam.mode=kubernetes \
    --set k8sServiceHost=${SERVER_LOOPBACK} \
    --set k8sServicePort=6443 \
    --set bpf.masquerade=true \
    --set hubble.enabled=false \
    --set operator.replicas=1 \
    --wait \
    --timeout 300s

echo ""
echo "  Waiting for Cilium agents to be ready..."
sleep 10

echo ""
echo "=== Cilium Status ==="
cilium status 2>/dev/null || kubectl -n kube-system get pods -l k8s-app=cilium

echo ""
echo "=== Node Status ==="
kubectl get nodes -o wide

echo ""
echo "=== Cilium CNI Installed ==="
echo "  Tunnel mode: VxLAN"
echo "  IPAM: Kubernetes"
echo "  Masquerade: BPF"
echo "  API server: ${SERVER_LOOPBACK}:6443"
echo ""
echo "  Verify pod networking:"
echo "    kubectl run test-1 --image=busybox --overrides='{\"spec\":{\"nodeSelector\":{\"topology.kubernetes.io/zone\":\"rack-1\"}}}' -- sleep 3600"
echo "    kubectl run test-2 --image=busybox --overrides='{\"spec\":{\"nodeSelector\":{\"topology.kubernetes.io/zone\":\"rack-4\"}}}' -- sleep 3600"
echo "    kubectl exec test-1 -- ping <test-2-pod-ip>"
