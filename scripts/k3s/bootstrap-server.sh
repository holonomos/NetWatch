#!/usr/bin/env bash
# ==========================================================================
# bootstrap-server.sh — Initialize k3s control plane on mgmt VM
# ==========================================================================
# The control plane runs on mgmt (OOB network) so it survives all chaos
# scenarios. Chaos scripts target the fabric bridges — mgmt is untouched.
#
# Agents connect to the API via the mgmt bridge (192.168.0.3:6443).
# kubectl from host connects directly (host is on the mgmt bridge).
#
# Run from host: bash scripts/k3s/bootstrap-server.sh
# ==========================================================================
set -euo pipefail

CONTROL_VM="mgmt"
CONTROL_IP="192.168.0.3"

echo "========================================"
echo " NetWatch: k3s Control Plane Bootstrap"
echo "========================================"
echo "  Server: $CONTROL_VM (OOB — chaos-proof)"
echo "  Bind:   $CONTROL_IP"
echo ""

# Check if already running
if vagrant ssh "$CONTROL_VM" -- -T "sudo systemctl is-active k3s 2>/dev/null" 2>/dev/null | grep -q "^active$"; then
    echo "k3s is already running on $CONTROL_VM"
    echo ""
    echo "Join token:"
    vagrant ssh "$CONTROL_VM" -- -T "sudo cat /var/lib/rancher/k3s/server/node-token" 2>/dev/null | tr -d '[:cntrl:]'
    echo ""
    exit 0
fi

echo "Creating k3s systemd service on $CONTROL_VM..."
vagrant ssh "$CONTROL_VM" -c "sudo bash -s" <<BOOTSTRAP
set -e

# Create systemd unit
cat > /etc/systemd/system/k3s.service <<EOF
[Unit]
Description=k3s server
After=network.target

[Service]
ExecStart=/usr/local/bin/k3s server --bind-address ${CONTROL_IP} --advertise-address ${CONTROL_IP} --node-ip ${CONTROL_IP} --node-external-ip ${CONTROL_IP} --flannel-backend=none --disable-network-policy --disable=traefik --disable=servicelb --cluster-cidr=10.42.0.0/16 --service-cidr=10.43.0.0/16 --write-kubeconfig-mode=644
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now k3s

# Wait for API server
echo "  Waiting for k3s API server..."
for i in \$(seq 1 60); do
    if k3s kubectl get nodes &>/dev/null; then
        echo "  k3s API server ready"
        break
    fi
    sleep 2
done

echo "  Control plane running on ${CONTROL_IP}:6443"
BOOTSTRAP

echo ""
echo "=== k3s Control Plane Ready ==="
echo ""
echo "Join token:"
vagrant ssh "$CONTROL_VM" -- -T "sudo cat /var/lib/rancher/k3s/server/node-token" 2>/dev/null | tr -d '[:cntrl:]'
echo ""
echo "Next: bash scripts/k3s/join-agents.sh"
