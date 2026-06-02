#!/usr/bin/env bash
# ==========================================================================
# build.sh — Build the NetWatch artifact depot (fabric-only)
# ==========================================================================
# Downloads artifacts needed for an offline fabric deployment:
#   - Base Fedora Vagrant box
#   - RPMs (via Docker + Fedora container)
#   - Binary tools (node_exporter, frr_exporter, promtail, loki, prometheus, grafana)
#
# Run ONCE on a machine with internet + Docker. After this, the fabric can
# boot and configure without network access.
#
# Prerequisites:
#   - Docker (for RPM download)
#   - createrepo_c (dnf install createrepo_c)
#   - Internet access
#
# Usage:
#   bash scripts/artifacts/build.sh
#
# Bootstrap sequence:
#   1. make artifacts-build   ← YOU ARE HERE
#   2. make bake              (builds golden box)
#   3. make box-register      (registers box with vagrant)
#   4. make generate          (generates configs)
#   5. make artifacts-serve   (starts HTTP server)
#   6. make vms               (boots all VMs — NO internet)
# ==========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACTS_DIR="$PROJECT_ROOT/artifacts"

# --- Source pinned versions ------------------------------------------------
source "$ARTIFACTS_DIR/versions.env"

# --- Preflight checks ------------------------------------------------------
echo "=== NetWatch Artifact Builder ==="
echo ""

MISSING=()
command -v docker &>/dev/null || MISSING+=("docker (needed for RPM download)")

if ! command -v createrepo_c &>/dev/null; then
  echo "createrepo_c not found, installing..."
  sudo dnf install -y createrepo_c || {
    MISSING+=("createrepo_c (dnf install createrepo_c)")
  }
fi

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "ERROR: Missing required tools:"
  for m in "${MISSING[@]}"; do
    echo "  - $m"
  done
  exit 1
fi

echo "  Versions:"
echo "    Fedora:          ${FEDORA_RELEASE}"
echo "    node_exporter:   ${NODE_EXPORTER_VERSION}"
echo "    frr_exporter:    ${FRR_EXPORTER_VERSION}"
echo "    promtail:        ${PROMTAIL_VERSION}"
echo "    loki:            ${LOKI_VERSION}"
echo "    prometheus:      ${PROMETHEUS_VERSION}"
echo "    grafana:         ${GRAFANA_VERSION}"
echo ""

# --- Directory setup -------------------------------------------------------
mkdir -p "$ARTIFACTS_DIR"/{boxes,rpms,binaries}

FAILED=0

# ==========================================================================
# Phase 1: Base Vagrant box
# ==========================================================================
echo "=== Phase 1: Base Fedora ${FEDORA_RELEASE} Vagrant box ==="
echo ""

FEDORA_BOX_NAME="fedora-${FEDORA_RELEASE}.box"
FEDORA_BOX="$ARTIFACTS_DIR/boxes/${FEDORA_BOX_NAME}"
FEDORA_BOX_URL="${FEDORA_BOX_URL:-https://app.vagrantup.com/fedora/boxes/${FEDORA_RELEASE}-cloud-base/versions/${FEDORA_RELEASE}.0/providers/libvirt/amd64/vagrant.box}"

if [ -f "$FEDORA_BOX" ]; then
  echo "  [skip] ${FEDORA_BOX_NAME} (already exists: $(du -h "$FEDORA_BOX" | cut -f1))"
else
  echo "  [download] ${FEDORA_BOX_NAME}..."
  if curl -fSL "$FEDORA_BOX_URL" -o "$FEDORA_BOX"; then
    echo "  [ok] ${FEDORA_BOX_NAME} ($(du -h "$FEDORA_BOX" | cut -f1))"
  else
    echo "  [FAIL] ${FEDORA_BOX_NAME}"
    echo "    URL: $FEDORA_BOX_URL"
    rm -f "$FEDORA_BOX"
    FAILED=$((FAILED + 1))
  fi
fi

# ==========================================================================
# Phase 2: RPM packages (Fedora container)
# ==========================================================================
echo ""
echo "=== Phase 2: Downloading RPMs (Fedora ${FEDORA_RELEASE} container) ==="
echo ""

RPM_LIST=(
  # Universal baseline
  chrony
  rsyslog
  # Bastion
  iptables-services
  # obs
  curl
  unzip
  jq
  dnsmasq
  # Networking
  ethtool
  iproute-tc
  # SELinux / Ansible
  python3-libselinux
  policycoreutils
  ansible
  sshpass
  audit
  # FRR routing
  frr
  # Misc
  logrotate
  bash-completion
  tar
  bpftool
  # Extras (dev tools, debugging, stress — installed post-boot via provision-extras.sh)
  wget
  git
  vim-enhanced
  tmux
  net-tools
  iproute
  bind-utils
  mtr
  tcpdump
  traceroute
  htop
  iotop
  iftop
  strace
  lsof
  nmap-ncat
  iputils
  stress-ng
  gcc
  make
  automake
  cmake
  openssl-devel
  openssl
  python3
  python3-pip
)

docker run --rm \
  -v "$ARTIFACTS_DIR/rpms:/rpms:z" \
  "fedora:${FEDORA_RELEASE}" \
  bash -c "
    dnf install -y 'dnf-command(download)' && \
    dnf download \
      --destdir=/rpms \
      --resolve \
      --alldeps \
      --skip-unavailable \
      ${RPM_LIST[*]} \
      2>&1 | tail -10
    echo \"RPMs downloaded: \$(ls /rpms/*.rpm 2>/dev/null | wc -l)\"
  "

# ==========================================================================
# Phase 3: Index RPM repository
# ==========================================================================
echo ""
echo "=== Phase 3: Indexing RPM repository ==="
echo ""

createrepo_c "$ARTIFACTS_DIR/rpms"
echo "  repodata created at: $ARTIFACTS_DIR/rpms/repodata/"

# ==========================================================================
# Phase 4: Binary artifacts
# ==========================================================================
echo ""
echo "=== Phase 4: Downloading binary artifacts ==="
echo ""

download_artifact() {
  local name="$1"
  local url="$2"
  local dest="$ARTIFACTS_DIR/binaries/$3"

  if [ -f "$dest" ]; then
    echo "  [skip] $name (already exists)"
    return 0
  fi

  echo "  [download] $name..."
  if curl -fSL "$url" -o "$dest"; then
    echo "  [ok] $name ($(du -h "$dest" | cut -f1))"
  else
    echo "  [FAIL] $name"
    echo "    URL: $url"
    rm -f "$dest"
    return 1
  fi
}

download_artifact "node_exporter v${NODE_EXPORTER_VERSION}" \
  "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz" \
  "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz" || FAILED=$((FAILED + 1))

download_artifact "frr_exporter v${FRR_EXPORTER_VERSION}" \
  "https://github.com/tynany/frr_exporter/releases/download/v${FRR_EXPORTER_VERSION}/frr_exporter-${FRR_EXPORTER_VERSION}.linux-amd64.tar.gz" \
  "frr_exporter-${FRR_EXPORTER_VERSION}.linux-amd64.tar.gz" || FAILED=$((FAILED + 1))

download_artifact "promtail v${PROMTAIL_VERSION}" \
  "https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}/promtail-linux-amd64.zip" \
  "promtail-linux-amd64.zip" || FAILED=$((FAILED + 1))

download_artifact "loki v${LOKI_VERSION}" \
  "https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/loki-linux-amd64.zip" \
  "loki-linux-amd64.zip" || FAILED=$((FAILED + 1))

download_artifact "prometheus v${PROMETHEUS_VERSION}" \
  "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz" \
  "prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz" || FAILED=$((FAILED + 1))

download_artifact "grafana v${GRAFANA_VERSION}" \
  "https://dl.grafana.com/oss/release/grafana-${GRAFANA_VERSION}-${GRAFANA_RPM_RELEASE}.x86_64.rpm" \
  "grafana-${GRAFANA_VERSION}-${GRAFANA_RPM_RELEASE}.x86_64.rpm" || FAILED=$((FAILED + 1))

# ==========================================================================
# Summary
# ==========================================================================
echo ""
echo "=== Artifact Build Complete ==="
RPM_COUNT=$(ls "$ARTIFACTS_DIR/rpms/"*.rpm 2>/dev/null | wc -l)
BIN_COUNT=$(ls "$ARTIFACTS_DIR/binaries/" 2>/dev/null | wc -l)
BOX_COUNT=$(ls "$ARTIFACTS_DIR/boxes/"*.box 2>/dev/null | wc -l)
TOTAL_SIZE=$(du -sh "$ARTIFACTS_DIR" 2>/dev/null | cut -f1)
echo "  Boxes:    $BOX_COUNT"
echo "  RPMs:     $RPM_COUNT packages"
echo "  Binaries: $BIN_COUNT artifacts"
echo "  Total:    $TOTAL_SIZE"
echo ""

if [ "$FAILED" -gt 0 ]; then
  echo "WARNING: $FAILED artifact(s) failed to download. Check output above."
  exit 1
fi

echo "Next steps:"
echo "  1. Build golden box:    make bake"
echo "  2. Register box:        make box-register"
echo "  3. Generate configs:    make generate"
echo "  4. Start artifact HTTP: make artifacts-serve"
echo "  5. Boot VMs:            make vms"
