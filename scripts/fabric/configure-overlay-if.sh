#!/usr/bin/env bash
# Configure one tenant-overlay NIC (tnt0/tnt1) on a member server.
# Called by setup-server-links.sh: ssh <server> -c "sudo bash -s -- <mac> <ip_cidr> <ifname>" < this
# Assigns only the tenant /24 (no gateway) so it can't perturb the ECMP underlay
# on the fabric NICs. MTU 1450 leaves 50 B of VXLAN headroom. Idempotent.
set -euo pipefail

MAC="${1:?usage: configure-overlay-if.sh <mac> <ip_cidr> <ifname> [gw] [overlay_supernet]}"
IP_CIDR="${2:?missing ip_cidr (e.g. 10.99.0.11/24)}"
IFNAME="${3:?missing ifname (e.g. tnt0)}"
# Optional anycast GW + overlay supernet from topology.yml; fall back to
# /24 arithmetic below when absent (correct for the all-/24 tenants).
GW_ARG="${4:-}"
SUPERNET_ARG="${5:-}"

# Find interface by MAC (lowercase compare). Matches the as-delivered NIC or,
# on a re-run, the already-renamed overlay NIC.
find_if_by_mac() {
    local target_mac
    target_mac="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
    for iface in /sys/class/net/*; do
        local iname
        iname=$(basename "$iface")
        [ "$iname" = "lo" ] && continue
        local mac
        mac=$(cat "$iface/address" 2>/dev/null || true)
        if [ "$mac" = "$target_mac" ]; then
            echo "$iname"
            return 0
        fi
    done
    return 1
}

IF=$(find_if_by_mac "$MAC") || { echo "ERROR: no interface with MAC $MAC"; exit 1; }

# Rename to the stable overlay name (skip if already correct).
if [ "$IF" != "$IFNAME" ]; then
    ip link set "$IF" down
    ip link set "$IF" name "$IFNAME"
fi
ip link set "$IFNAME" up

# Assign ONLY the tenant /24, no gateway, no routes (underlay isolation).
ip addr flush dev "$IFNAME" 2>/dev/null || true
ip addr add "$IP_CIDR" dev "$IFNAME"

# VXLAN headroom: 1500 - 50 B (outer IP/UDP/VXLAN) = 1450.
ip link set "$IFNAME" mtu 1450

# Inter-subnet reachability (EVPN symmetric IRB): route only the overlay supernet
# (10.99.0.0/16) via this tenant's anycast GW (.1 of the /24, an SVI on the local
# leaf). The local /24 stays connected, so same-subnet stays pure L2 over VXLAN;
# other tenant subnets route over the L3VNI. Never touches the ECMP underlay.
GW="${GW_ARG:-${IP_CIDR%.*}.1}"
OVERLAY_SUPERNET="${SUPERNET_ARG:-${IP_CIDR%.*.*}.0.0/16}"
# Leaf access port may not be enslaved yet: tnt0 can lack carrier and the gateway
# is not on-link, so this add can fail. The route is persisted in the NM keyfile
# (route1) and applied when the link gains carrier. Don't abort.
ip route replace "$OVERLAY_SUPERNET" via "$GW" dev "$IFNAME" 2>/dev/null || true

echo "  $IFNAME = ${IP_CIDR} (mac $MAC, mtu 1450); $OVERLAY_SUPERNET via $GW (IRB; underlay untouched)"

# IP persistence: NetworkManager keyfile (method=manual, supernet route only).
mkdir -p /etc/NetworkManager/system-connections

cat > "/etc/NetworkManager/system-connections/overlay-${IFNAME}.nmconnection" <<NMEOF
[connection]
id=overlay-${IFNAME}
type=ethernet
interface-name=${IFNAME}
autoconnect=true

[ethernet]
mac-address=${MAC}
mtu=1450

[ipv4]
method=manual
address1=${IP_CIDR}
route1=${OVERLAY_SUPERNET},${GW}

[ipv6]
method=disabled
NMEOF
chmod 600 "/etc/NetworkManager/system-connections/overlay-${IFNAME}.nmconnection"

# Reload NM to pick up the new profile (underlay NICs unaffected).
nmcli connection reload 2>/dev/null || true

echo "  NM profile written: overlay-${IFNAME} (tenant /24 only)"
