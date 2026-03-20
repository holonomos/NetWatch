#!/usr/bin/env bash
# provision-extras.sh — Install heavy packages on all VMs via SSH
# Run from the host after vagrant up completes:
#   bash scripts/provision-extras.sh
#
# Installs dev tools, debugging tools, stress-ng, etc. that are NOT needed
# for basic P3 bring-up but useful for later phases (chaos, debugging).
set -euo pipefail

EXTRAS_COMMON="curl wget git vim tmux jq net-tools iproute bind-utils mtr tcpdump traceroute htop iotop iftop strace lsof nmap-ncat iputils stress stress-ng"
EXTRAS_DEV="gcc make automake cmake openssl-devel openssl python3 python3-pip"

ALL_SERVERS=(
  srv-1-1 srv-1-2 srv-1-3 srv-1-4
  srv-2-1 srv-2-2 srv-2-3 srv-2-4
  srv-3-1 srv-3-2 srv-3-3 srv-3-4
  srv-4-1 srv-4-2 srv-4-3 srv-4-4
)

install_on() {
  local vm="$1"
  shift
  local pkgs="$*"
  echo "  [$vm] installing extras..."
  vagrant ssh "$vm" -c "sudo dnf install -y $pkgs 2>/dev/null" 2>/dev/null && \
    echo "  [$vm] done" || echo "  [$vm] some packages failed (non-fatal)"
}

echo "=== Installing extras on server VMs (parallel, 4 at a time) ==="
jobs_running=0
for vm in "${ALL_SERVERS[@]}"; do
  install_on "$vm" "$EXTRAS_COMMON" &
  jobs_running=$((jobs_running + 1))
  if [ "$jobs_running" -ge 4 ]; then
    wait -n
    jobs_running=$((jobs_running - 1))
  fi
done
wait

echo ""
echo "=== Installing extras on bastion ==="
vagrant ssh bastion -c "sudo dnf install -y $EXTRAS_COMMON $EXTRAS_DEV ansible python3-pip 2>/dev/null && sudo pip3 install paramiko jinja2 2>/dev/null" || true

echo ""
echo "=== Installing extras on mgmt ==="
vagrant ssh mgmt -c "sudo dnf install -y $EXTRAS_COMMON $EXTRAS_DEV ansible unzip python3-pip 2>/dev/null && sudo pip3 install paramiko jinja2 pyyaml 2>/dev/null" || true

echo ""
echo "Done. All extras installed."
