#!/usr/bin/env bash
# ==========================================================================
# bake-golden-image.sh — Build the NetWatch golden Vagrant box
# ==========================================================================
# Takes the base fedora_43.box, boots a temp VM with internet access,
# installs everything needed by ANY VM role (server, bastion, mgmt),
# cleans up, and exports a fully-loaded golden box.
#
# The result: VMs boot ready to go. Provisioning only configures, never installs.
#
# Package philosophy:
#   - Servers are k3s compute nodes. Workloads are container images pulled by k3s.
#   - The golden image carries: k3s, observability agents, debugging tools, sysctls.
#   - mgmt extras: prometheus, grafana, loki, dnsmasq (all pre-installed, enabled at config time).
#   - bastion extras: iptables-services (NAT gateway).
#   - Nothing is installed at boot. Ever.
#
# Usage:
#   bash scripts/bake-golden-image.sh
#
# Output:
#   netwatch-golden.box  (in project root)
# ==========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BAKE_DIR="$PROJECT_ROOT/.bake-tmp"
OUTPUT_BOX="$PROJECT_ROOT/netwatch-golden.box"

# --- Source pinned versions ------------------------------------------------
source "$PROJECT_ROOT/repo/versions.env"

K3S_VERSION="${K3S_VERSION:-v1.31.4+k3s1}"
FRR_REPO="${FRR_REPO:-frr-stable}"

echo "=== NetWatch Golden Image Builder ==="
echo ""
echo "  Base box:     netwatch-fedora43 (fedora_43.box)"
echo "  FRR:          $FRR_REPO (RPM from rpm.frrouting.org)"
echo "  k3s:          $K3S_VERSION"
echo "  node_exporter: $NODE_EXPORTER_VERSION"
echo "  frr_exporter:  $FRR_EXPORTER_VERSION"
echo "  promtail:      $PROMTAIL_VERSION"
echo "  loki:          $LOKI_VERSION"
echo "  prometheus:    $PROMETHEUS_VERSION"
echo "  grafana:       $GRAFANA_VERSION"
echo ""

# --- Preflight -------------------------------------------------------------
if [ -f "$OUTPUT_BOX" ]; then
  echo "WARNING: $OUTPUT_BOX already exists."
  read -rp "Overwrite? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
  rm -f "$OUTPUT_BOX"
fi

# Make sure the base box is registered
if ! vagrant box list | grep -q "netwatch-fedora43"; then
  echo "Base box not registered. Adding fedora_43.box..."
  vagrant box add --name netwatch-fedora43 "$PROJECT_ROOT/fedora_43.box"
fi

# --- Create temp workspace -------------------------------------------------
echo ""
echo "=== Setting up temp bake environment ==="
rm -rf "$BAKE_DIR"
mkdir -p "$BAKE_DIR"

cat > "$BAKE_DIR/Vagrantfile" <<'VAGRANTFILE'
Vagrant.configure("2") do |config|
  config.vm.box = "netwatch-fedora43"
  config.vm.hostname = "golden-bake"
  config.vm.synced_folder ".", "/vagrant", disabled: true

  config.vm.provider :libvirt do |lv|
    lv.memory = 2048
    lv.cpus = 2
    lv.driver = "kvm"
    # Keep the default NAT interface — we need internet to install packages
  end
end
VAGRANTFILE

# --- Boot the bake VM ------------------------------------------------------
echo ""
echo "=== Booting bake VM ==="
cd "$BAKE_DIR"
vagrant up

# --- Fix Docker vs libvirt forwarding conflict ----------------------------
# Docker sets iptables FORWARD policy to DROP, which blocks libvirt NAT.
# Add a temporary rule to allow traffic on the vagrant-libvirt bridge.
VIRT_BRIDGE=$(virsh -c qemu:///system net-info vagrant-libvirt 2>/dev/null | awk '/Bridge:/{print $2}')
if [ -n "$VIRT_BRIDGE" ]; then
  echo ""
  echo "=== Fixing Docker/libvirt forward conflict (bridge: $VIRT_BRIDGE) ==="
  sudo nft insert rule ip filter FORWARD iifname "$VIRT_BRIDGE" accept 2>/dev/null || \
    sudo iptables -I FORWARD -i "$VIRT_BRIDGE" -j ACCEPT 2>/dev/null || true
  sudo nft insert rule ip filter FORWARD oifname "$VIRT_BRIDGE" accept 2>/dev/null || \
    sudo iptables -I FORWARD -o "$VIRT_BRIDGE" -j ACCEPT 2>/dev/null || true
  FORWARD_FIX_APPLIED=1
else
  echo "WARNING: Could not find vagrant-libvirt bridge. Internet may not work in bake VM."
  FORWARD_FIX_APPLIED=0
fi

# Verify connectivity
echo "  Verifying VM internet access..."
vagrant ssh -c 'curl -s --connect-timeout 10 -o /dev/null -w "%{http_code}" https://fedoraproject.org/' || {
  echo "ERROR: Bake VM still cannot reach the internet."
  echo "  Check: sudo nft list chain ip filter FORWARD"
  exit 1
}

# ==========================================================================
# Phase 1: RPM packages
# ==========================================================================
echo ""
echo "=== Phase 1: RPM packages ==="

vagrant ssh -c 'sudo bash -s' <<'PROVISION_RPMS'
set -euo pipefail

echo "--- Updating package cache ---"
dnf makecache

echo "--- Installing RPMs ---"
dnf install -y \
  \
  `# === Every VM: base services ===` \
  chrony \
  rsyslog \
  \
  `# === k3s hard dependencies ===` \
  conntrack-tools \
  container-selinux \
  ethtool \
  ipset \
  \
  `# === k3s soft dependencies (specific features break without) ===` \
  socat \
  iproute-tc \
  nfs-utils \
  \
  `# === Ansible target requirements ===` \
  python3 \
  python3-libselinux \
  \
  `# === SELinux management ===` \
  policycoreutils \
  audit \
  \
  `# === Bastion: NAT gateway ===` \
  iptables-services \
  \
  `# === Mgmt: observability infra ===` \
  dnsmasq \
  logrotate \
  \
  `# === Debugging (SSH troubleshooting) ===` \
  curl \
  wget \
  jq \
  vim-enhanced \
  tmux \
  htop \
  tcpdump \
  traceroute \
  mtr \
  iproute \
  net-tools \
  bind-utils \
  lsof \
  strace \
  iputils \
  nmap-ncat \
  bash-completion \
  tar \
  unzip

echo ""
echo "--- $(rpm -qa | wc -l) RPMs installed ---"
PROVISION_RPMS

# ==========================================================================
# Phase 1b: FRR routing suite (for 12 switch VMs)
# ==========================================================================
echo ""
echo "=== Phase 1b: FRR routing suite ==="

vagrant ssh -c "sudo bash -s" <<PROVISION_FRR
set -euo pipefail

echo "--- Installing FRR from Fedora repos ---"
dnf install -y frr

echo "--- FRR version ---"
rpm -q frr

echo "--- Disabling FRR by default (enabled per-role at provision time) ---"
systemctl disable frr

echo "--- Ensuring /etc/frr directory ---"
mkdir -p /etc/frr
chown -R frr:frr /etc/frr

echo "--- FRR installed ---"
PROVISION_FRR

# ==========================================================================
# Phase 2: k3s binary
# ==========================================================================
echo ""
echo "=== Phase 2: k3s binary ==="

vagrant ssh -c "sudo bash -s" <<PROVISION_K3S
set -euo pipefail

K3S_VERSION="${K3S_VERSION}"

echo "--- Installing k3s \${K3S_VERSION} (binary only, no service start) ---"
curl -fSL "https://github.com/k3s-io/k3s/releases/download/\${K3S_VERSION}/k3s" -o /usr/local/bin/k3s
chmod +x /usr/local/bin/k3s

# Symlinks so kubectl/crictl/ctr work out of the box
ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl
ln -sf /usr/local/bin/k3s /usr/local/bin/crictl
ln -sf /usr/local/bin/k3s /usr/local/bin/ctr

k3s --version
echo "--- k3s installed (binary only, not started) ---"
PROVISION_K3S

# ==========================================================================
# Phase 3: Binary artifacts (observability)
# ==========================================================================
echo ""
echo "=== Phase 3: Binary artifacts ==="

vagrant ssh -c "sudo bash -s" <<PROVISION_BINS
set -euo pipefail

echo "--- node_exporter v${NODE_EXPORTER_VERSION} ---"
curl -fSL "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz" \
  | tar xz -C /usr/local/bin --strip-components=1 --wildcards '*/node_exporter'
node_exporter --version 2>&1 | head -1

echo "--- frr_exporter v${FRR_EXPORTER_VERSION} ---"
curl -fSL "https://github.com/tynany/frr_exporter/releases/download/v${FRR_EXPORTER_VERSION}/frr_exporter-${FRR_EXPORTER_VERSION}.linux-amd64.tar.gz" \
  | tar xz -C /usr/local/bin --strip-components=1 --wildcards '*/frr_exporter'
frr_exporter --version 2>&1 | head -1 || true

echo "--- promtail v${PROMTAIL_VERSION} ---"
curl -fSL "https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}/promtail-linux-amd64.zip" -o /tmp/promtail.zip
unzip -o /tmp/promtail.zip -d /tmp/
mv /tmp/promtail-linux-amd64 /usr/local/bin/promtail
chmod +x /usr/local/bin/promtail
promtail --version 2>&1 | head -1

echo "--- loki v${LOKI_VERSION} ---"
curl -fSL "https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/loki-linux-amd64.zip" -o /tmp/loki.zip
unzip -o /tmp/loki.zip -d /tmp/
mv /tmp/loki-linux-amd64 /usr/local/bin/loki
chmod +x /usr/local/bin/loki
loki --version 2>&1 | head -1

echo "--- prometheus v${PROMETHEUS_VERSION} ---"
curl -fSL "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz" \
  | tar xz -C /tmp
cp /tmp/prometheus-${PROMETHEUS_VERSION}.linux-amd64/prometheus /usr/local/bin/
cp /tmp/prometheus-${PROMETHEUS_VERSION}.linux-amd64/promtool /usr/local/bin/
mkdir -p /usr/local/share/prometheus
cp -r /tmp/prometheus-${PROMETHEUS_VERSION}.linux-amd64/consoles /usr/local/share/prometheus/
cp -r /tmp/prometheus-${PROMETHEUS_VERSION}.linux-amd64/console_libraries /usr/local/share/prometheus/
prometheus --version 2>&1 | head -1

echo "--- grafana v${GRAFANA_VERSION} ---"
dnf install -y "https://dl.grafana.com/oss/release/grafana-${GRAFANA_VERSION}-${GRAFANA_RPM_RELEASE}.x86_64.rpm"
grafana-server -v 2>&1 | head -1

echo ""
echo "--- All binaries installed ---"
PROVISION_BINS

# ==========================================================================
# Phase 4: Systemd units (all disabled — enabled at provision time)
# ==========================================================================
echo ""
echo "=== Phase 4: Systemd units + sysctls ==="

vagrant ssh -c 'sudo bash -s' <<'PROVISION_UNITS'
set -euo pipefail

# --- Systemd units (disabled by default, provisioner enables per role) ---

cat > /etc/systemd/system/node_exporter.service <<EOF
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
ExecStart=/usr/local/bin/node_exporter
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/prometheus.service <<EOF
[Unit]
Description=Prometheus
After=network.target

[Service]
ExecStart=/usr/local/bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/var/lib/prometheus
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/loki.service <<EOF
[Unit]
Description=Grafana Loki
After=network.target

[Service]
ExecStart=/usr/local/bin/loki -config.file=/etc/loki/loki-config.yml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/promtail.service <<EOF
[Unit]
Description=Promtail log forwarder
After=network.target loki.service

[Service]
ExecStart=/usr/local/bin/promtail -config.file=/etc/promtail/config.yml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# --- frr_exporter (runs on FRR switch VMs, disabled by default) ---
cat > /etc/systemd/system/frr_exporter.service <<EOF
[Unit]
Description=FRR Exporter for Prometheus
After=frr.service
Requires=frr.service

[Service]
ExecStart=/usr/local/bin/frr_exporter --web.listen-address=:9342
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# --- Config directories (populated by Vagrantfile provisioner) ---
mkdir -p /etc/prometheus /var/lib/prometheus
mkdir -p /etc/loki /var/lib/loki
mkdir -p /etc/promtail
mkdir -p /var/lib/grafana/dashboards

# --- Sysctls (baked in, apply on every boot) ---
cat > /etc/sysctl.d/99-netwatch.conf <<EOF
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
EOF

# --- Disable services that cause noise on isolated VMs ---
systemctl disable dnf-makecache.timer 2>/dev/null || true
systemctl disable dnf-makecache.service 2>/dev/null || true
systemctl disable systemd-resolved 2>/dev/null || true

# --- Fix SELinux contexts BEFORE virt-sysprep runs ---
# virt-sysprep relabels /usr/local/bin as user_tmp_t which prevents
# systemd from executing binaries. restorecon fixes them to bin_t.
restorecon -R /usr/local/bin

systemctl daemon-reload
echo "--- Systemd units + sysctls installed ---"
PROVISION_UNITS

# ==========================================================================
# Phase 5: Cleanup
# ==========================================================================
echo ""
echo "=== Phase 5: Cleanup ==="

vagrant ssh -c 'sudo bash -s' <<'PROVISION_CLEAN'
set -euo pipefail

# Clean package caches
dnf clean all
rm -rf /var/cache/dnf/*

# Clean tmp
rm -rf /tmp/*

# Clean logs
truncate -s 0 /var/log/*.log 2>/dev/null || true
journalctl --vacuum-size=1M 2>/dev/null || true

# Zero free space for better compression
dd if=/dev/zero of=/EMPTY bs=1M 2>/dev/null || true
rm -f /EMPTY

# Clear history
cat /dev/null > /root/.bash_history 2>/dev/null || true
cat /dev/null > /home/vagrant/.bash_history 2>/dev/null || true

echo "--- Cleanup complete ---"
PROVISION_CLEAN

# ==========================================================================
# Phase 6: Package
# ==========================================================================
echo ""
echo "=== Phase 6: Packaging golden box ==="

vagrant halt
vagrant package --output "$OUTPUT_BOX"

# --- Teardown ---------------------------------------------------------------
echo ""
echo "=== Tearing down bake VM ==="
vagrant destroy -f
cd "$PROJECT_ROOT"
rm -rf "$BAKE_DIR"

# Remove temporary forward rules
if [ "${FORWARD_FIX_APPLIED:-0}" = "1" ] && [ -n "${VIRT_BRIDGE:-}" ]; then
  echo "  Removing temporary forward rules for $VIRT_BRIDGE..."
  sudo nft delete rule ip filter FORWARD handle \
    $(sudo nft -a list chain ip filter FORWARD 2>/dev/null | grep "iifname \"$VIRT_BRIDGE\" accept" | awk '{print $NF}') 2>/dev/null || true
  sudo nft delete rule ip filter FORWARD handle \
    $(sudo nft -a list chain ip filter FORWARD 2>/dev/null | grep "oifname \"$VIRT_BRIDGE\" accept" | awk '{print $NF}') 2>/dev/null || true
fi

# --- Summary -----------------------------------------------------------------
echo ""
echo "=========================================="
echo "  Golden Image Complete"
echo "=========================================="
echo "  Output: $OUTPUT_BOX"
echo "  Size:   $(du -h "$OUTPUT_BOX" | cut -f1)"
echo ""
echo "  Baked in:"
echo "    RPMs:     chrony rsyslog iptables-services dnsmasq + debug tools"
echo "    k3s:      $K3S_VERSION (binary + kubectl/crictl/ctr symlinks)"
echo "    Obs:      node_exporter $NODE_EXPORTER_VERSION"
echo "              frr_exporter  $FRR_EXPORTER_VERSION"
echo "              promtail      $PROMTAIL_VERSION"
echo "              loki          $LOKI_VERSION"
echo "              prometheus    $PROMETHEUS_VERSION"
echo "              grafana       $GRAFANA_VERSION"
echo "    Sysctls:  rp_filter=2 (baked)"
echo "    Units:    all disabled (enable per role at provision time)"
echo ""
echo "  Next steps:"
echo "    1. vagrant box add --name netwatch-golden netwatch-golden.box --force"
echo "    2. Update Vagrantfile: config.vm.box = 'netwatch-golden'"
echo "    3. Vagrantfile provisioning: configure only, never install"
echo "=========================================="
