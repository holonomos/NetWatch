#!/usr/bin/env bash
# ==========================================================================
# nuke.sh — Full fabric teardown to a clean slate
# ==========================================================================
# Destroys: FRR VMs (force-kill), fabric bridges, orphaned vnet/tap interfaces,
# and detaches all fabric NICs from VMs.
#
# Does NOT destroy server/bastion/mgmt VMs — use vagrant halt/destroy for those.
#
# Usage: bash scripts/nuke.sh
# ==========================================================================
set -uo pipefail

VIRSH_PREFIX="NetWatch"

echo "========================================"
echo " NetWatch: FABRIC NUKE"
echo "========================================"

# --- 1. Kill any stuck virsh processes ---
pkill -f "virsh.*detach" 2>/dev/null || true
pkill -f "virsh.*attach" 2>/dev/null || true

# --- 2. Force-kill all FRR VMs ---
echo ""
echo "=== Destroying FRR VMs ==="
for node in border-1 border-2 spine-1 spine-2 leaf-{1..4}{a,b}; do
    domain="${VIRSH_PREFIX}_${node}"
    state=$(virsh -c qemu:///system domstate "$domain" 2>/dev/null || echo "not found")
    if [ "$state" = "running" ]; then
        virsh -c qemu:///system destroy "$domain" 2>/dev/null && echo "  $node: destroyed" || true
    elif [ "$state" = "shut off" ]; then
        echo "  $node: already shut off"
    else
        echo "  $node: $state"
    fi
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

# --- 5. Remove orphaned veth/tap pairs ---
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
echo "  FRR VMs: all force-killed"
echo "  Fabric bridges: $(ip link show type bridge 2>/dev/null | grep -c 'br[0-9]')"
echo ""
echo "  Server/bastion/mgmt VMs untouched. Use 'vagrant halt' or 'vagrant destroy -f' separately."
echo "  To rebuild fabric: make up"
