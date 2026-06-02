#!/usr/bin/env bash
# ==========================================================================
# evpn-metrics-collector.sh — Collect EVPN control + L2 data-path metrics
# ==========================================================================
# Runs on FRR leaf VTEPs via the evpn-metrics.timer systemd timer. Scrapes
# vtysh for EVPN state and writes Prometheus textfile format into
# node_exporter's --collector.textfile.directory, which exposes the metrics
# alongside node_exporter's own at the leaf's :9100/metrics.
#
# Emits two families:
#   CONTROL PLANE (existing, unchanged names):
#     netwatch_evpn_vni_count
#     netwatch_evpn_peers_established
#     netwatch_evpn_routes_total
#     netwatch_evpn_remote_vteps
#   L2 DATA PATH (new — proves real frames cross the overlay; per-VNI labelled):
#     netwatch_evpn_vni_info{vni,type,vrf}                      = 1
#     netwatch_evpn_mac_total{vni}                              learned MACs in VNI
#     netwatch_evpn_mac_local{vni}                              locally-learned MACs
#     netwatch_evpn_mac_remote{vni}                             remote (over-VXLAN) MACs
#     netwatch_evpn_arp_total{vni}                              ARP/ND (neigh) entries
#     netwatch_evpn_arp_remote{vni}                             remote ARP/ND entries
#     netwatch_evpn_vni_remote_vteps{vni}                       remote VTEPs per VNI
#   ROLLUPS (unlabelled, for simple single-stat panels):
#     netwatch_evpn_mac_remote_total                            sum of remote MACs
#     netwatch_evpn_l2vni_count / netwatch_evpn_l3vni_count
#
# A non-zero netwatch_evpn_mac_remote{vni="10000"} is the data-path proof:
# the leaf learned a PEER server's MAC over VXLAN (Type-2), i.e. an L2 frame
# crossed the overlay — not the routed underlay.
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
    count=d.get('totalRoutes', d.get('numRoutes', 0))
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

# ==========================================================================
# L2 DATA-PATH metrics (per-VNI). For every L2 VNI we ask FRR for its MAC and
# ARP/ND tables and classify local vs remote. Remote == learned over VXLAN
# from another VTEP (Type-2) == an L2 frame crossed the overlay. The whole
# per-VNI block is emitted by one Python pass that, for each VNI in
# `show evpn vni json`, pulls `show evpn mac vni <vni> json` +
# `show evpn arp-cache vni <vni> json` via a helper. We run vtysh per VNI in
# bash (simpler/robuster than embedding subprocess calls) and stream the JSON
# blobs to Python as: <vni> <type> <macjson> <arpjson> per line is awkward, so
# instead we build the per-VNI Prometheus lines incrementally below.
# ==========================================================================

# Discover the VNI -> type/vrf map once.
# NOTE: every field is emitted non-empty (empty -> '-'). With IFS=tab, bash
# collapses ADJACENT tab delimiters (tab is IFS-whitespace), which would shift
# columns when a field is blank (e.g. L2 VNIs have no vrf). The '-' sentinel
# keeps the 4 columns aligned; we translate '-' back to '' for the vrf label.
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
# older syntax is `show evpn neigh vni <vni> json` — try arp-cache then neigh.
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
        # Translate sentinels back ('-' was emitted for empty fields to keep
        # the tab columns aligned across the bash `read`).
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
