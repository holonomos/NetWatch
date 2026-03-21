#!/usr/bin/env bash
# ==========================================================================
# nuke.sh — Full fabric teardown to a clean slate
# ==========================================================================
# Destroys: FRR containers, fabric bridges, veths, orphaned vnet interfaces,
# and detaches all fabric NICs from VMs.
#
# Does NOT touch VMs themselves — use vagrant halt/destroy for that.
#
# Usage: bash scripts/nuke.sh
# ==========================================================================
set -uo pipefail

echo "========================================"
echo " NetWatch: FABRIC NUKE"
echo "========================================"

# --- 1. Kill any stuck virsh processes ---
pkill -f "virsh.*detach" 2>/dev/null || true
pkill -f "virsh.*attach" 2>/dev/null || true

# --- 2. Stop and remove ALL FRR containers ---
echo ""
echo "=== Removing FRR containers ==="
for c in border-1 border-2 spine-1 spine-2 leaf-{1..4}{a,b}; do
    docker rm -f "$c" 2>/dev/null && echo "  $c: removed" || true
done

# --- 3. Detach all fabric NICs from VMs ---
echo ""
echo "=== Detaching fabric NICs from VMs ==="
for vm in $(virsh -c qemu:///system list --all --name 2>/dev/null | grep -i netwatch); do
    # Detach all bridge-type interfaces (fabric NICs)
    while true; do
        mac=$(virsh -c qemu:///system domiflist "$vm" 2>/dev/null | grep "bridge" | head -1 | awk '{print $5}')
        [ -z "$mac" ] && break
        virsh -c qemu:///system detach-interface "$vm" bridge --mac "$mac" --config 2>/dev/null || break
    done
    remaining=$(virsh -c qemu:///system domiflist "$vm" 2>/dev/null | grep -c bridge || echo 0)
    echo "  $vm: cleaned ($remaining fabric NICs remaining)"
done

# --- 4. Remove ALL fabric bridges ---
echo ""
echo "=== Removing fabric bridges ==="
removed=0
for i in $(seq 0 99); do
    br=$(printf "br%03d" $i)
    if ip link show "$br" &>/dev/null; then
        sudo ip link set "$br" down 2>/dev/null
        sudo ip link del "$br" 2>/dev/null
        removed=$((removed + 1))
    fi
done
echo "  $removed bridges removed"

# --- 5. Remove orphaned veth pairs ---
echo ""
echo "=== Cleaning orphaned veths ==="
cleaned=0
for veth in $(ip -o link show 2>/dev/null | grep -oP 'h-\S+(?=@)' || true); do
    sudo ip link del "$veth" 2>/dev/null
    cleaned=$((cleaned + 1))
done
echo "  $cleaned veths removed"

# --- Summary ---
echo ""
echo "========================================"
echo " CLEAN SLATE"
echo "========================================"
echo "  Containers: $(docker ps -q --filter ancestor=quay.io/frrouting/frr:9.1.0 2>/dev/null | wc -l) running"
echo "  Fabric bridges: $(ip link show type bridge 2>/dev/null | grep -c 'br[0-9]')"
echo ""
echo "  VMs untouched. Use 'vagrant halt' or 'vagrant destroy -f' separately."
echo "  To rebuild fabric: make up"
