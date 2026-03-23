# NetWatch — Complete Reference

> Single-file reference for every detail in the project.
> Open this when you can't hold it all in mental RAM.

---

## 1. WHAT THIS IS

30-node hyperscale data center emulator. 12-node 3-tier L3 Clos routing fabric.
Runs on a laptop. Fabric is the product; workloads are validation.

**Success criterion:** Chaos Mesh runs unmodified against k3s.
Replicated nginx holds >99% availability over 10-min chaos run, <3s max outage.

---

## 2. NODE INVENTORY (30 total)

### Routing Fabric — 12 FRR Containers (Alpine, ~40 MB each)

| Node | Role | ASN | Loopback | Mgmt IP | Metrics |
|------|------|-----|----------|---------|---------|
| border-1 | border | 65000 | 10.0.1.1/32 | 192.168.0.10 | :9342 |
| border-2 | border | 65000 | 10.0.1.2/32 | 192.168.0.11 | :9342 |
| spine-1 | spine | 65001 | 10.0.2.1/32 | 192.168.0.20 | :9342 |
| spine-2 | spine | 65001 | 10.0.2.2/32 | 192.168.0.21 | :9342 |
| leaf-1a | leaf | 65101 | 10.0.3.1/32 | 192.168.0.30 | :9342 |
| leaf-1b | leaf | 65101 | 10.0.3.2/32 | 192.168.0.31 | :9342 |
| leaf-2a | leaf | 65102 | 10.0.3.3/32 | 192.168.0.32 | :9342 |
| leaf-2b | leaf | 65102 | 10.0.3.4/32 | 192.168.0.33 | :9342 |
| leaf-3a | leaf | 65103 | 10.0.3.5/32 | 192.168.0.34 | :9342 |
| leaf-3b | leaf | 65103 | 10.0.3.6/32 | 192.168.0.35 | :9342 |
| leaf-4a | leaf | 65104 | 10.0.3.7/32 | 192.168.0.36 | :9342 |
| leaf-4b | leaf | 65104 | 10.0.3.8/32 | 192.168.0.37 | :9342 |

### Compute Servers — 16 Fedora KVM VMs (1 vCPU, 768 MB each)

| Node | Rack | Mgmt IP | Dual-homed to |
|------|------|---------|---------------|
| srv-1-1 | rack-1 | 192.168.0.50 | leaf-1a, leaf-1b |
| srv-1-2 | rack-1 | 192.168.0.51 | leaf-1a, leaf-1b |
| srv-1-3 | rack-1 | 192.168.0.52 | leaf-1a, leaf-1b |
| srv-1-4 | rack-1 | 192.168.0.53 | leaf-1a, leaf-1b |
| srv-2-1 | rack-2 | 192.168.0.54 | leaf-2a, leaf-2b |
| srv-2-2 | rack-2 | 192.168.0.55 | leaf-2a, leaf-2b |
| srv-2-3 | rack-2 | 192.168.0.56 | leaf-2a, leaf-2b |
| srv-2-4 | rack-2 | 192.168.0.57 | leaf-2a, leaf-2b |
| srv-3-1 | rack-3 | 192.168.0.58 | leaf-3a, leaf-3b |
| srv-3-2 | rack-3 | 192.168.0.59 | leaf-3a, leaf-3b |
| srv-3-3 | rack-3 | 192.168.0.60 | leaf-3a, leaf-3b |
| srv-3-4 | rack-3 | 192.168.0.61 | leaf-3a, leaf-3b |
| srv-4-1 | rack-4 | 192.168.0.62 | leaf-4a, leaf-4b |
| srv-4-2 | rack-4 | 192.168.0.63 | leaf-4a, leaf-4b |
| srv-4-3 | rack-4 | 192.168.0.64 | leaf-4a, leaf-4b |
| srv-4-4 | rack-4 | 192.168.0.65 | leaf-4a, leaf-4b |

### Infrastructure — 2 Fedora KVM VMs

| Node | Role | Mgmt IP | vCPU | RAM | Services |
|------|------|---------|------|-----|----------|
| bastion | Admin + NAT | 192.168.0.2 | 1 | 1024 MB | sshd, iptables, kubectl, helm |
| mgmt | Observability | 192.168.0.3 | 2 | 2048 MB | Prometheus :9090, Grafana :3000, Loki :3100, dnsmasq :53, chrony :123 |

---

## 3. ASN MODEL

```
AS 65000    border-1, border-2           (shared ASN)
AS 65001    spine-1, spine-2             (shared ASN)
AS 65101    leaf-1a, leaf-1b             (rack-1 pair)
AS 65102    leaf-2a, leaf-2b             (rack-2 pair)
AS 65103    leaf-3a, leaf-3b             (rack-3 pair)
AS 65104    leaf-4a, leaf-4b             (rack-4 pair)
```

eBGP everywhere. No iBGP. ASN-per-rack = independent failure domains.
RFC 7938 recommended pattern.

**Critical config note:** Leaf pairs share an ASN. When spine re-advertises
leaf-1a's routes to leaf-1b, leaf-1b sees its own ASN in the path and rejects
it (eBGP loop prevention). Fix: `allowas-in` on leaf spine-facing sessions.

---

## 4. ADDRESS SPACE

| Range | Purpose | Advertised into BGP? |
|-------|---------|---------------------|
| 10.0.0.0/16 | Loopbacks (/32 per router) — router-ID, SSH target, scrape target | Yes |
| 172.16.0.0/16 | Fabric P2P links (/30 per link) | Connected routes only |
| 192.168.0.0/24 | OOB management — DHCP/DNS from mgmt node | No — isolated from fabric |

### Fabric P2P Pools

| Pool | Range | Link count |
|------|-------|------------|
| border ↔ spine | 172.16.1.0/24 | 4 links |
| spine ↔ leaf | 172.16.2.0/24 | 16 links |
| leaf ↔ server (rack-1) | 172.16.3.0/24 | 8 links |
| leaf ↔ server (rack-2) | 172.16.4.0/24 | 8 links |
| leaf ↔ server (rack-3) | 172.16.5.0/24 | 8 links |
| leaf ↔ server (rack-4) | 172.16.6.0/24 | 8 links |

**Total links:** 4 + 16 + 32 = 52 fabric links → 52 Linux bridges
**Plus:** 1 management bridge (br-mgmt) = 53 bridges total

### Convention
- `.1` address = higher-tier endpoint (border > spine > leaf > server)
- `.2` address = lower-tier endpoint

---

## 5. BGP SESSIONS (20 total)

### Border ↔ Spine (4 sessions)

| Session | Subnet | A (border) | B (spine) |
|---------|--------|------------|-----------|
| border-1 ↔ spine-1 | 172.16.1.0/30 | .1 | .2 |
| border-1 ↔ spine-2 | 172.16.1.4/30 | .5 | .6 |
| border-2 ↔ spine-1 | 172.16.1.8/30 | .9 | .10 |
| border-2 ↔ spine-2 | 172.16.1.12/30 | .13 | .14 |

### Spine ↔ Leaf (16 sessions)

| Session | Subnet | A (spine) | B (leaf) |
|---------|--------|-----------|----------|
| spine-1 ↔ leaf-1a | 172.16.2.0/30 | .1 | .2 |
| spine-1 ↔ leaf-1b | 172.16.2.4/30 | .5 | .6 |
| spine-1 ↔ leaf-2a | 172.16.2.8/30 | .9 | .10 |
| spine-1 ↔ leaf-2b | 172.16.2.12/30 | .13 | .14 |
| spine-1 ↔ leaf-3a | 172.16.2.16/30 | .17 | .18 |
| spine-1 ↔ leaf-3b | 172.16.2.20/30 | .21 | .22 |
| spine-1 ↔ leaf-4a | 172.16.2.24/30 | .25 | .26 |
| spine-1 ↔ leaf-4b | 172.16.2.28/30 | .29 | .30 |
| spine-2 ↔ leaf-1a | 172.16.2.32/30 | .33 | .34 |
| spine-2 ↔ leaf-1b | 172.16.2.36/30 | .37 | .38 |
| spine-2 ↔ leaf-2a | 172.16.2.40/30 | .41 | .42 |
| spine-2 ↔ leaf-2b | 172.16.2.44/30 | .45 | .46 |
| spine-2 ↔ leaf-3a | 172.16.2.48/30 | .49 | .50 |
| spine-2 ↔ leaf-3b | 172.16.2.52/30 | .53 | .54 |
| spine-2 ↔ leaf-4a | 172.16.2.56/30 | .57 | .58 |
| spine-2 ↔ leaf-4b | 172.16.2.60/30 | .61 | .62 |

**Servers do NOT run BGP.** They use ECMP static default routes via both leafs.

---

## 6. PROTOCOL TIMERS (10× DILATED)

| Protocol | Parameter | Lab Value | Production Equivalent |
|----------|-----------|-----------|----------------------|
| BFD | Tx interval | 1000 ms | 100 ms |
| BFD | Rx interval | 1000 ms | 100 ms |
| BFD | Detect multiplier | 3 | 3 |
| BFD | Detection time | 3 s | 300 ms |
| BGP | Keepalive | 30 s | 3 s |
| BGP | Hold time | 90 s | 9 s |

**Why:** CPU scheduling jitter on shared laptop hardware. A 300ms scheduling
delay at 100ms BFD = false link failure. At 1000ms BFD = mild jitter.
State machines identical. Only wall-clock changes.

**Grafana:** Lab View = real timers. Production View = durations ÷ 10, rates × 10.
Data-plane metrics untouched.

---

## 7. INTERCONNECT DESIGN

- Every P2P link = 1 dedicated Linux bridge + 2 veth endpoints
- Docker containers started with `--network=none` — all networking manual
- No Docker networking, no NAT in fabric path
- Raw L2/L3 frame exchange between containers and VMs
- Management bridge (br-mgmt) isolated from fabric

### Bridge naming convention
```
br{index:03d}             # fabric links (br000..br051)
virbr2                    # management (libvirt-managed)
```

### Key sysctls per FRR container namespace
```
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1   # if EVPN needs v6
```

---

## 8. EVPN / VxLAN (LATE PHASE — after underlay proven)

- All 8 leafs are VTEPs
- MP-BGP L2VPN address family
- VNI base: 10000
- VNI-per-tenant segmentation

**Critical config notes:**
1. Spines need `address-family l2vpn evpn` on all leaf-facing sessions
2. Spines need `next-hop-unchanged` for EVPN AFI — otherwise spine rewrites
   next-hop to itself and remote leafs build VxLAN tunnels to the spine
3. `allowas-in` on leafs (see ASN model note) — required for intra-rack
   VTEP reachability

---

## 9. OBSERVABILITY

All on mgmt VM (192.168.0.3):

| Service | Port | Scrapes | Interval |
|---------|------|---------|----------|
| Prometheus | 9090 | 12 FRR on :9342, 18 VMs on :9100 | 15s |
| Grafana | 3000 | — | — |
| Loki | 3100 | rsyslog from all 30 nodes | — |
| dnsmasq | 53 | — | — |
| chrony | 123 | — | — |

### Grafana Dashboards (6)
1. Fabric Overview — node and link health
2. BGP Status — session states, route counts, peer uptime
3. Node Detail — per-node CPU/memory/network
4. Interface Counters — bytes/packets per interface
5. Chaos Events — annotated timeline of injected faults
6. EVPN/VxLAN — overlay route distribution

Each dashboard has Lab View and Production View variants.

### Metrics ports
- FRR containers → :9342 (frr_exporter sidecar)
- VMs → :9100 (node_exporter)

**Note:** Verify chosen FRR Docker image includes the HTTP API / Prometheus
exporter. Not all builds have it. Pin down in P0.

---

## 10. CHAOS ENGINEERING

### Infrastructure Chaos (P6 — core)
Tool: `tc netem` + custom scripts targeting bridges/veth pairs

| Scenario | What it does |
|----------|-------------|
| link-down | Disable a veth pair |
| link-flap | Toggle on/off at interval |
| latency-inject | Add delay via tc netem |
| packet-loss | Percentage-based drop |
| packet-corruption | Corrupt packets in flight |
| rack-partition | Isolate all bridges for a rack |
| node-kill | Stop an FRR container |

### Workload Chaos (P7 — validation addon)
Tool: Chaos Mesh (CNCF), installed via Helm on k3s

| Scenario | What it does |
|----------|-------------|
| pod-kill | Kill individual pods |
| pod-failure | Inject application failures |
| network-partition | Isolate pods/nodes |
| network-delay | Add latency between services |
| node-drain | Drain a k3s node |

---

## 11. RESOURCE BUDGET

| Component | Count | Per-Unit | Total |
|-----------|-------|----------|-------|
| FRR containers | 12 | 40 MB | 480 MB |
| Server VMs (idle, KSM on) | 16 | ~36 MB eff. | 580 MB |
| Server VMs (k3s+Cilium) | 16 | ~340 MB eff. | 5,400 MB |
| Bastion VM | 1 | 100 MB | 300 MB |
| Mgmt VM | 1 | 900 MB | 900 MB |
| QEMU overhead | 18 VMs | 15 MB | 270 MB |
| **Fabric only** | | | **~2.3 GB** |
| **Full validation** | | | **~7.1 GB** |

Primary dev: HP OmniBook Ultra (Core Ultra 9, 32 GB, Fedora)
Portability test: HP Envy x360 (i7-1165G7, 16 GB, Fedora)

---

## 12. CONFIG GENERATOR (THE KEYSTONE)

**Input:** `topology.yml` — single source of truth
**Engine:** Python 3 + PyYAML + Jinja2
**Output directory:** `generated/` (gitignored)

### Generated files

| Output | Template | Per-node? |
|--------|----------|-----------|
| `generated/frr/{node}/frr.conf` | `templates/frr/frr.conf.j2` | Yes (12) |
| `generated/frr/{node}/daemons` | `templates/frr/daemons.j2` | Yes (12) |
| `generated/frr/{node}/vtysh.conf` | `templates/frr/vtysh.conf.j2` | Yes (12) |
| `generated/prometheus/prometheus.yml` | `templates/prometheus/prometheus.yml.j2` | No (1) |
| `generated/dnsmasq/dnsmasq.conf` | `templates/dnsmasq/dnsmasq.conf.j2` | No (1) |
| `generated/loki/loki-config.yml` | `templates/loki/loki-config.yml.j2` | No (1) |

### The rule
Change topology.yml → run generator → get different fabric.
Never hand-edit generated configs. If you hand-edit, you broke the contract.

---

## 13. BUILD PHASES

| Phase | Name | Gate | Est. Hours |
|-------|------|------|-----------|
| P0 | Environment | KVM, Vagrant, Docker, FRR, Python verified | 2-4 |
| P1 | Scaffold | Repo init, topology.yml finalized, tree created | 2-3 |
| P2 | Config Generator | Generator produces valid FRR + Prometheus + DHCP configs | 8-12 |
| P3 | Core Lab | All 30 nodes reachable on OOB mgmt network, bastion SSH works | 6-10 |
| P4 | Routing | 20 BGP Established, 20 BFD Up, ECMP verified, traceroute correct | 4-8 |
| P5 | Observability | All 30 targets scraped, dashboards live, logs flowing | 4-6 |
| P6 | Chaos | Failures visible in dashboards, fabric self-heals | 4-8 |
| P7 | Validation | EVPN/VxLAN, k3s, Cilium, Chaos Mesh, nginx >99% | 6-12 |

**Total: 35–70 hours.** Serial execution — don't skip gates.

### P4 Verification Commands (quick reference)
```bash
# BGP session status (from any FRR container)
vtysh -c "show bgp summary"

# BFD session status
vtysh -c "show bfd peers"

# ECMP paths
vtysh -c "show ip route"
# Look for multiple next-hops on the same prefix

# End-to-end traceroute
traceroute -n <loopback_ip>
```

---

## 14. PROJECT TREE

```
netwatch/
├── topology.yml
├── Vagrantfile
├── README.md
├── LICENSE
├── .gitignore
│
├── generator/
│   ├── generate.py
│   └── templates/
│       ├── frr/
│       │   ├── frr.conf.j2
│       │   ├── daemons.j2
│       │   └── vtysh.conf.j2
│       ├── prometheus/
│       │   └── prometheus.yml.j2
│       ├── grafana/
│       │   └── dashboards/
│       ├── dnsmasq/
│       │   └── dnsmasq.conf.j2
│       └── loki/
│           └── loki-config.yml.j2
│
├── scripts/
│   ├── fabric/
│   │   ├── setup-bridges.sh
│   │   ├── setup-frr-containers.sh
│   │   ├── teardown.sh
│   │   └── status.sh
│   └── chaos/
│       ├── link-down.sh
│       ├── link-flap.sh
│       ├── rack-partition.sh
│       ├── node-kill.sh
│       ├── latency-inject.sh
│       └── packet-loss.sh
│
├── generated/                   # gitignored
│   ├── frr/{node}/
│   ├── prometheus/
│   ├── grafana/
│   ├── dnsmasq/
│   └── loki/
│
├── validation/
│   ├── chaos-mesh/
│   │   └── experiments/
│   └── workloads/
│       └── nginx-replicated.yml
│
└── docs/
    ├── architecture.md
    ├── reference.md             # THIS FILE
    ├── phases.md
    └── one-pager.pdf
```

---

## 15. TECHNOLOGY STACK

| Layer | Tool | Version | Phase |
|-------|------|---------|-------|
| Hypervisor | KVM/QEMU | system | P0/P3 |
| VM lifecycle | Vagrant (libvirt) | latest | P0/P3 |
| Memory dedup | KSM | kernel | P3 |
| Container runtime | Docker | latest | P0/P3 |
| Network OS | FRRouting | 9.x | P0/P4 |
| Interconnect | Linux bridges + veth | kernel | P3 |
| DHCP/DNS | dnsmasq | latest | P3 |
| NTP | chrony | latest | P3 |
| Config gen | Python 3 + Jinja2 + PyYAML | 3.10+ | P2 |
| Metrics | Prometheus | latest | P5 |
| Dashboards | Grafana | latest | P5 |
| Logs | Loki + rsyslog | latest | P5 |
| Host metrics | node_exporter | latest | P5 |
| Fault injection | tc netem | kernel | P6 |
| Kubernetes | k3s | latest | P7 |
| CNI | Cilium | latest | P7 |
| Chaos | Chaos Mesh (CNCF) | latest | P7 |
| Workload | nginx | latest | P7 |

---

## 16. KEY RFCS (skim, don't study)

| RFC | What | Read |
|-----|------|------|
| RFC 4271 | BGP-4 | Section 8: FSM diagram (6 states) |
| RFC 5880 | BFD | Section 6.8.6: state machine (4 states) |
| RFC 7938 | BGP in the Data Center | Full read (~30 min), justifies this design |
| RFC 7348 | VxLAN | Skim when you reach P7 |
| RFC 7432 | EVPN | Skim when you reach P7 |

---

## 17. KNOWN GOTCHAS (9 ITEMS)

| # | Issue | Phase | Fix |
|---|-------|-------|-----|
| 1 | Leaf same-ASN loop prevention | P4 | `allowas-in` on leaf spine-facing BGP sessions |
| 2 | EVPN next-hop rewrite on spines | P7 | `next-hop-unchanged` on spines for L2VPN EVPN AFI |
| 3 | IP forwarding in containers | P3 | `sysctl net.ipv4.ip_forward=1` per FRR namespace |
| 4 | FRR Prometheus exporter missing | P0 | Verify FRR image build includes HTTP API |
| 5 | Border same-ASN loop prevention | P4 | `allowas-in` on border spine-facing BGP sessions |
| 6 | Server ECMP default routes | P3 | `ip route add default nexthop via X nexthop via Y` multipath syntax |
| 7 | Reverse path filtering drops | P3 | `net.ipv4.conf.all.rp_filter=2` (loose) on all nodes |
| 8 | STP on fabric bridges | P3 | `brctl stp <bridge> off` or `stp_state 0` on all 52 fabric bridges |
| 9 | Deterministic MACs for DHCP | P2 | Generator produces `02:NW:XX:XX:XX:XX` MACs from node index |
| — | Docker default networking | P3 | `--network=none` + manual veth wiring (already designed for) |
| — | BFD false flaps | P4 | Timer dilation (already designed for) |

---

## 18. THE RULE

The fabric is the product. Workloads are validation.
The config generator is the keystone. topology.yml is the source of truth.

Core NetWatch: topology model, FRR routing nodes, L3 Clos underlay,
BGP/BFD/ECMP, EVPN/VxLAN, observability, fault injection, config generation.

Validation addons: k3s, Cilium, Chaos Mesh, nginx.
These prove the fabric works. They are not the fabric.

This separation is load-bearing. Enforce it in the repo, the README,
and the resume. Without it, scope creep kills the project.
