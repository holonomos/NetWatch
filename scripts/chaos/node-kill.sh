#!/bin/bash
# NetWatch — Chaos: Node Kill / Restore
# Destroys or starts an FRR VM to simulate a complete node failure.
#
# Usage:
#   bash scripts/chaos/node-kill.sh <node-name>             # kill (virsh destroy)
#   bash scripts/chaos/node-kill.sh <node-name> --restore   # restore (virsh start + reconfigure)
#
# Only supports FRR VMs (12 fabric nodes).
# Does NOT support server VMs — use 'vagrant halt/up' for those.
#
# Examples:
#   bash scripts/chaos/node-kill.sh spine-1
#   bash scripts/chaos/node-kill.sh spine-1 --restore
#   bash scripts/chaos/node-kill.sh leaf-2a

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Help ---
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: bash $0 <node-name> [--restore]"
    echo ""
    echo "Kills an FRR VM (virsh destroy) or restores it (virsh start)."
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

# --- Validate node is an FRR VM ---
VALID=false
for vm in "${FRR_NODES[@]}"; do
    if [[ "$vm" == "$NODE" ]]; then
        VALID=true
        break
    fi
done

if [[ "$VALID" == false ]]; then
    log_chaos "ERROR: '${NODE}' is not a valid FRR VM"
    log_chaos "  Valid nodes: ${FRR_NODES[*]}"
    log_chaos "  For server VMs, use: vagrant halt <vm-name> / vagrant up <vm-name>"
    exit 1
fi

DOMAIN="${VIRSH_PREFIX}_${NODE}"

# --- Check current state ---
VM_STATE=$(virsh -c qemu:///system domstate "$DOMAIN" 2>/dev/null || echo "not_found")

if [[ "$VM_STATE" == "not_found" ]]; then
    log_chaos "ERROR: VM '${DOMAIN}' does not exist"
    log_chaos "  Has the fabric been started? Run: vagrant up ${NODE}"
    exit 1
fi

if [[ "$RESTORE" == true ]]; then
    # --- Restore ---
    if [[ "$VM_STATE" == "running" ]]; then
        log_chaos "VM '${NODE}' is already running — nothing to do"
        exit 0
    fi

    log_chaos "ACTION: Starting VM '${NODE}' (virsh start)"
    virsh -c qemu:///system start "$DOMAIN"

    # Wait for VM to be accessible
    log_chaos "Waiting for VM to become accessible..."
    SSH_OK=false
    for i in $(seq 1 30); do
        if cd "$PROJECT_ROOT" && vagrant ssh "$NODE" -c "true" 2>/dev/null; then
            SSH_OK=true
            break
        fi
        sleep 2
    done

    NEW_STATE=$(virsh -c qemu:///system domstate "$DOMAIN" 2>/dev/null || echo "unknown")
    log_chaos "VM '${NODE}' state: ${NEW_STATE}"

    if [[ "$SSH_OK" == false ]]; then
        log_chaos "WARNING: VM '${NODE}' started but SSH not accessible after 60s"
        log_chaos "  Manual intervention may be required: vagrant ssh ${NODE}"
        exit 1
    fi

    log_chaos "EXPECTED: FRR daemons restart inside VM (NM profiles persist IPs)"
    log_chaos "EXPECTED: BFD sessions re-establish on all interfaces within ~3s"
    log_chaos "EXPECTED: BGP sessions reconverge within ~30s"
    log_chaos "EXPECTED: Routes readvertised; traffic resumes via this node"

    annotate "RESTORE node-kill ${NODE} (virsh start, was ${VM_STATE})" \
        "chaos,node-restore,${NODE}"
else
    # --- Kill ---
    if [[ "$VM_STATE" != "running" ]]; then
        log_chaos "VM '${NODE}' is already stopped (state: ${VM_STATE}) — nothing to do"
        exit 0
    fi

    log_chaos "ACTION: Killing VM '${NODE}' (virsh destroy)"
    virsh -c qemu:///system destroy "$DOMAIN"

    NEW_STATE=$(virsh -c qemu:///system domstate "$DOMAIN" 2>/dev/null || echo "unknown")
    log_chaos "VM '${NODE}' state: ${NEW_STATE}"

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

    annotate "INJECT node-kill ${NODE} (virsh destroy, was ${VM_STATE})" \
        "chaos,node-kill,${NODE}"
fi

log_chaos "Done."
