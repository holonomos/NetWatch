#!/usr/bin/env bash
# ==========================================================================
# build-artifacts.sh — Download and bundle k3s container images + Helm charts
# ==========================================================================
# Run ONCE on a machine with Docker and internet access.
# Downloads Cilium, MetalLB, and k3s system images, saves as tarballs.
# These ship with the project — no internet needed at runtime.
#
# Prerequisites: Docker installed (only needed for this build step)
#
# Usage: bash scripts/build-artifacts.sh
# ==========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACTS_DIR="$PROJECT_ROOT/artifacts"

source "$PROJECT_ROOT/repo/versions.env"

CILIUM_VERSION="${CILIUM_VERSION:-1.16.6}"
METALLB_VERSION="${METALLB_VERSION:-0.14.9}"

mkdir -p "$ARTIFACTS_DIR"

echo "========================================"
echo " NetWatch: Build Container Artifacts"
echo "========================================"
echo "  Cilium:  v${CILIUM_VERSION}"
echo "  MetalLB: v${METALLB_VERSION}"
echo "  Output:  $ARTIFACTS_DIR/"
echo ""

# --- Cilium images ---
echo "=== Downloading Cilium v${CILIUM_VERSION} images ==="
CILIUM_IMAGES=(
    "quay.io/cilium/cilium:v${CILIUM_VERSION}"
    "quay.io/cilium/operator-generic:v${CILIUM_VERSION}"
    "quay.io/cilium/cilium-envoy:v1.30.9-1737073743-40a016d11c0d863b772961ed0168eea6fe6b10a5"
)

for img in "${CILIUM_IMAGES[@]}"; do
    echo "  Pulling $img..."
    docker pull "$img"
done

echo "  Saving cilium-images.tar..."
docker save -o "$ARTIFACTS_DIR/cilium-images.tar" "${CILIUM_IMAGES[@]}"
echo "  $(du -h "$ARTIFACTS_DIR/cilium-images.tar" | cut -f1)"

# --- MetalLB images ---
echo ""
echo "=== Downloading MetalLB v${METALLB_VERSION} images ==="
METALLB_IMAGES=(
    "quay.io/metallb/controller:v${METALLB_VERSION}"
    "quay.io/metallb/speaker:v${METALLB_VERSION}"
    "quay.io/frrouting/frr:9.1.0"
)

for img in "${METALLB_IMAGES[@]}"; do
    echo "  Pulling $img..."
    docker pull "$img"
done

echo "  Saving metallb-images.tar..."
docker save -o "$ARTIFACTS_DIR/metallb-images.tar" "${METALLB_IMAGES[@]}"
echo "  $(du -h "$ARTIFACTS_DIR/metallb-images.tar" | cut -f1)"

# --- k3s system images (pause container) ---
echo ""
echo "=== Downloading k3s system images ==="
K3S_IMAGES=(
    "rancher/mirrored-pause:3.6"
)

for img in "${K3S_IMAGES[@]}"; do
    echo "  Pulling $img..."
    docker pull "$img"
done

echo "  Saving k3s-system-images.tar..."
docker save -o "$ARTIFACTS_DIR/k3s-system-images.tar" "${K3S_IMAGES[@]}"
echo "  $(du -h "$ARTIFACTS_DIR/k3s-system-images.tar" | cut -f1)"

# --- Helm charts (offline install) ---
echo ""
echo "=== Downloading Helm charts ==="
helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
helm repo add metallb https://metallb.github.io/metallb 2>/dev/null || true
helm repo update 2>/dev/null

echo "  Pulling cilium chart v${CILIUM_VERSION}..."
helm pull cilium/cilium --version "${CILIUM_VERSION}" -d "$ARTIFACTS_DIR/"

echo "  Pulling metallb chart v${METALLB_VERSION}..."
helm pull metallb/metallb --version "${METALLB_VERSION}" -d "$ARTIFACTS_DIR/"

# --- Summary ---
echo ""
echo "========================================"
echo " Artifacts Built"
echo "========================================"
ls -lh "$ARTIFACTS_DIR/"
echo ""
echo "  Total: $(du -sh "$ARTIFACTS_DIR" | cut -f1)"
echo ""
echo "  These ship with the project. No internet needed at k3s runtime."
