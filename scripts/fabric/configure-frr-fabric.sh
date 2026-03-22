#!/usr/bin/env bash
# ==========================================================================
# configure-frr-fabric.sh — Configure fabric interfaces inside an FRR VM
# ==========================================================================
# Called by setup-frr-links.sh via:
#   vagrant ssh <vm> -c "sudo bash -s -- <args>" < configure-frr-fabric.sh
#
# Args: loopback_ip mgmt_ip mac1 name1 ip1 prefix1 mac2 name2 ip2 prefix2 ...
#
# Variable-length: processes groups of 4 (mac, name, ip, prefix) after loopback+mgmt.
# Configures interfaces, loopback, mgmt NM profile, sysctls, NM profiles,
# restarts FRR + frr_exporter.
# ==========================================================================
set -uo pipefail

if [ $# -lt 6 ]; then
    echo "Usage: $0 loopback_ip mgmt_ip mac1 name1 ip1 prefix1 [mac2 name2 ip2 prefix2 ...]"
    exit 1
fi

LOOPBACK_IP="$1"
MGMT_IP="$2"
shift 2

echo "  Configuring FRR fabric: loopback=$LOOPBACK_IP mgmt=$MGMT_IP"

# --- Sysctls ---
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null

# Persist sysctls
cat > /etc/sysctl.d/99-netwatch-fabric.conf <<SYSEOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
SYSEOF

# --- Loopback IP ---
ip addr show lo | grep -q "${LOOPBACK_IP}/32" 2>/dev/null || \
    ip addr add "${LOOPBACK_IP}/32" dev lo

# NM profile for loopback persistence
mkdir -p /etc/NetworkManager/system-connections
cat > /etc/NetworkManager/system-connections/fabric-lo.nmconnection <<LOEOF
[connection]
id=fabric-lo
type=loopback
interface-name=lo
autoconnect=true

[ipv4]
method=manual
address1=${LOOPBACK_IP}/32
LOEOF
chmod 600 /etc/NetworkManager/system-connections/fabric-lo.nmconnection

# NM profile for mgmt interface (ens5) persistence
cat > /etc/NetworkManager/system-connections/mgmt-ens5.nmconnection <<MGMTEOF
[connection]
id=mgmt-ens5
type=ethernet
interface-name=ens5
autoconnect=true

[ipv4]
method=manual
address1=${MGMT_IP}/24

[ipv6]
method=disabled
MGMTEOF
chmod 600 /etc/NetworkManager/system-connections/mgmt-ens5.nmconnection

# --- Find interface by MAC address (compare lowercase) ---
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

# --- Process interface groups: mac name ip prefix ---
IFACE_COUNT=0
while [ $# -ge 4 ]; do
    MAC="$1"
    IFNAME="$2"
    IP="$3"
    PREFIX="$4"
    shift 4
    IFACE_COUNT=$((IFACE_COUNT + 1))

    # Find the actual interface by MAC (may already be renamed by udev)
    IF_ACTUAL=$(find_if_by_mac "$MAC") || {
        echo "  WARNING: no interface with MAC $MAC (expected $IFNAME) -- NIC not yet attached?"
        continue
    }

    # Configure IP
    ip addr flush dev "$IF_ACTUAL" 2>/dev/null || true
    ip addr add "${IP}/${PREFIX}" dev "$IF_ACTUAL"
    ip link set "$IF_ACTUAL" up

    # Enable loose RPF on this interface
    sysctl -w "net.ipv4.conf.${IF_ACTUAL}.rp_filter=2" >/dev/null 2>&1 || true

    echo "  $IF_ACTUAL ($IFNAME) = ${IP}/${PREFIX} [MAC: $MAC]"

    # NM profile for persistence
    cat > "/etc/NetworkManager/system-connections/fabric-${IFNAME}.nmconnection" <<NMEOF
[connection]
id=fabric-${IFNAME}
type=ethernet
interface-name=${IF_ACTUAL}
autoconnect=true

[ethernet]
mac-address=${MAC}

[ipv4]
method=manual
address1=${IP}/${PREFIX}

[ipv6]
method=disabled
NMEOF
    chmod 600 "/etc/NetworkManager/system-connections/fabric-${IFNAME}.nmconnection"
done

# Reload NM to pick up new profiles
nmcli connection reload 2>/dev/null || true

# --- Restart FRR ---
echo "  Restarting FRR..."
systemctl restart frr

# --- Restart frr_exporter ---
systemctl restart frr_exporter 2>/dev/null || true

echo "  Done: $IFACE_COUNT fabric interfaces configured, FRR restarted"
