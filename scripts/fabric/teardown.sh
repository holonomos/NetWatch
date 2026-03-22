#!/bin/bash
# NetWatch — Teardown
# Generated from topology.yml — DO NOT HAND-EDIT
#
# Shuts down all FRR VMs and removes fabric bridges.
# Does NOT destroy VMs (use `vagrant destroy` for that).
#
# Run as root: sudo ./teardown.sh

set -uo pipefail

VIRSH_PREFIX="NetWatch"

echo "NetWatch: Tearing down fabric..."

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

# --- Management bridge ---
# Managed by libvirt — do NOT delete it here.

# --- Clean up orphaned veth pairs ---
echo ""
echo "  Cleaning orphaned veth pairs..."
for veth in $(ip -o link show | grep -oP 'h-\S+(?=@)' || true); do
    sudo ip link del "$veth" 2>/dev/null && echo "    $veth: removed" || true
done

echo ""
echo "NetWatch: Fabric teardown complete."
echo "  To destroy VMs: vagrant destroy -f"
