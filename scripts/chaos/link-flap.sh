#!/bin/bash
# NetWatch — Chaos: Link Flap
# Toggles a fabric link down/up repeatedly to stress BFD and BGP convergence.
#
# Usage:
#   bash scripts/chaos/link-flap.sh <node-a> <node-b> [--interval SECS] [--count N]
#
# Defaults: 5 second interval, 5 cycles.
# Each cycle: bridge down -> sleep interval -> bridge up -> sleep interval.
#
# Examples:
#   bash scripts/chaos/link-flap.sh spine-1 leaf-1a
#   bash scripts/chaos/link-flap.sh border-1 spine-2 --interval 3 --count 10

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# --- Help ---
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: bash $0 <node-a> <node-b> [--interval SECS] [--count N]"
    echo ""
    echo "Flaps a fabric link by toggling its bridge down/up in cycles."
    echo ""
    echo "Options:"
    echo "  --interval SECS   Seconds between each toggle (default: 5)"
    echo "  --count N          Number of down/up cycles (default: 5)"
    echo ""
    echo "Examples:"
    echo "  bash $0 spine-1 leaf-1a"
    echo "  bash $0 border-1 spine-2 --interval 3 --count 10"
    exit 0
fi

# --- Args ---
require_args 2 $# "bash $0 <node-a> <node-b> [--interval SECS] [--count N]"

NODE_A="$1"
NODE_B="$2"
shift 2

INTERVAL=5
COUNT=5

while [[ $# -gt 0 ]]; do
    case "$1" in
        --interval)
            INTERVAL="${2:?--interval requires a value}"
            shift 2
            ;;
        --count)
            COUNT="${2:?--count requires a value}"
            shift 2
            ;;
        *)
            log_chaos "ERROR: Unknown option: $1"
            echo "Usage: bash $0 <node-a> <node-b> [--interval SECS] [--count N]" >&2
            exit 1
            ;;
    esac
done

# --- Resolve bridge ---
BRIDGE=$(resolve_bridge "$NODE_A" "$NODE_B") || exit 1

TOTAL_TIME=$(( COUNT * INTERVAL * 2 ))
log_chaos "Link flap: ${NODE_A} <-> ${NODE_B} via bridge ${BRIDGE}"
log_chaos "  Cycles: ${COUNT}, Interval: ${INTERVAL}s, Estimated duration: ${TOTAL_TIME}s"

annotate "INJECT link-flap START ${NODE_A} &lt;-&gt; ${NODE_B} (${COUNT} cycles, ${INTERVAL}s interval)" \
    "chaos,link-flap,${NODE_A},${NODE_B}"

# --- Flap loop ---
for (( i=1; i<=COUNT; i++ )); do
    log_chaos "Cycle ${i}/${COUNT}: DOWN"
    sudo ip link set "$BRIDGE" down
    sleep "$INTERVAL"

    log_chaos "Cycle ${i}/${COUNT}: UP"
    sudo ip link set "$BRIDGE" up
    sleep "$INTERVAL"
done

# --- Ensure link is UP after flapping ---
sudo ip link set "$BRIDGE" up
STATE=$(ip -o link show "$BRIDGE" | grep -oP 'state \K\S+')
log_chaos "Flap complete. Bridge ${BRIDGE} state: ${STATE}"
log_chaos "EXPECTED: BFD may have flapped multiple times; BGP should reconverge within ~30s"
log_chaos "EXPECTED: Check 'show bfd peers' and 'show bgp summary' for session stability"

annotate "INJECT link-flap END ${NODE_A} &lt;-&gt; ${NODE_B} (${COUNT} cycles completed)" \
    "chaos,link-flap,${NODE_A},${NODE_B}"

log_chaos "Done."
