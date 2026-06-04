#!/usr/bin/env bash
# Collect EVPN control + L2 data-path metrics on FRR leaf VTEPs.
# Run as root via the evpn-metrics.timer; scrapes vtysh and writes Prometheus
# textfile format to node_exporter's textfile dir (exposed at :9100/metrics).
# A non-zero netwatch_evpn_mac_remote{vni="10000"} means the leaf learned a peer
# server's MAC over VXLAN (Type-2): an L2 frame crossed the overlay.
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
    peers=d.get('peers',d.get('default',d).get('peers',{}))
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
    # FRR 10.x exposes the EVPN route count as top-level totalPrefix/numPrefix;
    # older builds used totalRoutes/numRoutes. (Per-RD dicts hold the route
    # entries themselves, not a count, so the top-level scalar is authoritative.)
    count=(d.get('totalPrefix') or d.get('numPrefix')
           or d.get('totalRoutes') or d.get('numRoutes') or 0)
    print(count)
except Exception as e:
    import sys; sys.stderr.write(f'evpn-metrics-collector: {e}\n')
    print(0)
" 2>/dev/null || echo 0)

# --- Remote VTEP count (across all VNIs) ---
REMOTE_VTEPS=$(echo "$VNI_OUTPUT" | \
    python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    total=0
    for vni in d.values():
        if isinstance(vni, dict):
            total+=vni.get('numRemoteVteps', 0)
    print(total)
except Exception as e:
    import sys; sys.stderr.write(f'evpn-metrics-collector: {e}\n')
    print(0)
" 2>/dev/null || echo 0)

# L2 data-path metrics (per-VNI): query FRR MAC and ARP/ND tables, classify
# local vs remote. Remote == learned over VXLAN from another VTEP (Type-2).

# Discover the VNI -> type/vrf map once. Emit '-' for empty fields: IFS=tab
# collapses adjacent tab delimiters, which would shift columns on a blank field
# (L2 VNIs have no vrf). The '-' sentinel keeps the 4 columns aligned and is
# translated back to '' on read.
VNI_MAP=$(echo "$VNI_OUTPUT" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    for k,v in d.items():
        if not isinstance(v, dict):
            continue
        vni=v.get('vni', k)
        typ=v.get('type','') or '-'      # 'L2' or 'L3'
        vrf=v.get('vrf','') or '-'       # set for L3 VNIs
        rvteps=v.get('numRemoteVteps', 0)
        if rvteps in (None,'n/a'): rvteps=0
        print(f'{vni}\t{typ}\t{vrf}\t{rvteps}')
except Exception as e:
    import sys; sys.stderr.write(f'evpn-metrics-collector: {e}\n')
" 2>/dev/null || true)

# Accumulators / line buffers for the data-path families.
DATAPATH_LINES=""
L2VNI_COUNT=0
L3VNI_COUNT=0
MAC_REMOTE_TOTAL=0

# Helper: count MAC table entries for a VNI, classified local/remote.
# FRR `show evpn mac vni <vni> json` is keyed by MAC -> {type: local|remote, ...};
# some versions wrap entries under a 'macs' key. Returns "total local remote".
mac_counts() {
    local vni="$1"
    vtysh -c "show evpn mac vni $vni json" 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    macs=d.get('macs', d) if isinstance(d, dict) else {}
    # Drop scalar summary keys so only per-MAC dicts remain.
    entries=[v for k,v in macs.items() if isinstance(v, dict)]
    total=len(entries)
    local=sum(1 for e in entries if e.get('type','')=='local')
    remote=sum(1 for e in entries if e.get('type','')=='remote')
    print(total, local, remote)
except Exception:
    print(0, 0, 0)
" 2>/dev/null || echo "0 0 0"
}

# Helper: count ARP/ND (neigh) entries for a VNI, classified local/remote.
# `show evpn arp-cache vni <vni> json` is keyed by IP -> {type: local|remote,...};
# older syntax is `show evpn neigh vni <vni> json`; try arp-cache then neigh.
arp_counts() {
    local vni="$1" out
    out=$(vtysh -c "show evpn arp-cache vni $vni json" 2>/dev/null)
    [ -z "$out" ] && out=$(vtysh -c "show evpn neigh vni $vni json" 2>/dev/null)
    echo "$out" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    nb=d.get('neighbors', d) if isinstance(d, dict) else {}
    entries=[v for k,v in nb.items() if isinstance(v, dict)]
    total=len(entries)
    remote=sum(1 for e in entries if e.get('type','')=='remote')
    print(total, remote)
except Exception:
    print(0, 0)
" 2>/dev/null || echo "0 0"
}

if [ -n "$VNI_MAP" ]; then
    while IFS=$'\t' read -r vni typ vrf rvteps; do
        [ -z "$vni" ] && continue
        rvteps="${rvteps//[^0-9]/}"; rvteps="${rvteps:-0}"
        # Translate sentinels back to empty strings.
        [ "$typ" = "-" ] && typ=""
        [ "$vrf" = "-" ] && vrf=""

        # vni_info series (always emitted, labelled by type+vrf).
        DATAPATH_LINES+="netwatch_evpn_vni_info{vni=\"$vni\",type=\"$typ\",vrf=\"$vrf\"} 1"$'\n'
        DATAPATH_LINES+="netwatch_evpn_vni_remote_vteps{vni=\"$vni\"} $rvteps"$'\n'

        case "$typ" in
            L2|l2)
                L2VNI_COUNT=$((L2VNI_COUNT + 1))
                read -r m_total m_local m_remote < <(mac_counts "$vni")
                read -r a_total a_remote < <(arp_counts "$vni")
                m_total="${m_total//[^0-9]/}";   m_total="${m_total:-0}"
                m_local="${m_local//[^0-9]/}";   m_local="${m_local:-0}"
                m_remote="${m_remote//[^0-9]/}"; m_remote="${m_remote:-0}"
                a_total="${a_total//[^0-9]/}";   a_total="${a_total:-0}"
                a_remote="${a_remote//[^0-9]/}"; a_remote="${a_remote:-0}"
                MAC_REMOTE_TOTAL=$((MAC_REMOTE_TOTAL + m_remote))
                DATAPATH_LINES+="netwatch_evpn_mac_total{vni=\"$vni\"} $m_total"$'\n'
                DATAPATH_LINES+="netwatch_evpn_mac_local{vni=\"$vni\"} $m_local"$'\n'
                DATAPATH_LINES+="netwatch_evpn_mac_remote{vni=\"$vni\"} $m_remote"$'\n'
                DATAPATH_LINES+="netwatch_evpn_arp_total{vni=\"$vni\"} $a_total"$'\n'
                DATAPATH_LINES+="netwatch_evpn_arp_remote{vni=\"$vni\"} $a_remote"$'\n'
                ;;
            L3|l3)
                L3VNI_COUNT=$((L3VNI_COUNT + 1))
                ;;
        esac
    done <<< "$VNI_MAP"
fi

# --- Write Prometheus textfile (atomic via .tmp + mv) ---
{
cat <<EOF
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

# HELP netwatch_evpn_l2vni_count Number of L2 VNIs on this VTEP
# TYPE netwatch_evpn_l2vni_count gauge
netwatch_evpn_l2vni_count $L2VNI_COUNT

# HELP netwatch_evpn_l3vni_count Number of L3 VNIs on this VTEP
# TYPE netwatch_evpn_l3vni_count gauge
netwatch_evpn_l3vni_count $L3VNI_COUNT

# HELP netwatch_evpn_mac_remote_total Total remote (over-VXLAN) MACs across all L2 VNIs
# TYPE netwatch_evpn_mac_remote_total gauge
netwatch_evpn_mac_remote_total $MAC_REMOTE_TOTAL

# HELP netwatch_evpn_vni_info VNI presence/type/vrf (value always 1)
# TYPE netwatch_evpn_vni_info gauge
# HELP netwatch_evpn_vni_remote_vteps Remote VTEPs learned for this VNI
# TYPE netwatch_evpn_vni_remote_vteps gauge
# HELP netwatch_evpn_mac_total Total MACs learned in this L2 VNI
# TYPE netwatch_evpn_mac_total gauge
# HELP netwatch_evpn_mac_local Locally-learned MACs in this L2 VNI
# TYPE netwatch_evpn_mac_local gauge
# HELP netwatch_evpn_mac_remote Remote (over-VXLAN, Type-2) MACs in this L2 VNI
# TYPE netwatch_evpn_mac_remote gauge
# HELP netwatch_evpn_arp_total Total ARP/ND (neighbor) entries in this L2 VNI
# TYPE netwatch_evpn_arp_total gauge
# HELP netwatch_evpn_arp_remote Remote ARP/ND (neighbor) entries in this L2 VNI
# TYPE netwatch_evpn_arp_remote gauge
EOF
printf '%s' "$DATAPATH_LINES"
} > "${OUTPUT}.tmp"

mv "${OUTPUT}.tmp" "$OUTPUT"
