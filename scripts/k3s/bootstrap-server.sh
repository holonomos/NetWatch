#!/usr/bin/env bash
# ==========================================================================
# bootstrap-server.sh — Initialize k3s control plane on srv-1-1
# ==========================================================================
# Starts k3s server with fabric-routed networking:
#   - Binds to server loopback IP (reachable via Clos fabric)
#   - Disables Flannel (Cilium handles CNI)
#   - Disables Traefik (MetalLB handles ingress)
#   - Outputs join token for agents
#
# Run from host: bash scripts/k3s/bootstrap-server.sh
# ==========================================================================
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

SERVER_VM="srv-1-1"
SERVER_LOOPBACK="10.0.4.1"

echo "========================================"
echo " NetWatch: k3s Control Plane Bootstrap"
echo "========================================"
echo "  Server: $SERVER_VM"
echo "  Bind:   $SERVER_LOOPBACK"
echo ""

# Check if k3s is already running
if vagrant ssh "$SERVER_VM" -c "systemctl is-active k3s 2>/dev/null" 2>/dev/null | grep -q "^active$"; then
    echo "k3s is already running on $SERVER_VM"
    echo ""
    echo "Join token:"
    vagrant ssh "$SERVER_VM" -c "sudo cat /var/lib/rancher/k3s/server/node-token" 2>/dev/null
    echo ""
    echo "Kubeconfig:"
    echo "  vagrant ssh $SERVER_VM -c 'sudo cat /etc/rancher/k3s/k3s.yaml'"
    exit 0
fi

echo "Starting k3s server on $SERVER_VM..."
vagrant ssh "$SERVER_VM" -c "sudo bash -s" <<BOOTSTRAP
set -e

# k3s server with fabric networking
k3s server \
    --bind-address ${SERVER_LOOPBACK} \
    --advertise-address ${SERVER_LOOPBACK} \
    --node-ip ${SERVER_LOOPBACK} \
    --node-external-ip ${SERVER_LOOPBACK} \
    --flannel-backend=none \
    --disable-network-policy \
    --disable=traefik \
    --disable=servicelb \
    --cluster-cidr=10.42.0.0/16 \
    --service-cidr=10.43.0.0/16 \
    --write-kubeconfig-mode=644 \
    &

# Wait for k3s to be ready
echo "  Waiting for k3s API server..."
for i in \$(seq 1 60); do
    if k3s kubectl get nodes &>/dev/null; then
        echo "  k3s API server ready"
        break
    fi
    sleep 2
done

# Label this node with rack topology
RACK=\$(cat /etc/netwatch-rack 2>/dev/null || echo "rack-1")
k3s kubectl label node ${SERVER_VM} topology.kubernetes.io/zone=\${RACK} --overwrite

echo ""
echo "  Control plane running on ${SERVER_LOOPBACK}:6443"
BOOTSTRAP

echo ""
echo "=== k3s Control Plane Ready ==="
echo ""

# Get and display join token
echo "Join token:"
vagrant ssh "$SERVER_VM" -c "sudo cat /var/lib/rancher/k3s/server/node-token" 2>/dev/null
echo ""
echo "Next: bash scripts/k3s/join-agents.sh"
