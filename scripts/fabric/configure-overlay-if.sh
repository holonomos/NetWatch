#!/usr/bin/env bash
# ==========================================================================
# configure-overlay-if.sh — Configure a server's EVPN overlay access NIC
# ==========================================================================
# Called by setup-server-links.sh via:
#   vagrant ssh <server> -c "sudo bash -s -- <mac> <ip_cidr> <ifname>" < this
#
# Configures ONE additional tenant-overlay NIC (tnt0 / tnt1) on a member
# server. The NIC is given ONLY its tenant /24 via NetworkManager
# method=manual — NO gateway, NO routes — so it can NEVER perturb the /30
# ECMP underlay (10.0.0.0/8, 172.16.0.0/12, default) the server already has
# on its two fabric NICs. MTU is set to 1450 to leave 50 B of VXLAN headroom.
#
# Args: <mac> <ip_cidr> <ifname>
#   e.g. 02:4E:57:07:01:01 10.99.0.11/24 tnt0
#
# Idempotent: safe to re-run (rename is skipped if the NIC is already named,
# the address is flushed-then-set, and the NM keyfile is overwritten).
# ==========================================================================
set -euo pipefail

MAC="${1:?usage: configure-overlay-if.sh <mac> <ip_cidr> <ifname>}"
IP_CIDR="${2:?missing ip_cidr (e.g. 10.99.0.11/24)}"
IFNAME="${3:?missing ifname (e.g. tnt0)}"

# Find interface by MAC address (compare lowercase) — same idiom as
# configure-vm-fabric.sh. Matches either the as-delivered NIC or, on a
# re-run, the already-renamed overlay NIC.
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

# Rename to the stable overlay name (skip if already correct — idempotent).
if [ "$IF" != "$IFNAME" ]; then
    ip link set "$IF" down
    ip link set "$IF" name "$IFNAME"
fi
ip link set "$IFNAME" up

# Assign ONLY the tenant /24 — no gateway, no routes (underlay isolation).
ip addr flush dev "$IFNAME" 2>/dev/null || true
ip addr add "$IP_CIDR" dev "$IFNAME"

# VXLAN headroom: 1500 - 50 B (outer IP/UDP/VXLAN) = 1450.
ip link set "$IFNAME" mtu 1450

# --- Inter-subnet reachability (EVPN symmetric IRB) --------------------------
# Route ONLY the overlay supernet (10.99.0.0/16) to this tenant's distributed
# anycast gateway (the .1 of our /24 — an SVI on the local leaf). Our own /24
# stays a connected route, so same-subnet traffic remains pure L2 over VXLAN;
# only OTHER tenant subnets go via the GW, which routes them over the L3VNI.
# This adds 10.99.0.0/16 ONLY — it never touches the /30 ECMP underlay
# (10.0.0.0/8, 172.16.0.0/12, default) the server carries on its fabric NICs.
GW="${IP_CIDR%.*}.1"
OVERLAY_SUPERNET="${IP_CIDR%.*.*}.0.0/16"
# This runs during `make wire`, BEFORE `make overlay` enslaves the leaf access
# port — so tnt0 may have NO CARRIER yet, the connected /24 is not installed,
# and the gateway is not-yet-on-link ("Nexthop has invalid gateway"). So the
# immediate add is best-effort: the route is persisted in the NM keyfile
# (route1, applied when the link gains carrier) and setup-evpn.sh re-asserts it
# after the access ports are enslaved. Never abort the wire on it.
ip route replace "$OVERLAY_SUPERNET" via "$GW" dev "$IFNAME" 2>/dev/null || true

echo "  $IFNAME = ${IP_CIDR} (mac $MAC, mtu 1450); $OVERLAY_SUPERNET via $GW (IRB; underlay untouched)"

# ==========================================================================
# IP persistence — NetworkManager keyfile (method=manual, NO gateway/routes)
# ==========================================================================
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

# Reload NM to pick up the new profile (does not bounce the underlay NICs).
nmcli connection reload 2>/dev/null || true

echo "  NM profile written: overlay-${IFNAME} (tenant /24 only)"
