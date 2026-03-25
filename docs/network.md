# NetWatch — Network Architecture

> Complete reference for the NetWatch networking stack.
> Covers the physical topology, addressing, routing, overlay, and traffic flows.

---

## Topology

```
                        ┌─────────────┐
                        │   bastion    │  North-south gateway
                        │ 192.168.0.2 │  NAT masquerade to internet
                        └──┬───────┬──┘
                           │       │
                     br000 │       │ br001
                           │       │
                    ┌──────┴──┐ ┌──┴──────┐
                    │border-1 │ │border-2 │  AS 65000
                    │10.0.1.1 │ │10.0.1.2 │  Static default → bastion
                    └──┬───┬──┘ └──┬───┬──┘
                       │   │       │   │
              br002-05 │   │       │   │
                       │   │       │   │
                 ┌─────┴─┐ │     ┌─┴─────┐
                 │spine-1│ │     │spine-2│  AS 65001
                 │10.0.2.1│     │10.0.2.2│  10 BGP peers each
                 └─┬─┬─┬─┘     └─┬─┬─┬─┘
                   │ │ │ ...      │ │ │
              br006-021          br014-021
                   │ │ │          │ │ │
        ┌──────────┘ │ └──────┐   │ │ │
   ┌────┴──┐ ┌──────┴──┐ ┌───┴───┴─┴─┴───┐
   │leaf-1a│ │leaf-1b  │ │  ...8 leafs   │  AS 65101-65104
   │10.0.3.1│ │10.0.3.2│ │  EVPN VTEPs   │  2 per rack
   └──┬─┬──┘ └──┬─┬──┘  └───────────────┘
      │ │       │ │
   br022-029  br023-029
      │ │       │ │
   ┌──┴─┴──────┴─┴──┐
   │  4 servers/rack │  16 total, k3s agents
   │  dual-homed     │  ECMP via both leafs
   │  10.0.4-7.x/32  │  loopback identity
   └─────────────────┘
```

**30 VMs total:** 2 borders + 2 spines + 8 leafs + 1 bastion + 1 mgmt + 16 servers.
**54 Linux bridges** on the host, one per point-to-point link. STP disabled.
**Management bridge** (virbr1/virbr2) managed by libvirt, separate from fabric.

---

## Address Space

| Range | Purpose | Scope |
|-------|---------|-------|
| `10.0.1.0/24` | Border loopbacks | 10.0.1.1-2 |
| `10.0.2.0/24` | Spine loopbacks | 10.0.2.1-2 |
| `10.0.3.0/24` | Leaf loopbacks (VTEP source) | 10.0.3.1-8 |
| `10.0.4.0/24` | Rack-1 server loopbacks | 10.0.4.1-4 |
| `10.0.5.0/24` | Rack-2 server loopbacks | 10.0.5.1-4 |
| `10.0.6.0/24` | Rack-3 server loopbacks | 10.0.6.1-4 |
| `10.0.7.0/24` | Rack-4 server loopbacks | 10.0.7.1-4 |
| `10.42.0.0/16` | k3s pod CIDR | Cilium-managed |
| `10.43.0.0/16` | k3s service CIDR | ClusterIP range |
| `10.100.0.0/24` | MetalLB external IP pool | LoadBalancer services |
| `172.16.0.0/24` | Border-bastion P2P links | 2 × /30 |
| `172.16.1.0/24` | Border-spine P2P links | 4 × /30 |
| `172.16.2.0/24` | Spine-leaf P2P links | 16 × /30 |
| `172.16.3-6.0/24` | Leaf-server P2P links | 32 × /30 (per rack) |
| `192.168.0.0/24` | OOB management network | All 30 VMs + host |
| `192.168.121.0/24` | Vagrant NAT (bastion only) | Internet access |

---

## ASN Model

| Node(s) | ASN | Type |
|---------|-----|------|
| border-1, border-2 | 65000 | eBGP |
| spine-1, spine-2 | 65001 | eBGP |
| leaf-1a, leaf-1b | 65101 | eBGP |
| leaf-2a, leaf-2b | 65102 | eBGP |
| leaf-3a, leaf-3b | 65103 | eBGP |
| leaf-4a, leaf-4b | 65104 | eBGP |
| MetalLB speakers | 65200 | eBGP (dynamic peers on leafs) |

eBGP everywhere. No iBGP. `allowas-in` on borders and leafs for same-ASN reachability.

---

## BGP Sessions (20 total)

| From | To | Count |
|------|----|-------|
| border-1 | spine-1, spine-2 | 2 |
| border-2 | spine-1, spine-2 | 2 |
| spine-1 | 8 leafs | 8 |
| spine-2 | 8 leafs | 8 |
| **Total** | | **20** |

Each session has BFD enabled with 10x dilated timers (1000ms Tx/Rx, 3x multiplier = 3s detection).

---

## BFD (Bidirectional Forwarding Detection)

Fast failure detection on all 20 BGP sessions.

| Parameter | Value | Why |
|-----------|-------|-----|
| Tx interval | 1000ms | 10x dilation (real DC: 100ms) |
| Rx interval | 1000ms | Matches Tx |
| Detect multiplier | 3 | 3 missed = dead (3000ms detection) |

**Why dilated:** VM CPU scheduling on a laptop is unpredictable. At 100ms, BFD would false-flap from scheduler jitter. At 1000ms, the 96ms worst-case CFS jitter is 3.2% of the detection window — no false flaps.

---

## Route Redistribution

| Node role | Redistributes | Into BGP |
|-----------|---------------|----------|
| All FRR nodes | `connected` (filtered) | Fabric P2P /30 subnets + loopbacks |
| Borders | `static` | Default route 0.0.0.0/0 via bastion |
| Leafs | `static` | Server loopback /32 routes |

**CONNECTED-FILTER route-map:** Denies `192.168.0.0/24` (management network) from leaking into BGP. Permits everything else. Applied on all FRR nodes.

---

## Traffic Flows

### East-West (server to server, cross-rack)

```
srv-1-1 → leaf-1a (or leaf-1b, ECMP) → spine-1 (or spine-2, ECMP) → leaf-4a → srv-4-4
```

4 hops. <1ms latency. Longest-prefix-match: /30 and /32 routes always win over 0.0.0.0/0. Internal traffic never touches borders.

### North-South (server to internet)

```
srv-1-1 → leaf-1a → spine-1 → border-1 → bastion → internet
```

5 hops + NAT. Bastion masquerades source IPs from `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/24`.

### Host to k3s API (kubectl)

```
host (192.168.0.1) → mgmt bridge → mgmt (192.168.0.3:6443)
```

Direct L2. No routing, no bastion, no fabric. Chaos-proof — fabric failures don't affect kubectl.

### Host to k3s services (MetalLB)

```
host (192.168.0.1) → mgmt bridge → bastion (192.168.0.2) → fabric → server pod
```

Requires host route: `10.0.0.0/8 via 192.168.0.2`. MetalLB announces service /32 into BGP from server loopbacks. The fabric routes traffic to the correct node.

### k3s agent to API server

```
srv-X-Y (192.168.0.XX on ens5) → mgmt bridge → mgmt (192.168.0.3:6443)
```

Via OOB management network, not fabric. Agents register with `--node-ip` set to their fabric loopback (10.0.4-7.x) for Cilium tunnel endpoints, but control plane communication uses the mgmt NIC.

---

## EVPN/VxLAN Overlay

| Parameter | Value |
|-----------|-------|
| VNI | 10000 |
| VxLAN interface | `vxlan10000` on each leaf |
| Bridge | `br-vni10000` on each leaf |
| VTEP source | Leaf loopback IP (10.0.3.x) |
| Destination port | 4789 (standard) |
| Learning | Disabled (EVPN handles MAC learning via BGP) |

8 leaf VTEPs. Each discovers 6 remote VTEPs via BGP type-3 IMET routes. Spines pass EVPN routes with `next-hop-unchanged` so VTEPs communicate directly.

---

## MetalLB BGP

| Parameter | Value |
|-----------|-------|
| Speaker ASN | 65200 |
| Peer ASN | 65101-65104 (leaf ASN per rack) |
| Peer addresses | Leaf loopback IPs (10.0.3.1-8) |
| IP pool | 10.100.0.0/24 |
| Advertisement | /32 per assigned service IP |

FRR leafs accept MetalLB connections via `bgp listen range` with the METALLB peer-group. Each leaf accepts connections from its rack's server loopback range (e.g., leaf-1a accepts from 10.0.4.0/24).

---

## Dual-Homing

Every server has 2 fabric NICs — one to leaf-a, one to leaf-b of its rack. Both carry equal-cost paths.

| Server | Leaf-A NIC | Leaf-B NIC | ECMP |
|--------|-----------|-----------|------|
| srv-1-1 | 172.16.3.2/30 via leaf-1a | 172.16.3.6/30 via leaf-1b | Both active |
| srv-1-2 | 172.16.3.10/30 | 172.16.3.14/30 | Both active |
| ... | ... | ... | ... |

Default route ECMP through both leafs. If one leaf dies, BFD detects in ~3s, BGP withdraws routes, traffic shifts to the surviving leaf. The server's kernel removes the dead nexthop when the interface goes down.

---

## Network Isolation

| Network | Bridge | Accessible from host | Purpose |
|---------|--------|---------------------|---------|
| Management (OOB) | virbr1 | Yes (192.168.0.1) | SSH, DNS, NTP, Prometheus, Grafana, k3s API |
| Vagrant NAT | virbr2 | Yes (bastion only) | Internet access for bastion |
| Fabric (54 bridges) | br000-br053 | No | BGP routing, EVPN, data plane |

The host touches the management network only. The fabric is internal — the host cannot directly ping fabric IPs without a route through bastion.

---

## Host Requirements (Docker Conflict)

Docker sets `nftables FORWARD policy drop` on the host, blocking inter-VM traffic that traverses two different libvirt bridges. NetWatch applies accept rules at startup:

```bash
# Applied by 'make up' (hostfix target)
for br in $(ip link show type bridge | grep -oP 'virbr\d+' | sort -u); do
    sudo nft insert rule ip filter FORWARD iifname "$br" accept
    sudo nft insert rule ip filter FORWARD oifname "$br" accept
done
```

This is idempotent and runs before every fabric bring-up.

---

## MAC Address Scheme

Format: `02:4E:57:TT:PP:II`

| Byte | Meaning |
|------|---------|
| `02` | Locally administered, unicast |
| `4E:57` | "NW" (NetWatch) in ASCII |
| `TT` | Tier: 01=border, 02=spine, 03=leaf, 04=server(unused), 05=bastion, 06=mgmt |
| `PP` | Peer index (which link on this node) |
| `II` | Node index within tier |

Deterministic — generated from topology.yml. No collisions.

---

## Interface Naming

| VM type | Fabric interfaces | How named |
|---------|-------------------|-----------|
| FRR switches | `eth-spine-1`, `eth-leaf-1a`, `eth-bastion`, etc. | udev rules (MAC → name) |
| Servers | `ens6`, `ens7` (kernel-assigned) | Found by MAC at configure time |
| Bastion | `ens7`, `ens8` (kernel-assigned) | Found by MAC at configure time |

FRR configs reference interface names like `eth-spine-1`. The udev rules at `/etc/udev/rules.d/70-netwatch-fabric.rules` rename interfaces by MAC address before FRR starts.

---

## IP Persistence

Fabric IPs are configured via `ip addr add` at runtime by `make up` scripts. To survive reboots, NetworkManager keyfiles are written:

| File | Purpose |
|------|---------|
| `/etc/NetworkManager/system-connections/fabric-<ifname>.nmconnection` | Per-interface IP persistence |
| `/etc/NetworkManager/system-connections/fabric-lo.nmconnection` | Loopback IP persistence |
| `/etc/NetworkManager/dispatcher.d/99-netwatch-ecmp` | ECMP route re-application on interface up |

The dispatcher script uses MAC-based interface lookup to survive interface renumbering across reboots.
