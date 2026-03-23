#!/bin/bash
# NetWatch — Chaos: Rack Partition
# Isolates an entire rack by bringing down all 4 spine-to-leaf links.
# Each rack has 2 leafs, each connected to 2 spines = 4 links total.
#
# Usage:
#   bash scripts/chaos/rack-partition.sh <rack-N>             # partition rack
#   bash scripts/chaos/rack-partition.sh <rack-N> --restore   # restore rack
#
# Examples:
#   bash scripts/chaos/rack-partition.sh rack-1
#   bash scripts/chaos/rack-partition.sh rack-3 --restore

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# --- Help ---
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: bash $0 <rack-N> [--restore]"
    echo ""
    echo "Partitions an entire rack by disabling all spine-to-leaf links."
    echo "Each rack has 2 leafs x 2 spines = 4 links."
    echo ""
    echo "Valid racks: rack-1, rack-2, rack-3, rack-4"
    echo ""
    echo "Rack mapping:"
    echo "  rack-1 -> leaf-1a, leaf-1b (ASN 65101)"
    echo "  rack-2 -> leaf-2a, leaf-2b (ASN 65102)"
    echo "  rack-3 -> leaf-3a, leaf-3b (ASN 65103)"
    echo "  rack-4 -> leaf-4a, leaf-4b (ASN 65104)"
    echo ""
    echo "Examples:"
    echo "  bash $0 rack-1              # partition rack-1"
    echo "  bash $0 rack-3 --restore    # restore rack-3"
    exit 0
fi

# --- Args ---
require_args 1 $# "bash $0 <rack-N> [--restore]"

RACK="$1"
RESTORE=false

if [[ "${2:-}" == "--restore" ]]; then
    RESTORE=true
fi

# --- Validate rack ---
LEAFS="${RACK_LEAFS[$RACK]:-}"
if [[ -z "$LEAFS" ]]; then
    log_chaos "ERROR: Unknown rack '${RACK}'. Valid: rack-1, rack-2, rack-3, rack-4"
    exit 1
fi

read -r LEAF_A LEAF_B <<< "$LEAFS"
SPINES="spine-1 spine-2"

log_chaos "Rack partition: ${RACK} (leafs: ${LEAF_A}, ${LEAF_B})"

# --- Build list of bridges ---
BRIDGES=()
LINK_DESC=()
for leaf in $LEAF_A $LEAF_B; do
    for spine in $SPINES; do
        bridge=$(resolve_bridge "$spine" "$leaf") || exit 1
        BRIDGES+=("$bridge")
        LINK_DESC+=("${spine} <-> ${leaf} (${bridge})")
    done
done

if [[ "$RESTORE" == true ]]; then
    # --- Restore ---
    log_chaos "ACTION: Restoring all 4 spine-leaf links for ${RACK}"
    for i in "${!BRIDGES[@]}"; do
        sudo ip link set "${BRIDGES[$i]}" up
        log_chaos "  UP: ${LINK_DESC[$i]}"
    done

    log_chaos "EXPECTED: 4 BFD sessions re-establish within ~3s"
    log_chaos "EXPECTED: 4 BGP sessions reconverge within ~30s"
    log_chaos "EXPECTED: Rack ${RACK} servers become reachable again"

    annotate "RESTORE rack-partition ${RACK} (4 links restored: ${LEAF_A}, ${LEAF_B})" \
        "chaos,rack-partition-restore,${RACK}"
else
    # --- Inject ---
    log_chaos "ACTION: Partitioning ${RACK} — bringing down all 4 spine-leaf links"
    for i in "${!BRIDGES[@]}"; do
        sudo ip link set "${BRIDGES[$i]}" down
        log_chaos "  DOWN: ${LINK_DESC[$i]}"
    done

    log_chaos "EXPECTED: All 4 BFD sessions fail within ~3s"
    log_chaos "EXPECTED: All 4 BGP sessions go down; rack routes withdrawn"
    log_chaos "EXPECTED: Servers in ${RACK} become unreachable from other racks"
    log_chaos "EXPECTED: Leaf-to-server links within ${RACK} remain up (intra-rack still works)"
    log_chaos ""
    log_chaos "WARNING: This is a full rack partition. All servers in ${RACK} are isolated"
    log_chaos "  from the rest of the fabric. Use --restore to reconnect."

    annotate "INJECT rack-partition ${RACK} (4 links down: ${LEAF_A}, ${LEAF_B})" \
        "chaos,rack-partition,${RACK}"
fi

log_chaos "Done."
