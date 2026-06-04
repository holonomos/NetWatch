#!/bin/bash
# NetWatch: Teardown
# Generated from topology.yml: DO NOT HAND-EDIT
#
# Shut down FRR VMs, detach persisted (--config) fabric/overlay NICs, and remove
# fabric + overlay bridges. Does NOT destroy VMs (use `vagrant destroy`).

set -uo pipefail

VIRSH_PREFIX="$(basename "$(cd "$(dirname "$0")/../.." && pwd)")"

echo "NetWatch: Tearing down fabric..."

# Detach a persisted (--config) NIC by MAC. NICs were hot-plugged with --config
# (in the domain XML); without removing it, the next `vagrant up` references
# deleted bridges. Detaches --live too if running; missing domain/NIC is no-op.
detach_nic() {
    local vm="$1"
    local mac="$2"
    local domain="${VIRSH_PREFIX}_${vm}"

    virsh -c qemu:///system domiflist "$domain" >/dev/null 2>&1 </dev/null || return 0
    local state
    state=$(virsh -c qemu:///system domstate "$domain" 2>/dev/null || echo "shut off")
    if virsh -c qemu:///system domiflist "$domain" 2>/dev/null </dev/null | grep -qi "$mac"; then
        if [ "$state" = "running" ]; then
            virsh -c qemu:///system detach-interface "$domain" bridge --mac "$mac" \
                --live --config </dev/null >/dev/null 2>&1 \
                && echo "    $vm ($mac): detached (live+config)" || true
        else
            virsh -c qemu:///system detach-interface "$domain" bridge --mac "$mac" \
                --config </dev/null >/dev/null 2>&1 \
                && echo "    $vm ($mac): detached (config)" || true
        fi
    fi
}

# --- Shut down FRR VMs ---
echo "  Shutting down FRR VMs..."
virsh -c qemu:///system shutdown "${VIRSH_PREFIX}_border-1" 2>/dev/null && echo "    border-1: shutdown sent" || echo "    border-1: not running"
virsh -c qemu:///system shutdown "${VIRSH_PREFIX}_border-2" 2>/dev/null && echo "    border-2: shutdown sent" || echo "    border-2: not running"
virsh -c qemu:///system shutdown "${VIRSH_PREFIX}_leaf-1a" 2>/dev/null && echo "    leaf-1a: shutdown sent" || echo "    leaf-1a: not running"
virsh -c qemu:///system shutdown "${VIRSH_PREFIX}_leaf-1b" 2>/dev/null && echo "    leaf-1b: shutdown sent" || echo "    leaf-1b: not running"
virsh -c qemu:///system shutdown "${VIRSH_PREFIX}_leaf-2a" 2>/dev/null && echo "    leaf-2a: shutdown sent" || echo "    leaf-2a: not running"
virsh -c qemu:///system shutdown "${VIRSH_PREFIX}_leaf-2b" 2>/dev/null && echo "    leaf-2b: shutdown sent" || echo "    leaf-2b: not running"
virsh -c qemu:///system shutdown "${VIRSH_PREFIX}_leaf-3a" 2>/dev/null && echo "    leaf-3a: shutdown sent" || echo "    leaf-3a: not running"
virsh -c qemu:///system shutdown "${VIRSH_PREFIX}_leaf-3b" 2>/dev/null && echo "    leaf-3b: shutdown sent" || echo "    leaf-3b: not running"
virsh -c qemu:///system shutdown "${VIRSH_PREFIX}_leaf-4a" 2>/dev/null && echo "    leaf-4a: shutdown sent" || echo "    leaf-4a: not running"
virsh -c qemu:///system shutdown "${VIRSH_PREFIX}_leaf-4b" 2>/dev/null && echo "    leaf-4b: shutdown sent" || echo "    leaf-4b: not running"
virsh -c qemu:///system shutdown "${VIRSH_PREFIX}_spine-1" 2>/dev/null && echo "    spine-1: shutdown sent" || echo "    spine-1: not running"
virsh -c qemu:///system shutdown "${VIRSH_PREFIX}_spine-2" 2>/dev/null && echo "    spine-2: shutdown sent" || echo "    spine-2: not running"

# Wait briefly for graceful shutdown
echo "  Waiting for VMs to shut down..."
sleep 5

# Force-kill any that didn't shut down gracefully
STATE=$(virsh -c qemu:///system domstate "${VIRSH_PREFIX}_border-1" 2>/dev/null || echo "shut off")
if [ "$STATE" != "shut off" ]; then
    virsh -c qemu:///system destroy "${VIRSH_PREFIX}_border-1" 2>/dev/null && echo "    border-1: force-killed" || true
fi
STATE=$(virsh -c qemu:///system domstate "${VIRSH_PREFIX}_border-2" 2>/dev/null || echo "shut off")
if [ "$STATE" != "shut off" ]; then
    virsh -c qemu:///system destroy "${VIRSH_PREFIX}_border-2" 2>/dev/null && echo "    border-2: force-killed" || true
fi
STATE=$(virsh -c qemu:///system domstate "${VIRSH_PREFIX}_leaf-1a" 2>/dev/null || echo "shut off")
if [ "$STATE" != "shut off" ]; then
    virsh -c qemu:///system destroy "${VIRSH_PREFIX}_leaf-1a" 2>/dev/null && echo "    leaf-1a: force-killed" || true
fi
STATE=$(virsh -c qemu:///system domstate "${VIRSH_PREFIX}_leaf-1b" 2>/dev/null || echo "shut off")
if [ "$STATE" != "shut off" ]; then
    virsh -c qemu:///system destroy "${VIRSH_PREFIX}_leaf-1b" 2>/dev/null && echo "    leaf-1b: force-killed" || true
fi
STATE=$(virsh -c qemu:///system domstate "${VIRSH_PREFIX}_leaf-2a" 2>/dev/null || echo "shut off")
if [ "$STATE" != "shut off" ]; then
    virsh -c qemu:///system destroy "${VIRSH_PREFIX}_leaf-2a" 2>/dev/null && echo "    leaf-2a: force-killed" || true
fi
STATE=$(virsh -c qemu:///system domstate "${VIRSH_PREFIX}_leaf-2b" 2>/dev/null || echo "shut off")
if [ "$STATE" != "shut off" ]; then
    virsh -c qemu:///system destroy "${VIRSH_PREFIX}_leaf-2b" 2>/dev/null && echo "    leaf-2b: force-killed" || true
fi
STATE=$(virsh -c qemu:///system domstate "${VIRSH_PREFIX}_leaf-3a" 2>/dev/null || echo "shut off")
if [ "$STATE" != "shut off" ]; then
    virsh -c qemu:///system destroy "${VIRSH_PREFIX}_leaf-3a" 2>/dev/null && echo "    leaf-3a: force-killed" || true
fi
STATE=$(virsh -c qemu:///system domstate "${VIRSH_PREFIX}_leaf-3b" 2>/dev/null || echo "shut off")
if [ "$STATE" != "shut off" ]; then
    virsh -c qemu:///system destroy "${VIRSH_PREFIX}_leaf-3b" 2>/dev/null && echo "    leaf-3b: force-killed" || true
fi
STATE=$(virsh -c qemu:///system domstate "${VIRSH_PREFIX}_leaf-4a" 2>/dev/null || echo "shut off")
if [ "$STATE" != "shut off" ]; then
    virsh -c qemu:///system destroy "${VIRSH_PREFIX}_leaf-4a" 2>/dev/null && echo "    leaf-4a: force-killed" || true
fi
STATE=$(virsh -c qemu:///system domstate "${VIRSH_PREFIX}_leaf-4b" 2>/dev/null || echo "shut off")
if [ "$STATE" != "shut off" ]; then
    virsh -c qemu:///system destroy "${VIRSH_PREFIX}_leaf-4b" 2>/dev/null && echo "    leaf-4b: force-killed" || true
fi
STATE=$(virsh -c qemu:///system domstate "${VIRSH_PREFIX}_spine-1" 2>/dev/null || echo "shut off")
if [ "$STATE" != "shut off" ]; then
    virsh -c qemu:///system destroy "${VIRSH_PREFIX}_spine-1" 2>/dev/null && echo "    spine-1: force-killed" || true
fi
STATE=$(virsh -c qemu:///system domstate "${VIRSH_PREFIX}_spine-2" 2>/dev/null || echo "shut off")
if [ "$STATE" != "shut off" ]; then
    virsh -c qemu:///system destroy "${VIRSH_PREFIX}_spine-2" 2>/dev/null && echo "    spine-2: force-killed" || true
fi

# --- Detach persisted (--config) fabric/overlay NICs from every domain ---
# Servers/bastion stay running; only their extra fabric/overlay NICs are removed.
echo ""
echo "  Detaching persisted fabric/overlay NICs..."
detach_nic "border-1" "02:4E:57:01:01:01"
detach_nic "border-1" "02:4E:57:01:02:01"
detach_nic "border-1" "02:4E:57:01:03:01"
detach_nic "border-2" "02:4E:57:01:01:02"
detach_nic "border-2" "02:4E:57:01:02:02"
detach_nic "border-2" "02:4E:57:01:03:02"
detach_nic "leaf-1a" "02:4E:57:03:01:01"
detach_nic "leaf-1a" "02:4E:57:03:02:01"
detach_nic "leaf-1a" "02:4E:57:03:03:01"
detach_nic "leaf-1a" "02:4E:57:03:04:01"
detach_nic "leaf-1a" "02:4E:57:03:05:01"
detach_nic "leaf-1a" "02:4E:57:03:06:01"
detach_nic "leaf-1b" "02:4E:57:03:01:02"
detach_nic "leaf-1b" "02:4E:57:03:02:02"
detach_nic "leaf-1b" "02:4E:57:03:03:02"
detach_nic "leaf-1b" "02:4E:57:03:04:02"
detach_nic "leaf-1b" "02:4E:57:03:05:02"
detach_nic "leaf-1b" "02:4E:57:03:06:02"
detach_nic "leaf-2a" "02:4E:57:03:01:03"
detach_nic "leaf-2a" "02:4E:57:03:02:03"
detach_nic "leaf-2a" "02:4E:57:03:03:03"
detach_nic "leaf-2a" "02:4E:57:03:04:03"
detach_nic "leaf-2a" "02:4E:57:03:05:03"
detach_nic "leaf-2a" "02:4E:57:03:06:03"
detach_nic "leaf-2b" "02:4E:57:03:01:04"
detach_nic "leaf-2b" "02:4E:57:03:02:04"
detach_nic "leaf-2b" "02:4E:57:03:03:04"
detach_nic "leaf-2b" "02:4E:57:03:04:04"
detach_nic "leaf-2b" "02:4E:57:03:05:04"
detach_nic "leaf-2b" "02:4E:57:03:06:04"
detach_nic "leaf-3a" "02:4E:57:03:01:05"
detach_nic "leaf-3a" "02:4E:57:03:02:05"
detach_nic "leaf-3a" "02:4E:57:03:03:05"
detach_nic "leaf-3a" "02:4E:57:03:04:05"
detach_nic "leaf-3a" "02:4E:57:03:05:05"
detach_nic "leaf-3a" "02:4E:57:03:06:05"
detach_nic "leaf-3b" "02:4E:57:03:01:06"
detach_nic "leaf-3b" "02:4E:57:03:02:06"
detach_nic "leaf-3b" "02:4E:57:03:03:06"
detach_nic "leaf-3b" "02:4E:57:03:04:06"
detach_nic "leaf-3b" "02:4E:57:03:05:06"
detach_nic "leaf-3b" "02:4E:57:03:06:06"
detach_nic "leaf-4a" "02:4E:57:03:01:07"
detach_nic "leaf-4a" "02:4E:57:03:02:07"
detach_nic "leaf-4a" "02:4E:57:03:03:07"
detach_nic "leaf-4a" "02:4E:57:03:04:07"
detach_nic "leaf-4a" "02:4E:57:03:05:07"
detach_nic "leaf-4a" "02:4E:57:03:06:07"
detach_nic "leaf-4b" "02:4E:57:03:01:08"
detach_nic "leaf-4b" "02:4E:57:03:02:08"
detach_nic "leaf-4b" "02:4E:57:03:03:08"
detach_nic "leaf-4b" "02:4E:57:03:04:08"
detach_nic "leaf-4b" "02:4E:57:03:05:08"
detach_nic "leaf-4b" "02:4E:57:03:06:08"
detach_nic "spine-1" "02:4E:57:02:01:01"
detach_nic "spine-1" "02:4E:57:02:02:01"
detach_nic "spine-1" "02:4E:57:02:03:01"
detach_nic "spine-1" "02:4E:57:02:04:01"
detach_nic "spine-1" "02:4E:57:02:05:01"
detach_nic "spine-1" "02:4E:57:02:06:01"
detach_nic "spine-1" "02:4E:57:02:07:01"
detach_nic "spine-1" "02:4E:57:02:08:01"
detach_nic "spine-1" "02:4E:57:02:09:01"
detach_nic "spine-1" "02:4E:57:02:0A:01"
detach_nic "spine-2" "02:4E:57:02:01:02"
detach_nic "spine-2" "02:4E:57:02:02:02"
detach_nic "spine-2" "02:4E:57:02:03:02"
detach_nic "spine-2" "02:4E:57:02:04:02"
detach_nic "spine-2" "02:4E:57:02:05:02"
detach_nic "spine-2" "02:4E:57:02:06:02"
detach_nic "spine-2" "02:4E:57:02:07:02"
detach_nic "spine-2" "02:4E:57:02:08:02"
detach_nic "spine-2" "02:4E:57:02:09:02"
detach_nic "spine-2" "02:4E:57:02:0A:02"
detach_nic "leaf-1a" "02:4E:57:03:F0:01"
detach_nic "leaf-2a" "02:4E:57:03:F0:02"
detach_nic "leaf-3a" "02:4E:57:03:F0:03"
detach_nic "leaf-4a" "02:4E:57:03:F0:04"
detach_nic "leaf-4a" "02:4E:57:03:F0:05"
detach_nic "srv-1-1" "02:4E:57:04:01:01"
detach_nic "srv-1-1" "02:4E:57:04:01:02"
detach_nic "srv-1-2" "02:4E:57:04:02:01"
detach_nic "srv-1-2" "02:4E:57:04:02:02"
detach_nic "srv-1-3" "02:4E:57:04:03:01"
detach_nic "srv-1-3" "02:4E:57:04:03:02"
detach_nic "srv-1-4" "02:4E:57:04:04:01"
detach_nic "srv-1-4" "02:4E:57:04:04:02"
detach_nic "srv-2-1" "02:4E:57:04:05:01"
detach_nic "srv-2-1" "02:4E:57:04:05:02"
detach_nic "srv-2-2" "02:4E:57:04:06:01"
detach_nic "srv-2-2" "02:4E:57:04:06:02"
detach_nic "srv-2-3" "02:4E:57:04:07:01"
detach_nic "srv-2-3" "02:4E:57:04:07:02"
detach_nic "srv-2-4" "02:4E:57:04:08:01"
detach_nic "srv-2-4" "02:4E:57:04:08:02"
detach_nic "srv-3-1" "02:4E:57:04:09:01"
detach_nic "srv-3-1" "02:4E:57:04:09:02"
detach_nic "srv-3-2" "02:4E:57:04:0A:01"
detach_nic "srv-3-2" "02:4E:57:04:0A:02"
detach_nic "srv-3-3" "02:4E:57:04:0B:01"
detach_nic "srv-3-3" "02:4E:57:04:0B:02"
detach_nic "srv-3-4" "02:4E:57:04:0C:01"
detach_nic "srv-3-4" "02:4E:57:04:0C:02"
detach_nic "srv-4-1" "02:4E:57:04:0D:01"
detach_nic "srv-4-1" "02:4E:57:04:0D:02"
detach_nic "srv-4-2" "02:4E:57:04:0E:01"
detach_nic "srv-4-2" "02:4E:57:04:0E:02"
detach_nic "srv-4-3" "02:4E:57:04:0F:01"
detach_nic "srv-4-3" "02:4E:57:04:0F:02"
detach_nic "srv-4-4" "02:4E:57:04:10:01"
detach_nic "srv-4-4" "02:4E:57:04:10:02"
detach_nic "srv-1-1" "02:4E:57:07:01:01"
detach_nic "srv-2-1" "02:4E:57:07:05:01"
detach_nic "srv-3-1" "02:4E:57:07:09:01"
detach_nic "srv-4-1" "02:4E:57:07:0D:01"
detach_nic "srv-4-1" "02:4E:57:07:0D:02"
detach_nic "bastion" "02:4E:57:05:01:01"
detach_nic "bastion" "02:4E:57:05:01:02"

# --- Remove fabric bridges ---
echo ""
echo "  Removing fabric bridges..."
sudo ip link set br000 down 2>/dev/null || true
sudo ip link del br000 2>/dev/null && echo "    br000: removed" || true
sudo ip link set br001 down 2>/dev/null || true
sudo ip link del br001 2>/dev/null && echo "    br001: removed" || true
sudo ip link set br002 down 2>/dev/null || true
sudo ip link del br002 2>/dev/null && echo "    br002: removed" || true
sudo ip link set br003 down 2>/dev/null || true
sudo ip link del br003 2>/dev/null && echo "    br003: removed" || true
sudo ip link set br004 down 2>/dev/null || true
sudo ip link del br004 2>/dev/null && echo "    br004: removed" || true
sudo ip link set br005 down 2>/dev/null || true
sudo ip link del br005 2>/dev/null && echo "    br005: removed" || true
sudo ip link set br006 down 2>/dev/null || true
sudo ip link del br006 2>/dev/null && echo "    br006: removed" || true
sudo ip link set br007 down 2>/dev/null || true
sudo ip link del br007 2>/dev/null && echo "    br007: removed" || true
sudo ip link set br008 down 2>/dev/null || true
sudo ip link del br008 2>/dev/null && echo "    br008: removed" || true
sudo ip link set br009 down 2>/dev/null || true
sudo ip link del br009 2>/dev/null && echo "    br009: removed" || true
sudo ip link set br010 down 2>/dev/null || true
sudo ip link del br010 2>/dev/null && echo "    br010: removed" || true
sudo ip link set br011 down 2>/dev/null || true
sudo ip link del br011 2>/dev/null && echo "    br011: removed" || true
sudo ip link set br012 down 2>/dev/null || true
sudo ip link del br012 2>/dev/null && echo "    br012: removed" || true
sudo ip link set br013 down 2>/dev/null || true
sudo ip link del br013 2>/dev/null && echo "    br013: removed" || true
sudo ip link set br014 down 2>/dev/null || true
sudo ip link del br014 2>/dev/null && echo "    br014: removed" || true
sudo ip link set br015 down 2>/dev/null || true
sudo ip link del br015 2>/dev/null && echo "    br015: removed" || true
sudo ip link set br016 down 2>/dev/null || true
sudo ip link del br016 2>/dev/null && echo "    br016: removed" || true
sudo ip link set br017 down 2>/dev/null || true
sudo ip link del br017 2>/dev/null && echo "    br017: removed" || true
sudo ip link set br018 down 2>/dev/null || true
sudo ip link del br018 2>/dev/null && echo "    br018: removed" || true
sudo ip link set br019 down 2>/dev/null || true
sudo ip link del br019 2>/dev/null && echo "    br019: removed" || true
sudo ip link set br020 down 2>/dev/null || true
sudo ip link del br020 2>/dev/null && echo "    br020: removed" || true
sudo ip link set br021 down 2>/dev/null || true
sudo ip link del br021 2>/dev/null && echo "    br021: removed" || true
sudo ip link set br022 down 2>/dev/null || true
sudo ip link del br022 2>/dev/null && echo "    br022: removed" || true
sudo ip link set br023 down 2>/dev/null || true
sudo ip link del br023 2>/dev/null && echo "    br023: removed" || true
sudo ip link set br024 down 2>/dev/null || true
sudo ip link del br024 2>/dev/null && echo "    br024: removed" || true
sudo ip link set br025 down 2>/dev/null || true
sudo ip link del br025 2>/dev/null && echo "    br025: removed" || true
sudo ip link set br026 down 2>/dev/null || true
sudo ip link del br026 2>/dev/null && echo "    br026: removed" || true
sudo ip link set br027 down 2>/dev/null || true
sudo ip link del br027 2>/dev/null && echo "    br027: removed" || true
sudo ip link set br028 down 2>/dev/null || true
sudo ip link del br028 2>/dev/null && echo "    br028: removed" || true
sudo ip link set br029 down 2>/dev/null || true
sudo ip link del br029 2>/dev/null && echo "    br029: removed" || true
sudo ip link set br030 down 2>/dev/null || true
sudo ip link del br030 2>/dev/null && echo "    br030: removed" || true
sudo ip link set br031 down 2>/dev/null || true
sudo ip link del br031 2>/dev/null && echo "    br031: removed" || true
sudo ip link set br032 down 2>/dev/null || true
sudo ip link del br032 2>/dev/null && echo "    br032: removed" || true
sudo ip link set br033 down 2>/dev/null || true
sudo ip link del br033 2>/dev/null && echo "    br033: removed" || true
sudo ip link set br034 down 2>/dev/null || true
sudo ip link del br034 2>/dev/null && echo "    br034: removed" || true
sudo ip link set br035 down 2>/dev/null || true
sudo ip link del br035 2>/dev/null && echo "    br035: removed" || true
sudo ip link set br036 down 2>/dev/null || true
sudo ip link del br036 2>/dev/null && echo "    br036: removed" || true
sudo ip link set br037 down 2>/dev/null || true
sudo ip link del br037 2>/dev/null && echo "    br037: removed" || true
sudo ip link set br038 down 2>/dev/null || true
sudo ip link del br038 2>/dev/null && echo "    br038: removed" || true
sudo ip link set br039 down 2>/dev/null || true
sudo ip link del br039 2>/dev/null && echo "    br039: removed" || true
sudo ip link set br040 down 2>/dev/null || true
sudo ip link del br040 2>/dev/null && echo "    br040: removed" || true
sudo ip link set br041 down 2>/dev/null || true
sudo ip link del br041 2>/dev/null && echo "    br041: removed" || true
sudo ip link set br042 down 2>/dev/null || true
sudo ip link del br042 2>/dev/null && echo "    br042: removed" || true
sudo ip link set br043 down 2>/dev/null || true
sudo ip link del br043 2>/dev/null && echo "    br043: removed" || true
sudo ip link set br044 down 2>/dev/null || true
sudo ip link del br044 2>/dev/null && echo "    br044: removed" || true
sudo ip link set br045 down 2>/dev/null || true
sudo ip link del br045 2>/dev/null && echo "    br045: removed" || true
sudo ip link set br046 down 2>/dev/null || true
sudo ip link del br046 2>/dev/null && echo "    br046: removed" || true
sudo ip link set br047 down 2>/dev/null || true
sudo ip link del br047 2>/dev/null && echo "    br047: removed" || true
sudo ip link set br048 down 2>/dev/null || true
sudo ip link del br048 2>/dev/null && echo "    br048: removed" || true
sudo ip link set br049 down 2>/dev/null || true
sudo ip link del br049 2>/dev/null && echo "    br049: removed" || true
sudo ip link set br050 down 2>/dev/null || true
sudo ip link del br050 2>/dev/null && echo "    br050: removed" || true
sudo ip link set br051 down 2>/dev/null || true
sudo ip link del br051 2>/dev/null && echo "    br051: removed" || true
sudo ip link set br052 down 2>/dev/null || true
sudo ip link del br052 2>/dev/null && echo "    br052: removed" || true
sudo ip link set br053 down 2>/dev/null || true
sudo ip link del br053 2>/dev/null && echo "    br053: removed" || true

# --- Remove EVPN overlay access bridges ---
sudo ip link set br-ovl-01 down 2>/dev/null || true
sudo ip link del br-ovl-01 2>/dev/null && echo "    br-ovl-01: removed" || true
sudo ip link set br-ovl-05 down 2>/dev/null || true
sudo ip link del br-ovl-05 2>/dev/null && echo "    br-ovl-05: removed" || true
sudo ip link set br-ovl-09 down 2>/dev/null || true
sudo ip link del br-ovl-09 2>/dev/null && echo "    br-ovl-09: removed" || true
sudo ip link set br-ovl-0D down 2>/dev/null || true
sudo ip link del br-ovl-0D 2>/dev/null && echo "    br-ovl-0D: removed" || true
sudo ip link set br-ovl-0D-b down 2>/dev/null || true
sudo ip link del br-ovl-0D-b 2>/dev/null && echo "    br-ovl-0D-b: removed" || true

# --- Management bridge ---
# Managed by libvirt; do NOT delete it here.

echo ""
echo "NetWatch: Fabric teardown complete."
echo "  To destroy VMs: vagrant destroy -f"
