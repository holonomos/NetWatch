# NetWatch — Last Rites (Final Manifest)

> Everything from here to completion. No more refactors. No more scope changes.
> The infrastructure is built. What remains: validate it, overlay it, load it, break it, ship it.
>
> **Checkpoint:** P0-P5 DONE. FRR VMs live. Docker eliminated. 30/30 nodes, 31/31 status checks.

---

## What's Done

| Phase | Description | Status |
|-------|-------------|--------|
| P0 | Host environment | DONE |
| P1 | Scaffold + source of truth | DONE |
| P2 | Config generator (Jinja2, 39 files) | DONE |
| P3 | Golden image + 30-node core lab | DONE |
| P4 | BGP routing (20 sessions, BFD, ECMP) | DONE |
| P5 | Observability (Prometheus, Grafana, Loki) | DONE |
| R* | FRR container → VM refactor | DONE |

**Architecture:** 30 VMs (Vagrant/libvirt), 54 Linux bridges, eBGP Clos, north-south via bastion.
Zero Docker. Minimum spec: 8 threads, 16-32GB RAM, Linux + KVM + Vagrant + KSM.

---

## What Remains

### 1. IP Persistence (make fabric survive reboots)

Right now, `make wire` must be re-run after every VM reboot because fabric IPs
are applied via `ip addr add` (ephemeral). This is unacceptable for a tool users
will operate across sessions.

- [ ] **1.01** Write NetworkManager connection profiles for server fabric interfaces
      `configure-vm-fabric.sh` writes `/etc/NetworkManager/system-connections/fabric-*.nmconnection`
      IPs, routes, and ECMP defaults persist across reboot.

- [ ] **1.02** Write NetworkManager connection profiles for FRR VM fabric interfaces
      `configure-frr-fabric.sh` writes NM profiles for each fabric interface.
      Loopback IP on `lo` also persisted.

- [ ] **1.03** Write NetworkManager profile for bastion fabric interfaces
      Bastion's border-facing IPs + fabric ECMP routes persist.

- [ ] **1.04** Write NetworkManager profile for server/FRR mgmt static IPs
      The secondary `ip addr add <static>/24 dev ens5` also needs persistence.

- [ ] **1.05** Verify: reboot a server, confirm fabric IPs and default route survive
      ```bash
      vagrant reload srv-1-1
      vagrant ssh srv-1-1 -c "ip route show default"
      ```

- [ ] **1.06** Verify: reboot an FRR VM, confirm fabric IPs + FRR + BGP come back
      ```bash
      vagrant reload spine-1
      # Wait 30s for BGP convergence
      vagrant ssh spine-1 -c "sudo vtysh -c 'show bgp summary'"
      ```

### 2. Server Loopback IPs

Servers need a stable `/32` identity IP for k3s and any service binding.
Currently servers only have P2P `/30` IPs to their leaf switches.

- [ ] **2.01** Add loopback IPs to topology.yml
      Scheme: `10.0.4.x` for rack-1 servers, `10.0.5.x` for rack-2, etc.
      Add `loopback:` field to each server node definition.

- [ ] **2.02** Update generator to output server loopback IPs
      Pass loopback to `configure-vm-fabric.sh` and FRR static route context.

- [ ] **2.03** Configure loopbacks on servers (lo interface)
      `ip addr add 10.0.4.1/32 dev lo` — add to configure-vm-fabric.sh.

- [ ] **2.04** Add static routes on leaf switches pointing to server loopbacks
      Leaf-1a: `ip route 10.0.4.1/32 172.16.3.2` (server's P2P IP).
      Add `redistribute static` to leaf FRR configs (or use existing `redistribute connected`
      with a connected route trick).

- [ ] **2.05** Verify: ping a server loopback from a different rack
      ```bash
      vagrant ssh srv-4-4 -c "ping -c1 10.0.4.1"
      ```

### 3. EVPN/VxLAN Overlay

The FRR configs already have L2VPN EVPN address-family configured. VxLAN interfaces
and VNIs need to be created on the leaf VTEPs.

- [ ] **3.01** Create VxLAN interfaces on leaf VTEPs
      Each leaf gets a VxLAN interface with a VNI, sourced from its loopback IP.
      ```
      ip link add vxlan100 type vxlan id 100 local <leaf-loopback> dstport 4789 nolearning
      ```

- [ ] **3.02** Create bridge for each VNI on leafs
      ```
      ip link add br-vni100 type bridge
      ip link set vxlan100 master br-vni100
      ```

- [ ] **3.03** Verify EVPN control plane
      ```bash
      vagrant ssh leaf-1a -c "sudo vtysh -c 'show bgp l2vpn evpn summary'"
      ```
      Peers should be Established with type-3 IMET routes exchanged.

- [ ] **3.04** Verify EVPN route exchange
      ```bash
      vagrant ssh leaf-1a -c "sudo vtysh -c 'show bgp l2vpn evpn route'"
      ```
      Type-2 (MAC/IP) and type-3 (IMET) routes present.

- [ ] **3.05** Verify VxLAN tunnel endpoints
      ```bash
      vagrant ssh leaf-1a -c "sudo vtysh -c 'show evpn vni'"
      ```

- [ ] **3.06** Verify cross-rack L2 reachability over overlay
      Attach server interfaces to VNI bridge, verify L2 ping across racks.

### 4. Chaos Validation (P6 gate)

Scripts are implemented. Need to run each scenario and verify protocol response.

- [ ] **4.01** Test: link-down spine-1 ↔ leaf-1a
      ```bash
      bash scripts/chaos/link-down.sh spine-1 leaf-1a
      ```
      Expected: BFD timeout ~3s → BGP withdrawal → traffic shifts to spine-2.
      Check Grafana: Chaos Events dashboard shows annotation + session drop.
      Restore: `bash scripts/chaos/link-down.sh spine-1 leaf-1a --restore`

- [ ] **4.02** Test: link-flap spine-1 ↔ leaf-1a (5 cycles, 5s interval)
      ```bash
      bash scripts/chaos/link-flap.sh spine-1 leaf-1a --interval 5 --count 5
      ```
      Expected: BGPSessionFlapping alert fires.

- [ ] **4.03** Test: latency-inject spine-1 ↔ leaf-2a 200ms
      ```bash
      bash scripts/chaos/latency-inject.sh spine-1 leaf-2a --delay 200ms
      ```
      Verify: ping RTT from leaf-2a to spine-1 shows ~200ms.
      Restore: `--restore`

- [ ] **4.04** Test: packet-loss spine-2 ↔ leaf-3a 30%
      ```bash
      bash scripts/chaos/packet-loss.sh spine-2 leaf-3a --loss 30%
      ```
      Verify: ~30% loss on ping. NetworkPacketLoss alert fires.
      Restore: `--restore`

- [ ] **4.05** Test: rack-partition rack-1
      ```bash
      bash scripts/chaos/rack-partition.sh rack-1
      ```
      Expected: rack-1 leafs lose all BGP sessions. Other racks unaffected.
      Restore: `--restore`

- [ ] **4.06** Test: node-kill spine-1
      ```bash
      bash scripts/chaos/node-kill.sh spine-1
      ```
      Expected: all 10 spine-1 sessions drop. Traffic reconverges via spine-2.
      Restore: `--restore` (VM boots, IPs re-applied, FRR restarts, BGP re-establishes).

- [ ] **4.07** Verify Grafana annotations visible for all chaos events
      Check Chaos Events dashboard — each inject/restore should have a vertical marker.

### 5. k3s Cluster

k3s binary is baked into the golden image. Not started, not configured. Servers
use loopback IPs for cluster communication (depends on section 2).

- [ ] **5.01** Start k3s server on srv-1-1
      ```bash
      vagrant ssh srv-1-1 -c "sudo k3s server \
        --bind-address <loopback-ip> \
        --flannel-backend=none \
        --disable-network-policy \
        --disable=traefik &"
      ```

- [ ] **5.02** Get join token
      ```bash
      vagrant ssh srv-1-1 -c "sudo cat /var/lib/rancher/k3s/server/node-token"
      ```

- [ ] **5.03** Join remaining 15 servers as agents
      ```bash
      vagrant ssh srv-X-Y -c "sudo k3s agent \
        --server https://<srv-1-1-loopback>:6443 \
        --token <token> &"
      ```

- [ ] **5.04** Verify: `kubectl get nodes` → 16 nodes Ready

- [ ] **5.05** Label nodes with rack topology
      ```bash
      kubectl label node srv-1-1 topology.kubernetes.io/zone=rack-1
      # ... for all 16 nodes
      ```

### 6. Cilium CNI

- [ ] **6.01** Install Helm on srv-1-1 (or use bastion as control node)

- [ ] **6.02** Install Cilium via Helm
      ```bash
      helm install cilium cilium/cilium --namespace kube-system \
        --set tunnel=vxlan \
        --set ipam.mode=kubernetes
      ```

- [ ] **6.03** Verify Cilium: all agents healthy
      ```bash
      kubectl -n kube-system get pods -l k8s-app=cilium
      ```

- [ ] **6.04** Verify pod-to-pod networking cross-rack
      Deploy two test pods on different racks, ping between them.

### 7. Chaos Mesh (k8s-level chaos)

- [ ] **7.01** Install Chaos Mesh via Helm
      ```bash
      helm install chaos-mesh chaos-mesh/chaos-mesh \
        --namespace chaos-mesh --create-namespace \
        --set chaosDaemon.runtime=containerd \
        --set chaosDaemon.socketPath=/run/k3s/containerd/containerd.sock
      ```

- [ ] **7.02** Verify: controller + daemon pods running

### 8. Validation Workload + Survival Test

- [ ] **8.01** Deploy nginx (replicated, anti-affinity across racks using rack label)
      ```yaml
      topologyKey: topology.kubernetes.io/zone
      ```

- [ ] **8.02** Verify replicas spread across racks

- [ ] **8.03** Start availability monitor (continuous curl loop)

- [ ] **8.04** Apply Chaos Mesh experiments (pod-kill, network-partition, etc.)

- [ ] **8.05** Wait 10 minutes

- [ ] **8.06** Collect results:
      - Availability > 99%?
      - Max single outage < 3 seconds?
      - All events captured in Grafana?

- [ ] **8.07** If FAIL: debug, adjust, re-run

### 9. Capstone: Data Sculpture

- [ ] **9.01** Build k3s container image for Refik Anadol-inspired data sculpture
      Real-time particle physics visualization driven by live Prometheus metrics.

- [ ] **9.02** Deploy on the cluster, verify it renders

### 10. Cleanup + Ship

- [ ] **10.01** Delete obsolete files
      - `scripts/repo/build-repo.sh`, `scripts/repo/serve-repo.sh`
      - `scripts/provision-extras.sh`
      - `repo/fedora/` directory
      - `generator/templates/scripts/setup-frr-containers.sh.j2` (if still exists)

- [ ] **10.02** Fix EVPN next-hop-unchanged on border-facing spine sessions (known issue #8)
      Only apply `next-hop-unchanged` to leaf-facing sessions in frr.conf.j2.

- [ ] **10.03** Create SVG architecture diagram for README

- [ ] **10.04** Add Grafana dashboard screenshots to docs/

- [ ] **10.05** Write Quick Start section (clone → running fabric in ~10 commands)

- [ ] **10.06** Write Results section (chaos survival numbers)

- [ ] **10.07** Clean commit history, tag v1.0 release

- [ ] **10.08** Make repo public

---

## Dependencies

```
1. IP Persistence ──────────────────────────────┐
2. Server Loopbacks ─────────────────────────────┤
3. EVPN/VxLAN ───────────────────────────────────┤
                                                 ├── 5. k3s ── 6. Cilium ── 7. Chaos Mesh ── 8. Survival Test
4. Chaos Validation (can run in parallel) ───────┘
                                                                                                     │
                                                                                              9. Data Sculpture
                                                                                                     │
                                                                                              10. Cleanup + Ship
```

Sections 1-3 are sequential (each builds on the previous).
Section 4 (chaos validation) can run anytime the fabric is up.
Sections 5-8 are sequential (k3s → Cilium → Chaos Mesh → survival test).
Section 9 is the capstone — last feature.
Section 10 is the final polish.

---

## Minimum Spec (Final)

```
CPU:   8 threads (hard floor)
RAM:   16 GB (functional), 32 GB (comfortable)
Disk:  10 GB free
Host:  Linux with KVM/QEMU, Vagrant + vagrant-libvirt, KSM enabled
No Docker. No privileged containers. No kernel module requirements.
```

---

## Boot Sequence (Final)

```bash
# 1. Register golden image (one-time)
vagrant box add --name netwatch-golden netwatch-golden.box

# 2. Generate configs (if templates changed)
python3 generator/generate.py

# 3. Boot all 30 VMs
vagrant up mgmt
vagrant up border-1 border-2 spine-1 spine-2 leaf-1a leaf-1b leaf-2a leaf-2b leaf-3a leaf-3b leaf-4a leaf-4b
vagrant up bastion
vagrant up

# 4. Wire fabric + servers
make up

# 5. Verify
make status

# 6. Access Grafana
make dashboard
```
