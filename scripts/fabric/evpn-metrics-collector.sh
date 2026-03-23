#!/usr/bin/env bash
# ==========================================================================
# evpn-metrics-collector.sh — Collect EVPN metrics for Prometheus
# ==========================================================================
# Runs on FRR VMs via cron or systemd timer. Scrapes vtysh for EVPN state
# and writes Prometheus textfile format to node_exporter's textfile directory.
#
# node_exporter reads from --collector.textfile.directory and exposes the
# metrics alongside its own.
#
# Usage: Run as root (needs vtysh access)
#   bash /usr/local/bin/evpn-metrics-collector.sh
# ==========================================================================
set -uo pipefail

TEXTFILE_DIR="/var/lib/node_exporter/textfile"
OUTPUT="${TEXTFILE_DIR}/evpn.prom"

mkdir -p "$TEXTFILE_DIR"

# --- EVPN VNI count and details ---
VNI_OUTPUT=$(vtysh -c "show evpn vni json" 2>/dev/null || echo "{}")
VNI_COUNT=$(echo "$VNI_OUTPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d))" 2>/dev/null || echo 0)

# --- EVPN peer count (L2VPN EVPN sessions) ---
EVPN_PEERS_UP=$(vtysh -c "show bgp l2vpn evpn summary json" 2>/dev/null | \
    python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    peers=d.get('default',d).get('peers',{})
    up=sum(1 for p in peers.values() if p.get('state','') == 'Established')
    print(up)
except Exception as e:
    import sys; sys.stderr.write(f'evpn-metrics-collector: {e}\n')
    print(0)
" 2>/dev/null || echo 0)

# --- EVPN route count ---
EVPN_ROUTES=$(vtysh -c "show bgp l2vpn evpn json" 2>/dev/null | \
    python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    count=d.get('totalRoutes', d.get('numRoutes', 0))
    print(count)
except Exception as e:
    import sys; sys.stderr.write(f'evpn-metrics-collector: {e}\n')
    print(0)
" 2>/dev/null || echo 0)

# --- Remote VTEP count (from first VNI) ---
REMOTE_VTEPS=$(vtysh -c "show evpn vni json" 2>/dev/null | \
    python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    total=0
    for vni in d.values():
        total+=vni.get('numRemoteVteps', 0)
    print(total)
except Exception as e:
    import sys; sys.stderr.write(f'evpn-metrics-collector: {e}\n')
    print(0)
" 2>/dev/null || echo 0)

# --- Write Prometheus textfile ---
cat > "${OUTPUT}.tmp" <<EOF
# HELP netwatch_evpn_vni_count Number of active VNIs on this VTEP
# TYPE netwatch_evpn_vni_count gauge
netwatch_evpn_vni_count $VNI_COUNT

# HELP netwatch_evpn_peers_established Number of L2VPN EVPN BGP peers in Established state
# TYPE netwatch_evpn_peers_established gauge
netwatch_evpn_peers_established $EVPN_PEERS_UP

# HELP netwatch_evpn_routes_total Total EVPN routes (type-2 + type-3 + type-5)
# TYPE netwatch_evpn_routes_total gauge
netwatch_evpn_routes_total $EVPN_ROUTES

# HELP netwatch_evpn_remote_vteps Number of remote VTEPs discovered via EVPN
# TYPE netwatch_evpn_remote_vteps gauge
netwatch_evpn_remote_vteps $REMOTE_VTEPS
EOF

mv "${OUTPUT}.tmp" "$OUTPUT"
