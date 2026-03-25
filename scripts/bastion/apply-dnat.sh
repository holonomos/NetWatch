#!/usr/bin/env bash
# ==========================================================================
# apply-dnat.sh — Apply DNAT port-forwarding rules on bastion
# ==========================================================================
# Reads config/bastion-dnat.conf and applies iptables DNAT rules.
# For non-k3s users who run services directly on servers.
#
# Config format (one rule per line):
#   <external_port> <internal_ip> <internal_port> [protocol]
#   # comments and blank lines are ignored
#
# Example:
#   5432 10.0.5.1 5432 tcp    # PostgreSQL on srv-2-1
#   6379 10.0.6.2 6379 tcp    # Redis on srv-3-2
#   8080 10.0.4.1 80   tcp    # Web app on srv-1-1
#
# Run from host: bash scripts/bastion/apply-dnat.sh
# Or from bastion: sudo bash /usr/local/bin/apply-dnat.sh
# ==========================================================================
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DNAT_CONF="$PROJECT_ROOT/config/bastion-dnat.conf"

if [ ! -f "$DNAT_CONF" ]; then
    echo "No DNAT config found at $DNAT_CONF"
    echo "Create it with format: <ext_port> <internal_ip> <int_port> [protocol]"
    exit 0
fi

echo "========================================"
echo " NetWatch: Bastion DNAT Configuration"
echo "========================================"

# Build the iptables commands from config
RULES=""
RULE_COUNT=0
while IFS= read -r line; do
    # Skip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue

    ext_port=$(echo "$line" | awk '{print $1}')
    int_ip=$(echo "$line" | awk '{print $2}')
    int_port=$(echo "$line" | awk '{print $3}')
    proto=$(echo "$line" | awk '{print $4}')
    [ -z "$proto" ] && proto="tcp"

    RULES+="iptables -t nat -D PREROUTING -p $proto --dport $ext_port -j DNAT --to-destination ${int_ip}:${int_port} 2>/dev/null || true; "
    RULES+="iptables -t nat -A PREROUTING -p $proto --dport $ext_port -j DNAT --to-destination ${int_ip}:${int_port}; "
    RULES+="echo \"  :${ext_port} → ${int_ip}:${int_port} ($proto)\"; "
    RULE_COUNT=$((RULE_COUNT + 1))
done < "$DNAT_CONF"

if [ "$RULE_COUNT" -eq 0 ]; then
    echo "  No rules defined in $DNAT_CONF"
    exit 0
fi

echo "  Applying $RULE_COUNT DNAT rules to bastion..."

# Apply rules on bastion
vagrant ssh bastion -c "sudo bash -c '
$RULES
iptables-save > /etc/sysconfig/iptables
'"

echo ""
echo "  $RULE_COUNT DNAT rules applied"
echo "  Access services from host: curl http://192.168.0.2:<ext_port>"
