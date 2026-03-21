#!/bin/bash
# NetWatch — Chaos: Latency Injection
# Adds artificial latency (and optional jitter) to a fabric link using tc netem.
#
# Usage:
#   bash scripts/chaos/latency-inject.sh <node-a> <node-b> --delay 100ms [--jitter 20ms]
#   bash scripts/chaos/latency-inject.sh <node-a> <node-b> --restore
#
# Applies netem to ALL host-side veths on the bridge (both directions).
#
# Examples:
#   bash scripts/chaos/latency-inject.sh spine-1 leaf-1a --delay 100ms
#   bash scripts/chaos/latency-inject.sh spine-1 leaf-1a --delay 200ms --jitter 50ms
#   bash scripts/chaos/latency-inject.sh spine-1 leaf-1a --restore

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# --- Help ---
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: bash $0 <node-a> <node-b> --delay MS [--jitter MS]"
    echo "       bash $0 <node-a> <node-b> --restore"
    echo ""
    echo "Injects latency on a fabric link using tc netem."
    echo ""
    echo "Options:"
    echo "  --delay MS     Delay to add (e.g., 100ms, 500ms)"
    echo "  --jitter MS    Optional jitter (e.g., 20ms)"
    echo "  --restore      Remove all netem rules from the link"
    echo ""
    echo "Examples:"
    echo "  bash $0 spine-1 leaf-1a --delay 100ms"
    echo "  bash $0 spine-1 leaf-1a --delay 200ms --jitter 50ms"
    echo "  bash $0 spine-1 leaf-1a --restore"
    exit 0
fi

# --- Args ---
require_args 2 $# "bash $0 <node-a> <node-b> --delay MS [--jitter MS] | --restore"

NODE_A="$1"
NODE_B="$2"
shift 2

RESTORE=false
DELAY=""
JITTER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --restore)
            RESTORE=true
            shift
            ;;
        --delay)
            DELAY="${2:?--delay requires a value (e.g., 100ms)}"
            shift 2
            ;;
        --jitter)
            JITTER="${2:?--jitter requires a value (e.g., 20ms)}"
            shift 2
            ;;
        *)
            log_chaos "ERROR: Unknown option: $1"
            echo "Usage: bash $0 <node-a> <node-b> --delay MS [--jitter MS] | --restore" >&2
            exit 1
            ;;
    esac
done

if [[ "$RESTORE" == false && -z "$DELAY" ]]; then
    log_chaos "ERROR: Must specify --delay or --restore"
    echo "Usage: bash $0 <node-a> <node-b> --delay MS [--jitter MS] | --restore" >&2
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

    log_chaos "EXPECTED: Latency returns to normal immediately"

    annotate "RESTORE latency ${NODE_A} &lt;-&gt; ${NODE_B} (bridge ${BRIDGE})" \
        "chaos,latency-restore,${NODE_A},${NODE_B}"
else
    # --- Inject ---
    NETEM_ARGS="delay ${DELAY}"
    DESCRIPTION="delay=${DELAY}"
    if [[ -n "$JITTER" ]]; then
        NETEM_ARGS="${NETEM_ARGS} ${JITTER}"
        DESCRIPTION="${DESCRIPTION}, jitter=${JITTER}"
    fi

    log_chaos "ACTION: Injecting latency (${DESCRIPTION}) on all veths on ${BRIDGE}"
    while IFS= read -r veth; do
        # Remove existing qdisc first (idempotent)
        sudo tc qdisc del dev "$veth" root 2>/dev/null || true
        sudo tc qdisc add dev "$veth" root netem ${NETEM_ARGS}
        log_chaos "  Applied to: ${veth} (netem ${NETEM_ARGS})"
    done <<< "$VETHS"

    log_chaos "EXPECTED: RTT increases by ~${DELAY} per hop"
    log_chaos "EXPECTED: BFD may flap if delay exceeds detect threshold (3000ms with current timers)"
    log_chaos "EXPECTED: BGP keepalives may be delayed; watch for holdtime expiry at >90s total delay"

    annotate "INJECT latency ${NODE_A} &lt;-&gt; ${NODE_B} (${DESCRIPTION}, bridge ${BRIDGE})" \
        "chaos,latency-inject,${NODE_A},${NODE_B}"
fi

log_chaos "Done."
