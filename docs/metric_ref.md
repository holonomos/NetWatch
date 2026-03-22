# NetWatch — Metric Reference

> Quick reference for all Prometheus metrics, Grafana dashboards, and panels.
> For learning what each metric means and where it comes from.

---

## Metric Sources

| Source | Port | Job | What it monitors | Runs on |
|--------|------|-----|------------------|---------|
| **frr_exporter** | 9342 | `frr` | BGP sessions, BFD peers, route tables, EVPN state | 12 FRR switch VMs |
| **node_exporter** | 9100 | `node` | CPU, memory, disk, network interfaces | All 30 VMs |

---

## FRR Exporter Metrics

### BGP

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `frr_bgp_peer_state` | Gauge | instance, peer, peer_as, local_as, afi, safi | 1 = Established, 0 = Down. The core health indicator for BGP sessions. |
| `frr_bgp_peer_uptime_seconds` | Gauge | instance, peer, peer_as, local_as, afi, safi | Seconds since session establishment. Resets to 0 on flap — useful for measuring recovery time. |
| `frr_bgp_peer_prefixes_received_count_total` | Gauge | instance, peer, peer_as, local_as, afi, safi | Number of routes received from this peer. Drop = peer withdrew routes. |
| `frr_bgp_peer_prefixes_advertised_count_total` | Gauge | instance, peer, peer_as, local_as, afi, safi | Number of routes advertised to this peer. |
| `frr_bgp_peer_message_received_total` | Counter | instance, peer, peer_as, local_as, afi, safi | Total BGP messages received (keepalives, updates, notifications). Rate = message throughput. |
| `frr_bgp_peer_message_sent_total` | Counter | instance, peer, peer_as, local_as, afi, safi | Total BGP messages sent. |
| `frr_bgp_rib_count_total` | Gauge | instance, afi, safi | Total routes in the RIB (Routing Information Base). Sudden drop = route withdrawal event. |
| `frr_bgp_peers_count_total` | Gauge | instance, afi, safi | Number of configured BGP peers. |

**AFI/SAFI filtering:**
- `afi="ipv4", safi="unicast"` — IPv4 unicast BGP (the main routing table)
- `afi="l2vpn", safi="evpn"` — L2VPN EVPN (the overlay control plane)

### BFD

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `frr_bfd_peer_state` | Gauge | instance, peer, iface, local, vrf | 1 = Up, 0 = Down. BFD detects link failures in ~3s (1000ms × 3 multiplier). |
| `frr_bfd_peer_uptime` | Gauge | instance, peer, iface, local, vrf | Seconds since BFD session came up. |
| `frr_bfd_peer_count` | Gauge | instance | Total BFD peers configured. |

### Routing Table

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `frr_route_total` | Gauge | instance | Total routes in the RIB (all protocols). |
| `frr_route_total_fib` | Gauge | instance | Routes actually installed in the kernel FIB. Delta from RIB = filtered/inactive routes. |

### System

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `frr_status_up` | Gauge | instance | 1 = FRR daemon is running. |
| `frr_collector_up` | Gauge | instance | 1 = frr_exporter can reach FRR's vtysh. |

---

## Node Exporter Metrics (Key Subset)

| Metric | Type | Description |
|--------|------|-------------|
| `node_cpu_seconds_total` | Counter | CPU time by mode (idle, user, system, iowait, etc.). `rate(... {mode!="idle"}[5m])` = CPU utilization. |
| `node_memory_MemTotal_bytes` | Gauge | Total physical RAM. |
| `node_memory_MemAvailable_bytes` | Gauge | Available RAM (free + reclaimable caches). `1 - (Available/Total)` = memory pressure. |
| `node_network_receive_bytes_total` | Counter | Bytes received per interface. `rate(...[1m])` = throughput in bytes/sec. |
| `node_network_transmit_bytes_total` | Counter | Bytes transmitted per interface. |
| `node_network_receive_errs_total` | Counter | Receive errors per interface. Non-zero = hardware issue, driver bug, or CRC errors. |
| `node_network_receive_drop_total` | Counter | Packets dropped on receive. Often caused by rp_filter (reverse path filtering) rejections. |
| `node_disk_read_bytes_total` | Counter | Bytes read from disk. `rate(...[5m])` = read throughput. |
| `node_disk_written_bytes_total` | Counter | Bytes written to disk. |
| `up` | Gauge | 1 = Prometheus can scrape this target. 0 = target unreachable. |

---

## Grafana Dashboards

### 1. Fabric Overview (NOC Screen)
**Purpose:** Single-glance fabric health. Is anything down?

| Panel | Type | What it shows |
|-------|------|---------------|
| BGP Sessions Established | Stat | Count of BGP sessions in Established state. Green ≥ 20. |
| BGP Sessions Down | Stat | Count of down sessions. Green = 0, red ≥ 3. |
| BFD Sessions Up | Stat | Count of BFD peers up. Should track BGP count. |
| Targets Up | Stat | Prometheus scrape targets reachable. Green = 30. |
| BGP Session State | Timeseries | Per-peer session state over time. Drops visible as dips to 0. |
| RIB Route Count | Timeseries | Routes per router over time. Sudden drops = route withdrawal. |
| Prefixes Received | Timeseries | Routes received per peer. Shows route exchange health. |

### 2. BGP Status (Routing)
**Purpose:** Detailed BGP analysis. Per-router, per-peer breakdowns.

| Panel | Type | What it shows |
|-------|------|---------------|
| BGP Peer State | Timeseries | Session state with AS number in legend. Filter by router. |
| Prefixes Received | Timeseries | Inbound route count per peer. |
| Prefixes Advertised | Timeseries | Outbound route count per peer. |
| BGP Messages (rate/min) | Timeseries | Message throughput. Baseline ~2/min (keepalives). Spikes = updates. |
| BGP Peer Uptime | Timeseries | Session age. Sawtooth pattern = repeated flaps. |
| RIB Route Count | Timeseries | Total routes in the routing table. |

### 3. Node Detail (Per-Node)
**Purpose:** Resource monitoring for any single VM.

| Panel | Type | What it shows |
|-------|------|---------------|
| CPU Usage | Graph | CPU utilization by mode (user, system, iowait, softirq, etc.). |
| Memory Usage | Gauge | Percentage of RAM in use. Green < 50%, yellow < 75%, red > 90%. |
| Network Throughput | Graph | Bytes/sec RX and TX per interface. Excludes loopback and virbr. |
| Disk I/O | Graph | Read and write throughput in bytes/sec. |
| Network Errors | Graph | Receive errors and drops per interface. Should be zero in steady state. |

### 4. Interface Counters (Network Ops)
**Purpose:** Network operations view. FRR message rates + VM traffic.

| Panel | Type | What it shows |
|-------|------|---------------|
| BGP Messages Received | Timeseries | Message receive rate per FRR peer. |
| BGP Messages Sent | Timeseries | Message send rate per FRR peer. |
| FRR Route Count (RIB vs FIB) | Timeseries | RIB = known routes, FIB = installed routes. Delta = filtered. |
| BFD Peer Uptime | Timeseries | BFD session age. Resets indicate link failures. |
| VM Network RX | Timeseries | Per-interface receive rate on selected VM. |
| VM Network TX | Timeseries | Per-interface transmit rate on selected VM. |
| VM Network Errors + Drops | Timeseries | Errors and drops on selected VM. |

### 5. Chaos Events (SRE Timeline)
**Purpose:** Watch during chaos testing. Annotations mark inject/restore events.

| Panel | Type | What it shows |
|-------|------|---------------|
| BGP Sessions Established | Timeseries | Total session count. Drops correlate with chaos events. |
| BFD Sessions Up | Timeseries | BFD count. Drops ~3s before BGP (BFD detects first). |
| BGP Session State (per peer) | Timeseries | Individual session states. See which specific peer was affected. |
| BGP Peer Uptime | Timeseries | Uptime resets show recovery. Time from drop to reset = convergence time. |

**Annotations:** Chaos scripts POST to Grafana API with tag `chaos`. Enable the "Chaos Events" annotation layer to see vertical markers.

### 6. EVPN/VxLAN (Overlay)
**Purpose:** EVPN control plane health. VxLAN tunnel status.

| Panel | Type | What it shows |
|-------|------|---------------|
| EVPN Peers Established | Stat | L2VPN EVPN sessions up. All leaf-spine pairs. |
| EVPN Prefixes Received | Stat | Total EVPN routes (type-2 MAC/IP + type-3 IMET). |
| EVPN Prefixes Advertised | Stat | Total EVPN routes advertised by VTEPs. |
| EVPN Peer State | Timeseries | Per-peer L2VPN EVPN session state over time. |
| EVPN Prefixes Received (per peer) | Timeseries | Route count per peer. Shows VTEP discovery. |
| EVPN Messages (rate/min) | Timeseries | L2VPN EVPN message throughput. Spikes = VNI changes. |

---

## Prometheus Alert Rules

| Alert | Expression | Severity | Fires when |
|-------|-----------|----------|------------|
| BGPSessionDown | `frr_bgp_peer_state != 1` for 30s | Critical | Any BGP session drops |
| BGPSessionFlapping | `changes(frr_bgp_peer_state[10m]) > 3` for 1m | Warning | Session state changes > 3 times in 10 minutes |
| BFDSessionDown | `frr_bfd_peer_state != 1` for 10s | Warning | Any BFD peer drops (precedes BGP drop by ~30s) |
| NodeUnreachable | `up{job="frr"} == 0 or up{job="node"} == 0` for 60s | Critical | Can't scrape a target |
| RouteTableEmpty | `frr_bgp_rib_count_total < 10` for 2m | Warning | Route table suspiciously small — possible route loss |
| HighMemoryUsage | `(Total - Available) / Total > 0.9` for 5m | Warning | VM using > 90% RAM |
| DiskAlmostFull | `(Size - Available) / Size > 0.85` for 5m | Warning | Disk > 85% full |
| NetworkInterfaceErrors | `rate(errs_total[5m]) > 0` for 1m | Warning | Non-zero receive errors |
| NetworkPacketLoss | `rate(drop_total[5m]) > 0` for 1m | Warning | Non-zero packet drops |

---

## Label Reference

### Prometheus target labels (from scrape config)

| Label | Source | Values | Description |
|-------|--------|--------|-------------|
| `instance` | prometheus.yml | border-1, spine-1, leaf-1a, srv-1-1, bastion, mgmt | Friendly node name (not IP:port) |
| `job` | prometheus.yml | `frr` or `node` | Which exporter |
| `role` | prometheus.yml | border, spine, leaf, server, bastion, mgmt | Node role in the topology |
| `rack` | prometheus.yml | rack-1 through rack-4 | Rack affinity (leafs and servers only) |

### FRR metric labels (from frr_exporter)

| Label | Description |
|-------|-------------|
| `peer` | BGP/BFD neighbor IP address |
| `peer_as` | Neighbor's AS number |
| `local_as` | This router's AS number |
| `afi` | Address Family Identifier — `ipv4` or `l2vpn` |
| `safi` | Sub-Address Family — `unicast` or `evpn` |
| `vrf` | VRF name (always `default` in NetWatch) |
