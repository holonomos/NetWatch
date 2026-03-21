#!/bin/bash
# NetWatch — Chaos: Link Down / Restore
# Brings a fabric link down by disabling its bridge, or restores it.
#
# Usage:
#   bash scripts/chaos/link-down.sh <node-a> <node-b>             # bring link down
#   bash scripts/chaos/link-down.sh <node-a> <node-b> --restore   # bring link back up
#
# Examples:
#   bash scripts/chaos/link-down.sh spine-1 leaf-1a
#   bash scripts/chaos/link-down.sh spine-1 leaf-1a --restore

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# --- Help ---
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: bash $0 <node-a> <node-b> [--restore]"
    echo ""
    echo "Brings a fabric link down by disabling its Linux bridge."
    echo "Use --restore to bring the link back up."
    echo ""
    echo "Examples:"
    echo "  bash $0 spine-1 leaf-1a              # kill link"
    echo "  bash $0 spine-1 leaf-1a --restore    # restore link"
    exit 0
fi

# --- Args ---
require_args 2 $# "bash $0 <node-a> <node-b> [--restore]"

NODE_A="$1"
NODE_B="$2"
RESTORE=false

if [[ "${3:-}" == "--restore" ]]; then
    RESTORE=true
fi

# --- Resolve bridge ---
BRIDGE=$(resolve_bridge "$NODE_A" "$NODE_B") || exit 1

log_chaos "Link: ${NODE_A} <-> ${NODE_B} via bridge ${BRIDGE}"

if [[ "$RESTORE" == true ]]; then
    # --- Restore ---
    log_chaos "ACTION: Restoring link (ip link set ${BRIDGE} up)"
    sudo ip link set "$BRIDGE" up

    STATE=$(ip -o link show "$BRIDGE" | grep -oP 'state \K\S+')
    log_chaos "Bridge ${BRIDGE} state: ${STATE}"
    log_chaos "EXPECTED: BFD session re-establishes within ~3s, BGP reconverges within ~30s"

    annotate "RESTORE link ${NODE_A} &lt;-&gt; ${NODE_B} (bridge ${BRIDGE})" \
        "chaos,link-restore,${NODE_A},${NODE_B}"
else
    # --- Inject ---
    log_chaos "ACTION: Bringing link DOWN (ip link set ${BRIDGE} down)"
    sudo ip link set "$BRIDGE" down

    STATE=$(ip -o link show "$BRIDGE" | grep -oP 'state \K\S+')
    log_chaos "Bridge ${BRIDGE} state: ${STATE}"
    log_chaos "EXPECTED: BFD detects failure within ~3s (detect_multiplier=3, interval=1000ms)"
    log_chaos "EXPECTED: BGP withdraws routes after BFD triggers (or holdtime=90s without BFD)"
    log_chaos "EXPECTED: Traffic reconverges via alternate ECMP path"

    annotate "INJECT link-down ${NODE_A} &lt;-&gt; ${NODE_B} (bridge ${BRIDGE})" \
        "chaos,link-down,${NODE_A},${NODE_B}"
fi

log_chaos "Done."
