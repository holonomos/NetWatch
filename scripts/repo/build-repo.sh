#!/usr/bin/env bash
# ==========================================================================
# build-repo.sh — Build the NetWatch local package repository
# ==========================================================================
# Downloads all RPMs and binary artifacts needed by VMs and containers
# into repo/, creating a fully offline-capable local repository.
#
# Run once on the host with internet access before vagrant up.
#
# Prerequisites:
#   - Docker (for Fedora 43 container to resolve correct RPM deps)
#   - createrepo_c (dnf install createrepo_c)
#   - Internet access
#
# Usage:
#   bash scripts/repo/build-repo.sh
# ==========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_DIR="$PROJECT_ROOT/repo"

# --- Source pinned versions ------------------------------------------------
source "$REPO_DIR/versions.env"

# --- Preflight checks ------------------------------------------------------
echo "=== NetWatch Repository Builder ==="
echo ""

if ! command -v docker &>/dev/null; then
  echo "ERROR: Docker is required but not found."
  exit 1
fi

if ! command -v createrepo_c &>/dev/null; then
  echo "createrepo_c not found, installing..."
  sudo dnf install -y createrepo_c || {
    echo "ERROR: Failed to install createrepo_c"
    exit 1
  }
fi

# --- Directory setup -------------------------------------------------------
mkdir -p "$REPO_DIR/fedora/rpms"
mkdir -p "$REPO_DIR/binaries"

# --- Phase 1: Download RPMs inside Fedora 43 container --------------------
echo ""
echo "=== Phase 1: Downloading RPMs (Fedora ${FEDORA_RELEASE} container) ==="
echo ""

# Full package list for all VMs:
#   - Universal: chrony, rsyslog, node_exporter
#   - Bastion:   iptables-services
#   - Mgmt:      curl, unzip, jq, grafana deps, dnsmasq
#   - Extras:    dev tools, debugging, stress testing (for provision-extras.sh)
RPM_LIST=(
  # Universal baseline (node_exporter comes from repo/binaries/, not RPM)
  chrony
  rsyslog
  # Bastion
  iptables-services
  # Mgmt
  curl
  unzip
  jq
  dnsmasq
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
  ansible
)

# Use a Fedora 43 container to download RPMs with correct dependencies.
# The host may be a different Fedora version, so we can't trust its dep resolution.
docker run --rm \
  -v "$REPO_DIR/fedora/rpms:/rpms:z" \
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

# --- Phase 2: Index the RPM repository ------------------------------------
echo ""
echo "=== Phase 2: Indexing RPM repository ==="
echo ""

createrepo_c "$REPO_DIR/fedora"
echo "  repodata created at: $REPO_DIR/fedora/repodata/"

# --- Phase 3: Download binary artifacts ------------------------------------
echo ""
echo "=== Phase 3: Downloading binary artifacts ==="
echo ""

download_artifact() {
  local name="$1"
  local url="$2"
  local dest="$REPO_DIR/binaries/$3"

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

FAILED=0

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

# --- Phase 4: Pre-pull Docker images --------------------------------------
echo ""
echo "=== Phase 4: Pre-pulling Docker images ==="
echo ""

if [ -n "${FRR_IMAGE:-}" ]; then
  echo "  Pulling ${FRR_IMAGE}..."
  docker pull "$FRR_IMAGE"
else
  echo "  [skip] FRR_IMAGE not set (FRR now installed via RPM in golden image)"
fi

echo "  Installing Loki Docker logging driver..."
docker plugin install grafana/loki-docker-driver:latest --alias loki --grant-all-permissions 2>/dev/null || \
  docker plugin enable loki 2>/dev/null || \
  echo "  [skip] Loki driver already installed"

# --- Summary ---------------------------------------------------------------
echo ""
echo "=== Repository Build Complete ==="
RPM_COUNT=$(ls "$REPO_DIR/fedora/rpms/"*.rpm 2>/dev/null | wc -l)
BIN_COUNT=$(ls "$REPO_DIR/binaries/" 2>/dev/null | wc -l)
TOTAL_SIZE=$(du -sh "$REPO_DIR" 2>/dev/null | cut -f1)
echo "  RPMs:     $RPM_COUNT packages"
echo "  Binaries: $BIN_COUNT artifacts"
echo "  Total:    $TOTAL_SIZE"
echo ""

if [ "$FAILED" -gt 0 ]; then
  echo "WARNING: $FAILED artifact(s) failed to download. Check output above."
  exit 1
fi

echo "Next steps:"
echo "  1. Start the repo server:  bash scripts/repo/serve-repo.sh start"
echo "  2. Bring up VMs:           vagrant up"
