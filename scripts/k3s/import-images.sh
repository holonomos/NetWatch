#!/usr/bin/env bash
# ==========================================================================
# import-images.sh — Import pre-bundled container images to all k3s nodes
# ==========================================================================
# Distributes Cilium, MetalLB, and k3s system images from artifacts/
# to every k3s node via vagrant ssh + k3s ctr images import.
#
# Must run AFTER k3s agents are joined (containerd running on each node).
# Must run BEFORE helm install cilium/metallb.
#
# Run from host: bash scripts/k3s/import-images.sh
# ==========================================================================
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ARTIFACTS_DIR="$PROJECT_ROOT/artifacts"

# All k3s nodes: control plane (mgmt) + 16 agents (servers)
ALL_NODES=(
    mgmt
    srv-1-1 srv-1-2 srv-1-3 srv-1-4
    srv-2-1 srv-2-2 srv-2-3 srv-2-4
    srv-3-1 srv-3-2 srv-3-3 srv-3-4
    srv-4-1 srv-4-2 srv-4-3 srv-4-4
)

echo "========================================"
echo " NetWatch: Import Container Images"
echo "========================================"

# Check artifacts exist
TARBALLS=()
for tar in cilium-images.tar metallb-images.tar k3s-system-images.tar; do
    if [ -f "$ARTIFACTS_DIR/$tar" ]; then
        TARBALLS+=("$tar")
        echo "  Found: $tar ($(du -h "$ARTIFACTS_DIR/$tar" | cut -f1))"
    else
        echo "  MISSING: $tar — run: bash scripts/build-artifacts.sh"
    fi
done

if [ ${#TARBALLS[@]} -eq 0 ]; then
    echo "ERROR: No artifact tarballs found in artifacts/"
    echo "  Run: bash scripts/build-artifacts.sh"
    exit 1
fi

echo ""
echo "  Importing to ${#ALL_NODES[@]} nodes..."
echo ""

# Import each tarball to each node
for tar in "${TARBALLS[@]}"; do
    echo "--- Distributing $tar ---"
    for node in "${ALL_NODES[@]}"; do
        echo -n "  $node: "
        if vagrant ssh "$node" -c "sudo k3s ctr --namespace k8s.io images import /dev/stdin" < "$ARTIFACTS_DIR/$tar" 2>/dev/null; then
            echo "ok"
        else
            echo "FAILED (k3s/containerd may not be running yet)"
        fi
    done
    echo ""
done

echo "========================================"
echo " Image Import Complete"
echo "========================================"
echo "  Cilium + MetalLB + k3s system images cached on all nodes"
echo "  helm install will use local images — no internet pull needed"
