#!/usr/bin/env bash
# ==========================================================================
# configure-vm-fabric.sh — Configure fabric interfaces inside a VM
# ==========================================================================
# Called by setup-server-links.sh via: vagrant ssh <vm> -c "sudo bash /tmp/configure-vm-fabric.sh <args>"
#
# Args: mac_a ip_a gw_a mac_b ip_b gw_b prefix [--no-default-route] [loopback_ip]
#
# IP persistence: writes NM keyfiles for each fabric interface and an
# ECMP dispatcher script so routes survive reboots.
# ==========================================================================
set -euo pipefail

mac_a="$1"
ip_a="$2"
gw_a="$3"
mac_b="$4"
ip_b="$5"
gw_b="$6"
prefix="$7"
no_default="${8:-}"
loopback="${9:-}"

# If arg 8 is not --no-default-route, it might be the loopback
if [ -n "$no_default" ] && [ "$no_default" != "--no-default-route" ]; then
    loopback="$no_default"
    no_default=""
fi

# Find interface by MAC address (compare lowercase)
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

# Configure interfaces
ip addr flush dev "$IF_A" 2>/dev/null || true
ip addr add "${ip_a}/${prefix}" dev "$IF_A"
ip link set "$IF_A" up

ip addr flush dev "$IF_B" 2>/dev/null || true
ip addr add "${ip_b}/${prefix}" dev "$IF_B"
ip link set "$IF_B" up

# ECMP routes for fabric prefixes
ip route replace 10.0.0.0/8 \
    nexthop via "${gw_a}" dev "$IF_A" weight 1 \
    nexthop via "${gw_b}" dev "$IF_B" weight 1
ip route replace 172.16.0.0/12 \
    nexthop via "${gw_a}" dev "$IF_A" weight 1 \
    nexthop via "${gw_b}" dev "$IF_B" weight 1

# Replace default route with ECMP through fabric (north-south path)
if [ "$no_default" != "--no-default-route" ]; then
    ip route replace default \
        nexthop via "${gw_a}" dev "$IF_A" weight 1 \
        nexthop via "${gw_b}" dev "$IF_B" weight 1
fi

echo "  $IF_A = ${ip_a}/${prefix} -> gw ${gw_a}"
echo "  $IF_B = ${ip_b}/${prefix} -> gw ${gw_b}"

# --- Loopback IP (server identity, reachable via fabric) ---
if [ -n "$loopback" ]; then
    ip addr show lo | grep -q "${loopback}/32" 2>/dev/null || \
        ip addr add "${loopback}/32" dev lo
    echo "  lo = ${loopback}/32"
fi

# ==========================================================================
# IP Persistence — NM keyfiles + ECMP dispatcher
# ==========================================================================
# NM keyfiles persist the IP assignments across reboots.
# ECMP routes are applied by a dispatcher script because NM does not
# natively support multi-nexthop ECMP routes.
# ==========================================================================

mkdir -p /etc/NetworkManager/system-connections

# --- NM profile for fabric interface A ---
cat > "/etc/NetworkManager/system-connections/fabric-${IF_A}.nmconnection" <<NMEOF
[connection]
id=fabric-${IF_A}
type=ethernet
interface-name=${IF_A}
autoconnect=true

[ethernet]
mac-address=${mac_a}

[ipv4]
method=manual
address1=${ip_a}/${prefix}

[ipv6]
method=disabled
NMEOF
chmod 600 "/etc/NetworkManager/system-connections/fabric-${IF_A}.nmconnection"

# --- NM profile for fabric interface B ---
cat > "/etc/NetworkManager/system-connections/fabric-${IF_B}.nmconnection" <<NMEOF
[connection]
id=fabric-${IF_B}
type=ethernet
interface-name=${IF_B}
autoconnect=true

[ethernet]
mac-address=${mac_b}

[ipv4]
method=manual
address1=${ip_b}/${prefix}

[ipv6]
method=disabled
NMEOF
chmod 600 "/etc/NetworkManager/system-connections/fabric-${IF_B}.nmconnection"

# --- NM profile for loopback (if provided) ---
if [ -n "$loopback" ]; then
    cat > /etc/NetworkManager/system-connections/fabric-lo.nmconnection <<LOEOF
[connection]
id=fabric-lo
type=loopback
interface-name=lo
autoconnect=true

[ipv4]
method=manual
address1=${loopback}/32
LOEOF
    chmod 600 /etc/NetworkManager/system-connections/fabric-lo.nmconnection
fi

# --- ECMP dispatcher script ---
# NetworkManager dispatcher runs scripts in /etc/NetworkManager/dispatcher.d/
# when interface state changes. We use this to re-apply ECMP routes after
# both fabric interfaces are up. The script is idempotent.
#
# Uses MAC-based interface lookup so routes survive interface renumbering
# across reboots (kernel may assign different ens* names after hot-plug).
mkdir -p /etc/NetworkManager/dispatcher.d
cat > /etc/NetworkManager/dispatcher.d/99-netwatch-ecmp <<'DISPEOF'
#!/usr/bin/env bash
# NetWatch ECMP route dispatcher — re-apply multi-nexthop routes on interface up
# Called by NetworkManager: $1=interface $2=action
[ "$2" = "up" ] || exit 0

# Only act on fabric interfaces (NM connection IDs starting with "fabric-")
CONN_ID=$(nmcli -t -f GENERAL.CONNECTION device show "$1" 2>/dev/null | cut -d: -f2)
case "$CONN_ID" in
    fabric-*) ;;
    *) exit 0 ;;
esac

# Resolve interface names by MAC (survives renumbering across reboots)
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

DISPEOF

# Append MAC constants and route logic (not quoted — we want variable expansion)
cat >> /etc/NetworkManager/dispatcher.d/99-netwatch-ecmp <<DISPEOF

# MACs for fabric interfaces (stable across reboots)
MAC_A="${mac_a}"
MAC_B="${mac_b}"

# Wait briefly for both interfaces to be ready
sleep 1

DEV_A=\$(find_if_by_mac "\$MAC_A") || exit 0
DEV_B=\$(find_if_by_mac "\$MAC_B") || exit 0

# ECMP routes for fabric prefixes
ip route replace 10.0.0.0/8 \\
    nexthop via ${gw_a} dev \$DEV_A weight 1 \\
    nexthop via ${gw_b} dev \$DEV_B weight 1 2>/dev/null || true
ip route replace 172.16.0.0/12 \\
    nexthop via ${gw_a} dev \$DEV_A weight 1 \\
    nexthop via ${gw_b} dev \$DEV_B weight 1 2>/dev/null || true
DISPEOF

# Add default route ECMP if applicable
if [ "$no_default" != "--no-default-route" ]; then
    cat >> /etc/NetworkManager/dispatcher.d/99-netwatch-ecmp <<DISPEOF
ip route replace default \\
    nexthop via ${gw_a} dev \$DEV_A weight 1 \\
    nexthop via ${gw_b} dev \$DEV_B weight 1 2>/dev/null || true
DISPEOF
fi

chmod 755 /etc/NetworkManager/dispatcher.d/99-netwatch-ecmp

# Reload NM to pick up new profiles
nmcli connection reload 2>/dev/null || true

echo "  NM profiles written: fabric-${IF_A}, fabric-${IF_B}${loopback:+, fabric-lo}"
echo "  ECMP dispatcher: /etc/NetworkManager/dispatcher.d/99-netwatch-ecmp"
