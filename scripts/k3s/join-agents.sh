#!/usr/bin/env bash
# ==========================================================================
# join-agents.sh — Join remaining 15 servers as k3s agents
# ==========================================================================
# Each agent connects to the k3s API via the fabric (srv-1-1 loopback).
# Uses server loopback IPs for node identity (fabric-routed).
# Labels each node with its rack for topology-aware scheduling.
#
# Run from host: bash scripts/k3s/join-agents.sh
# ==========================================================================
set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

SERVER_VM="srv-1-1"
SERVER_LOOPBACK="10.0.4.1"
K3S_URL="https://${SERVER_LOOPBACK}:6443"

echo "========================================"
echo " NetWatch: k3s Agent Join"
echo "========================================"
echo "  API server: $K3S_URL"
echo ""

# Get join token from control plane
echo "Fetching join token from $SERVER_VM..."
TOKEN=$(vagrant ssh "$SERVER_VM" -c "sudo cat /var/lib/rancher/k3s/server/node-token" 2>/dev/null | tr -d '[:space:]')
if [ -z "$TOKEN" ]; then
    echo "ERROR: Could not get join token. Is k3s running on $SERVER_VM?"
    echo "  Run: bash scripts/k3s/bootstrap-server.sh"
    exit 1
fi
echo "  Token acquired"
echo ""

# Server loopback mapping (must match topology.yml)
declare -A LOOPBACKS=(
    [srv-1-2]=10.0.4.2 [srv-1-3]=10.0.4.3 [srv-1-4]=10.0.4.4
    [srv-2-1]=10.0.5.1 [srv-2-2]=10.0.5.2 [srv-2-3]=10.0.5.3 [srv-2-4]=10.0.5.4
    [srv-3-1]=10.0.6.1 [srv-3-2]=10.0.6.2 [srv-3-3]=10.0.6.3 [srv-3-4]=10.0.6.4
    [srv-4-1]=10.0.7.1 [srv-4-2]=10.0.7.2 [srv-4-3]=10.0.7.3 [srv-4-4]=10.0.7.4
)

join_agent() {
    local vm="$1"
    local loopback="$2"
    local rack
    rack=$(vagrant ssh "$vm" -c "cat /etc/netwatch-rack 2>/dev/null" 2>/dev/null | tr -d '[:space:]')
    [ -z "$rack" ] && rack="unknown"

    echo "  $vm ($loopback, $rack)..."

    vagrant ssh "$vm" -c "sudo bash -s" <<AGENT
set -e

# Check if already joined
if systemctl is-active k3s-agent &>/dev/null; then
    echo "    already running"
    exit 0
fi

# Start k3s agent
k3s agent \
    --server ${K3S_URL} \
    --token ${TOKEN} \
    --node-ip ${loopback} \
    --node-external-ip ${loopback} \
    &

# Wait for node to register
for i in \$(seq 1 30); do
    if k3s kubectl --server ${K3S_URL} --token ${TOKEN} get node ${vm} &>/dev/null 2>&1; then
        echo "    registered"
        break
    fi
    sleep 2
done
AGENT

    echo "    $vm joined"
}

# Join agents rack by rack
echo "--- Rack 1 (remaining) ---"
for vm in srv-1-2 srv-1-3 srv-1-4; do
    join_agent "$vm" "${LOOPBACKS[$vm]}" &
done
wait

echo "--- Rack 2 ---"
for vm in srv-2-1 srv-2-2 srv-2-3 srv-2-4; do
    join_agent "$vm" "${LOOPBACKS[$vm]}" &
done
wait

echo "--- Rack 3 ---"
for vm in srv-3-1 srv-3-2 srv-3-3 srv-3-4; do
    join_agent "$vm" "${LOOPBACKS[$vm]}" &
done
wait

echo "--- Rack 4 ---"
for vm in srv-4-1 srv-4-2 srv-4-3 srv-4-4; do
    join_agent "$vm" "${LOOPBACKS[$vm]}" &
done
wait

echo ""
echo "=== Labeling nodes with rack topology ==="
vagrant ssh "$SERVER_VM" -c "sudo bash -s" <<'LABELS'
set -e
for node in $(k3s kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
    rack=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 vagrant@${node} "cat /etc/netwatch-rack 2>/dev/null" 2>/dev/null || echo "")
    if [ -n "$rack" ]; then
        k3s kubectl label node "$node" topology.kubernetes.io/zone="$rack" --overwrite 2>/dev/null
        echo "  $node → $rack"
    fi
done
LABELS

echo ""
echo "=== k3s Cluster Status ==="
vagrant ssh "$SERVER_VM" -c "sudo k3s kubectl get nodes -o wide" 2>/dev/null

echo ""
echo "=== Done ==="
echo "  16 nodes should be Ready (may take 30-60s for all agents to settle)"
echo "  Next: bash scripts/k3s/setup-host-kubectl.sh"
