#!/bin/bash
# NetWatch — Server & Bastion Fabric Wiring
# Generated from topology.yml — DO NOT HAND-EDIT
#
# Hot-plugs fabric NICs into server and bastion VMs (via virsh),
# then configures IPs, ECMP routes, and NAT rules.
#
# - Servers: 2 NICs (leaf-a + leaf-b), ECMP default via both leafs
# - Bastion: 2 NICs (border-1 + border-2), ECMP fabric routes, NAT masquerade
#
# Prerequisites: VMs running (vagrant up), fabric bridges exist (setup-bridges.sh).
# Run as your user (NOT sudo): bash scripts/fabric/setup-server-links.sh
# (uses sudo internally for virsh commands only)

set -uo pipefail

VIRSH_PREFIX="NetWatch"
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "NetWatch: Wiring server and bastion VMs to fabric bridges..."

# Helper: attach a NIC to a VM on a given bridge (idempotent)
attach_nic() {
    local vm="$1"
    local bridge="$2"
    local mac="$3"
    local domain="${VIRSH_PREFIX}_${vm}"

    if virsh -c qemu:///system domiflist "$domain" 2>/dev/null | grep -qi "$mac"; then
        echo "    $bridge ($mac): already attached"
        # Still ensure bridge membership (libvirt sometimes misses this)
        local vnet
        vnet=$(virsh -c qemu:///system domiflist "$domain" 2>/dev/null | grep -i "$mac" | head -1 | awk '{print $1}')
        if [ -n "$vnet" ]; then
            local current_master
            current_master=$(ip link show "$vnet" 2>/dev/null | grep -oP 'master \K\S+' || true)
            if [ "$current_master" != "$bridge" ]; then
                sudo ip link set "$vnet" master "$bridge" 2>/dev/null && \
                    echo "    $bridge ($mac): fixed bridge membership ($vnet)"
            fi
        fi
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

    # Ensure the tap device is actually on the bridge (libvirt sometimes misses this)
    sleep 0.5
    local vnet
    vnet=$(virsh -c qemu:///system domiflist "$domain" 2>/dev/null | grep -i "$mac" | awk '{print $1}')
    if [ -n "$vnet" ]; then
        local current_master
        current_master=$(ip link show "$vnet" 2>/dev/null | grep -oP 'master \K\S+' || true)
        if [ "$current_master" != "$bridge" ]; then
            sudo ip link set "$vnet" master "$bridge" 2>/dev/null && \
                echo "    $bridge ($mac): fixed bridge membership ($vnet)"
        fi
    fi
}

# Helper: configure fabric interfaces inside a VM
# Uses configure-vm-fabric.sh piped through vagrant ssh (avoids heredoc issues)
FABRIC_SCRIPT="$PROJECT_ROOT/scripts/fabric/configure-vm-fabric.sh"

configure_server() {
    local vm="$1"
    local mgmt_ip="$2"
    shift 2
    # remaining args: mac_a ip_a gw_a mac_b ip_b gw_b prefix [--no-default-route]
    cd "$PROJECT_ROOT"
    vagrant ssh "$vm" -c "sudo bash -s -- $*" < "$FABRIC_SCRIPT"
}

# --- Wire each server ---
echo ""
echo "srv-1-1: br022 (leaf-1a) + br023 (leaf-1b)"
attach_nic "srv-1-1" "br022" "02:4E:57:06:01:01"
attach_nic "srv-1-1" "br023" "02:4E:57:06:01:02"
configure_server "srv-1-1" "192.168.0.50" \
    "02:4E:57:06:01:01" "172.16.3.2" "172.16.3.1" \
    "02:4E:57:06:01:02" "172.16.3.6" "172.16.3.5" \
    "30"
echo ""
echo "srv-1-2: br024 (leaf-1a) + br025 (leaf-1b)"
attach_nic "srv-1-2" "br024" "02:4E:57:06:02:01"
attach_nic "srv-1-2" "br025" "02:4E:57:06:02:02"
configure_server "srv-1-2" "192.168.0.51" \
    "02:4E:57:06:02:01" "172.16.3.10" "172.16.3.9" \
    "02:4E:57:06:02:02" "172.16.3.14" "172.16.3.13" \
    "30"
echo ""
echo "srv-1-3: br026 (leaf-1a) + br027 (leaf-1b)"
attach_nic "srv-1-3" "br026" "02:4E:57:06:03:01"
attach_nic "srv-1-3" "br027" "02:4E:57:06:03:02"
configure_server "srv-1-3" "192.168.0.52" \
    "02:4E:57:06:03:01" "172.16.3.18" "172.16.3.17" \
    "02:4E:57:06:03:02" "172.16.3.22" "172.16.3.21" \
    "30"
echo ""
echo "srv-1-4: br028 (leaf-1a) + br029 (leaf-1b)"
attach_nic "srv-1-4" "br028" "02:4E:57:06:04:01"
attach_nic "srv-1-4" "br029" "02:4E:57:06:04:02"
configure_server "srv-1-4" "192.168.0.53" \
    "02:4E:57:06:04:01" "172.16.3.26" "172.16.3.25" \
    "02:4E:57:06:04:02" "172.16.3.30" "172.16.3.29" \
    "30"
echo ""
echo "srv-2-1: br030 (leaf-2a) + br031 (leaf-2b)"
attach_nic "srv-2-1" "br030" "02:4E:57:06:05:01"
attach_nic "srv-2-1" "br031" "02:4E:57:06:05:02"
configure_server "srv-2-1" "192.168.0.54" \
    "02:4E:57:06:05:01" "172.16.4.2" "172.16.4.1" \
    "02:4E:57:06:05:02" "172.16.4.6" "172.16.4.5" \
    "30"
echo ""
echo "srv-2-2: br032 (leaf-2a) + br033 (leaf-2b)"
attach_nic "srv-2-2" "br032" "02:4E:57:06:06:01"
attach_nic "srv-2-2" "br033" "02:4E:57:06:06:02"
configure_server "srv-2-2" "192.168.0.55" \
    "02:4E:57:06:06:01" "172.16.4.10" "172.16.4.9" \
    "02:4E:57:06:06:02" "172.16.4.14" "172.16.4.13" \
    "30"
echo ""
echo "srv-2-3: br034 (leaf-2a) + br035 (leaf-2b)"
attach_nic "srv-2-3" "br034" "02:4E:57:06:07:01"
attach_nic "srv-2-3" "br035" "02:4E:57:06:07:02"
configure_server "srv-2-3" "192.168.0.56" \
    "02:4E:57:06:07:01" "172.16.4.18" "172.16.4.17" \
    "02:4E:57:06:07:02" "172.16.4.22" "172.16.4.21" \
    "30"
echo ""
echo "srv-2-4: br036 (leaf-2a) + br037 (leaf-2b)"
attach_nic "srv-2-4" "br036" "02:4E:57:06:08:01"
attach_nic "srv-2-4" "br037" "02:4E:57:06:08:02"
configure_server "srv-2-4" "192.168.0.57" \
    "02:4E:57:06:08:01" "172.16.4.26" "172.16.4.25" \
    "02:4E:57:06:08:02" "172.16.4.30" "172.16.4.29" \
    "30"
echo ""
echo "srv-3-1: br038 (leaf-3a) + br039 (leaf-3b)"
attach_nic "srv-3-1" "br038" "02:4E:57:06:09:01"
attach_nic "srv-3-1" "br039" "02:4E:57:06:09:02"
configure_server "srv-3-1" "192.168.0.58" \
    "02:4E:57:06:09:01" "172.16.5.2" "172.16.5.1" \
    "02:4E:57:06:09:02" "172.16.5.6" "172.16.5.5" \
    "30"
echo ""
echo "srv-3-2: br040 (leaf-3a) + br041 (leaf-3b)"
attach_nic "srv-3-2" "br040" "02:4E:57:06:0A:01"
attach_nic "srv-3-2" "br041" "02:4E:57:06:0A:02"
configure_server "srv-3-2" "192.168.0.59" \
    "02:4E:57:06:0A:01" "172.16.5.10" "172.16.5.9" \
    "02:4E:57:06:0A:02" "172.16.5.14" "172.16.5.13" \
    "30"
echo ""
echo "srv-3-3: br042 (leaf-3a) + br043 (leaf-3b)"
attach_nic "srv-3-3" "br042" "02:4E:57:06:0B:01"
attach_nic "srv-3-3" "br043" "02:4E:57:06:0B:02"
configure_server "srv-3-3" "192.168.0.60" \
    "02:4E:57:06:0B:01" "172.16.5.18" "172.16.5.17" \
    "02:4E:57:06:0B:02" "172.16.5.22" "172.16.5.21" \
    "30"
echo ""
echo "srv-3-4: br044 (leaf-3a) + br045 (leaf-3b)"
attach_nic "srv-3-4" "br044" "02:4E:57:06:0C:01"
attach_nic "srv-3-4" "br045" "02:4E:57:06:0C:02"
configure_server "srv-3-4" "192.168.0.61" \
    "02:4E:57:06:0C:01" "172.16.5.26" "172.16.5.25" \
    "02:4E:57:06:0C:02" "172.16.5.30" "172.16.5.29" \
    "30"
echo ""
echo "srv-4-1: br046 (leaf-4a) + br047 (leaf-4b)"
attach_nic "srv-4-1" "br046" "02:4E:57:06:0D:01"
attach_nic "srv-4-1" "br047" "02:4E:57:06:0D:02"
configure_server "srv-4-1" "192.168.0.62" \
    "02:4E:57:06:0D:01" "172.16.6.2" "172.16.6.1" \
    "02:4E:57:06:0D:02" "172.16.6.6" "172.16.6.5" \
    "30"
echo ""
echo "srv-4-2: br048 (leaf-4a) + br049 (leaf-4b)"
attach_nic "srv-4-2" "br048" "02:4E:57:06:0E:01"
attach_nic "srv-4-2" "br049" "02:4E:57:06:0E:02"
configure_server "srv-4-2" "192.168.0.63" \
    "02:4E:57:06:0E:01" "172.16.6.10" "172.16.6.9" \
    "02:4E:57:06:0E:02" "172.16.6.14" "172.16.6.13" \
    "30"
echo ""
echo "srv-4-3: br050 (leaf-4a) + br051 (leaf-4b)"
attach_nic "srv-4-3" "br050" "02:4E:57:06:0F:01"
attach_nic "srv-4-3" "br051" "02:4E:57:06:0F:02"
configure_server "srv-4-3" "192.168.0.64" \
    "02:4E:57:06:0F:01" "172.16.6.18" "172.16.6.17" \
    "02:4E:57:06:0F:02" "172.16.6.22" "172.16.6.21" \
    "30"
echo ""
echo "srv-4-4: br052 (leaf-4a) + br053 (leaf-4b)"
attach_nic "srv-4-4" "br052" "02:4E:57:06:10:01"
attach_nic "srv-4-4" "br053" "02:4E:57:06:10:02"
configure_server "srv-4-4" "192.168.0.65" \
    "02:4E:57:06:10:01" "172.16.6.26" "172.16.6.25" \
    "02:4E:57:06:10:02" "172.16.6.30" "172.16.6.29" \
    "30"

echo ""
echo "NetWatch: All 16 servers wired to fabric."
echo "  - 2 NICs per server (leaf-a + leaf-b)"
echo "  - ECMP default routes via fabric (north-south path active)"

# ========================================================================
# Bastion Fabric Wiring (north-south exit)
# ========================================================================
# Two NICs: one to each border router. ECMP routes for fabric prefixes.
# NAT masquerade for fabric source IPs exiting to the internet.
echo ""
echo "========================================"
echo " Wiring bastion to fabric..."
echo "========================================"


# Deterministic MACs for bastion fabric NICs
# Format: 02:4E:57:05:01:01 (border-1), 02:4E:57:05:01:02 (border-2)
BASTION_MAC_A="02:4E:57:05:01:01"
BASTION_MAC_B="02:4E:57:05:01:02"

echo "bastion: br000 (border-1) + br001 (border-2)"
attach_nic "bastion" "br000" "$BASTION_MAC_A"
attach_nic "bastion" "br001" "$BASTION_MAC_B"

# Configure bastion fabric interfaces (no default route — bastion keeps its own)
configure_server "bastion" "192.168.0.2" \
    "02:4E:57:05:01:01" "172.16.0.2" "172.16.0.1" \
    "02:4E:57:05:01:02" "172.16.0.6" "172.16.0.5" \
    "30" "--no-default-route"

# Configure NAT masquerade for fabric source IPs on bastion
cd "$PROJECT_ROOT"
vagrant ssh bastion -c "sudo bash -s" < <(cat <<'NATSCRIPT'
set -e
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
NATSCRIPT
)

echo ""
echo "NetWatch: Bastion wired to fabric."
echo "  - 2 NICs (border-1 + border-2)"
echo "  - ECMP routes for fabric prefixes"
echo "  - NAT masquerade for fabric source IPs"

echo ""
echo "Verify:"
echo "  vagrant ssh srv-1-1 -c 'ip route show default'"
echo "  vagrant ssh bastion -c 'ip route show 10.0.0.0/8'"
echo "  vagrant ssh srv-1-1 -c 'traceroute -n 8.8.8.8'"
