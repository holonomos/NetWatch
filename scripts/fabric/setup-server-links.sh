#!/bin/bash
# NetWatch — Server Fabric Wiring
# Generated from topology.yml — DO NOT HAND-EDIT
#
# Hot-plugs two fabric NICs into each server VM (via virsh),
# then configures IPs and ECMP default routes inside the VMs.
#
# Prerequisites: VMs running (vagrant up), fabric bridges exist (setup-bridges.sh).
# Run as your user (NOT sudo): bash scripts/fabric/setup-server-links.sh
# (uses sudo internally for virsh commands only)

set -uo pipefail

VIRSH_PREFIX="NetWatch"
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "NetWatch: Wiring server VMs to fabric bridges..."

# Helper: attach a NIC to a VM on a given bridge (idempotent)
attach_nic() {
    local vm="$1"
    local bridge="$2"
    local mac="$3"
    local domain="${VIRSH_PREFIX}_${vm}"

    if virsh -c qemu:///system domiflist "$domain" 2>/dev/null | grep -q "$mac"; then
        echo "    $bridge ($mac): already attached"
        return 0
    fi

    virsh -c qemu:///system attach-interface "$domain" \
        --type bridge \
        --source "$bridge" \
        --model virtio \
        --mac "$mac" \
        --live \
        --config
    echo "    $bridge ($mac): attached"
}

# Helper: configure interfaces inside VM by MAC address
configure_vm() {
    local vm="$1"
    local mgmt_ip="$2"
    local mac_a="$3"
    local ip_a="$4"
    local gw_a="$5"
    local mac_b="$6"
    local ip_b="$7"
    local gw_b="$8"
    local prefix="$9"

    # Use vagrant ssh-config to get the correct key and port
    cd "$PROJECT_ROOT"
    vagrant ssh "$vm" -c "sudo bash -s" <<REMOTESCRIPT
set -e

# Find interface by MAC address (compare lowercase)
find_if_by_mac() {
    local target_mac="\$(echo \$1 | tr '[:upper:]' '[:lower:]')"
    for iface in /sys/class/net/*; do
        iname=\$(basename "\$iface")
        [ "\$iname" = "lo" ] && continue
        mac=\$(cat "\$iface/address" 2>/dev/null || true)
        if [ "\$mac" = "\$target_mac" ]; then
            echo "\$iname"
            return 0
        fi
    done
    return 1
}

IF_A=\$(find_if_by_mac "$mac_a") || { echo "ERROR: no interface with MAC $mac_a"; exit 1; }
IF_B=\$(find_if_by_mac "$mac_b") || { echo "ERROR: no interface with MAC $mac_b"; exit 1; }

# Configure leaf-a interface
sudo ip addr flush dev \$IF_A 2>/dev/null || true
sudo ip addr add ${ip_a}/${prefix} dev \$IF_A
sudo ip link set \$IF_A up

# Configure leaf-b interface
sudo ip addr flush dev \$IF_B 2>/dev/null || true
sudo ip addr add ${ip_b}/${prefix} dev \$IF_B
sudo ip link set \$IF_B up

# ECMP routes for fabric prefixes (don't touch default — NetworkManager owns it)
sudo ip route replace 10.0.0.0/8 \
    nexthop via ${gw_a} dev \$IF_A weight 1 \
    nexthop via ${gw_b} dev \$IF_B weight 1
sudo ip route replace 172.16.0.0/12 \
    nexthop via ${gw_a} dev \$IF_A weight 1 \
    nexthop via ${gw_b} dev \$IF_B weight 1

echo "  \$IF_A = ${ip_a}/${prefix} → gw ${gw_a}"
echo "  \$IF_B = ${ip_b}/${prefix} → gw ${gw_b}"
echo "  ECMP fabric routes installed (10.0.0.0/8, 172.16.0.0/12)"
REMOTESCRIPT
}

# --- Wire each server ---
echo ""
echo "srv-1-1: br020 (leaf-1a) + br021 (leaf-1b)"
attach_nic "srv-1-1" "br020" "02:4E:57:06:01:01"
attach_nic "srv-1-1" "br021" "02:4E:57:06:01:02"
configure_vm "srv-1-1" "192.168.0.50" \
    "02:4E:57:06:01:01" "172.16.3.2" "172.16.3.1" \
    "02:4E:57:06:01:02" "172.16.3.6" "172.16.3.5" \
    "30"
echo ""
echo "srv-1-2: br022 (leaf-1a) + br023 (leaf-1b)"
attach_nic "srv-1-2" "br022" "02:4E:57:06:02:01"
attach_nic "srv-1-2" "br023" "02:4E:57:06:02:02"
configure_vm "srv-1-2" "192.168.0.51" \
    "02:4E:57:06:02:01" "172.16.3.10" "172.16.3.9" \
    "02:4E:57:06:02:02" "172.16.3.14" "172.16.3.13" \
    "30"
echo ""
echo "srv-1-3: br024 (leaf-1a) + br025 (leaf-1b)"
attach_nic "srv-1-3" "br024" "02:4E:57:06:03:01"
attach_nic "srv-1-3" "br025" "02:4E:57:06:03:02"
configure_vm "srv-1-3" "192.168.0.52" \
    "02:4E:57:06:03:01" "172.16.3.18" "172.16.3.17" \
    "02:4E:57:06:03:02" "172.16.3.22" "172.16.3.21" \
    "30"
echo ""
echo "srv-1-4: br026 (leaf-1a) + br027 (leaf-1b)"
attach_nic "srv-1-4" "br026" "02:4E:57:06:04:01"
attach_nic "srv-1-4" "br027" "02:4E:57:06:04:02"
configure_vm "srv-1-4" "192.168.0.53" \
    "02:4E:57:06:04:01" "172.16.3.26" "172.16.3.25" \
    "02:4E:57:06:04:02" "172.16.3.30" "172.16.3.29" \
    "30"
echo ""
echo "srv-2-1: br028 (leaf-2a) + br029 (leaf-2b)"
attach_nic "srv-2-1" "br028" "02:4E:57:06:05:01"
attach_nic "srv-2-1" "br029" "02:4E:57:06:05:02"
configure_vm "srv-2-1" "192.168.0.54" \
    "02:4E:57:06:05:01" "172.16.4.2" "172.16.4.1" \
    "02:4E:57:06:05:02" "172.16.4.6" "172.16.4.5" \
    "30"
echo ""
echo "srv-2-2: br030 (leaf-2a) + br031 (leaf-2b)"
attach_nic "srv-2-2" "br030" "02:4E:57:06:06:01"
attach_nic "srv-2-2" "br031" "02:4E:57:06:06:02"
configure_vm "srv-2-2" "192.168.0.55" \
    "02:4E:57:06:06:01" "172.16.4.10" "172.16.4.9" \
    "02:4E:57:06:06:02" "172.16.4.14" "172.16.4.13" \
    "30"
echo ""
echo "srv-2-3: br032 (leaf-2a) + br033 (leaf-2b)"
attach_nic "srv-2-3" "br032" "02:4E:57:06:07:01"
attach_nic "srv-2-3" "br033" "02:4E:57:06:07:02"
configure_vm "srv-2-3" "192.168.0.56" \
    "02:4E:57:06:07:01" "172.16.4.18" "172.16.4.17" \
    "02:4E:57:06:07:02" "172.16.4.22" "172.16.4.21" \
    "30"
echo ""
echo "srv-2-4: br034 (leaf-2a) + br035 (leaf-2b)"
attach_nic "srv-2-4" "br034" "02:4E:57:06:08:01"
attach_nic "srv-2-4" "br035" "02:4E:57:06:08:02"
configure_vm "srv-2-4" "192.168.0.57" \
    "02:4E:57:06:08:01" "172.16.4.26" "172.16.4.25" \
    "02:4E:57:06:08:02" "172.16.4.30" "172.16.4.29" \
    "30"
echo ""
echo "srv-3-1: br036 (leaf-3a) + br037 (leaf-3b)"
attach_nic "srv-3-1" "br036" "02:4E:57:06:09:01"
attach_nic "srv-3-1" "br037" "02:4E:57:06:09:02"
configure_vm "srv-3-1" "192.168.0.58" \
    "02:4E:57:06:09:01" "172.16.5.2" "172.16.5.1" \
    "02:4E:57:06:09:02" "172.16.5.6" "172.16.5.5" \
    "30"
echo ""
echo "srv-3-2: br038 (leaf-3a) + br039 (leaf-3b)"
attach_nic "srv-3-2" "br038" "02:4E:57:06:0A:01"
attach_nic "srv-3-2" "br039" "02:4E:57:06:0A:02"
configure_vm "srv-3-2" "192.168.0.59" \
    "02:4E:57:06:0A:01" "172.16.5.10" "172.16.5.9" \
    "02:4E:57:06:0A:02" "172.16.5.14" "172.16.5.13" \
    "30"
echo ""
echo "srv-3-3: br040 (leaf-3a) + br041 (leaf-3b)"
attach_nic "srv-3-3" "br040" "02:4E:57:06:0B:01"
attach_nic "srv-3-3" "br041" "02:4E:57:06:0B:02"
configure_vm "srv-3-3" "192.168.0.60" \
    "02:4E:57:06:0B:01" "172.16.5.18" "172.16.5.17" \
    "02:4E:57:06:0B:02" "172.16.5.22" "172.16.5.21" \
    "30"
echo ""
echo "srv-3-4: br042 (leaf-3a) + br043 (leaf-3b)"
attach_nic "srv-3-4" "br042" "02:4E:57:06:0C:01"
attach_nic "srv-3-4" "br043" "02:4E:57:06:0C:02"
configure_vm "srv-3-4" "192.168.0.61" \
    "02:4E:57:06:0C:01" "172.16.5.26" "172.16.5.25" \
    "02:4E:57:06:0C:02" "172.16.5.30" "172.16.5.29" \
    "30"
echo ""
echo "srv-4-1: br044 (leaf-4a) + br045 (leaf-4b)"
attach_nic "srv-4-1" "br044" "02:4E:57:06:0D:01"
attach_nic "srv-4-1" "br045" "02:4E:57:06:0D:02"
configure_vm "srv-4-1" "192.168.0.62" \
    "02:4E:57:06:0D:01" "172.16.6.2" "172.16.6.1" \
    "02:4E:57:06:0D:02" "172.16.6.6" "172.16.6.5" \
    "30"
echo ""
echo "srv-4-2: br046 (leaf-4a) + br047 (leaf-4b)"
attach_nic "srv-4-2" "br046" "02:4E:57:06:0E:01"
attach_nic "srv-4-2" "br047" "02:4E:57:06:0E:02"
configure_vm "srv-4-2" "192.168.0.63" \
    "02:4E:57:06:0E:01" "172.16.6.10" "172.16.6.9" \
    "02:4E:57:06:0E:02" "172.16.6.14" "172.16.6.13" \
    "30"
echo ""
echo "srv-4-3: br048 (leaf-4a) + br049 (leaf-4b)"
attach_nic "srv-4-3" "br048" "02:4E:57:06:0F:01"
attach_nic "srv-4-3" "br049" "02:4E:57:06:0F:02"
configure_vm "srv-4-3" "192.168.0.64" \
    "02:4E:57:06:0F:01" "172.16.6.18" "172.16.6.17" \
    "02:4E:57:06:0F:02" "172.16.6.22" "172.16.6.21" \
    "30"
echo ""
echo "srv-4-4: br050 (leaf-4a) + br051 (leaf-4b)"
attach_nic "srv-4-4" "br050" "02:4E:57:06:10:01"
attach_nic "srv-4-4" "br051" "02:4E:57:06:10:02"
configure_vm "srv-4-4" "192.168.0.65" \
    "02:4E:57:06:10:01" "172.16.6.26" "172.16.6.25" \
    "02:4E:57:06:10:02" "172.16.6.30" "172.16.6.29" \
    "30"

echo ""
echo "NetWatch: All 16 servers wired to fabric."
echo "  - 2 NICs per server (leaf-a + leaf-b)"
echo "  - ECMP default routes installed"
echo ""
echo "Verify: vagrant ssh srv-1-1 -c 'ip route show 10.0.0.0/8'"
