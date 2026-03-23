#!/usr/bin/env bash
# ==========================================================================
# configure-evpn-vtep.sh — Configure VxLAN + EVPN metrics on a leaf VTEP
# ==========================================================================
# Called by setup-evpn.sh via: vagrant ssh <leaf> -c "sudo bash -s -- <args>" < this_script
#
# Args: loopback_ip vni
# ==========================================================================
set -e

LOOPBACK="$1"
VNI="$2"
VXLAN_IF="vxlan${VNI}"
BRIDGE_IF="br-vni${VNI}"

# --- Create VxLAN interface ---
if ! ip link show "$VXLAN_IF" &>/dev/null; then
    ip link add "$VXLAN_IF" type vxlan \
        id "$VNI" \
        local "$LOOPBACK" \
        dstport 4789 \
        nolearning
    echo "  Created $VXLAN_IF (VNI $VNI, source $LOOPBACK)"
else
    echo "  $VXLAN_IF already exists"
fi

# --- Create bridge for this VNI ---
if ! ip link show "$BRIDGE_IF" &>/dev/null; then
    ip link add "$BRIDGE_IF" type bridge
    echo 0 > "/sys/class/net/$BRIDGE_IF/bridge/stp_state"
    ip link set "$BRIDGE_IF" up
    echo "  Created $BRIDGE_IF (STP disabled)"
else
    echo "  $BRIDGE_IF already exists"
fi

# --- Attach VxLAN to bridge ---
current_master=$(ip -o link show "$VXLAN_IF" 2>/dev/null | grep -oP 'master \K\S+' || true)
if [ "$current_master" != "$BRIDGE_IF" ]; then
    ip link set "$VXLAN_IF" master "$BRIDGE_IF"
    echo "  Attached $VXLAN_IF to $BRIDGE_IF"
fi
ip link set "$VXLAN_IF" up

# --- Create systemd timer for EVPN metrics collector ---
mkdir -p /usr/local/bin

cat > /etc/systemd/system/evpn-metrics.service <<EOF
[Unit]
Description=Collect EVPN metrics for Prometheus
[Service]
Type=oneshot
ExecStart=/usr/local/bin/evpn-metrics-collector.sh
EOF

cat > /etc/systemd/system/evpn-metrics.timer <<EOF
[Unit]
Description=Run EVPN metrics collector every 15s
[Timer]
OnBootSec=10s
OnUnitActiveSec=15s
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now evpn-metrics.timer 2>/dev/null || true

# --- Verify FRR sees the VNI ---
echo "  FRR VNI status:"
vtysh -c "show evpn vni $VNI" 2>/dev/null | head -3 || echo "  (FRR not aware of VNI yet)"

echo "  VTEP $LOOPBACK configured for VNI $VNI"
