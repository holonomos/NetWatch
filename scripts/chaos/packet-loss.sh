#!/bin/bash
# NetWatch — Chaos: Packet Loss Injection
# Introduces artificial packet loss on a fabric link using tc netem.
#
# Usage:
#   bash scripts/chaos/packet-loss.sh <node-a> <node-b> --loss 10%
#   bash scripts/chaos/packet-loss.sh <node-a> <node-b> --restore
#
# Applies netem to ALL host-side veths on the bridge (both directions).
#
# Examples:
#   bash scripts/chaos/packet-loss.sh spine-1 leaf-1a --loss 10%
#   bash scripts/chaos/packet-loss.sh spine-1 leaf-1a --loss 50%
#   bash scripts/chaos/packet-loss.sh spine-1 leaf-1a --restore

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# --- Help ---
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: bash $0 <node-a> <node-b> --loss PCT"
    echo "       bash $0 <node-a> <node-b> --restore"
    echo ""
    echo "Injects packet loss on a fabric link using tc netem."
    echo ""
    echo "Options:"
    echo "  --loss PCT     Packet loss percentage (e.g., 10%, 50%)"
    echo "  --restore      Remove all netem rules from the link"
    echo ""
    echo "Examples:"
    echo "  bash $0 spine-1 leaf-1a --loss 10%"
    echo "  bash $0 spine-1 leaf-1a --loss 50%"
    echo "  bash $0 spine-1 leaf-1a --restore"
    exit 0
fi

# --- Args ---
require_args 2 $# "bash $0 <node-a> <node-b> --loss PCT | --restore"

NODE_A="$1"
NODE_B="$2"
shift 2

RESTORE=false
LOSS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --restore)
            RESTORE=true
            shift
            ;;
        --loss)
            LOSS="${2:?--loss requires a value (e.g., 10%)}"
            shift 2
            ;;
        *)
            log_chaos "ERROR: Unknown option: $1"
            echo "Usage: bash $0 <node-a> <node-b> --loss PCT | --restore" >&2
            exit 1
            ;;
    esac
done

if [[ "$RESTORE" == false && -z "$LOSS" ]]; then
    log_chaos "ERROR: Must specify --loss or --restore"
    echo "Usage: bash $0 <node-a> <node-b> --loss PCT | --restore" >&2
    exit 1
fi

# --- Resolve bridge and veths ---
BRIDGE=$(resolve_bridge "$NODE_A" "$NODE_B") || exit 1
VETHS=$(find_veths "$BRIDGE") || exit 1

if [[ -z "$VETHS" ]]; then
    log_chaos "ERROR: No veth interfaces found on bridge ${BRIDGE}"
    log_chaos "  Is the fabric running? Check: ip link show master ${BRIDGE}"
    exit 1
fi

VETH_COUNT=$(echo "$VETHS" | wc -l)
log_chaos "Link: ${NODE_A} <-> ${NODE_B} via bridge ${BRIDGE} (${VETH_COUNT} veths)"

if [[ "$RESTORE" == true ]]; then
    # --- Restore ---
    log_chaos "ACTION: Removing netem rules from all veths on ${BRIDGE}"
    while IFS= read -r veth; do
        sudo tc qdisc del dev "$veth" root 2>/dev/null || true
        log_chaos "  Cleared: ${veth}"
    done <<< "$VETHS"

    log_chaos "EXPECTED: Packet loss stops immediately"

    annotate "RESTORE packet-loss ${NODE_A} &lt;-&gt; ${NODE_B} (bridge ${BRIDGE})" \
        "chaos,packet-loss-restore,${NODE_A},${NODE_B}"
else
    # --- Inject ---
    log_chaos "ACTION: Injecting ${LOSS} packet loss on all veths on ${BRIDGE}"
    while IFS= read -r veth; do
        # Remove existing qdisc first (idempotent)
        sudo tc qdisc del dev "$veth" root 2>/dev/null || true
        sudo tc qdisc add dev "$veth" root netem loss ${LOSS}
        log_chaos "  Applied to: ${veth} (netem loss ${LOSS})"
    done <<< "$VETHS"

    log_chaos "EXPECTED: ${LOSS} of packets dropped on this link"
    log_chaos "EXPECTED: BFD may flap at high loss rates (>30% with 1000ms intervals)"
    log_chaos "EXPECTED: BGP keepalives may be lost; holdtime expiry at 90s"
    log_chaos "EXPECTED: TCP throughput degrades significantly above 5% loss"

    annotate "INJECT packet-loss ${LOSS} ${NODE_A} &lt;-&gt; ${NODE_B} (bridge ${BRIDGE})" \
        "chaos,packet-loss,${NODE_A},${NODE_B}"
fi

log_chaos "Done."
