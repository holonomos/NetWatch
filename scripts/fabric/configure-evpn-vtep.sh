#!/usr/bin/env bash
# configure-evpn-vtep.sh: build the EVPN/VXLAN kernel datapath on a leaf VTEP.
# Run by setup-evpn.sh: vagrant ssh <leaf> -c "sudo bash -s -- <args>" < this.
#
# Builds the distributed-IRB datapath idempotently: VRF Tenant-A + symmetric
# L3VNI 10999, one vlan-aware bridge per L2VNI with a dedicated anycast-gateway
# SVI (same IP+MAC on every leaf), and enslaves the leaf overlay access NICs.
# Restarts FRR last so zebra ingests the kernel VNIs/VRF/SVIs.
#
# Usage: configure-evpn-vtep.sh <loopback> <l2vni_primary> \
#            [<l3vni> <vrf> <l3vlan> <anycast_mac> <tenantspec>...]
#   tenantspec = "l2vni:vlan:gwcidr:sviname"  e.g. 10000:99:10.99.0.1/24:svi-vni10000
# A 2-arg call builds a plain VTEP; full args build the IRB datapath.
# nolearning is set because FRR owns MAC learning.
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

# No-tenant mode: a 2-arg call (loopback + primary L2VNI) builds a plain VTEP
# without the VRF/L3VNI/anycast material.
if [ -z "$L3VNI" ] || [ ${#TENANTSPECS[@]} -eq 0 ]; then
    echo "  no L3VNI/tenant args: building plain VTEP for VNI $L2VNI_PRIMARY"
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
    # Full distributed-IRB datapath.
    echo "  [evpn] VTEP $LOOPBACK : L3VNI $L3VNI VRF $VRF (vlan $L3VLAN) anycast $ANYCAST_MAC"
    echo "  [evpn] tenants: ${TENANTSPECS[*]}"

    # VRF + L3VNI (symmetric IRB). VRF table id fixed by topology.yml
    # (evpn.l3vni_table: 1099).
    VRF_TABLE=1099
    if ! ip link show "$VRF" &>/dev/null; then
        ip link add "$VRF" type vrf table "$VRF_TABLE"
        echo "  Created VRF $VRF (table $VRF_TABLE)"
    fi
    ip link set "$VRF" up

    if ! ip link show br-l3vni &>/dev/null; then
        ip link add br-l3vni type bridge
        # Settings inside the create-guard: avoids a sysfs write racing a
        # just-changed VRF master under set -e.
        echo 1 > /sys/class/net/br-l3vni/bridge/vlan_filtering
        echo 0 > /sys/class/net/br-l3vni/bridge/stp_state
        echo "  Created br-l3vni (vlan-aware, VRF $VRF)"
    fi
    # ip link set ... master returns RTNETLINK 'File exists' (rc 2) if already
    # enslaved, which aborts under set -e on the idempotent re-run; so guard it.
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
    # Guarded master assignment (idempotent re-run safety under set -e).
    svil3_master=$(ip -o link show svi-l3vni 2>/dev/null | grep -oP 'master \K\S+' || true)
    [ "$svil3_master" != "$VRF" ] && ip link set svi-l3vni master "$VRF"
    # Stable fabric-wide L3VNI router-MAC: pinned so the RMAC in Type-2/Type-5
    # stays constant across FRR restarts. Same on every leaf; distinct from the
    # anycast GW MAC.
    ip link set svi-l3vni address 00:00:5e:00:01:98 2>/dev/null || true
    ip link set svi-l3vni up                                    # numberless; FRR routes via it

    # Per-tenant vlan-aware L2VNI bridge (pure L2) + dedicated anycast SVI:
    # one bridge : one vxlan : one access NIC : one VLAN SVI in the VRF.
    for spec in "${TENANTSPECS[@]}"; do
        IFS=':' read -r l2vni vlan gwcidr sviname rest <<< "$spec"
        if [ -z "$l2vni" ] || [ -z "$vlan" ] || [ -z "$gwcidr" ] || [ -z "$sviname" ]; then
            echo "  WARNING: malformed tenantspec '$spec' (want l2vni:vlan:gwcidr:sviname); skipping"
            continue
        fi
        BR="br-vni${l2vni}"
        VX="vxlan${l2vni}"

        if ! ip link show "$BR" &>/dev/null; then
            ip link add "$BR" type bridge
            echo 1 > "/sys/class/net/$BR/bridge/vlan_filtering"
            echo 0 > "/sys/class/net/$BR/bridge/stp_state"
            echo "  Created $BR (vlan-aware, pure L2, STP disabled)"
        fi
        # L2VNI bridge stays pure L2 (NOT VRF-enslaved); the routed anycast
        # gateway lives on the dedicated VLAN SVI ($sviname) created below.
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
        # vlan-aware mapping (mirrors the L3VNI): VXLAN port + bridge carry the
        # tenant access VLAN, untagged on the wire (VLAN is bridge-local).
        bridge vlan add dev "$VX" vid "$vlan" pvid untagged 2>/dev/null || true
        bridge vlan add dev "$VX" vid "$vlan" tunnel_info id "$l2vni" 2>/dev/null || true
        bridge vlan add dev "$BR" vid "$vlan" self 2>/dev/null || true
        # Per-VLAN ARP/ND suppression so the local SVI answers ARP for the GW IP.
        bridge vlan set dev "$VX" vid "$vlan" neigh_suppress on 2>/dev/null || true

        # Anycast gateway on a dedicated per-L2VNI VLAN SVI ($sviname on $BR),
        # enslaved to the VRF. IP+MAC MUST match frr.conf 'interface $sviname'.
        ip link show "$sviname" &>/dev/null || \
            ip link add link "$BR" name "$sviname" type vlan id "$vlan"
        svi_master=$(ip -o link show "$sviname" 2>/dev/null | grep -oP 'master \K\S+' || true)
        [ "$svi_master" != "$VRF" ] && ip link set "$sviname" master "$VRF"
        ip link set "$sviname" address "$ANYCAST_MAC" 2>/dev/null || true
        ip addr replace "$gwcidr" dev "$sviname"
        ip link set "$sviname" up
        echo "  Anycast GW $gwcidr ($ANYCAST_MAC) on dedicated SVI $sviname (vlan $vlan, VRF $VRF); $BR pure L2"
    done

    # Access ports: enslave the leaf overlay NICs (pure L2, no IP), renamed by
    # udev to eth-ovl / eth-ovl-b. If absent on the first EVPN pass (before
    # wire), this is a no-op completed by the make overlay re-run.
    if ip link show eth-ovl &>/dev/null; then
        ovl_master=$(ip -o link show eth-ovl 2>/dev/null | grep -oP 'master \K\S+' || true)
        [ "$ovl_master" != "br-vni10000" ] && ip link set eth-ovl master br-vni10000
        ip link set eth-ovl up
        # PVID-tag untagged server frames into tenant-a VLAN 99 (a vlan-aware
        # bridge drops untagged frames otherwise).
        bridge vlan add dev eth-ovl vid 99 pvid untagged 2>/dev/null || true
        echo "  Enslaved eth-ovl -> br-vni10000 (tenant-a access port, vlan 99)"
    else
        echo "  eth-ovl not present yet; access enslave deferred to 'make overlay'"
    fi
    if ip link show eth-ovl-b &>/dev/null; then
        ovlb_master=$(ip -o link show eth-ovl-b 2>/dev/null | grep -oP 'master \K\S+' || true)
        [ "$ovlb_master" != "br-vni10001" ] && ip link set eth-ovl-b master br-vni10001
        ip link set eth-ovl-b up
        # PVID-tag untagged server frames into tenant-b VLAN 98.
        bridge vlan add dev eth-ovl-b vid 98 pvid untagged 2>/dev/null || true
        echo "  Enslaved eth-ovl-b -> br-vni10001 (tenant-b access port, vlan 98)"
    fi
fi

# systemd timer for the EVPN metrics collector.
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

# Restart FRR last so zebra ingests the kernel VNIs/VRF/SVIs. FRR
# auto-classifies VNI 10999 as the L3VNI for VRF Tenant-A once the kernel
# binding exists; the L2VNIs become Type-2/3 capable.
if [ -n "$L3VNI" ] && [ ${#TENANTSPECS[@]} -gt 0 ]; then
    systemctl restart frr 2>/dev/null || echo "  WARNING: frr restart failed (will retry on next pass)"
    echo "  FRR restarted to ingest VNIs/VRF/SVIs"
fi

# Re-pin anycast SVI L3 state after the FRR restart (restart can clear it) and
# persist for reboots. MAC/IP must match frr.conf.j2.
if [ -n "$L3VNI" ] && [ ${#TENANTSPECS[@]} -gt 0 ]; then
    # VRF master + global forwarding.
    sysctl -w "net.ipv4.conf.${VRF}.forwarding=1" >/dev/null 2>&1 || true
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

    # L3VNI transit SVI (symmetric-IRB routed path between leaves).
    ip link set svi-l3vni up 2>/dev/null || true
    sysctl -w net.ipv4.conf.svi-l3vni.forwarding=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.conf.svi-l3vni.rp_filter=2 >/dev/null 2>&1 || true

    # Per-tenant anycast SVIs (the L2VNI bridge interfaces).
    for spec in "${TENANTSPECS[@]}"; do
        IFS=':' read -r l2vni vlan gwcidr sviname rest <<< "$spec"
        [ -n "$l2vni" ] && [ -n "$sviname" ] && [ -n "$gwcidr" ] || continue
        ip link set "$sviname" address "$ANYCAST_MAC" 2>/dev/null || true
        ip addr replace "$gwcidr" dev "$sviname" 2>/dev/null || true
        ip link set "$sviname" up 2>/dev/null || true
        # Bounded carrier wait, max 10s.
        for i in $(seq 1 10); do
            ip link show "$sviname" 2>/dev/null | grep -q 'LOWER_UP' && break
            sleep 1
        done
        # Flush the SVI ARP cache so it re-arms after the FRR restart. IP
        # neighbor table only; does not touch the bridge MAC FDB.
        ip neigh flush dev "$sviname" 2>/dev/null || true
        sysctl -w "net.ipv4.conf.${sviname}.forwarding=1" >/dev/null 2>&1 || true
        sysctl -w "net.ipv4.conf.${sviname}.rp_filter=2" >/dev/null 2>&1 || true
        sysctl -w "net.ipv4.conf.${sviname}.arp_ignore=0" >/dev/null 2>&1 || true
        sysctl -w "net.ipv4.conf.${sviname}.arp_accept=1" >/dev/null 2>&1 || true
        sysctl -w "net.ipv4.conf.${sviname}.arp_announce=0" >/dev/null 2>&1 || true
        echo "  Re-asserted anycast SVI $sviname ($gwcidr / $ANYCAST_MAC) + L3 sysctls"
    done

    # Persist for later boots. Keys for the known SVIs; harmless if absent.
    cat > /etc/sysctl.d/99-netwatch-evpn-svi.conf <<'SYSCTLEOF' || true
# NetWatch: EVPN anycast-SVI L3 datapath sysctls (persisted)
net.ipv4.ip_forward = 1
net.ipv4.conf.svi-l3vni.forwarding = 1
net.ipv4.conf.svi-l3vni.rp_filter = 2
net.ipv4.conf.svi-vni10000.forwarding = 1
net.ipv4.conf.svi-vni10000.rp_filter = 2
net.ipv4.conf.svi-vni10000.arp_ignore = 0
net.ipv4.conf.svi-vni10000.arp_accept = 1
net.ipv4.conf.svi-vni10000.arp_announce = 0
net.ipv4.conf.svi-vni10001.forwarding = 1
net.ipv4.conf.svi-vni10001.rp_filter = 2
net.ipv4.conf.svi-vni10001.arp_ignore = 0
net.ipv4.conf.svi-vni10001.arp_accept = 1
net.ipv4.conf.svi-vni10001.arp_announce = 0
SYSCTLEOF
    sysctl --system >/dev/null 2>&1 || true
fi

# Informational: what FRR now sees.
echo "  EVPN datapath summary:"
vtysh -c "show evpn vni" 2>/dev/null | head -6 || echo "  (FRR not aware of VNIs yet; convergence gate runs in setup-evpn.sh)"

echo "  VTEP $LOOPBACK configured (primary L2VNI $L2VNI_PRIMARY${L3VNI:+, L3VNI $L3VNI, VRF $VRF})"
