#!/usr/bin/env bash
# ==========================================================================
# setup-bastion-kubectl.sh — Configure kubectl on bastion (operations desk)
# ==========================================================================
# Copies kubeconfig from srv-1-1 to bastion, rewrites the server URL
# to use the fabric loopback IP (reachable from bastion via border → spine → leaf).
#
# Run from host: bash scripts/k3s/setup-bastion-kubectl.sh
# ==========================================================================
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

SERVER_VM="srv-1-1"
SERVER_LOOPBACK="10.0.4.1"

echo "========================================"
echo " NetWatch: Bastion kubectl Setup"
echo "========================================"

# Get kubeconfig from control plane
echo "Fetching kubeconfig from $SERVER_VM..."
KUBECONFIG_RAW=$(vagrant ssh "$SERVER_VM" -c "sudo cat /etc/rancher/k3s/k3s.yaml" 2>/dev/null)

if [ -z "$KUBECONFIG_RAW" ]; then
    echo "ERROR: Could not fetch kubeconfig. Is k3s running on $SERVER_VM?"
    exit 1
fi

# Rewrite server URL from localhost to fabric loopback
KUBECONFIG_FIXED=$(echo "$KUBECONFIG_RAW" | sed "s|https://127.0.0.1:6443|https://${SERVER_LOOPBACK}:6443|g")

# Deploy to bastion
echo "Deploying kubeconfig to bastion..."
echo "$KUBECONFIG_FIXED" | vagrant ssh bastion -c "sudo bash -c '
mkdir -p /home/vagrant/.kube
cat > /home/vagrant/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube
chmod 600 /home/vagrant/.kube/config
'"

# Verify
echo ""
echo "Verifying kubectl from bastion..."
vagrant ssh bastion -c "kubectl get nodes 2>/dev/null" || {
    echo ""
    echo "WARNING: kubectl verification failed. The k3s API may not be reachable"
    echo "from bastion yet. Check that the fabric path bastion → border → spine → leaf → srv-1-1"
    echo "is working: vagrant ssh bastion -c 'ping -c1 ${SERVER_LOOPBACK}'"
}

echo ""
echo "=== Bastion kubectl configured ==="
echo "  SSH into bastion and manage the cluster:"
echo "    vagrant ssh bastion"
echo "    kubectl get nodes"
echo "    kubectl get pods -A"
echo "    helm list -A"
