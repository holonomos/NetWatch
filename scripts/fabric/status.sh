#!/bin/bash
# NetWatch — Status
# Generated from topology.yml — DO NOT HAND-EDIT
#
# Shows the state of all fabric components:
#   - FRR VMs (running/stopped)
#   - Bridges (up/missing)
#   - Management network reachability
#   - BGP session summary (if VMs are running)

set -uo pipefail

VIRSH_PREFIX="NetWatch"
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Resolve management bridge dynamically
MGMT_BRIDGE=$(virsh net-info netwatch-mgmt 2>/dev/null | awk '/Bridge:/{print $2}')
if [ -z "$MGMT_BRIDGE" ]; then
    MGMT_BRIDGE="virbr2"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }

TOTAL=0
PASS=0

check() {
    TOTAL=$((TOTAL + 1))
    if eval "$1" >/dev/null 2>&1; then
        ok "$2"
        PASS=$((PASS + 1))
    else
        fail "$2"
    fi
}

echo "========================================"
echo " NetWatch Fabric Status"
echo "========================================"
echo ""

# --- FRR VMs ---
echo "FRR VMs (12):"
TOTAL=$((TOTAL + 1))
STATE=$(virsh -c qemu:///system domstate "${VIRSH_PREFIX}_border-1" 2>/dev/null || echo "not found")
if [ "$STATE" = "running" ]; then
    ok "border-1"
    PASS=$((PASS + 1))
else
    fail "border-1 ($STATE)"
fi
TOTAL=$((TOTAL + 1))
STATE=$(virsh -c qemu:///system domstate "${VIRSH_PREFIX}_border-2" 2>/dev/null || echo "not found")
if [ "$STATE" = "running" ]; then
    ok "border-2"
    PASS=$((PASS + 1))
else
    fail "border-2 ($STATE)"
fi
TOTAL=$((TOTAL + 1))
STATE=$(virsh -c qemu:///system domstate "${VIRSH_PREFIX}_leaf-1a" 2>/dev/null || echo "not found")
if [ "$STATE" = "running" ]; then
    ok "leaf-1a"
    PASS=$((PASS + 1))
else
    fail "leaf-1a ($STATE)"
fi
TOTAL=$((TOTAL + 1))
STATE=$(virsh -c qemu:///system domstate "${VIRSH_PREFIX}_leaf-1b" 2>/dev/null || echo "not found")
if [ "$STATE" = "running" ]; then
    ok "leaf-1b"
    PASS=$((PASS + 1))
else
    fail "leaf-1b ($STATE)"
fi
TOTAL=$((TOTAL + 1))
STATE=$(virsh -c qemu:///system domstate "${VIRSH_PREFIX}_leaf-2a" 2>/dev/null || echo "not found")
if [ "$STATE" = "running" ]; then
    ok "leaf-2a"
    PASS=$((PASS + 1))
else
    fail "leaf-2a ($STATE)"
fi
TOTAL=$((TOTAL + 1))
STATE=$(virsh -c qemu:///system domstate "${VIRSH_PREFIX}_leaf-2b" 2>/dev/null || echo "not found")
if [ "$STATE" = "running" ]; then
    ok "leaf-2b"
    PASS=$((PASS + 1))
else
    fail "leaf-2b ($STATE)"
fi
TOTAL=$((TOTAL + 1))
STATE=$(virsh -c qemu:///system domstate "${VIRSH_PREFIX}_leaf-3a" 2>/dev/null || echo "not found")
if [ "$STATE" = "running" ]; then
    ok "leaf-3a"
    PASS=$((PASS + 1))
else
    fail "leaf-3a ($STATE)"
fi
TOTAL=$((TOTAL + 1))
STATE=$(virsh -c qemu:///system domstate "${VIRSH_PREFIX}_leaf-3b" 2>/dev/null || echo "not found")
if [ "$STATE" = "running" ]; then
    ok "leaf-3b"
    PASS=$((PASS + 1))
else
    fail "leaf-3b ($STATE)"
fi
TOTAL=$((TOTAL + 1))
STATE=$(virsh -c qemu:///system domstate "${VIRSH_PREFIX}_leaf-4a" 2>/dev/null || echo "not found")
if [ "$STATE" = "running" ]; then
    ok "leaf-4a"
    PASS=$((PASS + 1))
else
    fail "leaf-4a ($STATE)"
fi
TOTAL=$((TOTAL + 1))
STATE=$(virsh -c qemu:///system domstate "${VIRSH_PREFIX}_leaf-4b" 2>/dev/null || echo "not found")
if [ "$STATE" = "running" ]; then
    ok "leaf-4b"
    PASS=$((PASS + 1))
else
    fail "leaf-4b ($STATE)"
fi
TOTAL=$((TOTAL + 1))
STATE=$(virsh -c qemu:///system domstate "${VIRSH_PREFIX}_spine-1" 2>/dev/null || echo "not found")
if [ "$STATE" = "running" ]; then
    ok "spine-1"
    PASS=$((PASS + 1))
else
    fail "spine-1 ($STATE)"
fi
TOTAL=$((TOTAL + 1))
STATE=$(virsh -c qemu:///system domstate "${VIRSH_PREFIX}_spine-2" 2>/dev/null || echo "not found")
if [ "$STATE" = "running" ]; then
    ok "spine-2"
    PASS=$((PASS + 1))
else
    fail "spine-2 ($STATE)"
fi

echo ""

# --- Bridges ---
echo "Fabric Bridges (54):"
BRIDGE_UP=0
BRIDGE_TOTAL=54
if ip link show br000 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br001 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br002 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br003 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br004 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br005 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br006 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br007 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br008 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br009 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br010 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br011 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br012 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br013 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br014 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br015 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br016 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br017 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br018 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br019 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br020 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br021 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br022 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br023 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br024 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br025 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br026 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br027 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br028 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br029 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br030 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br031 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br032 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br033 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br034 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br035 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br036 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br037 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br038 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br039 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br040 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br041 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br042 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br043 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br044 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br045 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br046 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br047 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br048 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br049 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br050 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br051 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br052 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if ip link show br053 >/dev/null 2>&1; then
    BRIDGE_UP=$((BRIDGE_UP + 1))
fi
if [ "$BRIDGE_UP" -eq "$BRIDGE_TOTAL" ]; then
    ok "All $BRIDGE_TOTAL fabric bridges up"
    PASS=$((PASS + 1))
else
    fail "$BRIDGE_UP / $BRIDGE_TOTAL fabric bridges up"
fi
TOTAL=$((TOTAL + 1))

echo ""
echo "Management Bridge:"
check "ip link show $MGMT_BRIDGE" "$MGMT_BRIDGE"

echo ""

# --- Management Network Reachability ---
echo "Management Network Ping:"
check "ping -c1 -W1 192.168.0.10" "border-1 (192.168.0.10)"
check "ping -c1 -W1 192.168.0.11" "border-2 (192.168.0.11)"
check "ping -c1 -W1 192.168.0.30" "leaf-1a (192.168.0.30)"
check "ping -c1 -W1 192.168.0.31" "leaf-1b (192.168.0.31)"
check "ping -c1 -W1 192.168.0.32" "leaf-2a (192.168.0.32)"
check "ping -c1 -W1 192.168.0.33" "leaf-2b (192.168.0.33)"
check "ping -c1 -W1 192.168.0.34" "leaf-3a (192.168.0.34)"
check "ping -c1 -W1 192.168.0.35" "leaf-3b (192.168.0.35)"
check "ping -c1 -W1 192.168.0.36" "leaf-4a (192.168.0.36)"
check "ping -c1 -W1 192.168.0.37" "leaf-4b (192.168.0.37)"
check "ping -c1 -W1 192.168.0.20" "spine-1 (192.168.0.20)"
check "ping -c1 -W1 192.168.0.21" "spine-2 (192.168.0.21)"

echo ""

# --- BGP Summary (from spine-1) ---
echo "BGP Sessions (from spine-1):"
STATE=$(virsh -c qemu:///system domstate "${VIRSH_PREFIX}_spine-1" 2>/dev/null || echo "not found")
if [ "$STATE" = "running" ]; then
    cd "$PROJECT_ROOT"
    vagrant ssh spine-1 -c "sudo vtysh -c 'show bgp summary'" 2>/dev/null || warn "FRR not responding on spine-1"
else
    warn "spine-1 not running -- skipping BGP check"
fi

echo ""

# --- North-South Path ---
echo "North-South Path:"

# Check border default route (static via bastion)
STATE=$(virsh -c qemu:///system domstate "${VIRSH_PREFIX}_border-1" 2>/dev/null || echo "not found")
if [ "$STATE" = "running" ]; then
    cd "$PROJECT_ROOT"
    if vagrant ssh border-1 -c "sudo vtysh -c 'show ip route 0.0.0.0/0'" 2>/dev/null | grep -q "static"; then
        ok "border-1: static default route to bastion"
        PASS=$((PASS + 1))
    else
        fail "border-1: no static default route"
    fi
else
    warn "border-1 not running -- skipping"
fi
TOTAL=$((TOTAL + 1))

STATE=$(virsh -c qemu:///system domstate "${VIRSH_PREFIX}_border-2" 2>/dev/null || echo "not found")
if [ "$STATE" = "running" ]; then
    cd "$PROJECT_ROOT"
    if vagrant ssh border-2 -c "sudo vtysh -c 'show ip route 0.0.0.0/0'" 2>/dev/null | grep -q "static"; then
        ok "border-2: static default route to bastion"
        PASS=$((PASS + 1))
    else
        fail "border-2: no static default route"
    fi
else
    warn "border-2 not running -- skipping"
fi
TOTAL=$((TOTAL + 1))

# Check default route propagation (spine should have 0.0.0.0/0 via BGP)
STATE=$(virsh -c qemu:///system domstate "${VIRSH_PREFIX}_spine-1" 2>/dev/null || echo "not found")
if [ "$STATE" = "running" ]; then
    cd "$PROJECT_ROOT"
    if vagrant ssh spine-1 -c "sudo vtysh -c 'show ip route 0.0.0.0/0'" 2>/dev/null | grep -q "bgp"; then
        ok "spine-1: default route via BGP from borders (ECMP)"
        PASS=$((PASS + 1))
    else
        fail "spine-1: no BGP default route from borders"
    fi
else
    warn "spine-1 not running -- skipping"
fi
TOTAL=$((TOTAL + 1))

# Check bastion fabric connectivity
STATE=$(virsh -c qemu:///system domstate "${VIRSH_PREFIX}_border-1" 2>/dev/null || echo "not found")
if [ "$STATE" = "running" ]; then
    cd "$PROJECT_ROOT"
    check "vagrant ssh border-1 -c 'ping -c1 -W2 172.16.0.2'" "bastion fabric IP 172.16.0.2 (via border-1)"
else
    warn "border-1 not running -- skipping bastion check"
    TOTAL=$((TOTAL + 1))
fi
STATE=$(virsh -c qemu:///system domstate "${VIRSH_PREFIX}_border-2" 2>/dev/null || echo "not found")
if [ "$STATE" = "running" ]; then
    cd "$PROJECT_ROOT"
    check "vagrant ssh border-2 -c 'ping -c1 -W2 172.16.0.6'" "bastion fabric IP 172.16.0.6 (via border-2)"
else
    warn "border-2 not running -- skipping bastion check"
    TOTAL=$((TOTAL + 1))
fi

echo ""

# --- Summary ---
echo "========================================"
echo -e " Score: ${PASS}/${TOTAL} checks passed"
if [ "$PASS" -eq "$TOTAL" ]; then
    echo -e " ${GREEN}All systems operational.${NC}"
else
    echo -e " ${YELLOW}Some checks failed. Review above.${NC}"
fi
echo "========================================"
