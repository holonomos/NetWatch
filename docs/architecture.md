# NetWatch — Complete Project Context

This document contains the full mental model for NetWatch. Every decision, every layer, every tradeoff, every constraint, from motivation to validation. Read this and you can reconstruct the entire project from first principles.

---

## Why This Exists

Mir is a recent engineering graduate working retail at Target, targeting entry-level infrastructure roles — data center technician, SRE, DevOps, network engineering — at companies like AWS, Meta, and Oracle. The problem is straightforward: these roles want people who understand production infrastructure, but you can't get production infrastructure experience without already having the job. Certifications prove you can pass a test. Lab exercises prove you can follow instructions. Neither proves you can reason about a real system.

NetWatch exists to close that gap. It's a portfolio project that demonstrates operational understanding of data center infrastructure by building a working emulation of one — not a toy diagram, not a GNS3 screenshot, but a running system with real routing protocols, real failure detection, real observability, and real chaos engineering. The validation criterion is concrete: if industry-standard chaos tooling can't tell NetWatch apart from production infrastructure, the project succeeds.

It also serves as a permanent test bench. Once built, any new technology (a different CNI, a new monitoring tool, a new routing feature) can be tested against a realistic fabric without provisioning cloud resources or buying hardware.

---

## What It Is, Precisely

A 30-node hyperscale data-center lab emulator built around a 12-node 3-tier L3 Clos routing fabric. It runs on a single laptop. The fabric is the product; workloads exist only to validate infrastructure behavior.

30 nodes break down as:
- 12 FRR routing containers (2 borders, 2 spines, 8 leafs)
- 16 Fedora KVM virtual machines (compute servers, 4 racks × 4 servers)
- 1 bastion VM (SSH jump host and NAT gateway)
- 1 management VM (Prometheus, Grafana, Loki, dnsmasq, chrony)

It is not a cloud platform, not a Kubernetes distribution, not a network simulator, and not a training lab with a GUI. It is an infrastructure emulator with a generator-first design where everything is derived from a single YAML topology file.

---

## The Architecture

### Topology

A 3-stage folded Clos, which in physical terms is a leaf-spine fabric. Every leaf connects to every spine. Every server dual-homes to both leafs in its rack.

```
borders (2)  →  spines (2)  →  leafs (8)  →  servers (16)
  AS 65000       AS 65001     AS 65101-65104    (4 racks × 4 servers)
```

Plus bastion and mgmt nodes on the management plane.

The topology is a single pod. Real hyperscalers run hundreds of pods connected by superspines (5-stage Clos), but a single pod exercises all the same protocols, failure modes, and recovery behaviors. The difference is scale, not kind. A 5-stage fabric runs identical BGP, BFD, ECMP, and EVPN — it just has more sessions and an extra routing tier. Adding a superspine layer would triple node count without adding behavioral richness that the validation framework can detect.

This topology was validated against published architectures from Google (Jupiter), Meta (F16/FBOSS), and what's publicly known about AWS. All three hyperscalers built on Clos foundations, with Google only evolving beyond pure Clos after a decade of running it at building scale. At NetWatch's 30-node scale, a 3-stage Clos is architecturally correct, not a simplification.

### Hybrid Approach: Containers for Routers, VMs for Servers

This is the breakthrough decision that makes the project viable on laptop hardware.

FRR routing containers are Alpine-based, approximately 40 MB each. They run the BGP, BFD, and EVPN control plane daemons and need nothing else — no kernel, no init system, no package manager in steady state. They share the host kernel but have isolated network namespaces, which is all that FRR requires. 12 containers × 40 MB = 480 MB for the entire routing fabric.

Server VMs are Fedora Cloud images running on KVM/QEMU. They need real kernels because k3s and Cilium require kernel-level networking features (eBPF, veth, network namespaces inside the VM). KSM (Kernel Same-page Merging) on the host deduplicates identical memory pages across VMs. At idle, when all 16 VMs are running the same Fedora image, KSM achieves approximately 72% deduplication, reducing effective per-VM memory from around 512 MB to approximately 36 MB each. Under load (k3s + Cilium + workloads), memory pages diverge and dedup drops to around 25%, bringing effective per-VM memory to approximately 340 MB.

The alternative was running all 30 nodes as VMs, which would have required roughly 12 GB just for the routing nodes at 1 GB each. The hybrid approach gets the full routing fabric into 480 MB. That's the difference between fitting on a 16 GB laptop and requiring 32 GB minimum.

### Interconnect: Raw Linux Bridges

Every point-to-point link in the fabric is a dedicated Linux bridge with exactly two veth endpoints. One endpoint lives in one container or VM's network namespace, the other in the peer's namespace. Docker networking is completely bypassed — containers are started with `--network=none` and all networking is wired manually with `ip link` and `brctl` commands.

This matters because Docker's default networking adds NAT, iptables rules, and proxy processes that would interfere with raw L2/L3 frame exchange. The fabric needs containers and VMs to exchange native Ethernet frames and IP packets exactly as physical switches and servers would. Manual veth/bridge wiring achieves this with zero overhead and zero abstraction leakage.

Total bridges: 52 fabric bridges (one per P2P link) + 1 management bridge = 53.

The physical layer (DAC cables, fiber optics, 400G transceivers) is entirely abstracted away. Linux bridges carry the same L2/L3 frames that physical media would carry. BGP, BFD, and EVPN operate identically regardless of whether the underlying transport is a copper cable or a veth pair. No emulator reproduces the physical layer, and no protocol behavior depends on it.

### Addressing

Three non-overlapping address families, each with a distinct purpose:

**10.0.0.0/16 — Loopbacks.** Every routing node gets a /32 loopback address. These are advertised into BGP and serve as router-IDs, SSH targets, and Prometheus scrape targets. They are the stable identities of each node — a loopback is always reachable if any path to the node exists, unlike an interface address that goes away when a specific link fails.

**172.16.0.0/16 — Fabric point-to-point links.** Every link between two routing nodes gets a /30 subnet (4 addresses: network, endpoint A, endpoint B, broadcast). These are connected routes only — they appear in the local routing table but are not explicitly advertised into BGP. Pools are organized by tier pair: 172.16.1.0/24 for border-spine, 172.16.2.0/24 for spine-leaf, 172.16.3.0/24 through 172.16.6.0/24 for leaf-server by rack. This encoding makes addresses self-documenting.

**192.168.0.0/24 — Out-of-band management.** Completely isolated from the routed fabric. All 30 nodes connect to a single management bridge (br-mgmt). dnsmasq on the mgmt VM serves DHCP reservations (MAC-to-IP bindings generated from topology.yml) and DNS (hostname.netwatch.lab → management IP). This is real DHCP and real DNS, operational on the management plane. The fabric addresses are static, applied by the config generator, which is how real data centers handle fabric addressing — ZTP might use DHCP for initial bootstrap, but fabric interface addresses are pushed by automation.

### ASN Model

6 ASNs total. eBGP everywhere, no iBGP.

- AS 65000: both border routers (shared ASN)
- AS 65001: both spine switches (shared ASN)
- AS 65101: rack 1 leaf pair
- AS 65102: rack 2 leaf pair
- AS 65103: rack 3 leaf pair
- AS 65104: rack 4 leaf pair

ASN-per-rack means each rack is an independent failure domain from BGP's perspective. If both leafs in a rack fail, only that ASN's routes withdraw. This is the model Meta runs and RFC 7938 recommends for data center fabrics.

eBGP everywhere means every session is between different autonomous systems. No iBGP means no route reflectors, no next-hop-self, no local preference complexity. eBGP is simpler to configure, simpler to debug, and is the modern DC standard. The tradeoff is that iBGP concepts (route reflectors, communities for policy) are not exercised. For the target roles, eBGP-everywhere is the more relevant pattern.

### Protocol Stack

**BGP (Border Gateway Protocol).** The routing protocol. Every pair of directly connected routing nodes peers via eBGP. Each router advertises its loopback and, for leafs, the server-facing connected subnets. ECMP (Equal-Cost Multi-Path) is enabled with max-paths 8, meaning traffic between any two endpoints uses all available equal-cost paths simultaneously. With 2 spines, most cross-rack traffic has 2 ECMP paths.

Total: 20 BGP sessions. 4 border-spine + 16 spine-leaf.

**BFD (Bidirectional Forwarding Detection).** A lightweight protocol that runs alongside BGP to detect link failures faster than BGP's own keepalive mechanism. BFD sends periodic control packets and declares a failure if several consecutive packets are missed. It then signals BGP to immediately withdraw routes over the failed link, rather than waiting for the BGP hold timer to expire.

Timers are 10× dilated (see below). Lab values: 1000ms Tx/Rx, detect-multiplier 3, so failure detection takes 3 seconds. Production equivalent: 100ms Tx/Rx, 300ms detection.

**EVPN/VxLAN.** The overlay network. EVPN (Ethernet VPN) is a BGP address family (L2VPN) that distributes MAC and IP reachability information across the fabric. VxLAN (Virtual Extensible LAN) is the data-plane encapsulation that tunnels Layer 2 frames over the Layer 3 underlay. Each leaf switch acts as a VTEP (VxLAN Tunnel Endpoint). VNI (VxLAN Network Identifier) provides per-tenant segmentation.

This layer is implemented late (after the underlay is proven) because it has the highest blast radius for mistakes — errors in VTEP configuration, VNI assignment, or MP-BGP address family negotiation propagate across the entire fabric.

### Time Dilation

All control-plane timers are multiplied by 10. BFD: 1000ms instead of 100ms. BGP keepalive: 30s instead of 3s. BGP hold: 90s instead of 9s.

The reason: KVM VMs and Docker containers share host CPU cores. Under load, the host scheduler may not grant a container CPU time for several hundred milliseconds. If BFD is running at production speed (100ms intervals), a scheduling delay of 300ms looks identical to a link failure. BFD would declare the peer dead, BGP would withdraw routes, traffic would reroute — all because of a scheduling hiccup, not an actual failure. This makes chaos testing unreliable because you can't distinguish injected faults from false positives.

10× dilation solves this. A 300ms scheduling delay against a 1000ms BFD interval is just mild jitter, not a missed detection window. The state machines are identical — BFD still transitions through the same states (AdminDown → Down → Init → Up), BGP still negotiates capabilities and exchanges UPDATE messages the same way. Only wall-clock duration changes.

Observability accounts for this with dual Grafana dashboards. The Lab View shows actual measured timers. The Production View divides all control-plane durations by 10 and multiplies all control-plane rates by 10, showing what the same events would look like at production speed. Data-plane metrics (throughput, packet counters) are untouched — dilation only applies to control-plane timers.

### Observability Stack

All running on the mgmt VM (192.168.0.3).

**Prometheus (port 9090).** Pull-based metrics collection. Scrapes targets every 15 seconds. For the 18 VMs, it scrapes node_exporter on port 9100 (standard host metrics — CPU, memory, disk, network interfaces). For the 12 FRR containers, it scrapes FRR's native Prometheus exporter on port 9101 (BGP session states, route counts, BFD session status, EVPN route types). This distinction matters because node_exporter inside a container that shares the host kernel would report host-level metrics, not container-specific metrics. FRR's built-in exporter reports the routing daemon metrics that the dashboards actually need.

**Grafana (port 3000).** Visualization. Six dashboards: Fabric Overview (node and link health), BGP Status (session states, route counts, peer uptime), Node Detail (per-node CPU/memory/network), Interface Counters (bytes/packets per interface), Chaos Events (annotated timeline of injected faults), and EVPN/VxLAN (overlay route distribution). Each dashboard has Lab View and Production View variants.

**Loki (port 3100).** Log aggregation. All 30 nodes forward syslog via rsyslog to Loki. Grafana queries Loki via LogQL. This captures FRR daemon logs (BGP state changes, BFD events, route advertisements), system logs, and any application logs from the validation layer.

**dnsmasq (port 53, DHCP on 67/68).** Serves DHCP reservations and DNS for the management network. Configuration generated from topology.yml.

**chrony (port 123).** NTP server for the lab. Consistent time across all nodes matters for correlating events in logs and dashboards.

### Chaos Engineering

Two layers, matching the core-vs-validation separation.

**Infrastructure chaos (P6, core).** Direct fault injection on the fabric using `tc netem` and link manipulation. Scripts target bridges and veth pairs. Scenarios: link-down (disable a veth pair), link-flap (toggle on/off at an interval), latency injection (add delay via tc netem), packet loss (percentage-based drop), packet corruption, rack partition (isolate all bridges for a rack), node kill (stop an FRR container). Each fault triggers a real protocol response — BFD timeout, BGP withdrawal, ECMP reconvergence — visible in Grafana.

**Workload chaos (P7, validation addon).** Chaos Mesh running inside k3s, installed via Helm. Chaos Mesh is a CNCF incubating project that defines chaos experiments as Kubernetes CRDs. Scenarios: pod kill, pod failure, network partition between services, network delay, node drain. Chaos Mesh targets the Kubernetes layer and can't tell it's running on an emulated fabric.

The original plan was Netflix Chaos Monkey, but Chaos Monkey requires Spinnaker (a massive deployment orchestration platform) and a MySQL database. Deploying Spinnaker on a laptop alongside a 30-node fabric would be absurd. Chaos Mesh does strictly more — Chaos Monkey only kills instances; Chaos Mesh adds network chaos, DNS chaos, stress testing, and more — with zero external dependencies beyond a running Kubernetes cluster.

### Success Criterion

Replicated nginx (3+ replicas, anti-affinity across racks) running on k3s with Cilium as the CNI. Chaos Mesh runs a 10-minute chaos experiment including pod kills, network partitions, and node failures. nginx must maintain >99% availability with <3 seconds maximum single outage. If it passes, the emulated infrastructure is behaviorally indistinguishable from production to the chaos tooling.

---

## The Config Generator

The keystone of the entire project. A Python script that reads topology.yml and produces every configuration file in the system using Jinja2 templates.

Input: `topology.yml` — one file, every node, every link, every address, every ASN, every timer.

Output directory `generated/` containing:
- `frr/{node}/frr.conf` — BGP neighbors, ASN, BFD timers, interface addresses, route redistribution
- `frr/{node}/daemons` — which FRR daemons to enable
- `frr/{node}/vtysh.conf` — hostname
- `prometheus/prometheus.yml` — scrape targets with correct ports
- `dnsmasq/dnsmasq.conf` — DHCP reservations and DNS entries
- `loki/loki-config.yml` — Loki configuration

The generator is probably 800–1500 lines of Python. It's straightforward scripting — read YAML, iterate over nodes and links, render templates, write files. The value isn't in the code complexity; it's in the correctness of what it produces and the fact that a single source of truth eliminates configuration drift.

The principle: change topology.yml, run the generator, get a different fabric. Never hand-edit a generated config.

---

## Resource Budget

Calibrated for a 16 GB laptop. Development happens on the HP OmniBook Ultra (Core Ultra 9 288V, 32 GB RAM, Fedora). Portability validation on the HP Envy x360 (i7-1165G7, 16 GB RAM, Fedora).

| Component | Count | Per-Unit | Total |
|---|---|---|---|
| FRR containers | 12 | 40 MB | 480 MB |
| Server VMs (idle, KSM on) | 16 | ~36 MB eff. | 580 MB |
| Server VMs (k3s+Cilium, KSM) | 16 | ~340 MB eff. | 5,400 MB |
| Bastion VM | 1 | 100 MB | 100 MB |
| Management VM | 1 | 900 MB | 900 MB |
| QEMU overhead | 18 VMs | 15 MB | 270 MB |
| **Fabric only** | | | **~2.3 GB** |
| **Full validation** | | | **~7.1 GB** |

On the 32 GB machine: ~22 GB headroom under full load. On the 16 GB machine: ~6 GB headroom, still comfortable.

---

## Build Phases

Eight phases with hard gates. Serial execution — you don't move forward until the gate passes.

**P0 — Environment.** Install and verify KVM, Vagrant (libvirt), Docker, FRR image, Python, KSM.

**P1 — Scaffold.** git init, topology.yml, directory structure, .gitignore, README.

**P2 — Config Generator.** Python/Jinja2 engine. Gate: all generated configs are syntactically valid with correct values.

**P3 — Core Lab.** Bring up all 30 nodes. Vagrantfile for 18 VMs, scripts for 12 containers and 52 bridges. Gate: all nodes pingable on management network, bastion SSH works, DNS resolves.

**P4 — Routing.** Deploy FRR configs, start daemons, verify BGP convergence. Gate: 20 BGP sessions Established, 20 BFD sessions Up, ECMP paths verified, end-to-end traceroute shows correct paths.

**P5 — Observability.** Prometheus, Grafana, Loki operational. Gate: all 30 targets scraped, dashboards loaded, logs flowing, dual-view timing works.

**P6 — Chaos (Infrastructure).** Fault injection scripts, Grafana annotations. Gate: spine kill causes BFD timeout in 3s, BGP reconverges, traffic shifts, recovery visible in dashboards.

**P7 — Validation.** EVPN/VxLAN overlay, k3s, Cilium, Chaos Mesh, nginx survival test. Gate: >99% availability, <3s max outage over 10-minute chaos run.

Estimated total: 35–70 hours depending on debugging time. A professional team of 5–6 would parallelize and finish in 2–3 weeks. Solo, it's 4–8 weeks part-time or 2–3 weeks focused.

---

## What It Can Do When Done

- Bring up a 30-node fabric with a single command sequence
- Run real BGP, BFD, ECMP, and EVPN/VxLAN with production-identical state machines
- Show control-plane events in real-time on Grafana dashboards with production-equivalent timing
- Inject infrastructure faults and watch the fabric self-heal
- Run unmodified CNCF Chaos Mesh and maintain workload availability under active chaos
- Regenerate the entire fabric from a modified topology.yml
- Serve as a permanent lab for testing new infrastructure tools and concepts

## What It Cannot Do

- Reproduce data-plane performance (no 400G line rate, no hardware ECMP hashing, no queue depth)
- Reproduce hardware-specific failure modes (no TCAM overflow, no optics degradation, no thermal throttle)
- Scale to thousands of nodes (single-pod, 30-node fixed topology)
- Demonstrate multi-tenancy at scale (one or two VNIs for proof-of-concept, not hundreds)
- Run as a frictionless out-of-the-box tool for arbitrary users (it's a technical project, not a product)

## Where It Is Production-Close

- **Control plane:** FRRouting runs the same BGP/BFD/EVPN protocol implementations as production routers
- **Observability:** Prometheus, Grafana, Loki are production-grade tools used by real SRE teams
- **Chaos engineering:** Chaos Mesh is a CNCF project used in production Kubernetes environments
- **Addressing model:** DHCP/DNS on management, static generator-driven on fabric, matches real DC patterns
- **Failure domains:** ASN-per-rack, dual-homing, ECMP redundancy are real hyperscaler patterns

## Where It Is Not Production-Close

- **Provisioning:** Vagrant and shell scripts, not Ansible/Terraform/Salt at enterprise scale (Ansible to be added post-build)
- **Physical layer:** Linux bridges, not ASICs, optics, DAC cables, or real switch hardware
- **Lifecycle management:** No firmware updates, no CMDB, no zero-touch provisioning pipeline
- **Scale:** 30 nodes, not tens of thousands

---

## Tradeoffs Made

**Fixed topology over dynamic topology engine.** A system that auto-computes node counts from spine radix would be software-engineering-cool but doesn't add BGP sessions, chaos scenarios, or infrastructure learning. Deferred to V2.

**eBGP everywhere over iBGP with route reflectors.** Simpler, modern, RFC 7938 recommended. Tradeoff: no iBGP concepts exercised. Right call for target roles.

**10× time dilation over real-time timers.** Eliminates false BFD flaps from CPU scheduling jitter. Makes chaos testing reliable. Tradeoff: slower wall-clock reconvergence. Compensated by dual Grafana views.

**Containers for routers over VMs for everything.** Saves ~11.5 GB RAM. Tradeoff: two provisioning paths, FRR-specific metrics exporter instead of node_exporter. Enables laptop-scale execution.

**Manual bridge/veth wiring over Docker networking.** Zero NAT, zero proxy overhead, raw L2/L3 frames. Tradeoff: more complex provisioning scripts, more debugging surface. Deeper Linux networking learning.

**Prometheus pull over push-based metrics.** Simpler for fixed topology. Scrape failure is itself a signal during chaos. Tradeoff: no "last known value" when a node is down.

**Chaos Mesh over Netflix Chaos Monkey.** No Spinnaker dependency, no MySQL, strictly more fault types, CNCF backed. Tradeoff: loses the Netflix brand name. Gains a tool that actually works in this context.

**Shell scripts for initial provisioning over Ansible from the start.** Transparent, no learning curve overhead, can be refactored later. Ansible to be added post-completion for resume value and operational polish.

---

## Options Excluded

**SONiC / Cumulus Linux** — Full network OS, too resource-heavy per node, additional realism doesn't add to validated behaviors.

**GNS3 / EVE-NG** — GUI-based training labs, incompatible with generator-first config-as-code design.

**Terraform** — Designed for cloud resource provisioning, the libvirt provider is immature. Vagrant handles local VM lifecycle better.

**Service mesh (Istio/Linkerd)** — Tests application-layer concerns outside NetWatch's scope. Cilium is sufficient for network validation.

**Multi-pod / 5-stage Clos** — Would triple node count. Same protocols, same failure modes, just more of them. Deferred to future extension.

**Dynamic DHCP for fabric addressing** — DHCP on /30 point-to-point links isn't done in production. Fabric addresses are static, pushed by automation (the generator). Management plane uses real DHCP.

---

## Toolchain Summary

| Tool | Purpose | Phase |
|---|---|---|
| topology.yml | Single source of truth | P1 |
| Python 3 + Jinja2 + PyYAML | Config generator | P2 |
| Vagrant (libvirt provider) | VM lifecycle | P3 |
| KVM/QEMU | Hypervisor | P3 |
| Docker | FRR container runtime | P3 |
| Linux bridges + veth | Fabric interconnect | P3 |
| FRRouting 9.x | BGP, BFD, EVPN, ECMP | P4 |
| KSM | VM memory deduplication | P3 |
| dnsmasq | DHCP + DNS (management plane) | P3 |
| chrony | NTP | P3 |
| Prometheus | Metrics collection | P5 |
| Grafana | Dashboards + visualization | P5 |
| Loki | Log aggregation | P5 |
| node_exporter | Host metrics (VMs) | P5 |
| FRR Prometheus exporter | Routing metrics (containers) | P5 |
| rsyslog | Log forwarding | P5 |
| tc netem | Infrastructure fault injection | P6 |
| k3s | Lightweight Kubernetes | P7 |
| Cilium | CNI with eBPF networking | P7 |
| Chaos Mesh | Kubernetes chaos engineering | P7 |
| nginx | Validation workload | P7 |
| Ansible | Configuration management (post-build) | Post |

---

## Key Files

| File | Purpose |
|---|---|
| `topology.yml` | Canonical topology definition — every node, link, address, ASN |
| `generator/generate.py` | Config generator — reads topology, renders templates |
| `generator/templates/` | Jinja2 templates for FRR, Prometheus, dnsmasq, Loki |
| `Vagrantfile` | Defines 18 VMs with libvirt provider |
| `scripts/fabric/` | Bridge creation, container setup, veth wiring, teardown |
| `scripts/chaos/` | Fault injection scripts (link-down, rack-partition, etc.) |
| `generated/` | Generator output directory (gitignored) |
| `validation/` | Chaos Mesh experiments and workload manifests |
| `docs/` | Architecture doc, phase gates, one-pager PDF |
| `README.md` | Project overview — first thing anyone reads |

---

## The Rule

The fabric is the product. Workloads are validation. The config generator is the keystone. topology.yml is the source of truth. If you change the topology, you regenerate. If you hand-edit a generated config, you've broken the contract.

Core NetWatch: topology model, FRR routing nodes, L3 Clos underlay, BGP/BFD/ECMP, EVPN/VxLAN, observability, fault injection, reproducible config generation.

Validation addons: k3s, Cilium, Chaos Mesh, nginx workloads. These prove the fabric works. They are not the fabric.

This separation must be enforced in the repo structure, in the README, and in how the project is described on a resume. Without it, the project drifts into "mini cloud platform" territory and dies of scope creep.
