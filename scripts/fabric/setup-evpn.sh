#!/usr/bin/env bash
# Configure the EVPN/VXLAN overlay data path on all 8 leaf VTEPs:
#   - VRF Tenant-A + symmetric L3VNI 10999 on every leaf (distributed GW)
#   - per-tenant L2VNI bridges + anycast SVIs (same IP+MAC on every leaf)
#   - enslave leaf overlay access NICs (eth-ovl/eth-ovl-b)
#   - deploy + seed the EVPN metrics collector
# L2VNIs: 10000 (tenant-a), 10001 (tenant-b); L3VNI: 10999 (VRF Tenant-A).
#
# `make up` runs `evpn` before `wire`, so on the first pass the server tnt0 NICs
# (and thus the leaf access NICs) do not exist yet; configure-evpn-vtep.sh is
# idempotent and the access-port enslave is finished by the `make overlay` re-run.
# Run: bash scripts/fabric/setup-evpn.sh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COLLECTOR_SCRIPT="$PROJECT_ROOT/scripts/fabric/evpn-metrics-collector.sh"
CONFIGURE_SCRIPT="$PROJECT_ROOT/scripts/fabric/configure-evpn-vtep.sh"

# --- EVPN constants (MUST MATCH topology.yml evpn.*) ---
VNI=10000                                  # primary L2VNI (tenant-a)
L3VNI=10999                                # symmetric IRB transit VNI
VRF=Tenant-A                               # tenant routing VRF
L3VLAN=999                                 # SVI VLAN for the L3VNI bridge
ANYCAST_MAC=00:00:5e:00:01:99              # identical anycast GW MAC on every leaf
# tenantspec = l2vni:vlan:gwcidr:sviname  (consumed by configure-evpn-vtep.sh)
TENANTS="10000:99:10.99.0.1/24:svi-vni10000 10001:98:10.99.1.1/24:svi-vni10001"

# Convergence gate: 20 tries x 6s = ~2 min ceiling (BGP keepalive is 30s).
CONVERGE_TRIES=20                          # * 6s ~= 2 min max wait
CONVERGE_INTERVAL=6

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

# Convergence gate: wait until the leaf has at least one Established L2VPN-EVPN
# BGP session before its VNI check, so status does not report "VNI not aware".
# Bounded retry; returns 1 on timeout (caller proceeds either way).
wait_for_evpn_convergence() {
    local leaf="$1"
    local try state
    for (( try=1; try<=CONVERGE_TRIES; try++ )); do
        # Count Established peers in the l2vpn evpn summary (JSON parsed in-VM).
        state=$(vagrant ssh "$leaf" -c "sudo vtysh -c 'show bgp l2vpn evpn summary json'" 2>/dev/null | \
            python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    peers=d.get('peers', d.get('default',{}).get('peers',{}))
    print(sum(1 for p in peers.values() if p.get('state','')=='Established'))
except Exception:
    print(0)
" 2>/dev/null || echo 0)
        state="${state//[^0-9]/}"; state="${state:-0}"
        if [ "$state" -ge 1 ]; then
            echo "  [converge] $leaf: $state EVPN peer(s) Established (try $try)"
            return 0
        fi
        echo "  [converge] $leaf: waiting for EVPN BGP sessions ($try/$CONVERGE_TRIES)..."
        sleep "$CONVERGE_INTERVAL"
    done
    echo "  [converge] WARNING: $leaf has no Established EVPN peer after ${CONVERGE_TRIES}x${CONVERGE_INTERVAL}s; proceeding anyway"
    return 1
}

# Configure each leaf VTEP sequentially (no stdin races)
for leaf in "${!LEAFS[@]}"; do
    loopback="${LEAFS[$leaf]}"
    echo ""
    echo "--- $leaf (VTEP: $loopback, L2VNI: $VNI, L3VNI: $L3VNI, VRF: $VRF) ---"

    # Upload the collector script FIRST (before the timer that references it)
    ( cat "$COLLECTOR_SCRIPT" | vagrant ssh "$leaf" -c "sudo bash -c 'cat > /usr/local/bin/evpn-metrics-collector.sh && chmod +x /usr/local/bin/evpn-metrics-collector.sh'" ) || \
        echo "  WARNING: failed to upload collector to $leaf"

    # Gate on BGP/EVPN convergence so the in-script VNI check is meaningful.
    # `|| true`: a convergence timeout (return 1) is non-fatal by design (set -e).
    wait_for_evpn_convergence "$leaf" || true

    # Configure VTEP: VRF + L3VNI + per-tenant L2VNI bridges + anycast SVIs +
    # access-NIC enslave; enables collector timer, restarts FRR last. Idempotent.
    ( vagrant ssh "$leaf" -c "sudo bash -s -- $loopback $VNI $L3VNI $VRF $L3VLAN $ANYCAST_MAC $TENANTS" < "$CONFIGURE_SCRIPT" )

    # Run collector once to seed initial metrics
    ( vagrant ssh "$leaf" -c "sudo /usr/local/bin/evpn-metrics-collector.sh" 2>/dev/null ) || true

    echo "  $leaf: VTEP + collector configured"
done

# Ping each member's anycast GW so the local leaf learns its MAC+IP and
# originates an EVPN Type-2 (MAC/IP) route. A member that never transmitted is
# unreachable to remote leaves, so inter-subnet (IRB) traffic to it fails until
# it speaks. On the pre-`wire` pass the tnt NICs do not exist yet (no-op),
# finished by the `make overlay` re-run.
# member -> space-separated "nic,gw" pairs (one per tenant NIC), matching
# topology.yml evpn.tenants[].members.
declare -A OVERLAY_MEMBERS=(
    [srv-1-1]="tnt0,10.99.0.1"
    [srv-2-1]="tnt0,10.99.0.1"
    [srv-3-1]="tnt0,10.99.0.1"
    [srv-4-1]="tnt0,10.99.0.1 tnt1,10.99.1.1"
)

# --- Generated overrides (single source of truth: topology.yml) ---
# Source generated params after the literals so they win when present; literals
# are the fallback. Re-declares VNI/L3VNI/VRF/L3VLAN/ANYCAST_MAC/TENANTS, LEAFS,
# OVERLAY_MEMBERS from evpn.*.
GEN_EVPN_PARAMS="$PROJECT_ROOT/generated/evpn/evpn-params.sh"
# shellcheck source=/dev/null
[ -f "$GEN_EVPN_PARAMS" ] && source "$GEN_EVPN_PARAMS"
echo ""
echo "--- finalizing overlay members (supernet route + GW announce) ---"
for srv in "${!OVERLAY_MEMBERS[@]}"; do
    kick=""
    for pair in ${OVERLAY_MEMBERS[$srv]}; do
        nic="${pair%%,*}"; gw="${pair#*,}"
        # Access ports are enslaved (carrier up): re-assert the overlay-supernet
        # route via the anycast GW (nexthop now on-link), then ping the GW so the
        # leaf learns this member's MAC+IP and originates an EVPN Type-2 route.
        kick+="ip route replace 10.99.0.0/16 via $gw dev $nic 2>/dev/null || true; ping -c1 -W2 $gw >/dev/null 2>&1 || true; "
    done
    ( vagrant ssh "$srv" -c "sudo bash -c '${kick}true'" 2>/dev/null && echo "  $srv finalized" ) || \
        echo "  $srv: overlay NIC not present yet (ok before 'make overlay')"
done

echo ""
echo "========================================"
echo " EVPN/VxLAN Overlay Configuration Complete"
echo "========================================"
echo "  L2VNIs:  10000 (tenant-a), 10001 (tenant-b)"
echo "  L3VNI:   $L3VNI  (VRF $VRF, distributed anycast GW $ANYCAST_MAC)"
echo "  VTEPs:   8 leaf switches"
echo "  Bridges: br-vni10000 / br-vni10001 / br-l3vni on each leaf"
echo ""
echo "Verify:"
echo "  vagrant ssh leaf-1a -c 'sudo vtysh -c \"show evpn vni\"'                       # 10000+10001 (L2) + 10999 (L3)"
echo "  vagrant ssh leaf-1a -c 'sudo vtysh -c \"show evpn mac vni 10000\"'             # local + remote server MACs"
echo "  vagrant ssh leaf-1a -c 'sudo vtysh -c \"show bgp l2vpn evpn route type macip\"'"
