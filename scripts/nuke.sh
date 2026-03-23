#!/usr/bin/env bash
# ==========================================================================
# nuke.sh — Full fabric teardown to a clean slate
# ==========================================================================
# Destroys: FRR VMs (force-kill), fabric bridges, orphaned vnet/tap interfaces,
# and detaches all fabric NICs from VMs.
#
# Does NOT destroy server/bastion/mgmt VMs — use vagrant halt/destroy for those.
# Protects management NICs (netwatch-mgmt bridge) from being detached.
#
# Usage: bash scripts/nuke.sh
# ==========================================================================
set -uo pipefail

VIRSH_PREFIX="NetWatch"

# --- Resolve management bridge name (must be protected from detach) ---
MGMT_BRIDGE=$(virsh -c qemu:///system net-info netwatch-mgmt 2>/dev/null | awk '/Bridge:/{print $2}')
if [ -z "$MGMT_BRIDGE" ]; then
    MGMT_BRIDGE="virbr2"  # fallback
fi

echo "========================================"
echo " NetWatch: FABRIC NUKE"
echo "========================================"
echo "  Management bridge: $MGMT_BRIDGE (protected)"

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

# --- 3. Detach fabric NICs from VMs (protect management NICs) ---
echo ""
echo "=== Detaching fabric NICs from VMs ==="
for vm in $(virsh -c qemu:///system list --all --name 2>/dev/null | grep -i netwatch); do
    vm_state=$(virsh -c qemu:///system domstate "$vm" 2>/dev/null || echo "shut off")
    detached=0

    # Parse domiflist: skip header lines, skip mgmt bridge NICs
    while IFS= read -r line; do
        # domiflist columns: Interface  Type  Source  Model  MAC
        iface_source=$(echo "$line" | awk '{print $3}')
        iface_mac=$(echo "$line" | awk '{print $5}')
        iface_type=$(echo "$line" | awk '{print $2}')

        # Skip non-bridge interfaces
        [ "$iface_type" = "bridge" ] || continue

        # PROTECT management NICs — never detach the mgmt bridge
        if [ "$iface_source" = "$MGMT_BRIDGE" ]; then
            continue
        fi

        # Detach from both live (if running) and persistent config
        if [ "$vm_state" = "running" ]; then
            virsh -c qemu:///system detach-interface "$vm" bridge --mac "$iface_mac" --live --config 2>/dev/null && \
                detached=$((detached + 1)) || true
        else
            virsh -c qemu:///system detach-interface "$vm" bridge --mac "$iface_mac" --config 2>/dev/null && \
                detached=$((detached + 1)) || true
        fi
    done < <(virsh -c qemu:///system domiflist "$vm" 2>/dev/null | tail -n +3)

    echo "  $vm: detached $detached fabric NICs (mgmt NIC preserved)"
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
echo "  Fabric bridges: $(ip link show type bridge 2>/dev/null | grep -c 'br[0-9]' || echo 0)"
echo "  Mgmt bridge: $MGMT_BRIDGE (preserved)"
echo ""
echo "  Server/bastion/mgmt VMs untouched. Use 'vagrant halt' or 'vagrant destroy -f' separately."
echo "  To rebuild fabric: make up"
