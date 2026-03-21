#!/bin/bash
# NetWatch — Chaos: Node Kill / Restore
# Stops or starts an FRR container to simulate a complete node failure.
#
# Usage:
#   bash scripts/chaos/node-kill.sh <node-name>             # kill (docker stop)
#   bash scripts/chaos/node-kill.sh <node-name> --restore   # restore (docker start)
#
# Only supports FRR containers (12 fabric nodes).
# Does NOT support server VMs — use 'vagrant halt/up' for those.
#
# Examples:
#   bash scripts/chaos/node-kill.sh spine-1
#   bash scripts/chaos/node-kill.sh spine-1 --restore
#   bash scripts/chaos/node-kill.sh leaf-2a

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# --- Help ---
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: bash $0 <node-name> [--restore]"
    echo ""
    echo "Kills an FRR container (docker stop) or restores it (docker start)."
    echo ""
    echo "Valid nodes:"
    echo "  border-1, border-2"
    echo "  spine-1, spine-2"
    echo "  leaf-1a, leaf-1b, leaf-2a, leaf-2b"
    echo "  leaf-3a, leaf-3b, leaf-4a, leaf-4b"
    echo ""
    echo "Examples:"
    echo "  bash $0 spine-1              # kill spine-1"
    echo "  bash $0 spine-1 --restore    # restore spine-1"
    exit 0
fi

# --- Args ---
require_args 1 $# "bash $0 <node-name> [--restore]"

NODE="$1"
RESTORE=false

if [[ "${2:-}" == "--restore" ]]; then
    RESTORE=true
fi

# --- Validate node is an FRR container ---
VALID=false
for container in "${FRR_CONTAINERS[@]}"; do
    if [[ "$container" == "$NODE" ]]; then
        VALID=true
        break
    fi
done

if [[ "$VALID" == false ]]; then
    log_chaos "ERROR: '${NODE}' is not a valid FRR container"
    log_chaos "  Valid nodes: ${FRR_CONTAINERS[*]}"
    log_chaos "  For server VMs, use: vagrant halt <vm-name> / vagrant up <vm-name>"
    exit 1
fi

# --- Check current state ---
CONTAINER_STATE=$(docker inspect -f '{{.State.Status}}' "$NODE" 2>/dev/null || echo "not_found")

if [[ "$CONTAINER_STATE" == "not_found" ]]; then
    log_chaos "ERROR: Container '${NODE}' does not exist"
    log_chaos "  Has the fabric been started? Run: bash scripts/fabric/setup-frr-containers.sh"
    exit 1
fi

if [[ "$RESTORE" == true ]]; then
    # --- Restore ---
    if [[ "$CONTAINER_STATE" == "running" ]]; then
        log_chaos "Container '${NODE}' is already running — nothing to do"
        exit 0
    fi

    log_chaos "ACTION: Starting container '${NODE}' (docker start)"
    docker start "$NODE"

    # Wait briefly for container to be running
    sleep 1
    NEW_STATE=$(docker inspect -f '{{.State.Status}}' "$NODE" 2>/dev/null || echo "unknown")
    log_chaos "Container '${NODE}' state: ${NEW_STATE}"

    log_chaos "EXPECTED: FRR daemons restart inside container"
    log_chaos "EXPECTED: BFD sessions re-establish on all interfaces within ~3s"
    log_chaos "EXPECTED: BGP sessions reconverge within ~30s"
    log_chaos "EXPECTED: Routes readvertised; traffic resumes via this node"

    annotate "RESTORE node-kill ${NODE} (docker start, was ${CONTAINER_STATE})" \
        "chaos,node-restore,${NODE}"
else
    # --- Kill ---
    if [[ "$CONTAINER_STATE" != "running" ]]; then
        log_chaos "Container '${NODE}' is already stopped (state: ${CONTAINER_STATE}) — nothing to do"
        exit 0
    fi

    log_chaos "ACTION: Killing container '${NODE}' (docker stop)"
    docker stop "$NODE"

    NEW_STATE=$(docker inspect -f '{{.State.Status}}' "$NODE" 2>/dev/null || echo "unknown")
    log_chaos "Container '${NODE}' state: ${NEW_STATE}"

    # Describe impact based on role
    case "$NODE" in
        border-*)
            log_chaos "EXPECTED: One border router down. External connectivity via remaining border."
            log_chaos "EXPECTED: 2 BGP sessions lost (to spine-1 and spine-2)"
            ;;
        spine-*)
            log_chaos "EXPECTED: One spine down. All leafs lose one uplink path."
            log_chaos "EXPECTED: 10 BGP sessions lost (2 border + 8 leaf)"
            log_chaos "EXPECTED: Traffic converges to remaining spine via ECMP"
            ;;
        leaf-*)
            RACK_NUM="${NODE:5:1}"
            log_chaos "EXPECTED: One leaf in rack-${RACK_NUM} down."
            log_chaos "EXPECTED: 2 BGP sessions lost (to spine-1 and spine-2)"
            log_chaos "EXPECTED: Servers lose one of two uplinks; ECMP shifts to remaining leaf"
            ;;
    esac

    annotate "INJECT node-kill ${NODE} (docker stop, was ${CONTAINER_STATE})" \
        "chaos,node-kill,${NODE}"
fi

log_chaos "Done."
