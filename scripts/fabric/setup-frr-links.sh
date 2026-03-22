#!/bin/bash
# NetWatch — FRR VM Fabric Wiring
# Generated from topology.yml — DO NOT HAND-EDIT
#
# Hot-plugs fabric NICs into FRR VMs (via virsh), then configures IPs,
# loopback, sysctls, and restarts FRR + frr_exporter.
#
# Prerequisites: FRR VMs running (vagrant up), fabric bridges exist (setup-bridges.sh).
# Run as your user (NOT sudo): bash scripts/fabric/setup-frr-links.sh
# (uses sudo internally for virsh commands only)

set -uo pipefail

VIRSH_PREFIX="NetWatch"
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "NetWatch: Wiring FRR VMs to fabric bridges..."

# Helper: attach a NIC to a VM on a given bridge (idempotent)
attach_nic() {
    local vm="$1"
    local bridge="$2"
    local mac="$3"
    local domain="${VIRSH_PREFIX}_${vm}"

    if virsh -c qemu:///system domiflist "$domain" 2>/dev/null </dev/null | grep -qi "$mac"; then
        echo "    $bridge ($mac): already attached"
    else
        virsh -c qemu:///system attach-interface "$domain" \
            --type bridge \
            --source "$bridge" \
            --model virtio \
            --mac "$mac" \
            --live \
            --config </dev/null
        echo "    $bridge ($mac): attached"
        sleep 0.5
    fi

    # Ensure the tap device is actually on the bridge (libvirt sometimes misses this)
    local vnet
    vnet=$(virsh -c qemu:///system domiflist "$domain" 2>/dev/null </dev/null | grep -i "$mac" | head -1 | awk '{print $1}')
    if [ -n "$vnet" ]; then
        local current_master
        current_master=$(ip link show "$vnet" 2>/dev/null | grep -oP 'master \K\S+' || true)
        if [ "$current_master" != "$bridge" ]; then
            sudo ip link set "$vnet" master "$bridge" 2>/dev/null && \
                echo "    $bridge ($mac): fixed bridge membership ($vnet)"
        fi
    fi
}

# Helper: configure fabric interfaces inside an FRR VM
# Uses configure-frr-fabric.sh passed via stdin
FABRIC_SCRIPT="$PROJECT_ROOT/scripts/fabric/configure-frr-fabric.sh"

configure_frr() {
    local vm="$1"
    shift
    # remaining args: loopback_ip mac1 name1 ip1 prefix1 mac2 name2 ip2 prefix2 ...
    cd "$PROJECT_ROOT"
    vagrant ssh "$vm" -c "sudo bash -s -- $*" < "$FABRIC_SCRIPT"
}

# --- Wire each FRR node ---
echo ""
echo "border-1: attaching 3 fabric NICs"
attach_nic "border-1" "br000" "02:4E:57:01:01:01"
attach_nic "border-1" "br002" "02:4E:57:01:02:01"
attach_nic "border-1" "br003" "02:4E:57:01:03:01"
configure_frr "border-1" \
    "10.0.1.1" \
    "02:4E:57:01:01:01" "eth-bastion" "172.16.0.1" "30" \
    "02:4E:57:01:02:01" "eth-spine-1" "172.16.1.1" "30" \
    "02:4E:57:01:03:01" "eth-spine-2" "172.16.1.5" "30"

echo ""
echo "border-2: attaching 3 fabric NICs"
attach_nic "border-2" "br001" "02:4E:57:01:01:02"
attach_nic "border-2" "br004" "02:4E:57:01:02:02"
attach_nic "border-2" "br005" "02:4E:57:01:03:02"
configure_frr "border-2" \
    "10.0.1.2" \
    "02:4E:57:01:01:02" "eth-bastion" "172.16.0.5" "30" \
    "02:4E:57:01:02:02" "eth-spine-1" "172.16.1.9" "30" \
    "02:4E:57:01:03:02" "eth-spine-2" "172.16.1.13" "30"

echo ""
echo "leaf-1a: attaching 6 fabric NICs"
attach_nic "leaf-1a" "br006" "02:4E:57:03:01:01"
attach_nic "leaf-1a" "br014" "02:4E:57:03:02:01"
attach_nic "leaf-1a" "br022" "02:4E:57:03:03:01"
attach_nic "leaf-1a" "br024" "02:4E:57:03:04:01"
attach_nic "leaf-1a" "br026" "02:4E:57:03:05:01"
attach_nic "leaf-1a" "br028" "02:4E:57:03:06:01"
configure_frr "leaf-1a" \
    "10.0.3.1" \
    "02:4E:57:03:01:01" "eth-spine-1" "172.16.2.2" "30" \
    "02:4E:57:03:02:01" "eth-spine-2" "172.16.2.34" "30" \
    "02:4E:57:03:03:01" "eth-srv-1-1" "172.16.3.1" "30" \
    "02:4E:57:03:04:01" "eth-srv-1-2" "172.16.3.9" "30" \
    "02:4E:57:03:05:01" "eth-srv-1-3" "172.16.3.17" "30" \
    "02:4E:57:03:06:01" "eth-srv-1-4" "172.16.3.25" "30"

echo ""
echo "leaf-1b: attaching 6 fabric NICs"
attach_nic "leaf-1b" "br007" "02:4E:57:03:01:02"
attach_nic "leaf-1b" "br015" "02:4E:57:03:02:02"
attach_nic "leaf-1b" "br023" "02:4E:57:03:03:02"
attach_nic "leaf-1b" "br025" "02:4E:57:03:04:02"
attach_nic "leaf-1b" "br027" "02:4E:57:03:05:02"
attach_nic "leaf-1b" "br029" "02:4E:57:03:06:02"
configure_frr "leaf-1b" \
    "10.0.3.2" \
    "02:4E:57:03:01:02" "eth-spine-1" "172.16.2.6" "30" \
    "02:4E:57:03:02:02" "eth-spine-2" "172.16.2.38" "30" \
    "02:4E:57:03:03:02" "eth-srv-1-1" "172.16.3.5" "30" \
    "02:4E:57:03:04:02" "eth-srv-1-2" "172.16.3.13" "30" \
    "02:4E:57:03:05:02" "eth-srv-1-3" "172.16.3.21" "30" \
    "02:4E:57:03:06:02" "eth-srv-1-4" "172.16.3.29" "30"

echo ""
echo "leaf-2a: attaching 6 fabric NICs"
attach_nic "leaf-2a" "br008" "02:4E:57:03:01:03"
attach_nic "leaf-2a" "br016" "02:4E:57:03:02:03"
attach_nic "leaf-2a" "br030" "02:4E:57:03:03:03"
attach_nic "leaf-2a" "br032" "02:4E:57:03:04:03"
attach_nic "leaf-2a" "br034" "02:4E:57:03:05:03"
attach_nic "leaf-2a" "br036" "02:4E:57:03:06:03"
configure_frr "leaf-2a" \
    "10.0.3.3" \
    "02:4E:57:03:01:03" "eth-spine-1" "172.16.2.10" "30" \
    "02:4E:57:03:02:03" "eth-spine-2" "172.16.2.42" "30" \
    "02:4E:57:03:03:03" "eth-srv-2-1" "172.16.4.1" "30" \
    "02:4E:57:03:04:03" "eth-srv-2-2" "172.16.4.9" "30" \
    "02:4E:57:03:05:03" "eth-srv-2-3" "172.16.4.17" "30" \
    "02:4E:57:03:06:03" "eth-srv-2-4" "172.16.4.25" "30"

echo ""
echo "leaf-2b: attaching 6 fabric NICs"
attach_nic "leaf-2b" "br009" "02:4E:57:03:01:04"
attach_nic "leaf-2b" "br017" "02:4E:57:03:02:04"
attach_nic "leaf-2b" "br031" "02:4E:57:03:03:04"
attach_nic "leaf-2b" "br033" "02:4E:57:03:04:04"
attach_nic "leaf-2b" "br035" "02:4E:57:03:05:04"
attach_nic "leaf-2b" "br037" "02:4E:57:03:06:04"
configure_frr "leaf-2b" \
    "10.0.3.4" \
    "02:4E:57:03:01:04" "eth-spine-1" "172.16.2.14" "30" \
    "02:4E:57:03:02:04" "eth-spine-2" "172.16.2.46" "30" \
    "02:4E:57:03:03:04" "eth-srv-2-1" "172.16.4.5" "30" \
    "02:4E:57:03:04:04" "eth-srv-2-2" "172.16.4.13" "30" \
    "02:4E:57:03:05:04" "eth-srv-2-3" "172.16.4.21" "30" \
    "02:4E:57:03:06:04" "eth-srv-2-4" "172.16.4.29" "30"

echo ""
echo "leaf-3a: attaching 6 fabric NICs"
attach_nic "leaf-3a" "br010" "02:4E:57:03:01:05"
attach_nic "leaf-3a" "br018" "02:4E:57:03:02:05"
attach_nic "leaf-3a" "br038" "02:4E:57:03:03:05"
attach_nic "leaf-3a" "br040" "02:4E:57:03:04:05"
attach_nic "leaf-3a" "br042" "02:4E:57:03:05:05"
attach_nic "leaf-3a" "br044" "02:4E:57:03:06:05"
configure_frr "leaf-3a" \
    "10.0.3.5" \
    "02:4E:57:03:01:05" "eth-spine-1" "172.16.2.18" "30" \
    "02:4E:57:03:02:05" "eth-spine-2" "172.16.2.50" "30" \
    "02:4E:57:03:03:05" "eth-srv-3-1" "172.16.5.1" "30" \
    "02:4E:57:03:04:05" "eth-srv-3-2" "172.16.5.9" "30" \
    "02:4E:57:03:05:05" "eth-srv-3-3" "172.16.5.17" "30" \
    "02:4E:57:03:06:05" "eth-srv-3-4" "172.16.5.25" "30"

echo ""
echo "leaf-3b: attaching 6 fabric NICs"
attach_nic "leaf-3b" "br011" "02:4E:57:03:01:06"
attach_nic "leaf-3b" "br019" "02:4E:57:03:02:06"
attach_nic "leaf-3b" "br039" "02:4E:57:03:03:06"
attach_nic "leaf-3b" "br041" "02:4E:57:03:04:06"
attach_nic "leaf-3b" "br043" "02:4E:57:03:05:06"
attach_nic "leaf-3b" "br045" "02:4E:57:03:06:06"
configure_frr "leaf-3b" \
    "10.0.3.6" \
    "02:4E:57:03:01:06" "eth-spine-1" "172.16.2.22" "30" \
    "02:4E:57:03:02:06" "eth-spine-2" "172.16.2.54" "30" \
    "02:4E:57:03:03:06" "eth-srv-3-1" "172.16.5.5" "30" \
    "02:4E:57:03:04:06" "eth-srv-3-2" "172.16.5.13" "30" \
    "02:4E:57:03:05:06" "eth-srv-3-3" "172.16.5.21" "30" \
    "02:4E:57:03:06:06" "eth-srv-3-4" "172.16.5.29" "30"

echo ""
echo "leaf-4a: attaching 6 fabric NICs"
attach_nic "leaf-4a" "br012" "02:4E:57:03:01:07"
attach_nic "leaf-4a" "br020" "02:4E:57:03:02:07"
attach_nic "leaf-4a" "br046" "02:4E:57:03:03:07"
attach_nic "leaf-4a" "br048" "02:4E:57:03:04:07"
attach_nic "leaf-4a" "br050" "02:4E:57:03:05:07"
attach_nic "leaf-4a" "br052" "02:4E:57:03:06:07"
configure_frr "leaf-4a" \
    "10.0.3.7" \
    "02:4E:57:03:01:07" "eth-spine-1" "172.16.2.26" "30" \
    "02:4E:57:03:02:07" "eth-spine-2" "172.16.2.58" "30" \
    "02:4E:57:03:03:07" "eth-srv-4-1" "172.16.6.1" "30" \
    "02:4E:57:03:04:07" "eth-srv-4-2" "172.16.6.9" "30" \
    "02:4E:57:03:05:07" "eth-srv-4-3" "172.16.6.17" "30" \
    "02:4E:57:03:06:07" "eth-srv-4-4" "172.16.6.25" "30"

echo ""
echo "leaf-4b: attaching 6 fabric NICs"
attach_nic "leaf-4b" "br013" "02:4E:57:03:01:08"
attach_nic "leaf-4b" "br021" "02:4E:57:03:02:08"
attach_nic "leaf-4b" "br047" "02:4E:57:03:03:08"
attach_nic "leaf-4b" "br049" "02:4E:57:03:04:08"
attach_nic "leaf-4b" "br051" "02:4E:57:03:05:08"
attach_nic "leaf-4b" "br053" "02:4E:57:03:06:08"
configure_frr "leaf-4b" \
    "10.0.3.8" \
    "02:4E:57:03:01:08" "eth-spine-1" "172.16.2.30" "30" \
    "02:4E:57:03:02:08" "eth-spine-2" "172.16.2.62" "30" \
    "02:4E:57:03:03:08" "eth-srv-4-1" "172.16.6.5" "30" \
    "02:4E:57:03:04:08" "eth-srv-4-2" "172.16.6.13" "30" \
    "02:4E:57:03:05:08" "eth-srv-4-3" "172.16.6.21" "30" \
    "02:4E:57:03:06:08" "eth-srv-4-4" "172.16.6.29" "30"

echo ""
echo "spine-1: attaching 10 fabric NICs"
attach_nic "spine-1" "br002" "02:4E:57:02:01:01"
attach_nic "spine-1" "br004" "02:4E:57:02:02:01"
attach_nic "spine-1" "br006" "02:4E:57:02:03:01"
attach_nic "spine-1" "br007" "02:4E:57:02:04:01"
attach_nic "spine-1" "br008" "02:4E:57:02:05:01"
attach_nic "spine-1" "br009" "02:4E:57:02:06:01"
attach_nic "spine-1" "br010" "02:4E:57:02:07:01"
attach_nic "spine-1" "br011" "02:4E:57:02:08:01"
attach_nic "spine-1" "br012" "02:4E:57:02:09:01"
attach_nic "spine-1" "br013" "02:4E:57:02:0A:01"
configure_frr "spine-1" \
    "10.0.2.1" \
    "02:4E:57:02:01:01" "eth-border-1" "172.16.1.2" "30" \
    "02:4E:57:02:02:01" "eth-border-2" "172.16.1.10" "30" \
    "02:4E:57:02:03:01" "eth-leaf-1a" "172.16.2.1" "30" \
    "02:4E:57:02:04:01" "eth-leaf-1b" "172.16.2.5" "30" \
    "02:4E:57:02:05:01" "eth-leaf-2a" "172.16.2.9" "30" \
    "02:4E:57:02:06:01" "eth-leaf-2b" "172.16.2.13" "30" \
    "02:4E:57:02:07:01" "eth-leaf-3a" "172.16.2.17" "30" \
    "02:4E:57:02:08:01" "eth-leaf-3b" "172.16.2.21" "30" \
    "02:4E:57:02:09:01" "eth-leaf-4a" "172.16.2.25" "30" \
    "02:4E:57:02:0A:01" "eth-leaf-4b" "172.16.2.29" "30"

echo ""
echo "spine-2: attaching 10 fabric NICs"
attach_nic "spine-2" "br003" "02:4E:57:02:01:02"
attach_nic "spine-2" "br005" "02:4E:57:02:02:02"
attach_nic "spine-2" "br014" "02:4E:57:02:03:02"
attach_nic "spine-2" "br015" "02:4E:57:02:04:02"
attach_nic "spine-2" "br016" "02:4E:57:02:05:02"
attach_nic "spine-2" "br017" "02:4E:57:02:06:02"
attach_nic "spine-2" "br018" "02:4E:57:02:07:02"
attach_nic "spine-2" "br019" "02:4E:57:02:08:02"
attach_nic "spine-2" "br020" "02:4E:57:02:09:02"
attach_nic "spine-2" "br021" "02:4E:57:02:0A:02"
configure_frr "spine-2" \
    "10.0.2.2" \
    "02:4E:57:02:01:02" "eth-border-1" "172.16.1.6" "30" \
    "02:4E:57:02:02:02" "eth-border-2" "172.16.1.14" "30" \
    "02:4E:57:02:03:02" "eth-leaf-1a" "172.16.2.33" "30" \
    "02:4E:57:02:04:02" "eth-leaf-1b" "172.16.2.37" "30" \
    "02:4E:57:02:05:02" "eth-leaf-2a" "172.16.2.41" "30" \
    "02:4E:57:02:06:02" "eth-leaf-2b" "172.16.2.45" "30" \
    "02:4E:57:02:07:02" "eth-leaf-3a" "172.16.2.49" "30" \
    "02:4E:57:02:08:02" "eth-leaf-3b" "172.16.2.53" "30" \
    "02:4E:57:02:09:02" "eth-leaf-4a" "172.16.2.57" "30" \
    "02:4E:57:02:0A:02" "eth-leaf-4b" "172.16.2.61" "30"


echo ""
echo "NetWatch: All 12 FRR VMs wired to fabric."
echo "  - Fabric interfaces: up with IPs (renamed via udev rules)"
echo "  - Loopback IPs: configured"
echo "  - ip_forward=1, rp_filter=2 (loose mode)"
echo "  - FRR + frr_exporter: restarted"
echo ""
echo "Verify: vagrant ssh spine-1 -c 'sudo vtysh -c \"show bgp summary\"'"
