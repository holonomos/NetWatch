#!/usr/bin/env bash
# ==========================================================================
# join-agents.sh — Join all 16 servers as k3s agents
# ==========================================================================
# Creates systemd services for k3s agent on each server.
# Joins rack by rack (4 at a time) to avoid overwhelming the control plane.
#
# Run from host: bash scripts/k3s/join-agents.sh
# ==========================================================================
set -euo pipefail

CONTROL_VM="mgmt"
CONTROL_IP="192.168.0.3"
K3S_URL="https://${CONTROL_IP}:6443"
EXPECTED_TOTAL_NODES=17
READY_WAIT_SECONDS=180
READY_POLL_SECONDS=5

echo "========================================"
echo " NetWatch: k3s Agent Join"
echo "========================================"
echo "  API server: $K3S_URL"
echo ""

# Get join token (PTY disabled, control chars stripped)
echo "Fetching join token from $CONTROL_VM..."
if ! TOKEN=$(vagrant ssh "$CONTROL_VM" -- -T "sudo cat /var/lib/rancher/k3s/server/node-token" 2>/dev/null | tr -d '[:space:][:cntrl:]'); then
    TOKEN=""
fi
if [ -z "$TOKEN" ]; then
    echo "ERROR: Could not get join token. Is k3s running on $CONTROL_VM?"
    echo "  Run: bash scripts/k3s/bootstrap-server.sh"
    exit 1
fi
echo "  Token acquired"
echo ""

# Server loopback mapping (must match topology.yml)
declare -A LOOPBACKS=(
    [srv-1-1]=10.0.4.1 [srv-1-2]=10.0.4.2 [srv-1-3]=10.0.4.3 [srv-1-4]=10.0.4.4
    [srv-2-1]=10.0.5.1 [srv-2-2]=10.0.5.2 [srv-2-3]=10.0.5.3 [srv-2-4]=10.0.5.4
    [srv-3-1]=10.0.6.1 [srv-3-2]=10.0.6.2 [srv-3-3]=10.0.6.3 [srv-3-4]=10.0.6.4
    [srv-4-1]=10.0.7.1 [srv-4-2]=10.0.7.2 [srv-4-3]=10.0.7.3 [srv-4-4]=10.0.7.4
)

join_agent() {
    local vm="$1"
    local loopback="$2"

    # Check if service file exists AND is running
    if vagrant ssh "$vm" -- -T "test -f /etc/systemd/system/k3s-agent.service && sudo systemctl is-active k3s-agent 2>/dev/null" 2>/dev/null | tr -d '[:cntrl:]' | grep -q "^active$"; then
        echo "    $vm: already running"
        return 0
    fi

    echo "    $vm ($loopback)..."
    vagrant ssh "$vm" -- -T "sudo bash -s" <<AGENT
set -e

# Create systemd unit for k3s agent
cat > /etc/systemd/system/k3s-agent.service <<EOF
[Unit]
Description=k3s agent
After=network.target

[Service]
ExecStart=/usr/local/bin/k3s agent --server ${K3S_URL} --token ${TOKEN} --node-ip ${loopback} --node-external-ip ${loopback}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now k3s-agent

if ! systemctl is-active --quiet k3s-agent; then
    echo "ERROR: k3s-agent is not active on ${vm}"
    systemctl --no-pager status k3s-agent || true
    exit 1
fi

echo "    $vm: agent started"
AGENT
}

wait_for_all_nodes_ready() {
    local wait_seconds="$1"
    local poll_seconds="$2"
    local attempts
    local attempt
    local status
    local total
    local ready

    attempts=$((wait_seconds / poll_seconds))
    if [ "$attempts" -lt 1 ]; then
        attempts=1
    fi

    echo ""
    echo "=== Waiting for node readiness ==="
    for attempt in $(seq 1 "$attempts"); do
        if ! status=$(vagrant ssh "$CONTROL_VM" -- -T "sudo k3s kubectl get nodes --no-headers 2>/dev/null" 2>/dev/null); then
            status=""
        fi

        total=$(printf '%s\n' "$status" | awk 'NF {c++} END {print c+0}')
        ready=$(printf '%s\n' "$status" | awk '$2 ~ /^Ready/ {c++} END {print c+0}')
        echo "  Attempt $attempt/$attempts: Ready $ready/$total (target ${EXPECTED_TOTAL_NODES}/${EXPECTED_TOTAL_NODES})"

        if [ "$total" -eq "$EXPECTED_TOTAL_NODES" ] && [ "$ready" -eq "$EXPECTED_TOTAL_NODES" ]; then
            echo "  All nodes are Ready"
            return 0
        fi

        sleep "$poll_seconds"
    done

    echo "ERROR: Timed out waiting for all nodes to become Ready"
    return 1
}

# Join rack by rack with pause between racks
echo "--- Rack 1 (4 servers) ---"
for vm in srv-1-1 srv-1-2 srv-1-3 srv-1-4; do
    join_agent "$vm" "${LOOPBACKS[$vm]}"
done
echo "  Rack 1 joined. Waiting 10s for API to settle..."
sleep 10

echo "--- Rack 2 ---"
for vm in srv-2-1 srv-2-2 srv-2-3 srv-2-4; do
    join_agent "$vm" "${LOOPBACKS[$vm]}"
done
echo "  Rack 2 joined. Waiting 10s..."
sleep 10

echo "--- Rack 3 ---"
for vm in srv-3-1 srv-3-2 srv-3-3 srv-3-4; do
    join_agent "$vm" "${LOOPBACKS[$vm]}"
done
echo "  Rack 3 joined. Waiting 10s..."
sleep 10

echo "--- Rack 4 ---"
for vm in srv-4-1 srv-4-2 srv-4-3 srv-4-4; do
    join_agent "$vm" "${LOOPBACKS[$vm]}"
done

echo ""
echo "  Waiting 15s for all agents to register..."
sleep 15

# Label all nodes with rack topology
echo ""
echo "=== Labeling nodes with rack topology ==="
for vm in "${!LOOPBACKS[@]}"; do
    rack=$(vagrant ssh "$vm" -- -T "cat /etc/netwatch-rack 2>/dev/null" 2>/dev/null | tr -d '[:space:][:cntrl:]')
    if [ -n "$rack" ]; then
        if vagrant ssh "$CONTROL_VM" -- -T "sudo k3s kubectl label node $vm topology.kubernetes.io/zone=$rack --overwrite"; then
            echo "  $vm -> $rack"
        else
            echo "ERROR: Failed to label $vm with topology.kubernetes.io/zone=$rack"
            exit 1
        fi
    else
        echo "ERROR: Could not read /etc/netwatch-rack from $vm"
        exit 1
    fi
done

if ! wait_for_all_nodes_ready "$READY_WAIT_SECONDS" "$READY_POLL_SECONDS"; then
    echo ""
    echo "=== Current k3s Cluster Status ==="
    vagrant ssh "$CONTROL_VM" -- -T "sudo k3s kubectl get nodes -o wide" 2>/dev/null || true
    exit 1
fi

echo ""
echo "=== k3s Cluster Status ==="
vagrant ssh "$CONTROL_VM" -- -T "sudo k3s kubectl get nodes -o wide" 2>/dev/null

echo ""
echo "=== Done ==="
echo "  17 nodes are Ready: 1 server (mgmt) + 16 agents"
echo "  Next: bash scripts/k3s/setup-host-kubectl.sh"
