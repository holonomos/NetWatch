# NetWatch

A 30-node hyperscale data-center lab emulator built around a 12-node 3-tier L3 Clos routing fabric.

NetWatch reproduces production-like control-plane behavior on a laptop using real BGP, real BFD, real EVPN/VxLAN, full observability, and chaos engineering — validated by running CNCF Chaos Mesh unmodified against the infrastructure. The fabric is the product; workloads exist only to validate infrastructure behavior.

## Architecture

```
                    ┌───────────┐   ┌───────────┐
                    │ border-1  │   │ border-2  │       AS 65000
                    │ (AS 65000)│   │ (AS 65000)│
                    └─────┬─┬───┘   └───┬─┬─────┘
                          │ │           │ │
                     ┌────┘ └─────┬─────┘ └────┐
                     │            │             │
                ┌────┴────┐ ┌────┴────┐
                │ spine-1 │ │ spine-2 │             AS 65001
                │(AS65001)│ │(AS65001)│
                └┬┬┬┬┬┬┬┬┘ └┬┬┬┬┬┬┬┬┘
                 ││││││││    ││││││││
        ┌────────┘│││││└───────┘│││││└────────┐
        │    ┌────┘││└────┐ ┌──┘││└────┐      │
        │    │  ┌──┘└──┐  │ │ ┌─┘└──┐  │     │
      ┌─┴─┬─┴┐┌┴─┬──┐┌┴─┬┴┐┌┴┬──┐┌─┴┬─┴─┐
      │l1a│l1b││l2a│l2b││l3a│l3b││l4a│l4b│   AS 65101-65104
      └─┬─┴─┬─┘└─┬─┴──┘└─┬─┴─┘└──┴─┬─┘└─┬─┴─┘
        │   │     │        │          │     │
      ┌─┴───┴─┐┌──┴───┐┌──┴───┐┌────┴──┐
      │ Rack 1 ││Rack 2││Rack 3││ Rack 4│
      │4 servers││4 srv ││4 srv ││4 srv  │    16 Fedora VMs
      └────────┘└──────┘└──────┘└───────┘
```

**12 FRR routing containers** (Alpine, ~40 MB each) form the Clos fabric.
**16 Fedora KVM VMs** act as compute servers, dual-homed to leaf pairs.
**1 bastion VM** provides SSH and NAT gateway access.
**1 management VM** runs Prometheus, Grafana, Loki, dnsmasq, and chrony.

All interconnects are raw Linux bridges with manual veth wiring — no Docker networking, no NAT in the fabric path.

## Key Design Decisions

- **eBGP everywhere, no iBGP.** 6-ASN model with ASN-per-rack failure domains.
- **10x control-plane time dilation.** Prevents false BFD flaps from CPU jitter. State machines identical to production; only wall-clock duration changes.
- **Hybrid containers + VMs.** FRR containers for routing (480 MB total), KVM VMs for compute (KSM deduplication). Full validation load ~7.1 GB.
- **Config generator as keystone.** `topology.yml` → Python/Jinja2 → all configs. No hand-edited snowflakes.
- **Core fabric vs. validation addons.** The fabric, observability, and chaos scripts are the product. k3s, Cilium, and Chaos Mesh are the test harness.

## Prerequisites

- Linux host (Fedora recommended) with 16+ GB RAM
- KVM/QEMU with hardware virtualization enabled
- Vagrant with libvirt provider
- Docker
- Python 3.10+ with PyYAML and Jinja2
- FRRouting 9.x container image

## Project Structure

```
netwatch/
├── topology.yml                 # Single source of truth
├── Vagrantfile                  # VM lifecycle management
├── README.md
├── LICENSE
├── .gitignore
│
├── generator/                   # Config generation engine (P2)
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
├── scripts/                     # Operational scripts
│   ├── fabric/                  # Fabric lifecycle (P3)
│   │   ├── setup-bridges.sh
│   │   ├── setup-frr-containers.sh
│   │   ├── teardown.sh
│   │   └── status.sh
│   └── chaos/                   # Fault injection (P6)
│       ├── link-down.sh
│       ├── link-flap.sh
│       ├── rack-partition.sh
│       ├── node-kill.sh
│       ├── latency-inject.sh
│       └── packet-loss.sh
│
├── generated/                   # Generator output (gitignored)
│   ├── frr/{node}/
│   ├── prometheus/
│   ├── grafana/
│   ├── dnsmasq/
│   └── loki/
│
├── validation/                  # Validation layer (P7)
│   ├── chaos-mesh/
│   │   └── experiments/
│   └── workloads/
│       └── nginx-replicated.yml
│
└── docs/
    ├── architecture.md
    ├── phases.md
    └── one-pager.pdf
```

## Build Phases

| Phase | Gate | Description |
|-------|------|-------------|
| **P0** | KVM, Vagrant, Docker, FRR verified on host | Environment setup |
| **P1** | Repo initialized, topology.yml finalized | Scaffold |
| **P2** | Generator produces valid FRR + Prometheus configs | Config generator |
| **P3** | All 30 nodes reachable on OOB management network | Core lab |
| **P4** | 20 BGP sessions Established, ECMP paths verified | Routing |
| **P5** | Prometheus scraping all nodes, Grafana dashboards live | Observability |
| **P6** | Failures visible in dashboards, fabric self-heals | Chaos |
| **P7** | Chaos Mesh on k3s, nginx >99% availability under chaos | Validation |

## Success Criterion

Chaos Mesh runs unmodified against the k3s validation layer. Replicated nginx maintains >99% availability over a 10-minute chaos run with <3 second maximum outage. If the chaos tooling cannot distinguish the emulated fabric from production infrastructure, the project succeeds.

## Technology Stack

| Layer | Technology |
|-------|-----------|
| Virtualization | KVM/QEMU + Vagrant (libvirt) + KSM |
| Containers | Docker (`--network=none`) + manual veth/bridge |
| Network OS | FRRouting 9.x (bgpd, bfdd, zebra, staticd) |
| Protocols | eBGP, BFD, ECMP, EVPN/VxLAN (MP-BGP L2VPN) |
| Observability | Prometheus + Grafana + Loki |
| Chaos | tc netem + Chaos Mesh |
| Validation | k3s + Cilium |
| Config gen | Python 3 + Jinja2 + YAML |

## License

MIT
