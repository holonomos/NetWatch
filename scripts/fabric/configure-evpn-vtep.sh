#!/usr/bin/env bash
# ==========================================================================
# configure-evpn-vtep.sh — Build the EVPN/VXLAN kernel datapath on a leaf VTEP
# ==========================================================================
# Called by setup-evpn.sh via:
#   vagrant ssh <leaf> -c "sudo bash -s -- <args>" < this_script
#
# Builds, idempotently, the full distributed-IRB EVPN datapath (symmetric
# L3VNI + anycast gateway):
#   * VRF Tenant-A + symmetric L3VNI 10999 (br-l3vni, vlan-aware, svi-l3vni)
#   * One PLAIN bridge per L2VNI  (br-vni<l2vni> + vxlan<l2vni>), enslaved to
#     the VRF, with an anycast-gateway SVI (same IP + MAC on every leaf)
#   * Enslaves the leaf overlay access NICs (eth-ovl / eth-ovl-b) — pure L2,
#     NO IP — into the matching L2VNI bridge so server frames cross the overlay
#   * systemd timer for the EVPN metrics collector
#   * LAST: restart FRR so zebra ingests the kernel VNIs/VRF/SVIs
#
# Arg contract (BACKWARD COMPATIBLE — a 2-arg call still builds a plain VTEP):
#   configure-evpn-vtep.sh <loopback> <l2vni_primary> \
#       [<l3vni> <vrf> <l3vlan> <anycast_mac> <tenantspec> ...]
#
#   tenantspec = "l2vni:vlan:gwcidr:sviname"
#       e.g. 10000:99:10.99.0.1/24:svi-vni10000
#
# Example (leaf-1a), exactly what setup-evpn.sh emits:
#   configure-evpn-vtep.sh 10.0.3.1 10000 10999 Tenant-A 999 00:00:5e:00:01:99 \
#       10000:99:10.99.0.1/24:svi-vni10000 10001:98:10.99.1.1/24:svi-vni10001
#
# Every create is guarded (|| true / show-before-add) so a second pass — the
# `make overlay` re-run AFTER `wire` — only enslaves the now-present access
# NICs and restarts FRR. nolearning is correct: FRR owns MAC learning.
# ==========================================================================
set -euo pipefail

LOOPBACK="${1:?usage: configure-evpn-vtep.sh <loopback> <l2vni_primary> [l3vni vrf l3vlan anycast_mac tenantspec...]}"
L2VNI_PRIMARY="${2:?missing primary L2VNI}"
L3VNI="${3:-}"
VRF="${4:-}"
L3VLAN="${5:-}"
ANYCAST_MAC="${6:-}"
shift $(( $# < 6 ? $# : 6 ))
TENANTSPECS=("$@")          # remaining args are tenantspecs (may be empty)

VXLAN_DSTPORT=4789

# ==========================================================================
# Legacy / no-tenant mode: build the plain VTEP exactly as before so a bare
# 2-arg invocation keeps working (backward compatibility for any caller that
# has not adopted the L3VNI/tenant arg contract yet).
# ==========================================================================
if [ -z "$L3VNI" ] || [ ${#TENANTSPECS[@]} -eq 0 ]; then
    echo "  [legacy] no L3VNI/tenant args — building plain VTEP for VNI $L2VNI_PRIMARY"
    BR="br-vni${L2VNI_PRIMARY}"
    VX="vxlan${L2VNI_PRIMARY}"
    if ! ip link show "$VX" &>/dev/null; then
        ip link add "$VX" type vxlan id "$L2VNI_PRIMARY" \
            local "$LOOPBACK" dstport "$VXLAN_DSTPORT" nolearning
        echo "  Created $VX (VNI $L2VNI_PRIMARY, source $LOOPBACK)"
    fi
    if ! ip link show "$BR" &>/dev/null; then
        ip link add "$BR" type bridge
        echo 0 > "/sys/class/net/$BR/bridge/stp_state"
        ip link set "$BR" up
        echo "  Created $BR (STP disabled)"
    fi
    current_master=$(ip -o link show "$VX" 2>/dev/null | grep -oP 'master \K\S+' || true)
    [ "$current_master" != "$BR" ] && ip link set "$VX" master "$BR"
    ip link set "$VX" up
else
    # ======================================================================
    # Full distributed-IRB datapath
    # ======================================================================
    echo "  [evpn] VTEP $LOOPBACK : L3VNI $L3VNI VRF $VRF (vlan $L3VLAN) anycast $ANYCAST_MAC"
    echo "  [evpn] tenants: ${TENANTSPECS[*]}"

    # ----------------------------------------------------------------------
    # 4.1 VRF + L3VNI (symmetric IRB)
    # ----------------------------------------------------------------------
    # VRF table id is fixed by the design (topology.yml evpn.l3vni_table: 1099).
    VRF_TABLE=1099
    if ! ip link show "$VRF" &>/dev/null; then
        ip link add "$VRF" type vrf table "$VRF_TABLE"
        echo "  Created VRF $VRF (table $VRF_TABLE)"
    fi
    ip link set "$VRF" up

    if ! ip link show br-l3vni &>/dev/null; then
        ip link add br-l3vni type bridge
        # One-time bridge settings; writing the same value on a re-run is a
        # harmless no-op, but keeping them inside the create-guard avoids any
        # sysfs write racing a just-changed VRF master under `set -e`.
        echo 1 > /sys/class/net/br-l3vni/bridge/vlan_filtering
        echo 0 > /sys/class/net/br-l3vni/bridge/stp_state
        echo "  Created br-l3vni (vlan-aware, VRF $VRF)"
    fi
    # Guarded: `ip link set ... master` returns RTNETLINK 'File exists' (rc 2)
    # if the device is ALREADY enslaved to the VRF, which would abort under
    # `set -e` on the idempotent `make overlay` re-run.
    l3br_master=$(ip -o link show br-l3vni 2>/dev/null | grep -oP 'master \K\S+' || true)
    [ "$l3br_master" != "$VRF" ] && ip link set br-l3vni master "$VRF"
    ip link set br-l3vni up

    if ! ip link show vxlan10999 &>/dev/null; then
        ip link add vxlan10999 type vxlan id "$L3VNI" \
            local "$LOOPBACK" dstport "$VXLAN_DSTPORT" nolearning
        echo "  Created vxlan10999 (L3VNI $L3VNI)"
    fi
    l3vni_master=$(ip -o link show vxlan10999 2>/dev/null | grep -oP 'master \K\S+' || true)
    [ "$l3vni_master" != "br-l3vni" ] && ip link set vxlan10999 master br-l3vni
    ip link set vxlan10999 up
    bridge link set dev vxlan10999 neigh_suppress on            # IRB hygiene
    bridge vlan add dev vxlan10999 vid "$L3VLAN" 2>/dev/null || true
    bridge vlan add dev vxlan10999 vid "$L3VLAN" tunnel_info id "$L3VNI" 2>/dev/null || true
    bridge vlan add dev br-l3vni vid "$L3VLAN" self 2>/dev/null || true

    if ! ip link show svi-l3vni &>/dev/null; then
        ip link add link br-l3vni name svi-l3vni type vlan id "$L3VLAN"
        echo "  Created svi-l3vni (numberless, VRF $VRF)"
    fi
    # Guarded master assignment (idempotent re-run safety under `set -e`).
    svil3_master=$(ip -o link show svi-l3vni 2>/dev/null | grep -oP 'master \K\S+' || true)
    [ "$svil3_master" != "$VRF" ] && ip link set svi-l3vni master "$VRF"
    ip link set svi-l3vni up                                    # numberless; FRR routes via it

    # ----------------------------------------------------------------------
    # 4.2 Per-tenant plain L2VNI bridge + anycast SVI
    #     (one plain bridge : one vxlan : one access NIC)
    # ----------------------------------------------------------------------
    for spec in "${TENANTSPECS[@]}"; do
        IFS=':' read -r l2vni vlan gwcidr sviname rest <<< "$spec"
        if [ -z "$l2vni" ] || [ -z "$vlan" ] || [ -z "$gwcidr" ] || [ -z "$sviname" ]; then
            echo "  WARNING: malformed tenantspec '$spec' (want l2vni:vlan:gwcidr:sviname) — skipping"
            continue
        fi
        BR="br-vni${l2vni}"
        VX="vxlan${l2vni}"

        if ! ip link show "$BR" &>/dev/null; then
            ip link add "$BR" type bridge
            echo 0 > "/sys/class/net/$BR/bridge/stp_state"
            echo "  Created $BR (plain, STP disabled)"
        fi
        # Guarded: enslave L2 bridge to VRF (IRB). Skip if already a member so
        # the idempotent re-run does not hit RTNETLINK 'File exists' under set -e.
        br_master=$(ip -o link show "$BR" 2>/dev/null | grep -oP 'master \K\S+' || true)
        [ "$br_master" != "$VRF" ] && ip link set "$BR" master "$VRF"
        ip link set "$BR" up

        if ! ip link show "$VX" &>/dev/null; then
            ip link add "$VX" type vxlan id "$l2vni" \
                local "$LOOPBACK" dstport "$VXLAN_DSTPORT" nolearning
            echo "  Created $VX (L2VNI $l2vni, source $LOOPBACK)"
        fi
        vx_master=$(ip -o link show "$VX" 2>/dev/null | grep -oP 'master \K\S+' || true)
        [ "$vx_master" != "$BR" ] && ip link set "$VX" master "$BR"
        ip link set "$VX" up
        bridge link set dev "$VX" neigh_suppress on

        # Anycast gateway on the L2VNI bridge interface itself (plain
        # bridge-per-VNI IRB). $BR is already enslaved to the VRF above, so
        # giving the bridge the anycast IP+MAC makes the bridge itself the SVI
        # (the traditional-bridge model). On a plain (non-vlan-aware) bridge the
        # server's untagged frames never reach a VLAN sub-interface, so the
        # gateway must live on the bridge, not on a "br-vniX.vlan" sub-interface.
        # `ip link del $sviname` clears any leftover VLAN-style SVI. IP+MAC must
        # match frr.conf 'interface $BR'.
        ip link del "$sviname" 2>/dev/null || true
        ip link set "$BR" address "$ANYCAST_MAC" 2>/dev/null || true
        gwip="${gwcidr%%/*}"
        if ! ip addr show dev "$BR" 2>/dev/null | grep -q "$gwip"; then
            ip addr add "$gwcidr" dev "$BR" 2>/dev/null || true
        fi
        ip link set "$BR" up
        echo "  Anycast GW $gwcidr ($ANYCAST_MAC) on bridge $BR (SVI = bridge interface)"
    done

    # ----------------------------------------------------------------------
    # 4.3 Access ports: enslave the leaf overlay NICs (pure L2, NO IP).
    #     Attached during `fabric`; renamed by udev to eth-ovl / eth-ovl-b.
    #     If they do not exist yet (first EVPN pass, before `wire`) this is a
    #     no-op completed by the `make overlay` re-run.
    # ----------------------------------------------------------------------
    if ip link show eth-ovl &>/dev/null; then
        ovl_master=$(ip -o link show eth-ovl 2>/dev/null | grep -oP 'master \K\S+' || true)
        [ "$ovl_master" != "br-vni10000" ] && ip link set eth-ovl master br-vni10000
        ip link set eth-ovl up
        echo "  Enslaved eth-ovl -> br-vni10000 (tenant-a access port)"
    else
        echo "  eth-ovl not present yet — access enslave deferred to 'make overlay'"
    fi
    if ip link show eth-ovl-b &>/dev/null; then
        ovlb_master=$(ip -o link show eth-ovl-b 2>/dev/null | grep -oP 'master \K\S+' || true)
        [ "$ovlb_master" != "br-vni10001" ] && ip link set eth-ovl-b master br-vni10001
        ip link set eth-ovl-b up
        echo "  Enslaved eth-ovl-b -> br-vni10001 (tenant-b access port)"
    fi
fi

# ==========================================================================
# 4.4 systemd timer for the EVPN metrics collector (UNCHANGED behaviour)
# ==========================================================================
mkdir -p /usr/local/bin

cat > /etc/systemd/system/evpn-metrics.service <<EOF
[Unit]
Description=Collect EVPN metrics for Prometheus
[Service]
Type=oneshot
ExecStart=/usr/local/bin/evpn-metrics-collector.sh
EOF

cat > /etc/systemd/system/evpn-metrics.timer <<EOF
[Unit]
Description=Run EVPN metrics collector every 15s
[Timer]
OnBootSec=10s
OnUnitActiveSec=15s
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now evpn-metrics.timer 2>/dev/null || true

# ==========================================================================
# 4.5 LAST: restart FRR so zebra ingests the kernel VNIs / VRF / SVIs.
#     (FRR auto-classifies VNI 10999 as the L3VNI for VRF Tenant-A once the
#      kernel binding exists; the L2VNIs become Type-2/3 capable.)
# ==========================================================================
if [ -n "$L3VNI" ] && [ ${#TENANTSPECS[@]} -gt 0 ]; then
    systemctl restart frr 2>/dev/null || echo "  WARNING: frr restart failed (will retry on next pass)"
    echo "  FRR restarted to ingest VNIs/VRF/SVIs"
fi

# --- Informational: what FRR now sees ---
echo "  EVPN datapath summary:"
vtysh -c "show evpn vni" 2>/dev/null | head -6 || echo "  (FRR not aware of VNIs yet — convergence gate runs in setup-evpn.sh)"

echo "  VTEP $LOOPBACK configured (primary L2VNI $L2VNI_PRIMARY${L3VNI:+, L3VNI $L3VNI, VRF $VRF})"
