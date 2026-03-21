#!/usr/bin/env bash
# ==========================================================================
# configure-vm-fabric.sh — Configure fabric interfaces inside a VM
# ==========================================================================
# Called by setup-server-links.sh via: vagrant ssh <vm> -c "sudo bash /tmp/configure-vm-fabric.sh <args>"
#
# Args: mac_a ip_a gw_a mac_b ip_b gw_b prefix [--no-default-route]
# ==========================================================================
set -e

mac_a="$1"
ip_a="$2"
gw_a="$3"
mac_b="$4"
ip_b="$5"
gw_b="$6"
prefix="$7"
no_default="${8:-}"

# Find interface by MAC address (compare lowercase)
find_if_by_mac() {
    local target_mac="$(echo $1 | tr '[:upper:]' '[:lower:]')"
    for iface in /sys/class/net/*; do
        iname=$(basename "$iface")
        [ "$iname" = "lo" ] && continue
        mac=$(cat "$iface/address" 2>/dev/null || true)
        if [ "$mac" = "$target_mac" ]; then
            echo "$iname"
            return 0
        fi
    done
    return 1
}

IF_A=$(find_if_by_mac "$mac_a") || { echo "ERROR: no interface with MAC $mac_a"; exit 1; }
IF_B=$(find_if_by_mac "$mac_b") || { echo "ERROR: no interface with MAC $mac_b"; exit 1; }

# Configure interfaces
ip addr flush dev $IF_A 2>/dev/null || true
ip addr add ${ip_a}/${prefix} dev $IF_A
ip link set $IF_A up

ip addr flush dev $IF_B 2>/dev/null || true
ip addr add ${ip_b}/${prefix} dev $IF_B
ip link set $IF_B up

# ECMP routes for fabric prefixes
ip route replace 10.0.0.0/8 \
    nexthop via ${gw_a} dev $IF_A weight 1 \
    nexthop via ${gw_b} dev $IF_B weight 1
ip route replace 172.16.0.0/12 \
    nexthop via ${gw_a} dev $IF_A weight 1 \
    nexthop via ${gw_b} dev $IF_B weight 1

# Replace default route with ECMP through fabric (north-south path)
if [ "$no_default" != "--no-default-route" ]; then
    ip route replace default \
        nexthop via ${gw_a} dev $IF_A weight 1 \
        nexthop via ${gw_b} dev $IF_B weight 1
fi

echo "  $IF_A = ${ip_a}/${prefix} -> gw ${gw_a}"
echo "  $IF_B = ${ip_b}/${prefix} -> gw ${gw_b}"
