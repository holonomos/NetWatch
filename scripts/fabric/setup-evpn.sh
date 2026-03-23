#!/usr/bin/env bash
# ==========================================================================
# setup-evpn.sh — Configure EVPN/VxLAN overlay on leaf VTEPs
# ==========================================================================
# Creates VxLAN interfaces and bridges on all 8 leaf VMs.
# Each leaf becomes a VTEP sourcing VxLAN from its loopback IP.
# Also deploys the EVPN metrics collector for Prometheus.
#
# VNI 100: shared L2 domain across all racks
#
# Prerequisites:
#   - All leaf VMs running with fabric interfaces configured
#   - BGP EVPN sessions established
#   - Leaf loopbacks reachable
#
# Run as your user: bash scripts/fabric/setup-evpn.sh
# ==========================================================================
set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# MUST MATCH topology.yml evpn.vni_base
VNI=10000
COLLECTOR_SCRIPT="$PROJECT_ROOT/scripts/fabric/evpn-metrics-collector.sh"
CONFIGURE_SCRIPT="$PROJECT_ROOT/scripts/fabric/configure-evpn-vtep.sh"

echo "========================================"
echo " NetWatch: Configuring EVPN/VxLAN Overlay"
echo "========================================"

# Leaf VTEP definitions: name loopback_ip
# MUST MATCH topology.yml nodes.leafs[].loopback (without /32 suffix)
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

# Configure each leaf VTEP sequentially (no stdin races)
for leaf in "${!LEAFS[@]}"; do
    loopback="${LEAFS[$leaf]}"
    echo ""
    echo "--- $leaf (VTEP: $loopback, VNI: $VNI) ---"

    # Upload the collector script FIRST (before the timer that references it)
    ( cat "$COLLECTOR_SCRIPT" | vagrant ssh "$leaf" -c "sudo bash -c 'cat > /usr/local/bin/evpn-metrics-collector.sh && chmod +x /usr/local/bin/evpn-metrics-collector.sh'" ) || \
        echo "  WARNING: failed to upload collector to $leaf"

    # Configure VTEP (creates VxLAN, bridge, enables systemd timer for collector)
    ( vagrant ssh "$leaf" -c "sudo bash -s -- $loopback $VNI" < "$CONFIGURE_SCRIPT" )

    # Run collector once to seed initial metrics
    ( vagrant ssh "$leaf" -c "sudo /usr/local/bin/evpn-metrics-collector.sh" 2>/dev/null ) || true

    echo "  $leaf: VTEP + collector configured"
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
