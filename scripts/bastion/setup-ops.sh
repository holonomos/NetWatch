#!/usr/bin/env bash
# ==========================================================================
# setup-ops.sh — Configure bastion as the operations desk
# ==========================================================================
# Sets up bastion with everything an operator needs:
#   - kubectl (done by setup-bastion-kubectl.sh)
#   - Shell aliases for common operations
#   - DNAT rules for Grafana/Prometheus access from host
#   - SSH config for jump access to all nodes
#
# Run from host: bash scripts/bastion/setup-ops.sh
# ==========================================================================
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "========================================"
echo " NetWatch: Bastion Operations Setup"
echo "========================================"

# --- Shell aliases + motd ---
echo "  Setting up shell environment..."
vagrant ssh bastion -c "sudo bash -s" <<'OPS'
set -e

# MOTD
cat > /etc/motd <<'MOTD'

  ╔══════════════════════════════════════════╗
  ║         NetWatch Bastion Gateway         ║
  ╠══════════════════════════════════════════╣
  ║  ssh srv-1-1                → any node  ║
  ║  bgp / bfd / fabric-status → routing   ║
  ║  kubectl runs on HOST, not here        ║
  ╚══════════════════════════════════════════╝

MOTD

# Shell aliases
cat > /etc/profile.d/netwatch.sh <<'ALIASES'
# NetWatch bastion aliases (SSH jump + fabric inspection)
# NOTE: kubectl/helm run on the HOST, not bastion. Use 'vagrant ssh bastion' for emergencies only.
alias bgp='for n in spine-1 spine-2; do echo "=== $n ==="; ssh -o StrictHostKeyChecking=no vagrant@$n "sudo vtysh -c \"show bgp summary\"" 2>/dev/null; done'
alias bfd='ssh -o StrictHostKeyChecking=no vagrant@spine-1 "sudo vtysh -c \"show bfd peers\"" 2>/dev/null'
alias fabric-status='for n in border-1 border-2 spine-1 spine-2; do echo "=== $n ==="; ssh -o StrictHostKeyChecking=no vagrant@$n "sudo vtysh -c \"show bgp summary\"" 2>/dev/null | tail -15; echo; done'
alias routes='for n in spine-1 leaf-1a border-1; do echo "=== $n ==="; ssh -o StrictHostKeyChecking=no vagrant@$n "sudo vtysh -c \"show ip route summary\"" 2>/dev/null; done'
ALIASES

# SSH config for passwordless jump to all nodes
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
echo "  From HOST (operator workstation):"
echo "    kubectl get nodes     → cluster status"
echo "    kubectl get pods -A   → all pods"
echo "    curl http://10.100.0.x → MetalLB services"
echo ""
echo "  From bastion (SSH emergency + fabric inspection):"
echo "    bgp            → show BGP summary from spines"
echo "    fabric-status  → routing overview"
echo "    ssh srv-1-1    → jump to any node"
