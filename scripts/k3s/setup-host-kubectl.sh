#!/usr/bin/env bash
# ==========================================================================
# setup-host-kubectl.sh — Configure kubectl on the HOST (operator workstation)
# ==========================================================================
# Copies kubeconfig from the k3s control plane (srv-1-1) to the host.
# Rewrites the server URL to use the fabric loopback IP, reachable from
# the host via: host → mgmt bridge → bastion → fabric → srv-1-1.
#
# Prerequisites:
#   - k3s running on srv-1-1 (make k3s-init)
#   - Host route for 10.0.0.0/8 via bastion (make routes)
#
# Run from host: bash scripts/k3s/setup-host-kubectl.sh
# ==========================================================================
set -euo pipefail

CONTROL_VM="mgmt"
CONTROL_IP="192.168.0.3"
KUBECONFIG_DIR="${HOME}/.kube"
KUBECONFIG_FILE="${KUBECONFIG_DIR}/netwatch-config"

echo "========================================"
echo " NetWatch: Host kubectl Setup"
echo "========================================"

# Fetch kubeconfig from control plane
echo "  Fetching kubeconfig from $CONTROL_VM..."
# Use -- -T to disable PTY allocation (prevents terminal escape sequences in output)
KUBECONFIG_RAW=$(vagrant ssh "$CONTROL_VM" -- -T "sudo cat /etc/rancher/k3s/k3s.yaml" 2>/dev/null | tr -d '\r')

if [ -z "$KUBECONFIG_RAW" ]; then
    echo "ERROR: Could not fetch kubeconfig. Is k3s running on $CONTROL_VM?"
    echo "  Run: make k3s-init"
    exit 1
fi

# Rewrite server URL: localhost → fabric loopback
KUBECONFIG_FIXED=$(echo "$KUBECONFIG_RAW" | sed "s|https://127.0.0.1:6443|https://${CONTROL_IP}:6443|g")

# Write to host
mkdir -p "$KUBECONFIG_DIR"
echo "$KUBECONFIG_FIXED" > "$KUBECONFIG_FILE"
chmod 600 "$KUBECONFIG_FILE"

echo "  Kubeconfig written to $KUBECONFIG_FILE"

echo ""
echo "  Run this in every terminal session:"
echo "    export KUBECONFIG=$KUBECONFIG_FILE"

# Verify connectivity
echo ""
echo "  Verifying kubectl access to cluster..."
if kubectl --kubeconfig="$KUBECONFIG_FILE" get nodes &>/dev/null; then
    echo ""
    echo "=== kubectl connected ==="
    kubectl --kubeconfig="$KUBECONFIG_FILE" get nodes -o wide
else
    echo ""
    echo "WARNING: kubectl can't reach the k8s API at https://${CONTROL_IP}:6443"
    echo "  Check: ping ${CONTROL_IP}  (should route via bastion)"
    echo "  Check: make routes  (adds 10.0.0.0/8 via bastion)"
fi

echo ""
echo "  From your terminal:"
echo "    export KUBECONFIG=$KUBECONFIG_FILE"
echo "    kubectl get nodes"
echo "    kubectl get pods -A"
