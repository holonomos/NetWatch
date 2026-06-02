# NetWatch Architecture

This document explains *how* and *why* NetWatch is built the way it is. For operating it, see [RUNBOOK.md](RUNBOOK.md); for current defects and drift, see [KNOWN-ISSUES.md](KNOWN-ISSUES.md).

---

## 1. Design philosophy

NetWatch emulates a hyperscale data-center fabric on one laptop with enough fidelity that the **control-plane behaves like production**, while accepting that the **data-plane is software** (Linux kernel forwarding, not ASICs).

Five decisions shape everything:

1. **All VMs, no containers.** Every node, routers included, is a full Fedora KVM VM running real `systemd`, real `FRR`, real `iproute2`. This trades RAM (~19 GB) for realism: you can `ssh` into a "switch", `systemctl restart frr`, watch real interface state, and hard-kill it with `virsh destroy` exactly as you would a real box.

2. **One golden image.** All 31 VMs boot from a single `netwatch-golden` Vagrant box that already contains FRR, the exporters, Prometheus, Grafana, Loki, and every tool. **Provisioning only configures; it never installs.** This makes `vagrant up` fast and fully offline. Role differentiation happens entirely through which services get `systemctl enable`d at first boot. See [§7](#7-the-golden-image--provisioning).

3. **`topology.yml` is the single source of truth.** A single YAML file defines every node, link, ASN, IP, and timer. `generator/generate.py` renders all FRR configs, the Prometheus scrape list, dnsmasq, Loki, and the host wiring scripts from it. The fabric is reproducible and diff-able; you reason about the network by reading one file. See [§6](#6-the-configuration-generation-pipeline).

4. **eBGP everywhere, ASN-per-rack.** No iBGP, no IGP, no route reflectors in the underlay. A 6-ASN model maps cleanly onto failure domains and makes BGP path selection easy to reason about. See [§3](#3-control-plane).

5. **Control-plane timers are 10× dilated.** On shared laptop CPUs, scheduling jitter causes false BFD flaps. NetWatch multiplies all control-plane timers by 10 (BFD 100 ms → 1000 ms, BGP keepalive 3 s → 30 s) so the state machines are identical to production but immune to host jitter. Data-plane metrics (latency, loss) are untouched, so chaos measurements stay meaningful (`topology.yml` §timers).

---

## 2. Node inventory

31 VMs in five roles, all on the `netwatch-golden` box:

| Role | Count | Names | vCPU / RAM | ASN | Loopback | Mgmt IP | Metrics |
|---|---|---|---|---|---|---|---|
| border | 2 | border-1,2 | 1 / 256 MB | 65000 | 10.0.1.1-2 | .10-.11 | frr_exporter :9342 |
| spine | 2 | spine-1,2 | 1 / 256 MB | 65001 | 10.0.2.1-2 | .20-.21 | :9342 |
| leaf | 8 | leaf-{1..4}{a,b} | 1 / 256 MB | 651xx/rack | 10.0.3.1-8 | .30-.37 | :9342 |
| server | 16 | srv-{1..4}-{1..4} | 1 / 768 MB | — | 10.0.4-7.x | .50-.65 | node_exporter :9100 |
| bastion | 1 | bastion | 1 / 384 MB | — | — | .2 | :9100 |
| obs | 1 | obs | 2 / 2048 MB | — | — | .4 | node_exporter :9100 + stack host |
| mgmt | 1 | mgmt | 2 / 2048 MB | — | — | .3 | :9100 |

> **`obs` is the observability host** (`192.168.0.4`): it runs Prometheus, Grafana, Loki, dnsmasq (DNS for `netwatch.lab`), and chrony (NTP), and is provisioned by `scripts/provision-obs.sh`. `obs` is a first-class node in `topology.yml` (under `nodes.infrastructure`), and `observability.{prometheus,grafana,loki}.host` all point at `obs`. `mgmt` (`192.168.0.3`) is a reserved stub: base + client provisioning only, no services. The `Vagrantfile` remains the runtime ground truth and the table above agrees with it.

---

## 3. Control plane

### ASN model (6 ASNs, eBGP only)

```
border-1, border-2          AS 65000     (shared)
spine-1,  spine-2           AS 65001     (shared)
leaf-1a,  leaf-1b           AS 65101     rack-1
leaf-2a,  leaf-2b           AS 65102     rack-2
leaf-3a,  leaf-3b           AS 65103     rack-3
leaf-4a,  leaf-4b           AS 65104     rack-4
```

Each rack is its own ASN, a clean failure domain. Both nodes in a tier (or rack) share an ASN, which has a consequence: a route that transits the shared tier comes back carrying that AS in its path. NetWatch handles this with `allowas-in 1` on the `border` and `leaf` roles (`generate.py:273` sets `needs_allowas_in` for those roles):

- **Intra-rack reachability:** `leaf-1a → spine → leaf-1b`. The route arrives at leaf-1b with `65101` already in the AS-path (its own ASN), normally rejected as a loop, so `allowas-in 1` permits one occurrence.
- **Inter-border reachability:** `border-1 → spine → border-2` similarly carries `65000`.

Spines do not need `allowas-in` (the spine ASN never loops back to a spine through this topology).

### BGP configuration (per generated `frr.conf`)

Every FRR node runs `frr defaults datacenter` and a single `router bgp <asn>` with:

- `no bgp ebgp-requires-policy`: accept routes without an explicit inbound policy (lab convenience).
- `no bgp default ipv4-unicast`: neighbors are explicitly `activate`d per address-family.
- `bgp bestpath as-path multipath-relax` + `maximum-paths 8`: ECMP across equal-cost paths with differing AS-paths (essential for Clos: a leaf reaches a remote rack via either spine).
- `timers bgp 30 90`: dilated keepalive/hold.
- BFD on every neighbor (`neighbor X bfd`) with a matching `bfd ... peer` block: tx/rx 1000 ms, detect-multiplier 3, so ~3 s failure detection.
- `redistribute connected route-map CONNECTED-FILTER`: inject the fabric `/30`s and loopbacks, but the route-map's prefix-list denies `192.168.0.0/24` so the OOB management network never leaks into the routed fabric.
- Leaf and border also `redistribute static` (leaf: server-loopback `/32`s; border: the default route).

### Route propagation

- **Server loopbacks (`10.0.4-7.x/32`):** each leaf has `ip route <srv-loopback>/32 <srv-p2p-ip>` static routes (servers don't run BGP), redistributed into BGP and flooded fabric-wide.
- **Default route (north-south):** each **border** has `ip route 0.0.0.0/0 172.16.0.2` (its bastion neighbor) and `redistribute static`, so a default originates at the borders and propagates border → spine → leaf → server. Servers therefore learn a default via BGP *and* have a kernel ECMP default installed directly (see [§4](#4-data-plane--forwarding-paths)).

---

## 4. Data plane / forwarding paths

The data plane is **Linux kernel L3 forwarding**. Every fabric link is a routed `/30`; there is no L2 bridging in the underlay (host bridges have STP disabled and carry exactly two endpoints each).

**East-west (server-to-server, different racks):**
```
srv-1-1 ─(ECMP)→ leaf-1a / leaf-1b ─(ECMP)→ spine-1 / spine-2 ─→ leaf-3a / leaf-3b ─→ srv-3-2
```
Fully routed, ECMP at every hop. A server installs equal-cost routes for `10.0.0.0/8` and `172.16.0.0/12` via **both** of its leafs (`configure-vm-fabric.sh`), and each leaf has two spines, so there are 4 disjoint paths between any two racks.

**North-south (server → internet):**
```
srv → leaf → spine → border → bastion ─(NAT MASQUERADE)→ internet
```
The bastion is the **sole** NAT gateway and the only node with an internet-facing interface. It masquerades `10.0.0.0/8`, `172.16.0.0/12`, and `192.168.0.0/24` out the host-facing NIC (`Vagrantfile` bastion block / `configure-bastion-fabric.sh`).

**Server dual-homing.** Each of the 16 servers is wired to **both** leafs in its rack (32 leaf↔server links). A NetworkManager dispatcher script (`configure-vm-fabric.sh`) re-applies the ECMP routes whenever a fabric NIC comes up, so dual-homing survives reboots and link flaps.

**Host access.** `make routes` adds `ip route 10.0.0.0/8 via 192.168.0.2` on the host, so you can reach any loopback/server straight from the laptop through the bastion.

---

## 5. EVPN / VXLAN overlay (real L2 tenant segments)

> **Status:** the overlay is a traffic-carrying L2 fabric (symmetric IRB design with a distributed anycast gateway). The full datapath runs `topology.yml` → `generate.py` → templates → `configure-evpn-vtep.sh`/`setup-evpn.sh`.
>
> Same-subnet L2 over VXLAN is validated on the 31-VM fabric at 0% loss (see [RUNBOOK.md §5a](RUNBOOK.md) for the procedure): a server's ARP neighbor for a cross-rack peer in the same tenant resolves to the peer's real NIC MAC over VXLAN, with remote MACs learned on the L2VNI, a genuine L2 frame crossing the overlay.
>
> The inter-subnet symmetric-IRB datapath through the distributed anycast gateway is implemented and its EVPN control plane is verified (Type-2 MAC/IP and Type-5 routes, explicit RD/RT, VRF `Tenant-A` routes all present on the remote leaves). Inter-subnet forwarding does not work on a fresh bring-up: the anycast-GW SVI does not answer/forward for its own IP, so inter-subnet ping does not succeed on a clean build. See [KNOWN-ISSUES.md](KNOWN-ISSUES.md) and the IRB section below.
>
> The design is additive. The routed `/30` ECMP underlay from [§4](#4-data-plane--forwarding-paths) is byte-identical and keeps working regardless of overlay state: routed cross-rack loopback ping and the ECMP default are intact, and the `10.99.0.0/16` overlay supernet is not injected into the underlay BGP (`CONNECTED-FILTER` denies it).

The 8 leafs are VXLAN VTEPs (`local = loopback`, `dstport 4789`, `nolearning`, so FRR owns MAC learning). The control plane is MP-BGP `l2vpn evpn`; the spines are EVPN route-reflectors; the data plane is Linux-kernel VXLAN + a VRF + IRB SVIs.

### Tenants, VLANs, and VNIs (the actual constants)

Two tenant L2 segments live on top of the underlay. Servers join a segment via a dedicated extra access NIC (`tnt0`/`tnt1`), single-homed to leaf-`Xa`, given a tenant `/24` plus one route: the overlay supernet `10.99.0.0/16` via the tenant's anycast gateway (so cross-tenant traffic finds the IRB while same-subnet traffic stays connected/L2; the NIC never touches the underlay ECMP), MTU 1450 (50 B VXLAN headroom):

| Tenant | L2VNI | Access VLAN | Subnet | Anycast GW | EVPN RT | Members (server → leaf, overlay IP, access NIC) |
|---|---|---|---|---|---|---|
| tenant-a | 10000 | 99 | 10.99.0.0/24 | 10.99.0.1/24 | 65000:10000 | srv-1-1→leaf-1a (.11), srv-2-1→leaf-2a (.21), srv-3-1→leaf-3a (.31), srv-4-1→leaf-4a (.41); all `tnt0` |
| tenant-b | 10001 | 98 | 10.99.1.0/24 | 10.99.1.1/24 | 65000:10001 | srv-4-1→leaf-4a (.41); `tnt1` (a second segment / a server attached to two VNIs) |

The anycast gateway is the L2VNI bridge interface itself (`interface br-vni10000` / `br-vni10001` in `frr.conf`; the IP+MAC are put on the bridge in `configure-evpn-vtep.sh`), not a separate SVI device; see the IRB section below for why. The whole `10.99.0.0/16` overlay supernet is denied in `CONNECTED-FILTER` (prefix-list seq 6) so overlay subnets never leak into the routed underlay BGP; the routed loopback `/30` underlay is unchanged.

### Symmetric IRB / L3VNI (distributed anycast gateway)

Inter-subnet (tenant-a ↔ tenant-b) routing uses symmetric IRB over a transit L3VNI 10999, all inside VRF `Tenant-A` (kernel route-table 1099, transit SVI `svi-l3vni` on VLAN 999, RT 65000:10999). The gateway is distributed: every one of the 8 leafs (including the `b` leafs that host no tenant members) gives both L2VNI bridge interfaces the identical anycast IP and the identical anycast MAC `00:00:5e:00:01:99` (IANA VRRP-style), so a server always ARPs its default gateway and gets an answer from its directly-attached leaf wherever it lives. This is the part that does not work on a fresh build: a member cannot reach its anycast gateway `.1`. The gateway's SVI (the VRF-enslaved L2VNI bridge interface) does not answer ARP/ICMP for its own IP and does not forward inter-subnet traffic, even though the IP is present in VRF `Tenant-A`, `arp_ignore=0`, and the EVPN control plane is correct (remote MACs and Type-2 MAC/IP routes for the other tenant's hosts are learned on every leaf). The same config worked on a long-lived instance; suspected kernel/VRF state issue on fresh bring-up. Same-subnet L2 is unaffected. See [KNOWN-ISSUES.md](KNOWN-ISSUES.md).

**Why the gateway lives on the bridge interface, not a VLAN sub-interface.** Each L2VNI is a plain (non-vlan-aware) bridge and server frames arrive untagged, so a VLAN sub-interface (`br-vniX.<vlan>`) would never see them. NetWatch uses the standard traditional-bridge IRB model: the L2VNI bridge, already enslaved to the VRF, is the IRB SVI, so the anycast IP+MAC go directly on `interface br-vni10000` / `br-vni10001`. The EVPN control plane this enables is verified: for the inter-subnet case (srv-1-1 / srv-3-1 in tenant-a ↔ srv-4-1's `tnt1` in tenant-b) the EVPN Type-2 route `[2]…[10.99.1.41]` is present on the ingress leaf via the egress VTEP. The corresponding data plane does not forward on a fresh build (the bridge-interface SVI does not answer/forward for its own anycast IP); see the distributed-anycast-gateway note above and [KNOWN-ISSUES.md](KNOWN-ISSUES.md).

RD/RT are explicit, not auto-derived, because each rack is a distinct ASN (65101–65104): per-router RD = `<router-id>:VNI`, but the import/export RTs are pinned (`65000:1000x` for the L2VNIs, `65000:10999` for the L3VNI) so Type-2/3/5 routes import correctly across racks. Auto-derived RTs encode the local ASN and so would not match between racks; the explicit RT is what makes cross-rack import work. The leaf FRR config carries:
- `vrf Tenant-A` / `vni 10999` (binds the L3VNI to the VRF);
- per-L2VNI `vni 10000` / `vni 10001` blocks inside `address-family l2vpn evpn`, each with explicit `rd` + `route-target import/export`;
- a top-level `router bgp <asn> vrf Tenant-A` stanza that re-originates the tenant subnets as Type-5 routes (`advertise ipv4 unicast`, L3VNI RT);
- `advertise-all-vni` + `advertise-svi-ip` on the main BGP instance.

### Roles by tier

- **Leafs** (`configure-evpn-vtep.sh`, run by `setup-evpn.sh`): VRF `Tenant-A` + vlan-aware `br-l3vni` (enslaved to the VRF) + `vxlan10999`; one plain L2 bridge per tenant (`br-vni10000`, `br-vni10001`, enslaved to the VRF) each with its `vxlan<vni>` and the anycast gateway on the bridge interface itself (identical IP+MAC); and the leaf access NICs `eth-ovl` → `br-vni10000` / `eth-ovl-b` → `br-vni10001` (pure L2, no IP). FRR is restarted last so zebra ingests the kernel VNIs/VRF/SVIs.
- **Spines:** `l2vpn evpn` with `next-hop-unchanged` on every neighbor; EVPN route-reflectors only, no anycast/L3VNI.
- **Borders:** no `l2vpn evpn` family (outside the overlay).
- A 15 s systemd timer runs `evpn-metrics-collector.sh` on each leaf, exporting the control-plane counters and per-VNI L2 data-path metrics (see [§9](#9-observability)).

### How a frame crosses racks

**Same-subnet, different racks** (e.g. srv-1-1 `10.99.0.11` ↔ srv-2-1 `10.99.0.21`, both tenant-a / L2VNI 10000, validated at 0% loss):

```
srv-1-1 tnt0 ─► br-ovl-01 ─► leaf-1a eth-ovl ─► br-vni10000 ─► vxlan10000
        │  (Type-2 MAC/IP learned via BGP-EVPN from leaf-2a)              │
        │  VXLAN-encap (VNI 10000), outer src=leaf-1a loopback,           ▼
        │  outer dst=leaf-2a loopback ── routed over the /30 ECMP underlay (spines) ──►
        ▼                                                                 │
   leaf-2a vxlan10000 ─► br-vni10000 ─► eth-ovl ─► br-ovl-05 ─► srv-2-1 tnt0
```

The L2 frame is encapsulated in VXLAN and carried inside the routed underlay between the two leaf loopbacks: the underlay is the transport, the overlay is the tenant L2 segment, and no L3 routing happens to the inner packet. The destination's ARP neighbor resolves to the peer server's real NIC MAC (an L2 frame crossed VXLAN, it was not routed), and a leaf shows ~14 remote MACs learned on VNI 10000.

**Different subnet** (tenant-a ↔ tenant-b, e.g. srv-1-1/srv-3-1 in `10.99.0.0/24` ↔ srv-4-1's `tnt1` `10.99.1.41` in `10.99.1.0/24`). This is the designed path; it is a known data-plane limitation on a clean from-scratch bring-up (see [KNOWN-ISSUES.md](KNOWN-ISSUES.md)). The source server sends to its anycast gateway `.1` (which `configure-overlay-if.sh` makes routable by installing `10.99.0.0/16 via <gw> dev tntX`, so the other tenant subnet does not fall into the server's `10.0.0.0/8` underlay route). The ingress leaf is meant to route the inner packet into VRF `Tenant-A`, re-encapsulate it with the transit L3VNI 10999, and the egress leaf de-encapsulate and route it onto the destination tenant bridge: classic symmetric IRB (route → L3VNI → route). The control plane is verified (the ingress leaf carries the EVPN Type-2 route `[2]…[10.99.1.41]` via the egress VTEP), but on a fresh build the anycast-GW SVI does not answer/forward, so this path does not complete and inter-subnet ping does not succeed on a clean build.

### Bring-up ordering (important)

`make up` runs `evpn` before `wire`, so on the first EVPN pass the server `tnt0` NICs (and therefore the leaf `eth-ovl` access NICs) do not exist yet. That is intentional: `configure-evpn-vtep.sh` builds the VRF/VNIs/SVIs on the first pass and logs a no-op for the access enslave; the `make overlay` step (a second, idempotent `setup-evpn.sh` run after `wire`) completes the `eth-ovl`/`eth-ovl-b` enslave once the server NICs are present. `setup-evpn.sh` gates each leaf on BGP-EVPN convergence (≥1 Established L2VPN-EVPN peer, bounded ~2 min) before the VNI check, so the VNI check is meaningful.

**Type-2 advertisement on first transmit.** A leaf only advertises an EVPN Type-2 (MAC/IP) route for a member once it has learned that member's MAC+IP, i.e. once the member has transmitted. A still-silent member is unresolvable to remote leaves, so inter-subnet traffic to it fails until it first speaks. After the access ports are enslaved, `setup-evpn.sh` has each member ping its anycast gateway(s) (one per tenant NIC), which makes its leaf learn it and originate the Type-2 route.

### Host-side wiring summary

Beyond the 54 underlay `/30` bridges, the overlay adds 5 host bridges (`setup-bridges.sh`): `br-ovl-01`, `br-ovl-05`, `br-ovl-09`, `br-ovl-0D` (tenant-a access for srv-1-1/2-1/3-1/4-1) and `br-ovl-0D-b` (tenant-b access for srv-4-1's `tnt1`). Leaf access-NIC MACs are in the reserved `02:4E:57:03:F0:xx` range with matching udev rules. None of this touches the underlay registry or the `len(interfaces)==2` server guard; the tenant access NICs are added through separate generator context lists, not the top-level `links:`.

---

## 6. The configuration-generation pipeline

```
topology.yml ──► generator/generate.py ──► generated/   (configs, never hand-edited)
                       │                └─► scripts/fabric/  (5 wiring scripts, GENERATED)
                       └─ Jinja2 templates in generator/templates/
```

`generate.py` (run via `make generate`):

1. **Loads & validates** `topology.yml` (requires the `project/timers/asn/addressing/nodes/links/management/observability` keys).
2. **Builds a node registry:** flattens all nodes, assigns each a deterministic MAC `02:4E:57:<tier>:<...>` (`02:4E:57` = "NW", locally administered).
3. **Builds a link registry:** for each of the 54 links, assigns a host bridge `brNNN`, names the in-guest interfaces `eth-<peer>` (e.g. `eth-spine-1`), generates fabric MACs, and derives the BGP-neighbor lists (only between `frr-vm` nodes).
4. **Renders** per the templates:
   - `generated/frr/<node>/` → `frr.conf`, `daemons`, `vtysh.conf`, and `70-netwatch-fabric.rules` (udev rules that rename NICs to `eth-<peer>` by MAC).
   - `generated/prometheus/prometheus.yml`: scrape targets (built from the node registry: 12 `frr` + 19 `node` jobs; it does not read `topology.yml`'s `observability.targets` list).
   - `generated/dnsmasq/dnsmasq.conf`, `generated/loki/loki-config.yml`.
   - `generated/grafana/dashboards/*.json`: the 8 NOC dashboards copied verbatim from `generator/templates/grafana/dashboards/`. The dashboards are source under `templates/`, so the "never hand-edit `generated/`" rule holds for them too: edit the template, re-`make generate`, and the obs VM re-rsyncs them. `make generate` prints `[Grafana] 8 dashboards`.
   - **Into `scripts/fabric/`** (not `generated/`): `setup-bridges.sh`, `setup-frr-links.sh`, `setup-server-links.sh`, `status.sh`, `teardown.sh`.

> Those five fabric scripts are generated output and `make generate` overwrites them. **To fix a bug in any of them, edit the Jinja template under `generator/templates/scripts/`, not the file in `scripts/fabric/`,** otherwise your fix is lost on the next regenerate. The other scripts in `scripts/fabric/` (`configure-*.sh` including `configure-overlay-if.sh`, `setup-evpn.sh`, `configure-evpn-vtep.sh`, `evpn-metrics-collector.sh`) are hand-maintained and safe to edit directly. This split is the key distinction when modifying fabric code.

The overlay datapath ([§5](#5-evpn--vxlan-overlay-real-l2-tenant-segments)) is driven from the same `topology.yml` `evpn:` block: `generate.py` renders the per-tenant anycast gateway on each L2VNI bridge interface, the VRF/L3VNI binding, the per-VNI RD/RT and the L3VNI Type-5 re-origination stanza into each leaf `frr.conf`; the overlay host bridges + leaf access-NIC udev rules into the generated scripts; and the server access-NIC wiring into `setup-server-links.sh` (which pipes the hand-maintained `configure-overlay-if.sh` into each member server).

---

## 7. The golden image & provisioning

**Build pipeline** (`scripts/bake-golden-image.sh`, run via `make bake`):

1. Start from `artifacts/boxes/fedora-${FEDORA_RELEASE}.box` (registered as `netwatch-fedora${FEDORA_RELEASE}`), version pinned in `artifacts/versions.env` (currently `FEDORA_RELEASE=44`).
2. **Phase 1, RPMs:** chrony, rsyslog, iptables-services, dnsmasq, FRR, plus a debug toolkit (`tcpdump`, `mtr`, `tc`, `htop`, …). FRR is installed then `systemctl disable`d (baked but off).
3. **Phase 2, binaries** (from GitHub/Grafana into `/usr/local/bin`): `node_exporter`, `frr_exporter`, `promtail`, `loki`, `prometheus`/`promtool`, and the Grafana RPM.
4. **Phase 3, systemd units & sysctls:** unit files for all of the above written but not enabled; bakes `rp_filter=2`; disables `systemd-resolved` and `dnf-makecache.timer`; `restorecon` on `/usr/local/bin`.
5. **Phase 4-5, cleanup & package:** `dnf clean`, zero free space, `vagrant package` → `netwatch-golden.box` (~1.5 GB).

**Net effect:** every binary for every role exists in every VM. A node becomes a router or an observability host purely by which units its provisioner enables.

**Provisioning at `vagrant up`** (`Vagrantfile`):

- **`COMMON_BASE`** (all VMs): point DNS at `192.168.0.4` (obs), pin NetworkManager `dns=none`, activate sysctls, enable `node_exporter` (with textfile collector), harden SSH to key-only.
- **`COMMON_CLIENT`** (servers/bastion/FRR/mgmt): chrony → `192.168.0.4`, rsyslog → `192.168.0.4:514` (Loki).
- **`FRR_COMMON`** (12 switches): rsync `generated/frr/<node>/` to `/tmp/netwatch-config/frr`, copy into `/etc/frr/`, install udev rules, enable `ip_forward`, `systemctl enable --now frr` and `frr_exporter`. FRR starts with the full config but only the mgmt NIC exists, so the fabric `interface eth-*` stanzas stay dormant until NICs are hot-plugged.
- **`obs`**: runs `provision-obs.sh` → enables Prometheus, Grafana, Loki, dnsmasq (DNS for `netwatch.lab`), chrony (NTP server), rsyslog receiver, promtail.
- **`mgmt`**: inline base+client stub only (reserved for future use); no provisioner script is wired in.
- **`bastion`**: enables `ip_forward` + iptables MASQUERADE on the internet-facing NIC.

---

## 8. Fabric bring-up sequence (`make up`)

`make up` = `hostfix → bridges → fabric → evpn → wire → routes → overlay → status`. FRR configs are already on the VMs from provisioning; bring-up wires the data path and restarts FRR onto it. `setup-evpn.sh` runs twice: once at `evpn` (builds the VRF/VNIs/SVIs before the access NICs exist) and again at `overlay` (after `wire`, to enslave the now-present access NICs); see [§5](#5-evpn--vxlan-overlay-real-l2-tenant-segments) for why.

| Step | Script | Action |
|---|---|---|
| **hostfix** | inline | Insert `nft` FORWARD ACCEPT rules for every `virbr*` (defeats Docker's FORWARD DROP). |
| **bridges** | `setup-bridges.sh` | Create 54 host `/30` bridges `br000`–`br053` plus 5 overlay bridges (`br-ovl-*`), STP disabled, up. |
| **fabric** | `setup-frr-links.sh` | For each of the 12 FRR VMs: `virsh attach-interface` each fabric NIC (`--live --config`, deterministic MAC) onto its bridge (including the leaf overlay access NICs `eth-ovl`/`eth-ovl-b`), then pipe `configure-frr-fabric.sh` over `vagrant ssh` to set loopback, IP-by-MAC the `/30`s, write NM keyfiles, and `systemctl restart frr`. |
| **evpn** | `setup-evpn.sh` (pass 1) | For each of the 8 leafs: gate on BGP-EVPN convergence, upload the metrics collector, pipe `configure-evpn-vtep.sh` to build VRF `Tenant-A` + L3VNI 10999 + per-tenant L2VNI bridges (`br-vni10000`/`br-vni10001`) + the anycast gateway IP+MAC on each L2VNI bridge interface + the 15 s metrics timer. The access-NIC enslave is a logged no-op here (server NICs not wired yet). |
| **wire** | `setup-server-links.sh` | Same hot-attach pattern for the 16 servers (dual-NIC ECMP + NM dispatcher) and the bastion (dual-NIC + NAT), plus the 5 overlay access NICs (`tnt0`/`tnt1`) on the member servers via `configure-overlay-if.sh` (tenant `/24` only, MTU 1450, no gateway/routes). |
| **routes** | inline | Host route `10.0.0.0/8 via 192.168.0.2` so the laptop can reach the fabric. |
| **overlay** | `setup-evpn.sh` (pass 2) | Idempotent re-run that now finds the leaf `eth-ovl`/`eth-ovl-b` NICs and enslaves them into `br-vni10000`/`br-vni10001`, completing the L2 datapath. |
| **status** | `status.sh` | 31 underlay checks (domain states, 54 bridges, mgmt pings, BGP summary, default routes, bastion reachability) plus informational overlay checks (5 `br-ovl-*` bridges, L2VNI 10000 / L3VNI 10999 presence, remote-MAC count on VNI 10000). |

NIC delivery is hot-plug, not boot-time: VMs boot with only their mgmt NIC, and fabric NICs are attached afterward. This is why FRR is installed-but-restarted and why interface lookup is by MAC (udev naming may not have settled when the configure scripts run).

---

## 9. Observability

```
 every node:  node_exporter :9100   (16 servers + bastion + obs + mgmt)
              frr_exporter  :9342   (12 FRR switches)
              rsyslog ───────────────────────────┐
 leaf VTEPs:  evpn-metrics (textfile, 15 s)       │  (control-plane + L2 data-path)
                                                   ▼
        obs VM (192.168.0.4):  Prometheus :9090 ──► Grafana :3000
                               Loki :3100  ◄── (rsyslog/promtail)
```

The stack lives on the **`obs`** VM (`192.168.0.4`). `obs` is a first-class node in `topology.yml` and `observability.{prometheus,grafana,loki}.host` all point at it.

- **Prometheus** (built by `generate.py` from the node registry, 15 s interval) scrapes the `frr` job (12 switches :9342) and the `node` job (19 targets :9100: 16 servers + bastion + mgmt + obs itself, each labelled with its `role`). Per-leaf EVPN metrics are surfaced through each leaf's node_exporter textfile collector, so they arrive on the same `:9100` scrape.
- **Loki** ingests syslog forwarded from every node (`*.* @@192.168.0.4:514`); query in Grafana via LogQL.
- **EVPN metrics** (`evpn-metrics-collector.sh`, 15 s timer on each leaf, written to `/var/lib/node_exporter/textfile/evpn.prom`):
  - *Control plane:* `netwatch_evpn_vni_count`, `netwatch_evpn_peers_established`, `netwatch_evpn_routes_total`, `netwatch_evpn_remote_vteps`.
  - *L2 data path (per-VNI, label `vni`):* `netwatch_evpn_vni_info{vni,type,vrf}`, `netwatch_evpn_mac_total`/`_local`/`_remote`, `netwatch_evpn_arp_total`/`_remote`, `netwatch_evpn_vni_remote_vteps`. `netwatch_evpn_mac_remote{vni="10000"}` is the data-path proof: a non-zero value means a peer server's MAC was learned over VXLAN (Type-2), i.e. an L2 frame crossed the overlay rather than the routed underlay.
  - *Rollups:* `netwatch_evpn_mac_remote_total`, `netwatch_evpn_l2vni_count`, `netwatch_evpn_l3vni_count`.
- **Grafana** is the front end, provisioned (`provision-obs.sh`) with two fixed-UID datasources (`netwatch-prometheus` and `netwatch-loki`) and a file-based dashboard provider pointed at `/var/lib/grafana/dashboards`. 8 NOC dashboards ship and load on the obs VM (Grafana healthy, all 8 JSON on disk), each referencing the provisioned `netwatch-prometheus`/`netwatch-loki` UIDs:

  | Dashboard JSON | uid | Focus |
  |---|---|---|
  | `noc-overview` | `netwatch-noc-overview` | top-level NOC health roll-up |
  | `fabric-overview` | `netwatch-fabric-overview` | fabric-wide up/state at a glance |
  | `bgp-status` | `netwatch-bgp-status` | BGP sessions / message rates per peer |
  | `node-detail` | `netwatch-node-detail` | per-node CPU/mem/disk/net |
  | `interface-counters` | `netwatch-interface-counters` | interface throughput / errors |
  | `chaos-events` | `netwatch-chaos-events` | chaos annotations + impact |
  | `evpn-vxlan` | `netwatch-evpn-vxlan` | EVPN/VXLAN control plane and L2 data path |
  | `netwatch-smoke` | `netwatch-smoke` | smoke board (target up-counts, BGP msg rate, recent logs) |

  The `evpn-vxlan` board surfaces `netwatch_evpn_mac_remote` (the L2 data-path proof) alongside the per-VNI counters. The dashboard metric names were reconciled against the live `frr_exporter`/textfile output, so the panels populate against the running fabric.
- **Access:** `make dashboard` (SSH tunnel from obs) or the bastion's DNAT ports (`config/bastion-dnat.conf`: 3000/9090/3100 → `192.168.0.4`), reachable at `http://192.168.0.2:<port>`.

---

## 10. Chaos engineering

Chaos scenarios live in `scripts/chaos/` (shared helpers in `lib.sh`, which holds the 54-entry bridge map and POSTs Grafana annotations around each event):

| Scenario | Mechanism | Reverses how |
|---|---|---|
| `link-down` / `link-up` | `ip link set <bridge> down/up` | `--restore` / `link-up` |
| `flap` | loop down/up N times | self-heals (ends up) |
| `latency` | `tc qdisc … netem delay` on the bridge's veths | `--restore` |
| `loss` | `tc qdisc … netem loss` on the veths | `--restore` |
| `partition` | down all 4 spine↔leaf bridges of a rack | `--restore` |
| `kill` | `virsh destroy <domain>` (hard power-off) | `--restore` (`virsh start` + wait SSH) |

All scenarios, including `kill` and `nuke`, target the libvirt domain `NetWatch-main_<node>`: `lib.sh` and `nuke.sh` derive the prefix from the project-root basename (`$(basename "$PROJECT_ROOT")`, see `scripts/chaos/lib.sh:23`), matching the fabric scripts. Measure impact with `validation/monitor.sh <ip>`, which reports running availability % and the longest outage gap.

**Success criteria** (`topology.yml` §validation): fabric stays converged under chaos, >99 % availability over a 10-minute run, max outage < 3 s (driven by the ~3 s BFD detection).
