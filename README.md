
# NetWatch

> A data-center network fabric on one Linux box: an [RFC 7938](https://www.rfc-editor.org/rfc/rfc7938) eBGP-Clos underlay with an EVPN/VXLAN overlay, across 31 KVM VMs. No containers, all generated from a single `topology.yml`.

<img width="2877" height="879" alt="noc" src="https://github.com/user-attachments/assets/164341d9-42d0-48e4-bf9b-120189a96aa2" />

## What it is

A single-host emulation of a 3-tier Clos fabric (border / spine / leaf) running FRR. The underlay is eBGP-everywhere with BFD and ECMP; the overlay is EVPN/VXLAN with a symmetric-IRB L3VNI and a distributed anycast gateway carrying real tenant L2 and L3 traffic. Prometheus, Grafana and Loki watch it; a `tc`/`virsh` toolkit breaks it.

It runs on real VMs and kernel networking (veth, Linux bridges, VRF, VXLAN) instead of containers, so the control plane, data plane and failure modes are the real thing.

## Topology

```mermaid
flowchart TD
    NET([Internet]) -->|NAT / MASQUERADE| BAS["bastion<br/>192.168.0.2<br/>jump host · N-S exit · NO BGP"]

    BAS -->|static| B1["border-1<br/>AS 65000"]
    BAS -->|static| B2["border-2<br/>AS 65000"]

    B1 & B2 ==>|4 eBGP links| S1["spine-1<br/>AS 65001<br/>EVPN RR"]
    B1 & B2 ==>|4 eBGP links| S2["spine-2<br/>AS 65001<br/>EVPN RR"]

    S1 & S2 ==>|16 eBGP links| L1["rack-1 leaf VTEPs<br/>leaf-1a / leaf-1b<br/>AS 65101"]
    S1 & S2 ==> L2["rack-2 leaf VTEPs<br/>leaf-2a / leaf-2b<br/>AS 65102"]
    S1 & S2 ==> L3["rack-3 leaf VTEPs<br/>leaf-3a / leaf-3b<br/>AS 65103"]
    S1 & S2 ==> L4["rack-4 leaf VTEPs<br/>leaf-4a / leaf-4b<br/>AS 65104"]

    L1 -->|dual-homed, static| SRV1["srv-1-1 .. srv-1-4"]
    L2 -->|32 leaf↔server links| SRV2["srv-2-1 .. srv-2-4"]
    L3 --> SRV3["srv-3-1 .. srv-3-4"]
    L4 --> SRV4["srv-4-1 .. srv-4-4"]

    classDef edge fill:#fde68a,stroke:#b45309,color:#000;
    classDef tier fill:#dbeafe,stroke:#1e40af,color:#000;
    classDef srv fill:#dcfce7,stroke:#15803d,color:#000;
    class NET,BAS edge;
    class B1,B2,S1,S2,L1,L2,L3,L4 tier;
    class SRV1,SRV2,SRV3,SRV4 srv;
```

Each server is dual-homed to both leaves in its rack (ECMP, static routes, no BGP). 54 point-to-point links total: 2 border-bastion, 4 border-spine, 16 spine-leaf, 32 leaf-server, each backed by a host Linux bridge.

## The stack

- **Underlay (RFC 7938):** eBGP on every node, 6 ASNs (one per rack), BFD, ECMP across both spines. Control-plane timers are 10x dilated for laptop-class CPUs.
- **Overlay (RFC 7432 / 8365):** MP-BGP EVPN with the spines as route reflectors, two L2VNIs and a symmetric-IRB L3VNI, distributed anycast gateway. Same-subnet traffic is bridged over VXLAN; inter-subnet is routed through the anycast gateway over the L3VNI.
- **Observability:** Prometheus + Grafana + Loki on a dedicated `obs` node, with node/FRR exporters and a per-leaf EVPN textfile collector, feeding four NOC dashboards.
- **Chaos:** `tc`/netem and `virsh` scripts for link down/flap, latency, loss, rack partition, and node kill.
- **Generation:** `topology.yml` -> `generate.py` (Jinja2) renders all per-node configs, the observability config, the dashboards, and five host wiring scripts.

## What works

Verified on a clean bring-up:

- **Underlay:** cross-rack loopback reachability at 0% loss, ECMP balanced across both spines.
- **Overlay L2:** same-subnet hosts on different racks reach each other over VXLAN; remote MACs are learned via EVPN Type-2.
- **Overlay L3:** inter-subnet and inter-tenant traffic is routed through the distributed anycast gateway (symmetric IRB).
- **Health:** `make status` passes 31/31 and the four dashboards populate live.

## Dashboards

**Fabric & Routing** - per-peer BGP/BFD state, prefix counts, message rate, session flaps.

<img width="2877" height="1503" alt="controlPlane" src="https://github.com/user-attachments/assets/04b37660-879d-44bd-a8fa-5a8ba1bca657" />

**EVPN / VXLAN** - VNI inventory, per-VNI local vs remote MACs and ARP, remote VTEPs.

<img width="2877" height="1393" alt="vnis" src="https://github.com/user-attachments/assets/2d702dde-183d-4b36-bfcb-6c80e38347b9" />


**Hosts & Interfaces** - per-node CPU/memory/disk and per-interface throughput, errors and drops.

<img width="2877" height="1185" alt="interfaces" src="https://github.com/user-attachments/assets/9ae514dc-2798-4639-a496-15f9b1adc91c" />


## Quickstart

Requires Linux with KVM/libvirt, Vagrant (with the `vagrant-libvirt` plugin), and about 19 GB of RAM.

```bash
make generate     # render configs + wiring scripts from topology.yml
make vms          # boot the 31 VMs
make up           # wire the fabric, bring up BGP + EVPN
make status       # 31-check health report
make dashboard    # tunnel to Grafana / Prometheus / Loki on the obs node
```

Break something and watch it reconverge:

```bash
make chaos-link-down ARGS="spine-1 leaf-1a"
make chaos-kill      ARGS="spine-1"
```

`make help` lists every target.

## How it's built

`topology.yml` is the single source of truth: every node, ASN, IP, link, VNI and timer. `generate.py` renders the per-node FRR configs, the Prometheus/Loki/dnsmasq configs, the Grafana dashboards, and the host wiring scripts. VMs boot from one pre-baked golden image (build once, configure many); fabric NICs are hot-plugged onto host bridges after boot and matched by MAC. Two planes stay separate: the routed fabric (`10.0.0.0/16` loopbacks, `172.16.0.0/16` point-to-point links) and an isolated out-of-band management network (`192.168.0.0/24`) reached only through the bastion.

## Scope

A single-host learning lab, not a production system. It models one fabric domain so you can run real routing, a real EVPN overlay, and real failures on a laptop or a spare server.
