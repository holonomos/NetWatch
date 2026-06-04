#!/usr/bin/env bash
# Configure the bastion ops desk: shell aliases, DNAT for Grafana/Prometheus,
# and SSH jump config for all nodes. Run from host.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "========================================"
echo " NetWatch: Bastion Operations Setup"
echo "========================================"

# --- Shell aliases + motd ---
echo "  Setting up shell environment..."
vagrant ssh bastion -c "sudo bash -s" <<'OPS'
set -e

cat > /etc/motd <<'MOTD'

  ╔══════════════════════════════════════════╗
  ║         NetWatch Bastion Gateway         ║
  ╠══════════════════════════════════════════╣
  ║  ssh srv-1-1                → any node  ║
  ║  bgp / bfd / fabric-status → routing   ║
  ╚══════════════════════════════════════════╝

MOTD

cat > /etc/profile.d/netwatch.sh <<'ALIASES'
# NetWatch bastion aliases (SSH jump + fabric inspection)
alias bgp='for n in spine-1 spine-2; do echo "=== $n ==="; ssh -o StrictHostKeyChecking=no vagrant@$n "sudo vtysh -c \"show bgp summary\"" 2>/dev/null; done'
alias bfd='ssh -o StrictHostKeyChecking=no vagrant@spine-1 "sudo vtysh -c \"show bfd peers\"" 2>/dev/null'
alias fabric-status='for n in border-1 border-2 spine-1 spine-2; do echo "=== $n ==="; ssh -o StrictHostKeyChecking=no vagrant@$n "sudo vtysh -c \"show bgp summary\"" 2>/dev/null | tail -15; echo; done'
alias routes='for n in spine-1 leaf-1a border-1; do echo "=== $n ==="; ssh -o StrictHostKeyChecking=no vagrant@$n "sudo vtysh -c \"show ip route summary\"" 2>/dev/null; done'
ALIASES

# Passwordless jump to all nodes
cat > /home/vagrant/.ssh/config <<'SSHCONF'
Host srv-* leaf-* spine-* border-* mgmt obs
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
    User vagrant
SSHCONF
chown vagrant:vagrant /home/vagrant/.ssh/config
chmod 600 /home/vagrant/.ssh/config

echo "  Shell environment configured"
OPS

# --- Apply default DNAT rules (Grafana, Prometheus, Loki) ---
echo ""
echo "  Applying DNAT rules..."
bash "$PROJECT_ROOT/scripts/bastion/apply-dnat.sh" 2>/dev/null || true

echo ""
echo "=== Bastion Operations Desk Ready ==="
echo ""
echo "  SSH in:    vagrant ssh bastion"
echo "  Grafana:    http://192.168.0.4:3000  (admin/admin)"
echo "  Prometheus: http://192.168.0.4:9090"
echo ""
echo "  From bastion (SSH emergency + fabric inspection):"
echo "    bgp            → show BGP summary from spines"
echo "    fabric-status  → routing overview"
echo "    ssh srv-1-1    → jump to any node"
