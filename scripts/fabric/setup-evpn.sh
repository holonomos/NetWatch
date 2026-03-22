#!/usr/bin/env bash
# ==========================================================================
# setup-evpn.sh — Configure EVPN/VxLAN overlay on leaf VTEPs
# ==========================================================================
# Creates VxLAN interfaces and bridges on all 8 leaf VMs.
# Each leaf becomes a VTEP sourcing VxLAN from its loopback IP.
#
# VNI 100: shared L2 domain across all racks (for k3s pod networking, etc.)
#
# Prerequisites:
#   - All leaf VMs running with fabric interfaces configured
#   - BGP EVPN sessions established (show bgp l2vpn evpn summary)
#   - Leaf loopbacks reachable from all other leafs
#
# Run as your user: bash scripts/fabric/setup-evpn.sh
# ==========================================================================
set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VNI=100

echo "========================================"
echo " NetWatch: Configuring EVPN/VxLAN Overlay"
echo "========================================"

# Leaf VTEP definitions: name loopback_ip
declare -A LEAFS=(
    [leaf-1a]=10.0.3.1
    [leaf-1b]=10.0.3.2
    [leaf-2a]=10.0.3.3
    [leaf-2b]=10.0.3.4
    [leaf-3a]=10.0.3.5
    [leaf-3b]=10.0.3.6
    [leaf-4a]=10.0.3.7
    [leaf-4b]=10.0.3.8
)

configure_vtep() {
    local leaf="$1"
    local loopback="$2"
    local vni="$3"

    echo ""
    echo "--- $leaf (VTEP: $loopback, VNI: $vni) ---"

    cd "$PROJECT_ROOT"
    vagrant ssh "$leaf" -c "sudo bash -s -- $loopback $vni" <<'VTEPSCRIPT'
set -e
LOOPBACK="$1"
VNI="$2"
VXLAN_IF="vxlan${VNI}"
BRIDGE_IF="br-vni${VNI}"

# Create VxLAN interface
# - id: VNI number
# - local: source IP (leaf loopback)
# - dstport: standard VxLAN port
# - nolearning: let EVPN handle MAC learning via BGP, not data-plane flooding
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

# Create bridge for this VNI
if ! ip link show "$BRIDGE_IF" &>/dev/null; then
    ip link add "$BRIDGE_IF" type bridge
    ip link set "$BRIDGE_IF" up
    echo "  Created $BRIDGE_IF"
else
    echo "  $BRIDGE_IF already exists"
fi

# Attach VxLAN interface to bridge
if ! ip link show "$VXLAN_IF" | grep -q "master $BRIDGE_IF"; then
    ip link set "$VXLAN_IF" master "$BRIDGE_IF"
    echo "  Attached $VXLAN_IF to $BRIDGE_IF"
fi
ip link set "$VXLAN_IF" up

# Verify FRR sees the VNI
echo "  FRR VNI status:"
vtysh -c "show evpn vni $VNI" 2>/dev/null | head -5 || echo "  (FRR not aware of VNI yet — will detect on next scan)"

echo "  VTEP $LOOPBACK configured for VNI $VNI"
VTEPSCRIPT
}

# Configure all 8 leaf VTEPs
for leaf in "${!LEAFS[@]}"; do
    configure_vtep "$leaf" "${LEAFS[$leaf]}" "$VNI"
done

echo ""
echo "========================================"
echo " EVPN/VxLAN Overlay Configuration Complete"
echo "========================================"
echo "  VNI:    $VNI"
echo "  VTEPs:  8 leaf switches"
echo "  Bridge: br-vni${VNI} on each leaf"
echo ""
echo "Verify:"
echo "  vagrant ssh leaf-1a -c 'sudo vtysh -c \"show evpn vni\"'"
echo "  vagrant ssh leaf-1a -c 'sudo vtysh -c \"show bgp l2vpn evpn route\"'"
echo "  vagrant ssh spine-1 -c 'sudo vtysh -c \"show bgp l2vpn evpn summary\"'"
