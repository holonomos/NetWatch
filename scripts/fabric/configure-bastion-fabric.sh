#!/usr/bin/env bash
# ==========================================================================
# configure-bastion-fabric.sh — Configure bastion's fabric interfaces + NAT
# ==========================================================================
# Called by setup-server-links.sh via:
#   vagrant ssh bastion -c "sudo bash -s -- <args>" < this_script
#
# Args: mac_a ip_a gw_a mac_b ip_b gw_b prefix
# ==========================================================================
set -euo pipefail

mac_a="$1"
ip_a="$2"
gw_a="$3"
mac_b="$4"
ip_b="$5"
gw_b="$6"
prefix="$7"

# Find interface by MAC address
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

IF_A=$(find_if_by_mac "$mac_a") || { echo "ERROR: no interface with MAC $mac_a"; exit 1; }
IF_B=$(find_if_by_mac "$mac_b") || { echo "ERROR: no interface with MAC $mac_b"; exit 1; }

# Configure fabric interfaces
ip addr flush dev "$IF_A" 2>/dev/null || true
ip addr add "${ip_a}/${prefix}" dev "$IF_A"
ip link set "$IF_A" up

ip addr flush dev "$IF_B" 2>/dev/null || true
ip addr add "${ip_b}/${prefix}" dev "$IF_B"
ip link set "$IF_B" up

# ECMP routes for fabric prefixes (no default route — bastion keeps its own)
# Retry up to 5 times — nexthop ARP resolution may fail if borders haven't
# responded yet on newly-attached interfaces.
for attempt in $(seq 1 5); do
    if ip route replace 10.0.0.0/8 \
        nexthop via "${gw_a}" dev "$IF_A" weight 1 \
        nexthop via "${gw_b}" dev "$IF_B" weight 1 2>/dev/null && \
       ip route replace 172.16.0.0/12 \
        nexthop via "${gw_a}" dev "$IF_A" weight 1 \
        nexthop via "${gw_b}" dev "$IF_B" weight 1 2>/dev/null; then
        echo "  ECMP routes applied (attempt $attempt)"
        break
    fi
    echo "  Route apply failed (attempt $attempt/5) — waiting for ARP..."
    sleep 2
done

echo "  $IF_A = ${ip_a}/${prefix} -> gw ${gw_a}"
echo "  $IF_B = ${ip_b}/${prefix} -> gw ${gw_b}"

# NAT masquerade for fabric source IPs
INET_IF=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
if [ -n "$INET_IF" ]; then
    iptables -t nat -D POSTROUTING -s 10.0.0.0/8 -o "$INET_IF" -j MASQUERADE 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s 172.16.0.0/12 -o "$INET_IF" -j MASQUERADE 2>/dev/null || true
    iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -o "$INET_IF" -j MASQUERADE
    iptables -t nat -A POSTROUTING -s 172.16.0.0/12 -o "$INET_IF" -j MASQUERADE
    iptables -t nat -C POSTROUTING -s 192.168.0.0/24 -o "$INET_IF" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -s 192.168.0.0/24 -o "$INET_IF" -j MASQUERADE
    iptables-save > /etc/sysconfig/iptables
    echo "  NAT masquerade on $INET_IF for 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/24"
else
    echo "WARNING: No internet-facing interface found. NAT not configured."
fi

# NM profiles for persistence
mkdir -p /etc/NetworkManager/system-connections
cat > "/etc/NetworkManager/system-connections/fabric-${IF_A}.nmconnection" <<NMEOF
[connection]
id=fabric-${IF_A}
type=ethernet
interface-name=${IF_A}
autoconnect=true

[ipv4]
method=manual
address1=${ip_a}/${prefix}

[ipv6]
method=disabled
NMEOF
chmod 600 "/etc/NetworkManager/system-connections/fabric-${IF_A}.nmconnection"

cat > "/etc/NetworkManager/system-connections/fabric-${IF_B}.nmconnection" <<NMEOF
[connection]
id=fabric-${IF_B}
type=ethernet
interface-name=${IF_B}
autoconnect=true

[ipv4]
method=manual
address1=${ip_b}/${prefix}

[ipv6]
method=disabled
NMEOF
chmod 600 "/etc/NetworkManager/system-connections/fabric-${IF_B}.nmconnection"

nmcli connection reload 2>/dev/null || true
echo "  Bastion fabric configured (IPs + NAT + NM persistence)"
