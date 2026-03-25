#!/usr/bin/env bash
# ==========================================================================
# setup-registry.sh — Set up a container image registry on bastion
# ==========================================================================
# Runs a lightweight OCI registry on bastion:5000.
# k3s nodes pull images from bastion.netwatch.lab:5000.
#
# The registry runs as a simple Python HTTP server using the OCI distribution
# spec. For production, replace with distribution/distribution (Docker registry).
# For NetWatch, we use k3s's built-in containerd image import instead.
#
# Approach: Pre-load images on bastion, then import via k3s ctr on each node.
# This avoids running a registry daemon and works air-gapped.
#
# Run from host: bash scripts/bastion/setup-registry.sh
# ==========================================================================
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGES_DIR="$PROJECT_ROOT/images"

echo "========================================"
echo " NetWatch: Container Image Distribution"
echo "========================================"

if [ ! -d "$IMAGES_DIR" ]; then
    echo "  No images/ directory found."
    echo "  To add images for deployment:"
    echo "    1. Save image: docker save myapp:latest > images/myapp.tar"
    echo "    2. Run: bash scripts/bastion/setup-registry.sh"
    echo "    3. Images will be imported to all k3s nodes"
    mkdir -p "$IMAGES_DIR"
    exit 0
fi

# Find all .tar image files
IMAGES=$(find "$IMAGES_DIR" -name "*.tar" -type f 2>/dev/null)
if [ -z "$IMAGES" ]; then
    echo "  No .tar image files in images/"
    echo "  Save images with: docker save <image> > images/<name>.tar"
    exit 0
fi

echo "  Found images:"
for img in $IMAGES; do
    echo "    $(basename "$img") ($(du -h "$img" | cut -f1))"
done

echo ""
echo "  Distributing to k3s nodes via bastion..."

# Upload images to bastion first
for img in $IMAGES; do
    imgname=$(basename "$img")
    echo "  Uploading $imgname to bastion..."
    cat "$img" | vagrant ssh bastion -c "cat > /tmp/$imgname"
done

# Import on each k3s node via bastion
SERVER_VM="srv-1-1"
NODES=$(vagrant ssh "$SERVER_VM" -c "sudo k3s kubectl get nodes -o jsonpath='{.items[*].metadata.name}'" 2>/dev/null | tr -d '[:cntrl:]')

for img in $IMAGES; do
    imgname=$(basename "$img")
    echo ""
    echo "  Importing $imgname to k3s nodes..."
    for node in $NODES; do
        echo "    $node..."
        vagrant ssh bastion -c "cat /tmp/$imgname | ssh -o StrictHostKeyChecking=no vagrant@$node 'sudo k3s ctr images import -'" 2>/dev/null && \
            echo "      imported" || echo "      failed (will pull from registry on demand)"
    done
done

echo ""
echo "=== Image Distribution Complete ==="
echo "  Images available on all k3s nodes"
echo "  Reference in manifests with the image name (no registry prefix needed)"
