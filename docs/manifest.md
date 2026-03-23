# NetWatch — Build Manifest

> Linear task list from bare metal to a fully operational hyperscale DC emulator.
> Each task depends on the ones above it. Check them off as you go.
>
> **Current state:** P0-P3 complete. P4 BGP converged. P5 observability live.
> Golden image approach — VMs boot fully loaded, provisioning only configures.

---

## PHASE 0 — HOST ENVIRONMENT
> Confirm the host machine can run everything NetWatch needs.

- [x] **0.01** KVM hardware virtualization enabled
      `egrep -c '(vmx|svm)' /proc/cpuinfo` → > 0
      `lsmod | grep kvm` → kvm_intel or kvm_amd loaded

- [x] **0.02** libvirtd running
      `sudo systemctl status libvirtd`
      `virsh list --all` → responds without error

- [x] **0.03** Vagrant + libvirt plugin installed
      `vagrant --version` → 2.4+
      `vagrant plugin list` → vagrant-libvirt present

- [x] **0.04** Docker daemon running (NOT Podman)
      `docker run --rm hello-world`
      `docker run --rm --network=none alpine echo ok`

- [x] **0.05** FRR image pulled
      `docker pull quay.io/frrouting/frr:9.1.0`
      `docker run --rm quay.io/frrouting/frr:9.1.0 vtysh -c "show version"`

- [x] **0.06** Python environment
      `python3 -c "import yaml; import jinja2; print('ok')"`

- [x] **0.07** Bridge utilities
      `which brctl` and `which ip` → both present

- [x] **0.08** KSM enabled on host (dedup across 16 identical server VMs)
      `cat /sys/kernel/mm/ksm/run` → 1
      If 0: `echo 1 | sudo tee /sys/kernel/mm/ksm/run`
      Persist via systemd or rc.local

- [x] **0.09** guestfs-tools installed (needed by `vagrant package` for virt-sysprep)
      `which virt-sysprep` → present
      If missing: `sudo dnf install -y guestfs-tools`

- [x] **0.10** createrepo_c installed (needed by bake script if rebuilding RPM repo)
      `which createrepo_c`
      If missing: `sudo dnf install -y createrepo_c`

**P0 GATE:** All checks pass. Host is ready.

---

## PHASE 1 — SCAFFOLD
> Project structure, source of truth, version control.

- [x] **1.01** Directory tree created
- [x] **1.02** topology.yml finalized (single source of truth — all nodes, links, IPs, ASNs)
- [x] **1.03** Documentation: architecture.md, reference.md, phases.md, manifest.md
- [x] **1.04** .gitignore, LICENSE
- [x] **1.05** Git repo initialized and first commit

**P1 GATE:** `tree` matches reference.md. Git clean.

---

## PHASE 2 — CONFIG GENERATOR
> Python/Jinja2 generator that produces all configs from topology.yml.

- [x] **2.01** generate.py — topology loader, node registry, link registry, MAC generation
- [x] **2.02** frr.conf.j2 — BGP, BFD, EVPN, allowas-in, next-hop-unchanged
- [x] **2.03** daemons.j2 — zebra, bgpd, bfdd, staticd enabled; VTY on 0.0.0.0
- [x] **2.04** vtysh.conf.j2 — hostname, integrated-vtysh-config
- [x] **2.05** prometheus.yml.j2 — 30 scrape targets (12 FRR on :9342, 18 VMs on :9100)
- [x] **2.06** alerts.yml — BGPSessionDown, BGPSessionFlapping, BFDSessionDown, NodeUnreachable, etc.
- [x] **2.07** dnsmasq.conf.j2 — DNS-only (30 A records, no DHCP — libvirt handles DHCP)
- [x] **2.08** loki-config.yml.j2
- [x] **2.09** setup-bridges.sh.j2 — 52 fabric bridges, STP disabled
- [x] **2.10** setup-frr-containers.sh.j2 — 12 containers, veth wiring, mgmt attachment, frr_exporter sidecars
- [x] **2.11** setup-server-links.sh.j2 — hot-plug NICs via virsh, configure IPs + ECMP inside VMs
- [x] **2.12** teardown.sh.j2, status.sh.j2
- [x] **2.13** Validate: `python3 generator/generate.py` → all outputs clean
      Spot-check: leaf-1a ASN=65101, spine-1 has 10 neighbors, border allowas-in present

**P2 GATE:** Generator produces correct configs from topology.yml. 39 files, all verified.

---

## PHASE 3 — GOLDEN IMAGE + CORE LAB
> Build the golden Vagrant box. Boot all 30 nodes. OOB management network live.

### Golden image

- [x] **3.01** Pin all artifact versions in `repo/versions.env`
      k3s v1.31.4+k3s1, node_exporter 1.7.0, frr_exporter 1.10.1,
      promtail 2.9.3, loki 2.9.3, prometheus 2.47.0, grafana 10.0.3

- [x] **3.02** Build golden box: `bash scripts/bake-golden-image.sh`
      Boots temp VM from fedora_43.box, installs everything, packages as netwatch-golden.box.
      **Gotcha — Docker/libvirt forward conflict:** Docker sets nftables FORWARD policy to DROP,
      blocking libvirt NAT. The bake script inserts temporary nft rules:
      ```
      sudo nft insert rule ip filter FORWARD iifname "virbr1" accept
      sudo nft insert rule ip filter FORWARD oifname "virbr1" accept
      ```
      These are removed after packaging. If the bake VM can't reach the internet, this is why.

- [x] **3.03** Verify golden box contents (boot a throwaway VM and check):
      - RPMs: chrony, rsyslog, conntrack-tools, container-selinux, ethtool, ipset,
        socat, iproute-tc, nfs-utils, python3, python3-libselinux, policycoreutils,
        audit, iptables-services, dnsmasq, logrotate, bash-completion, debug tools
      - Binaries: k3s (+kubectl/crictl/ctr symlinks), node_exporter, frr_exporter,
        promtail, loki, prometheus, grafana
      - Systemd units: all present at /etc/systemd/system/, all disabled
      - Sysctls: /etc/sysctl.d/99-netwatch.conf (rp_filter=2)
      - Config dirs: /etc/prometheus, /etc/loki, /etc/promtail, /var/lib/grafana/dashboards

- [x] **3.04** Register golden box
      `vagrant box add --name netwatch-golden netwatch-golden.box`

- [x] **3.05** Remove old boxes and orphaned libvirt volumes
      `vagrant box remove netwatch-fedora43 --force`
      `virsh vol-delete --pool default <old-volume-name>`

### Virtual machines (18)

- [x] **3.06** Boot mgmt VM first (DNS, NTP, observability depend on it)
      `vagrant up mgmt`
      **Gotcha — SELinux:** virt-sysprep mislabels /usr/local/bin binaries as `user_tmp_t`.
      The Vagrantfile runs `restorecon -R /usr/local/bin` in COMMON_BASE to fix this.
      Without it, systemd can't exec loki, promtail, prometheus, etc.

- [x] **3.07** Boot bastion VM (NAT gateway)
      `vagrant up bastion`

- [x] **3.08** Boot all 16 server VMs
      `vagrant up` (boots remaining VMs in parallel)

- [x] **3.09** Verify all 18 VMs running
      `vagrant status` → all 18 "running"

- [x] **3.10** Verify static IPs on all VMs
      Vagrant can't reconfigure the NIC it SSH'd in on (single-NIC VMs with mgmt_attach=false).
      The Vagrantfile adds static IPs as secondary addresses: `ip addr add <ip>/24 dev ens5`.
      Verify: `vagrant ssh srv-1-1 -c "ip -4 addr show ens5"` → shows both DHCP and static IP.

### FRR containers (12)

- [x] **3.11** Create 52 fabric bridges
      `sudo bash scripts/fabric/setup-bridges.sh`
      Verify: all 52 bridges up, STP disabled. Mgmt bridge (virbr2) is libvirt-managed.

- [x] **3.12** Start FRR containers + wire fabric
      `sudo bash scripts/fabric/setup-frr-containers.sh`
      This script: starts 12 Alpine containers (--network=none), creates veth pairs,
      moves interfaces into container namespaces, assigns IPs, connects to mgmt bridge,
      applies sysctls (ip_forward=1, rp_filter=2), starts frr_exporter sidecar on :9342.
      **Note:** frr_exporter is installed from repo/binaries/ tarball, NOT the old HTTP server.

- [x] **3.13** Verify all 12 containers running with BGP converged
      `sudo bash scripts/fabric/status.sh` → 26/26 checks pass

### Server data-plane wiring

- [x] **3.14** Wire server VMs to fabric bridges
      `bash scripts/fabric/setup-server-links.sh` (run as your user, NOT sudo)
      **Gotcha:** The script uses `sudo virsh` for NIC attachment (needs qemu:///system)
      but SSH uses Vagrant keys owned by your user. Running the whole script as root
      breaks SSH key access. The script handles this internally.

- [x] **3.15** Verify server dual-homing
      From srv-1-1: `ip route show` → ECMP routes via both leaf-1a and leaf-1b
      Ping both gateways to confirm both fabric paths are up.

### DNS and management

- [x] **3.16** Verify DNS resolution from mgmt
      `dig @127.0.0.1 spine-1.netwatch.lab` → 192.168.0.20
      dnsmasq is DNS-only (no DHCP). DHCP handled by libvirt on the host.
      **Gotcha — systemd-resolved:** Fedora runs systemd-resolved on port 53.
      provision-mgmt.sh disables it before starting dnsmasq:
      `systemctl disable --now systemd-resolved`

- [x] **3.17** Verify bastion SSH jump
      `ssh -J vagrant@192.168.0.2 vagrant@192.168.0.50 hostname` → srv-1-1

- [x] **3.18** Run full status check
      `sudo bash scripts/fabric/status.sh` → all checks green

**P3 GATE:** All 30 nodes up and pingable on management network.
DNS resolves all hostnames. Bastion SSH works. Servers dual-homed with ECMP.
Status script all green. Zero packages installed at boot time.

---

## PHASE 4 — ROUTING
> Full BGP convergence across the 3-tier Clos fabric.

### BGP verification

- [x] **4.01** FRR configs deployed (setup-frr-containers.sh bind-mounts generated/frr/<node>/)

- [x] **4.02** Verify border BGP: 2 peers each (spine-1, spine-2) Established
      `docker exec border-1 vtysh -c "show bgp summary"`

- [x] **4.03** Verify spine BGP: 10 peers each (2 borders + 8 leafs) Established
      `docker exec spine-1 vtysh -c "show bgp summary"`

- [x] **4.04** Verify leaf BGP: 2 peers each (spine-1, spine-2) Established
      ```
      for leaf in leaf-{1..4}{a,b}; do
        echo "--- $leaf ---"
        docker exec $leaf vtysh -c "show bgp summary"
      done
      ```

- [x] **4.05** Total BGP session count = 20 (all Established)

### BFD verification

- [x] **4.06** Verify BFD on spine-1: 10 peers Up
      `docker exec spine-1 vtysh -c "show bfd peers"`

- [x] **4.07** Verify BFD timers are dilated (10x — 1000ms Tx/Rx)
      `docker exec spine-1 vtysh -c "show bfd peers"` → Tx/Rx = 1000ms
      This prevents false flaps on a laptop where CPU scheduling is unpredictable.

### ECMP verification

- [x] **4.08** Check ECMP paths on leaf-1a to a remote rack
      `docker exec leaf-1a vtysh -c "show ip route 10.0.3.7"`
      → 2 next-hops (via spine-1 and spine-2)

- [x] **4.09** Check ECMP paths on spine-1 to a leaf loopback
      `docker exec spine-1 vtysh -c "show ip route 10.0.3.1"`
      → direct connected (single path — spine to directly-connected leaf)

### allowas-in verification

- [x] **4.10** Leaf-1a can reach leaf-1b (same ASN 65101, same rack)
      `docker exec leaf-1a ping -c3 10.0.3.2` → success

- [x] **4.11** Border-1 can reach border-2 (same ASN 65000)
      `docker exec border-1 ping -c3 10.0.1.2` → success

### End-to-end path verification

- [x] **4.12** Traceroute: leaf-1a → leaf-4a (cross-rack, 2 hops)
      `docker exec leaf-1a traceroute -n 10.0.3.7`
      Path: leaf-1a → spine-1 → leaf-4a

- [x] **4.13** Traceroute: leaf-1a → border-1 (2 hops)
      `docker exec leaf-1a traceroute -n 10.0.1.1`

- [x] **4.14** Ping: srv-1-1 → srv-4-4 (full fabric traversal, 4 hops, 0% loss)
      `vagrant ssh srv-1-1 -c "ping -c3 172.16.6.26"` → 0.625ms avg

- [x] **4.15** Traceroute: srv-1-1 → srv-4-4
      Path: srv-1-1 → leaf-1a (172.16.3.1) → spine-1 (172.16.2.1) → leaf-4a (172.16.2.26) → srv-4-4 (172.16.6.26)

### Route table completeness

- [x] **4.16** Spine-1 has routes to all loopbacks
      `docker exec spine-1 vtysh -c "show ip route" | grep "/32" | wc -l` → 11

- [x] **4.17** Leaf-1a has routes to all remote loopbacks
      `docker exec leaf-1a vtysh -c "show ip route" | grep "10.0." | wc -l` → 12

**P4 GATE:** 20 BGP Established. 20 BFD Up (dilated timers). ECMP working.
allowas-in verified. End-to-end server-to-server ping across fabric.

---

## PHASE 5 — OBSERVABILITY
> Prometheus, Grafana, Loki operational. All 30 nodes scraped and dashboarded.

### Observability stack (all on mgmt VM, pre-installed in golden image)

- [x] **5.01** All services running on mgmt VM
      dnsmasq (:53), chronyd (:123), rsyslog (receiver on :514),
      loki (:3100), prometheus (:9090), promtail, grafana (:3000), node_exporter (:9100)
      Verify: `systemctl is-active dnsmasq chronyd rsyslog loki prometheus promtail grafana-server node_exporter`

- [x] **5.02** Prometheus scraping 30/30 targets
      12 FRR containers on :9342 (frr_exporter) + 18 VMs on :9100 (node_exporter)
      Verify: `curl -s http://localhost:9090/api/v1/targets | python3 -c "..."`

- [x] **5.03** Grafana datasources provisioned (file-based, no API calls)
      Prometheus + Loki datasources at /etc/grafana/provisioning/datasources/netwatch.yaml

- [x] **5.04** Grafana dashboards deployed
      6 dashboards at /var/lib/grafana/dashboards/:
      - fabric-overview.json — node up/down, link health
      - bgp-status.json — session states, route counts
      - node-detail.json — CPU, memory, network, disk per node (variable: instance)
      - interface-counters.json — bytes/packets per interface
      - chaos-events.json — annotated timeline (populated in P6)
      - evpn-vxlan.json — VNI status, VTEP reach (populated in P7)

- [x] **5.05** Access Grafana from host browser via SSH tunnel
      `vagrant ssh mgmt -- -L 3000:localhost:3000 -L 9090:localhost:9090 -L 3100:localhost:3100`
      Open http://localhost:3000 (admin/admin)

### Alert rules

- [x] **5.06** Prometheus alert rules loaded (/etc/prometheus/alerts.yml)
      BGPSessionDown, BGPSessionFlapping, BFDSessionDown, NodeUnreachable,
      RouteTableEmpty, HighMemoryUsage, DiskAlmostFull, NetworkInterfaceErrors, NetworkPacketLoss
      **Gotcha — alerts.yml bug:** `changes()` requires a range vector.
      The original `HighBGPConvergenceTime` expression used `changes(frr_bgp_peer_state)`
      (instant vector) — passes promtool static check but fails at runtime.
      Fixed: replaced with `BGPSessionFlapping` using `changes(frr_bgp_peer_state[10m]) > 3`.

### Logging

- [x] **5.07** Loki receiving logs
      FRR containers: Docker Loki logging driver (if installed) or journal
      VMs: rsyslog forwards to mgmt:514, promtail reads /var/log/remote.log
      Verify: `curl -s 'http://localhost:3100/loki/api/v1/query?query={job="remote-syslog"}'`

### NTP

- [x] **5.08** chrony on mgmt VM is NTP server (stratum 10, allows 192.168.0.0/24)
      All other VMs sync from mgmt via chrony client config.
      Consistent timestamps across all 30 nodes for log correlation.

### Housekeeping

- [x] **5.09** Disable dnf-makecache on all VMs (fails without internet, spams journal)
      `sudo systemctl disable --now dnf-makecache.timer dnf-makecache.service`
      **TODO:** Bake this into the golden image on next rebuild.

- [x] **5.10** Logrotate configured on mgmt for /var/log/remote.log
      `/etc/logrotate.d/netwatch-remote` — daily, 7 days retention, compressed.
      Also added to provision-mgmt.sh for future rebuilds.

**P5 GATE:** 30/30 Prometheus targets up. 6 Grafana dashboards rendering live data.
Loki receiving logs. NTP synchronized. Grafana accessible via SSH tunnel.

---

## PHASE 6 — CHAOS (INFRASTRUCTURE)
> Fault injection scripts with visible protocol response in dashboards.

### Write chaos scripts

- [ ] **6.01** `scripts/chaos/link-down.sh` — bring a fabric link down/up
      Args: node-a node-b [--restore]
      Action: `ip link set <bridge> down` / `up`
      Must resolve bridge name from the node pair (use bridge naming convention br{index:03d}).

- [ ] **6.02** `scripts/chaos/link-flap.sh` — toggle a link repeatedly
      Args: node-a node-b --interval 5 --count 10

- [ ] **6.03** `scripts/chaos/latency-inject.sh` — add netem delay to a link
      Args: node-a node-b --delay 100ms [--jitter 20ms]
      Action: `tc qdisc add dev <veth> root netem delay 100ms 20ms`
      **Requires:** iproute-tc package (baked into golden image)

- [ ] **6.04** `scripts/chaos/packet-loss.sh` — inject packet loss
      Args: node-a node-b --loss 10%
      Action: `tc qdisc add dev <veth> root netem loss 10%`

- [ ] **6.05** `scripts/chaos/rack-partition.sh` — isolate an entire rack
      Args: rack-N [--restore]
      Action: down all bridges connecting rack-N leafs to spines (4 bridges per leaf × 2 leafs)

- [ ] **6.06** `scripts/chaos/node-kill.sh` — stop/start a container
      Args: node-name [--restore]
      Action: `docker stop <node>` / `docker start <node>`

### Validate chaos scenarios

- [ ] **6.07** Test: link-down spine-1 ↔ leaf-1a
      Expected: BFD timeout ~3s → BGP withdrawal → traffic shifts to spine-2
      Verify in Grafana: BGP Status shows session drop, Fabric Overview shows link down

- [ ] **6.08** Test: link-flap spine-1 ↔ leaf-1a (5s interval, 5 cycles)
      Expected: repeated BFD flaps, BGPSessionFlapping alert fires
      Verify in Grafana: Chaos Events timeline shows flap pattern

- [ ] **6.09** Test: latency-inject spine-1 ↔ leaf-2a 200ms
      Expected: increased RTT visible in interface counters
      Verify: `docker exec leaf-2a ping -c5 <spine-1-ip>` shows ~200ms

- [ ] **6.10** Test: packet-loss spine-2 ↔ leaf-3a 30%
      Expected: degraded throughput, NetworkPacketLoss alert fires
      Verify in Grafana: interface error counters rise

- [ ] **6.11** Test: rack-partition rack-1
      Expected: ALL rack-1 leaf BGP sessions drop, rack-1 servers unreachable from other racks
      Other racks unaffected. Recovery on restore.

- [ ] **6.12** Test: node-kill spine-1
      Expected: all 10 spine-1 BGP sessions drop, full reconvergence to spine-2
      All cross-rack traffic survives via spine-2. Recovery on restart.

### Grafana annotations

- [ ] **6.13** Chaos scripts POST annotations to Grafana API on inject/restore
      `curl -X POST http://admin:admin@localhost:3000/api/annotations -H 'Content-Type: application/json' \
        -d '{"text":"link-down spine-1 ↔ leaf-1a","tags":["chaos","link-down"]}'`

**P6 GATE:** Each scenario produces expected protocol response.
All events visible in Grafana with annotations. Fabric self-heals after every fault.

---

## PHASE 7 — VALIDATION
> EVPN/VxLAN overlay + k3s cluster + Chaos Mesh survival test.

### EVPN/VxLAN overlay

- [ ] **7.01** Redeploy FRR configs with EVPN enabled (already in templates)
      `python3 generator/generate.py` → redeploy to containers

- [ ] **7.02** Create VxLAN interfaces on leaf VTEPs

- [ ] **7.03** Verify EVPN control plane
      `docker exec leaf-1a vtysh -c "show bgp l2vpn evpn summary"` → peers Established

- [ ] **7.04** Verify EVPN route exchange (type-2 MAC/IP + type-3 IMET routes)

- [ ] **7.05** Verify VxLAN tunnel endpoints
      `docker exec leaf-1a vtysh -c "show evpn vni"` → VNIs with remote VTEPs

- [ ] **7.06** Verify cross-rack L2 reachability over overlay

### k3s cluster

- [ ] **7.07** Install k3s server on srv-1-1
      k3s binary is pre-installed in the golden image. Just start the service:
      ```
      k3s server --flannel-backend=none --disable-network-policy --disable=traefik &
      ```
      **Note:** k3s is NOT started at boot. Cluster formation is deliberate — server first,
      then agents join with token.

- [ ] **7.08** Get join token: `sudo cat /var/lib/rancher/k3s/server/node-token`

- [ ] **7.09** Join remaining 15 servers as agents
      ```
      k3s agent --server https://<srv-1-1-ip>:6443 --token <token> &
      ```

- [ ] **7.10** Verify: `kubectl get nodes` → 16 nodes, all Ready

### Cilium CNI

- [ ] **7.11** Install Cilium via Helm
      **Requires:** ethtool (baked into golden image — needed by Cilium for NIC offload queries)

- [ ] **7.12** Verify Cilium: all agents healthy, pod-to-pod networking cross-rack

### Chaos Mesh

- [ ] **7.13** Install Chaos Mesh via Helm
      Configure for k3s containerd socket: `/run/k3s/containerd/containerd.sock`

- [ ] **7.14** Verify: controller + daemon pods running

### Validation workload

- [ ] **7.15** Deploy nginx (replicated, anti-affinity across racks)
      **Known issue:** current anti-affinity uses hostname topologyKey — should use rack label
      for real cross-rack distribution. Add rack labels to nodes first:
      `kubectl label node srv-1-1 topology.kubernetes.io/zone=rack-1`

- [ ] **7.16** Verify replicas spread across racks

### The survival test

- [ ] **7.17** Start availability monitor (continuous curl loop against nginx service)

- [ ] **7.18** Apply Chaos Mesh experiments (pod-kill, pod-failure, network-partition, network-delay)

- [ ] **7.19** Wait 10 minutes

- [ ] **7.20** Collect results:
      - Total requests
      - Successful responses
      - Max gap between successes

- [ ] **7.21** Evaluate against success criteria:
      - Availability > 99%?
      - Max single outage < 3 seconds?
      - All events captured in Grafana?

- [ ] **7.22** If FAIL: debug, adjust, re-run

### Capstone workload

- [ ] **7.23** Build custom k3s container image: Refik Anadol-inspired data sculpture
      Real-time particle physics visualization driven by live Prometheus metrics.
      This IS the validation workload AND the art piece.

**P7 GATE:** >99% availability. <3s max outage. Chaos Mesh indifferent.
Data sculpture rendering live fabric metrics.

---

## PHASE 8 — POLISH
> Production-grade documentation and presentation.

- [ ] **8.01** Create SVG architecture diagram for README
- [ ] **8.02** Add Grafana dashboard screenshots to docs/
- [ ] **8.03** Write Quick Start (clone → running fabric in ~10 commands)
- [ ] **8.04** Write Results section (Chaos Mesh survival numbers)
- [ ] **8.05** Clean commit history, tag release
- [ ] **8.06** Make repo public

### Golden image rebuild checklist (for next bake)
> Things to bake in that we fixed post-boot this time around:

- [ ] Disable dnf-makecache.timer and dnf-makecache.service
- [ ] Disable systemd-resolved (conflicts with dnsmasq on mgmt)
- [ ] Run `restorecon -R /usr/local/bin` after installing binaries (before virt-sysprep mislabels them — or add `restorecon` to the bake cleanup phase)
- [ ] Verify SELinux contexts on all /usr/local/bin binaries are `bin_t` not `user_tmp_t`

---

## PROGRESS SUMMARY

| Phase | Description | Status |
|-------|-------------|--------|
| P0 | Host environment | DONE |
| P1 | Scaffold | DONE |
| P2 | Config generator | DONE |
| P3 | Golden image + core lab | DONE (30/30 nodes up) |
| P4 | Routing | DONE (20 BGP, 10 BFD, ECMP, server-to-server verified) |
| P5 | Observability | DONE (30/30 targets, Grafana live) |
| P6 | Chaos | Not started |
| P7 | Validation | Not started |
| P8 | Polish | Not started |

---

## KEY FILES

| File | Purpose |
|------|---------|
| `topology.yml` | Single source of truth (nodes, links, IPs, ASNs, timers) |
| `generator/generate.py` | Jinja2 config generator |
| `repo/versions.env` | Pinned versions for all artifacts |
| `scripts/bake-golden-image.sh` | Builds the golden Vagrant box |
| `scripts/provision-mgmt.sh` | Configures mgmt VM (observability stack) |
| `scripts/fabric/setup-bridges.sh` | Creates 52 fabric bridges |
| `scripts/fabric/setup-frr-containers.sh` | Starts 12 FRR containers, wires fabric |
| `scripts/fabric/setup-server-links.sh` | Wires server VMs to leaf switches |
| `scripts/fabric/status.sh` | Full fabric health check |
| `Vagrantfile` | 18 VMs, golden image, config-only provisioning |

## RESOURCE ALLOCATION

| Component | Count | RAM | CPUs | Notes |
|-----------|-------|-----|------|-------|
| Server VMs | 16 | 768 MB | 1 | k3s compute nodes |
| Bastion VM | 1 | 1024 MB | 1 | Admin box (helm, kubectl), NAT |
| Mgmt VM | 1 | 2048 MB | 2 | Prometheus, Grafana, Loki, dnsmasq, chrony |
| FRR containers | 12 | ~40 MB | — | Alpine, host Docker |
| **Total** | **30** | **~15 GB** | — | **~10 GB effective with KSM** |
