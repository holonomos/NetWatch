#!/usr/bin/env bash
# ==========================================================================
# provision-mgmt.sh — Configure the management VM
# ==========================================================================
# Called by Vagrant provisioner. Everything is pre-installed in the golden
# image — this script only writes config files and enables services.
#
# Expects synced folders at /tmp/netwatch-config/{prometheus,loki,grafana,dnsmasq}
# ==========================================================================
set -euo pipefail

echo "=== Configuring mgmt VM ==="

# --- Copy generated configs to final locations ----------------------------
cp /tmp/netwatch-config/prometheus/prometheus.yml /etc/prometheus/
cp /tmp/netwatch-config/prometheus/alerts.yml /etc/prometheus/
cp /tmp/netwatch-config/loki/loki-config.yml /etc/loki/
cp /tmp/netwatch-config/dnsmasq/dnsmasq.conf /etc/dnsmasq.conf
cp /tmp/netwatch-config/grafana/dashboards/*.json /var/lib/grafana/dashboards/ 2>/dev/null || true

# --- Chrony (NTP server, stratum 10) -------------------------------------
cat > /etc/chrony.conf <<EOF
driftfile /var/lib/chrony/drift
rtcsync
logdir /var/log/chrony
allow 192.168.0.0/24
local stratum 10
EOF

# --- Rsyslog (receive syslog from all nodes) ------------------------------
cat > /etc/rsyslog.d/99-netwatch-receiver.conf <<'EOF'
$ModLoad imudp
$UDPServerRun 514
$ModLoad imtcp
$InputTCPServerRun 514
:fromhost-ip, !isequal, "127.0.0.1" /var/log/remote.log
EOF

# --- Promtail config ------------------------------------------------------
cat > /etc/promtail/config.yml <<'EOF'
clients:
  - url: http://localhost:3100/loki/api/v1/push
scrape_configs:
  - job_name: journal
    journal:
      path: /var/log/journal
      labels:
        job: systemd-journal
        host: mgmt
    relabel_configs:
      - source_labels: ['__journal__systemd_unit']
        target_label: 'unit'
      - source_labels: ['__journal_hostname']
        target_label: 'hostname'
  - job_name: remote-syslog
    static_configs:
      - targets:
          - localhost
        labels:
          job: remote-syslog
          host: mgmt
          __path__: /var/log/remote.log
EOF

# --- Grafana provisioning (datasources + dashboard provider) --------------
mkdir -p /etc/grafana/provisioning/datasources
cat > /etc/grafana/provisioning/datasources/netwatch.yaml <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    url: http://127.0.0.1:9090
    access: proxy
    isDefault: true
  - name: Loki
    type: loki
    url: http://127.0.0.1:3100
    access: proxy
EOF

mkdir -p /etc/grafana/provisioning/dashboards
cat > /etc/grafana/provisioning/dashboards/netwatch.yaml <<'EOF'
apiVersion: 1
providers:
  - name: NetWatch Dashboards
    type: file
    allowUiUpdates: false
    updateIntervalSeconds: 30
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: false
EOF

chown -R grafana:grafana /var/lib/grafana/dashboards/ 2>/dev/null || true

# --- Disable systemd-resolved (conflicts with dnsmasq on port 53) ---------
systemctl disable --now systemd-resolved 2>/dev/null || true
# Point resolv.conf directly (not through the stub resolver)
rm -f /etc/resolv.conf
cat > /etc/resolv.conf <<EOF
nameserver 127.0.0.1
search netwatch.lab
EOF

# --- Enable services (dependency order) -----------------------------------
systemctl enable --now dnsmasq
systemctl enable --now chronyd
systemctl enable --now rsyslog
systemctl enable --now loki
systemctl enable --now prometheus
systemctl enable --now promtail
systemctl enable --now grafana-server
systemctl enable --now node_exporter

echo "=== mgmt VM configured ==="
