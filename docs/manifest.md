# NetWatch — Build Manifest

> Linear task list. Every task from current state to completion.
> No task starts until the one above it passes.
> Check them off as you go.

**Status:** P1 and P2 complete. Generator verified. Repo scaffold standing.

---

## PHASE 0 — ENVIRONMENT VERIFICATION
> Confirm the host machine can run everything NetWatch needs.

- [ ] **0.01** Verify KVM hardware virtualization enabled
      `egrep -c '(vmx|svm)' /proc/cpuinfo` → must be > 0
      `lsmod | grep kvm` → kvm_intel or kvm_amd loaded

- [ ] **0.02** Verify libvirtd running
      `sudo systemctl status libvirtd`
      `virsh list --all` → responds without error

- [ ] **0.03** Install Vagrant + libvirt plugin
      `vagrant --version` → 2.4+
      `vagrant plugin install vagrant-libvirt`
      `vagrant plugin list` → vagrant-libvirt present

- [ ] **0.04** Verify Docker daemon
      `docker run --rm hello-world`
      `docker run --rm --network=none alpine echo ok`

- [ ] **0.05** Pull and verify FRR image
      `docker pull quay.io/frrouting/frr:9.1.0`
      `docker run --rm quay.io/frrouting/frr:9.1.0 vtysh -c "show version"`

- [ ] **0.06** Verify FRR Prometheus exporter availability
      ```
      docker run --rm -d --name frr-test quay.io/frrouting/frr:9.1.0
      docker exec frr-test wget -qO- http://localhost:9101/metrics
      docker stop frr-test
      ```
      If no exporter: try `quay.io/frrouting/frr:10.0.0` or plan custom image.

- [ ] **0.07** Verify Python environment
      `python3 --version` → 3.10+
      `python3 -c "import yaml; import jinja2; print('ok')"`
      If missing: `pip install pyyaml jinja2`

- [ ] **0.08** Verify bridge utilities
      `which brctl` → present (or `sudo dnf install bridge-utils`)
      `which ip` → present (iproute2)

- [ ] **0.09** Enable KSM on host
      `cat /sys/kernel/mm/ksm/run` → should be 1
      If 0: `echo 1 | sudo tee /sys/kernel/mm/ksm/run`
      Persist: add to `/etc/rc.local` or systemd unit

- [ ] **0.10** Verify Fedora Cloud box available for Vagrant
      `vagrant box add fedora/40-cloud-base --provider=libvirt`

**P0 GATE:** All 10 checks pass. FRR exporter confirmed working.

---

## PHASE 1 — REPO INITIALIZATION
> Get the project under version control on your machine.

- [x] **1.01** ~~Directory tree created~~ (done — in tarball)
- [x] **1.02** ~~topology.yml finalized~~ (done — 639 lines, all nodes/links/IPs)
- [x] **1.03** ~~README.md written~~ (done)
- [x] **1.04** ~~LICENSE, .gitignore created~~ (done)
- [x] **1.05** ~~Docs: architecture.md, reference.md, phases.md~~ (done)

- [ ] **1.06** Unpack tarball on OmniBook
      ```
      tar xzf netwatch-repo.tar.gz
      cd netwatch
      ```

- [ ] **1.07** Run generator to verify
      `python3 generator/generate.py` → all outputs clean

- [ ] **1.08** Initialize git repo
      ```
      git init
      git add -A
      git commit -m "P1: scaffold — topology, docs, directory tree"
      ```

- [ ] **1.09** Create GitHub repo (private for now)
      ```
      gh repo create netwatch --private --source=. --push
      ```

**P1 GATE:** `tree` matches reference.md. Generator runs clean. Repo on GitHub.

---

## PHASE 2 — CONFIG GENERATOR
> Already complete. Verify on target machine and commit.

- [x] **2.01** ~~generate.py — topology loader~~ (done)
- [x] **2.02** ~~generate.py — node registry builder~~ (done)
- [x] **2.03** ~~generate.py — link registry builder~~ (done)
- [x] **2.04** ~~generate.py — MAC address generation (02:4E:57:xx:xx:xx)~~ (done)
- [x] **2.05** ~~frr.conf.j2 — BGP, BFD, EVPN, allowas-in, next-hop-unchanged~~ (done)
- [x] **2.06** ~~daemons.j2 — daemon selection~~ (done)
- [x] **2.07** ~~vtysh.conf.j2 — hostname~~ (done)
- [x] **2.08** ~~prometheus.yml.j2 — 30 scrape targets~~ (done)
- [x] **2.09** ~~dnsmasq.conf.j2 — 30 DHCP/DNS entries~~ (done)
- [x] **2.10** ~~loki-config.yml.j2~~ (done)
- [x] **2.11** ~~setup-bridges.sh.j2 — 53 bridges, STP off~~ (done)
- [x] **2.12** ~~setup-frr-containers.sh.j2 — 12 containers, veth wiring, sysctls~~ (done)
- [x] **2.13** ~~teardown.sh.j2~~ (done)
- [x] **2.14** ~~status.sh.j2~~ (done)

- [ ] **2.15** Validate all 12 FRR configs on target machine
      Spot-check: leaf-1a ASN, spine-1 neighbor count, border allowas-in

- [ ] **2.16** Commit
      `git add generator/ && git commit -m "P2: config generator"`

**P2 GATE:** Generator produces 39 correct files from topology.yml.

---


done
done
done


## PHASE 3 — CORE LAB
> All 30 nodes running and reachable on the management network.

### Management network

- [ ] **3.01** Create management bridge on host
      `sudo scripts/fabric/setup-bridges.sh`
      Verify: `ip link show br-mgmt` → up

### Virtual machines (18)

- [ ] **3.02** Bring up bastion VM
      `vagrant up bastion`
      Verify: `vagrant ssh bastion -c "hostname"` → bastion

- [ ] **3.03** Bring up mgmt VM
      `vagrant up mgmt`
      Verify: `vagrant ssh mgmt -c "hostname"` → mgmt

- [ ] **3.04** Bring up rack-1 servers (4 VMs)
      `vagrant up srv-1-1 srv-1-2 srv-1-3 srv-1-4`

- [ ] **3.05** Bring up rack-2 servers (4 VMs)
      `vagrant up srv-2-1 srv-2-2 srv-2-3 srv-2-4`

- [ ] **3.06** Bring up rack-3 servers (4 VMs)
      `vagrant up srv-3-1 srv-3-2 srv-3-3 srv-3-4`

- [ ] **3.07** Bring up rack-4 servers (4 VMs)
      `vagrant up srv-4-1 srv-4-2 srv-4-3 srv-4-4`

- [ ] **3.08** Verify all 18 VMs running
      `vagrant status` → all 18 "running"

### FRR containers (12)

- [ ] **3.09** Run FRR container setup
      `sudo scripts/fabric/setup-frr-containers.sh`

- [ ] **3.10** Verify all 12 containers running
      `docker ps --filter label=netwatch=frr --format "{{.Names}}"` → 12 names

### Fabric wiring verification

- [ ] **3.11** Verify all 52 fabric bridges exist and are up
      `ip link show type bridge | grep -c "br[0-9]"` → 52

- [ ] **3.12** Verify STP disabled on all fabric bridges
      `for i in $(seq 0 51); do cat /sys/class/net/br$(printf '%03d' $i)/bridge/stp_state; done`
      → all 0

- [ ] **3.13** Verify ip_forward=1 on all FRR containers
      `for c in border-1 border-2 spine-1 spine-2 leaf-{1..4}{a,b}; do
        echo -n "$c: "; docker exec $c sysctl net.ipv4.ip_forward; done`

- [ ] **3.14** Verify rp_filter=2 on all FRR containers
      `for c in border-1 border-2 spine-1 spine-2 leaf-{1..4}{a,b}; do
        echo -n "$c: "; docker exec $c sysctl net.ipv4.conf.all.rp_filter; done`

### Management network connectivity

- [ ] **3.15** ping all 12 FRR containers on management IPs
      `for ip in 192.168.0.{10,11,20,21,30,31,32,33,34,35,36,37}; do
        ping -c1 -W1 $ip; done`

- [ ] **3.16** Ping all 18 VMs on management IPs
      `for ip in 192.168.0.{2,3,50,51,52,53,54,55,56,57,58,59,60,61,62,63,64,65}; do
        ping -c1 -W1 $ip; done`

### Server network wiring

- [ ] **3.17** Wire server VMs to fabric bridges
      (This requires attaching VM interfaces to the correct bridges via libvirt
      or manual veth wiring from host into VM namespaces. May need a dedicated
      script: `setup-server-links.sh` — to be written.)

- [ ] **3.18** Configure ECMP default routes on all 16 servers
      Per server: `ip route add default nexthop via <leaf-a-ip> dev eth1 nexthop via <leaf-b-ip> dev eth2`
      (Generator should produce a per-server provisioning script or Vagrant inline shell)

- [ ] **3.19** Verify server dual-homing
      From srv-1-1: `ip route show default` → two next-hops
      From srv-1-1: `ping -c1 172.16.3.1` (leaf-1a) and `ping -c1 172.16.3.5` (leaf-1b)

### DNS and bastion

- [ ] **3.20** Deploy dnsmasq config to mgmt VM
      `scp generated/dnsmasq/dnsmasq.conf mgmt:/etc/dnsmasq.conf`
      `vagrant ssh mgmt -c "sudo systemctl restart dnsmasq"`

- [ ] **3.21** Verify DNS resolution
      `dig @192.168.0.3 spine-1.netwatch.lab` → 192.168.0.20

- [ ] **3.22** Verify bastion SSH jump
      `ssh -J vagrant@192.168.0.2 vagrant@192.168.0.50 hostname` → srv-1-1

- [ ] **3.23** Run status script
      `scripts/fabric/status.sh` → all checks green

- [ ] **3.24** Commit
      `git add -A && git commit -m "P3: core lab — 30 nodes up, OOB, DNS, bastion"`

**P3 GATE:** All 30 nodes ping on management. DNS resolves. Bastion SSH works.
Status script all green. Servers dual-homed with ECMP defaults.

---

## PHASE 4 — ROUTING
> Full BGP convergence across the Clos fabric.

### Deploy FRR configs

- [ ] **4.01** Copy configs into all 12 FRR containers
      ```
      for node in border-{1,2} spine-{1,2} leaf-{1..4}{a,b}; do
        docker cp generated/frr/$node/frr.conf $node:/etc/frr/frr.conf
        docker cp generated/frr/$node/daemons $node:/etc/frr/daemons
        docker cp generated/frr/$node/vtysh.conf $node:/etc/frr/vtysh.conf
      done
      ```

- [ ] **4.02** Restart FRR daemons in all containers
      ```
      for node in border-{1,2} spine-{1,2} leaf-{1..4}{a,b}; do
        docker exec $node /usr/lib/frr/frrinit.sh restart
      done
      ```

### BGP verification

- [ ] **4.03** Verify border-1 BGP: 2 peers (spine-1, spine-2) Established
      `docker exec border-1 vtysh -c "show bgp summary"`

- [ ] **4.04** Verify border-2 BGP: 2 peers Established
      `docker exec border-2 vtysh -c "show bgp summary"`

- [ ] **4.05** Verify spine-1 BGP: 10 peers Established
      (2 borders + 8 leafs)
      `docker exec spine-1 vtysh -c "show bgp summary"`

- [ ] **4.06** Verify spine-2 BGP: 10 peers Established
      `docker exec spine-2 vtysh -c "show bgp summary"`

- [ ] **4.07** Verify each leaf: 2 peers (spine-1, spine-2) Established
      ```
      for leaf in leaf-{1..4}{a,b}; do
        echo "--- $leaf ---"
        docker exec $leaf vtysh -c "show bgp summary"
      done
      ```

- [ ] **4.08** Total BGP session count = 20
      `docker exec spine-1 vtysh -c "show bgp summary" | grep -c Estab`
      → 10 (spine-1 sees 10 peers)

### BFD verification

- [ ] **4.09** Verify BFD on spine-1: 10 peers Up
      `docker exec spine-1 vtysh -c "show bfd peers"`

- [ ] **4.10** Verify BFD timers are dilated
      `docker exec spine-1 vtysh -c "show bfd peers"` → Tx/Rx = 1000ms

### ECMP verification

- [ ] **4.11** Check ECMP paths on leaf-1a to a remote rack
      `docker exec leaf-1a vtysh -c "show ip route 10.0.3.7"`
      → 2 next-hops (via spine-1 and spine-2)

- [ ] **4.12** Check ECMP paths on spine-1 to a leaf loopback
      `docker exec spine-1 vtysh -c "show ip route 10.0.3.1"`
      → direct connected (single path — spine to directly-connected leaf)

### allowas-in verification

- [ ] **4.13** Leaf-1a can reach leaf-1b (same ASN, same rack)
      `docker exec leaf-1a ping -c3 10.0.3.2` → success

- [ ] **4.14** Border-1 can reach border-2 (same ASN)
      `docker exec border-1 ping -c3 10.0.1.2` → success

### End-to-end path verification

- [ ] **4.15** Traceroute: leaf-1a → leaf-4a (cross-rack)
      `docker exec leaf-1a traceroute -n 10.0.3.7`
      Expected: leaf-1a → spine-X → leaf-4a (3 hops)

- [ ] **4.16** Traceroute: leaf-1a → border-1
      `docker exec leaf-1a traceroute -n 10.0.1.1`
      Expected: leaf-1a → spine-X → border-1 (3 hops)

- [ ] **4.17** Ping: srv-1-1 → srv-4-4 (full fabric traversal)
      `vagrant ssh srv-1-1 -c "ping -c3 172.16.6.30"`
      Expected: srv → leaf → spine → leaf → srv (5 hops)

- [ ] **4.18** Traceroute: srv-1-1 → srv-4-4
      `vagrant ssh srv-1-1 -c "traceroute -n 172.16.6.30"`
      Verify path through Clos fabric

### Route table completeness

- [ ] **4.19** Verify spine-1 has routes to all 12 loopbacks
      `docker exec spine-1 vtysh -c "show ip route" | grep "/32" | wc -l` → 12

- [ ] **4.20** Verify leaf-1a has routes to all remote loopbacks
      `docker exec leaf-1a vtysh -c "show ip route" | grep "10.0." | wc -l`
      → at least 11 (all other loopbacks)

- [ ] **4.21** Commit
      `git add -A && git commit -m "P4: routing — 20 BGP, 20 BFD, ECMP verified"`

**P4 GATE:** 20 BGP Established. 20 BFD Up. ECMP working. allowas-in verified.
End-to-end server-to-server ping across fabric. All loopbacks reachable.

---

## PHASE 5 — OBSERVABILITY
> Prometheus, Grafana, Loki operational. All 30 nodes scraped.

### Deploy Prometheus

- [ ] **5.01** Install Prometheus on mgmt VM
      ```
      vagrant ssh mgmt
      sudo dnf install -y prometheus2  # or download binary
      ```

- [ ] **5.02** Deploy generated prometheus.yml
      `scp generated/prometheus/prometheus.yml mgmt:/etc/prometheus/prometheus.yml`

- [ ] **5.03** Start Prometheus
      `sudo systemctl enable --now prometheus`

- [ ] **5.04** Verify Prometheus is scraping
      `curl -s http://192.168.0.3:9090/api/v1/targets | python3 -c "
      import json,sys; d=json.load(sys.stdin)
      up = sum(1 for t in d['data']['activeTargets'] if t['health']=='up')
      print(f'{up}/30 targets up')"`

- [ ] **5.05** Debug any targets not scraping
      (Common: firewall on VM blocking 9100, FRR exporter not running on 9101)

### Deploy node_exporter on VMs

- [ ] **5.06** Verify node_exporter running on all 18 VMs
      (Vagrant provisioning should have installed it — verify)
      ```
      for ip in 192.168.0.{2,3,50..65}; do
        curl -s -o /dev/null -w "%{http_code} $ip\n" http://$ip:9100/metrics
      done
      ```

- [ ] **5.07** Fix any VMs where node_exporter isn't running

### Deploy Grafana

- [ ] **5.08** Install Grafana on mgmt VM
      ```
      vagrant ssh mgmt
      sudo dnf install -y grafana  # or add Grafana repo first
      ```

- [ ] **5.09** Start Grafana
      `sudo systemctl enable --now grafana-server`

- [ ] **5.10** Configure Prometheus data source in Grafana
      `curl -X POST http://admin:admin@192.168.0.3:3000/api/datasources \
        -H 'Content-Type: application/json' \
        -d '{"name":"Prometheus","type":"prometheus","url":"http://localhost:9090","access":"proxy"}'`

- [ ] **5.11** Create Dashboard 1: Fabric Overview
      Panels: node up/down status, link health, overall fabric state

- [ ] **5.12** Create Dashboard 2: BGP Status
      Panels: session states, route counts per peer, peer uptime, state changes

- [ ] **5.13** Create Dashboard 3: Node Detail
      Panels: CPU, memory, disk, network interface stats (per-node variable)

- [ ] **5.14** Create Dashboard 4: Interface Counters
      Panels: bytes/packets in/out per interface, error counts

- [ ] **5.15** Create Dashboard 5: Chaos Events
      Panels: annotated timeline, event markers, before/during/after views

- [ ] **5.16** Create Dashboard 6: EVPN/VxLAN (placeholder until P7)
      Panels: VNI status, VTEP reachability, overlay route counts

- [ ] **5.17** Create Lab View / Production View variants
      Production View: all control-plane durations ÷ 10, rates × 10

### Deploy Loki

- [ ] **5.18** Install Loki on mgmt VM
      `sudo dnf install -y loki` or download binary

- [ ] **5.19** Deploy generated loki-config.yml
      `scp generated/loki/loki-config.yml mgmt:/etc/loki/config.yml`

- [ ] **5.20** Start Loki
      `sudo systemctl enable --now loki`

- [ ] **5.21** Configure rsyslog on all 30 nodes to forward to Loki
      Each node needs rsyslog config pointing to 192.168.0.3:3100
      (May need a promtail agent instead — Loki doesn't accept raw syslog)

- [ ] **5.22** Configure Loki data source in Grafana

- [ ] **5.23** Verify log flow
      `curl -s 'http://192.168.0.3:3100/loki/api/v1/query?query={job="syslog"}'`
      → returns log entries

### Deploy chrony

- [ ] **5.24** Install chrony on mgmt VM
      `sudo dnf install -y chrony`
      Configure as NTP server for the lab

- [ ] **5.25** Point all 30 nodes' NTP to mgmt VM
      (Consistent timestamps for log correlation)

- [ ] **5.26** Commit
      `git add -A && git commit -m "P5: observability — Prometheus, Grafana, Loki live"`

**P5 GATE:** 30/30 Prometheus targets up. 6 Grafana dashboards rendering.
Loki receiving logs. Dual-view timing working.

---

## PHASE 6 — CHAOS (INFRASTRUCTURE)
> Fault injection with visible protocol response in dashboards.

### Write chaos scripts

- [ ] **6.01** Write `scripts/chaos/link-down.sh`
      Args: node-a node-b [--restore]
      Action: `ip link set <bridge> down` / `up`

- [ ] **6.02** Write `scripts/chaos/link-flap.sh`
      Args: node-a node-b --interval 5 --count 10
      Action: toggle bridge down/up at interval

- [ ] **6.03** Write `scripts/chaos/latency-inject.sh`
      Args: node-a node-b --delay 100ms [--jitter 20ms]
      Action: `tc qdisc add dev <veth> root netem delay 100ms 20ms`

- [ ] **6.04** Write `scripts/chaos/packet-loss.sh`
      Args: node-a node-b --loss 10%
      Action: `tc qdisc add dev <veth> root netem loss 10%`

- [ ] **6.05** Write `scripts/chaos/rack-partition.sh`
      Args: rack-N [--restore]
      Action: down all bridges connecting rack-N leafs to spines

- [ ] **6.06** Write `scripts/chaos/node-kill.sh`
      Args: node-name [--restore]
      Action: `docker stop <node>` / `docker start <node>`

### Validate chaos scenarios
The generator produces br000...br051. The generated scripts use the index names correctly — but when you write the P6 chaos scripts, don't follow the docs. Follow the actual names in the generated output
- [ ] **6.07** Test: link-down spine-1 ↔ leaf-1a
      Expected: BFD timeout ~3s → BGP withdrawal → traffic shifts to spine-2
      Verify in Grafana: BGP Status shows session drop, recovery on restore

- [ ] **6.08** Test: link-flap spine-1 ↔ leaf-1a (5s interval, 5 cycles)
      Expected: repeated BFD flaps, BGP dampening behavior
      Verify in Grafana: Chaos Events timeline shows flap pattern

- [ ] **6.09** Test: latency-inject spine-1 ↔ leaf-2a 200ms
      Expected: increased RTT visible in interface counters
      Verify: `docker exec leaf-2a ping -c5 <spine-1-ip>` shows ~200ms

- [ ] **6.10** Test: packet-loss spine-2 ↔ leaf-3a 30%
      Expected: degraded throughput, possible BFD jitter (but not timeout at 30%)
      Verify in Grafana: interface error counters rise

- [ ] **6.11** Test: rack-partition rack-1
      Expected: ALL rack-1 leaf BGP sessions drop, rack-1 server routes withdraw
      Other racks unaffected. Recovery on restore.

- [ ] **6.12** Test: node-kill spine-1
      Expected: all 10 spine-1 BGP sessions drop, full reconvergence to spine-2
      All cross-rack traffic survives via spine-2. Recovery on restart.

- [ ] **6.13** Add Grafana annotations for chaos events
      Scripts should POST annotations to Grafana API on fault inject/restore

- [ ] **6.14** Commit
      `git add scripts/chaos/ && git commit -m "P6: chaos — fault injection verified"`

**P6 GATE:** Each scenario produces expected protocol response.
All events visible in Grafana with annotations. Fabric self-heals after every fault.

---

## PHASE 7 — VALIDATION
> EVPN/VxLAN overlay + Chaos Mesh survival test.

### EVPN/VxLAN overlay

- [ ] **7.01** Update FRR configs for EVPN (already in templates, just redeploy)
      Regenerate: `python3 generator/generate.py`
      Redeploy to all 12 containers (same as 4.01–4.02)

- [ ] **7.02** Create VxLAN interfaces on leaf VTEPs
      (May require additional scripting or FRR config for VNI-to-bridge mapping)

- [ ] **7.03** Verify EVPN control plane
      `docker exec leaf-1a vtysh -c "show bgp l2vpn evpn summary"`
      → peers Established

- [ ] **7.04** Verify EVPN route exchange
      `docker exec leaf-1a vtysh -c "show bgp l2vpn evpn route"`
      → type-2 (MAC/IP) and type-3 (IMET) routes present

- [ ] **7.05** Verify VxLAN tunnel endpoints
      `docker exec leaf-1a vtysh -c "show evpn vni"`
      → VNIs listed with remote VTEPs

- [ ] **7.06** Verify cross-rack L2 reachability over overlay
      Ping between servers in different racks using overlay addresses

### k3s cluster

- [ ] **7.07** Install k3s server on srv-1-1
      ```
      curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='\
        --flannel-backend=none \
        --disable-network-policy \
        --disable=traefik' sh -
      ```

- [ ] **7.08** Get join token
      `sudo cat /var/lib/rancher/k3s/server/node-token`

- [ ] **7.09** Join srv-1-2, srv-1-3, srv-1-4 as agents (rack-1)
      ```
      curl -sfL https://get.k3s.io | \
        K3S_URL=https://<srv-1-1-ip>:6443 \
        K3S_TOKEN=<token> sh -
      ```

- [ ] **7.10** Join rack-2 servers as agents (4 nodes)
- [ ] **7.11** Join rack-3 servers as agents (4 nodes)
- [ ] **7.12** Join rack-4 servers as agents (4 nodes)

- [ ] **7.13** Verify k3s cluster: 16 nodes Ready
      `kubectl get nodes` → 16 nodes, all Ready

### Cilium CNI

- [ ] **7.14** Install Helm on srv-1-1 (or wherever kubectl runs)
      `curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash`

- [ ] **7.15** Install Cilium
      ```
      helm repo add cilium https://helm.cilium.io/
      helm install cilium cilium/cilium --namespace kube-system \
        --set tunnel=vxlan \
        --set ipam.mode=kubernetes
      ```

- [ ] **7.16** Verify Cilium
      `cilium status` → all agents healthy
      `kubectl -n kube-system get pods -l k8s-app=cilium` → 16 running

- [ ] **7.17** Verify pod-to-pod networking cross-rack
      Deploy two test pods on different racks, ping between them

### Chaos Mesh

- [ ] **7.18** Install Chaos Mesh
      ```
      helm repo add chaos-mesh https://charts.chaos-mesh.org
      helm install chaos-mesh chaos-mesh/chaos-mesh \
        --namespace chaos-mesh --create-namespace \
        --set chaosDaemon.runtime=containerd \
        --set chaosDaemon.socketPath=/run/k3s/containerd/containerd.sock
      ```

- [ ] **7.19** Verify Chaos Mesh
      `kubectl get pods -n chaos-mesh` → controller + daemon pods running

### Validation workload

- [ ] **7.20** Deploy nginx
      `kubectl apply -f validation/workloads/nginx-replicated.yml`

- [ ] **7.21** Verify nginx replicas spread across racks
      `kubectl get pods -o wide` → pods on nodes in different racks

- [ ] **7.22** Write Chaos Mesh experiment manifests
      Create CRDs in `validation/chaos-mesh/experiments/`:
      - pod-kill.yml
      - pod-failure.yml
      - network-partition.yml
      - network-delay.yml
      - node-drain.yml (or combined experiment)

- [ ] **7.23** Write availability monitoring script
      Continuous curl loop against nginx service, log response codes + timestamps

### The survival test

- [ ] **7.24** Start availability monitor

- [ ] **7.25** Apply Chaos Mesh experiments
      `kubectl apply -f validation/chaos-mesh/experiments/`

- [ ] **7.26** Wait 10 minutes

- [ ] **7.27** Collect results
      Calculate: total requests, successful responses, max gap between successes

- [ ] **7.28** Evaluate against success criteria
      - Availability > 99%? ___
      - Max single outage < 3 seconds? ___
      - All events captured in Grafana? ___

- [ ] **7.29** If FAIL: debug, adjust, re-run
      Common issues: pod anti-affinity not spreading enough,
      Cilium health check too slow, chaos too aggressive

- [ ] **7.30** Commit
      `git add -A && git commit -m "P7: validation — EVPN, k3s, Cilium, Chaos Mesh PASS"`

**P7 GATE:** >99% availability. <3s max outage. Chaos Mesh indifferent.

---

## POST-BUILD — PORTFOLIO POLISH
> Make it recruiter-ready and resume-worthy.

### Architecture diagram

- [ ] **8.01** Create SVG architecture diagram for README
      3-tier Clos topology, all node names, ASN labels, address ranges

- [ ] **8.02** Add diagram to README.md (replace ASCII art or supplement)

### Commit history

- [ ] **8.03** Review commit history, squash/reword if needed
      Each phase should be 1-3 clean commits with descriptive messages

- [ ] **8.04** Tag releases
      `git tag v1.0-p4-routing` etc. (optional, one final `v1.0` tag)

### README polish

- [ ] **8.05** Add "Quick Start" section to README
      3-5 commands to go from clone to running fabric

- [ ] **8.06** Add screenshots of Grafana dashboards to README or docs/

- [ ] **8.07** Add "Results" section
      Chaos Mesh survival test results, timing data, availability numbers

### Resume integration

- [ ] **8.08** Update resume: NetWatch as anchor project
      Keywords: BGP, EVPN/VxLAN, BFD, ECMP, Clos, FRRouting, Prometheus,
      Grafana, Chaos Mesh, Python/Jinja2, IaC, observability

- [ ] **8.09** Update one-pager PDF (fix Chaos Monkey references → Chaos Mesh)

### GitHub

- [ ] **8.10** Make repo public
- [ ] **8.11** Add GitHub topics/tags: networking, bgp, data-center, chaos-engineering

### Future extensions (V2, not blocking)

- [ ] **9.01** Ansible playbooks for configuration management
- [ ] **9.02** Dynamic topology engine (compute node counts from spine radix)
- [ ] **9.03** Multi-pod / 5-stage Clos extension
- [ ] **9.04** Ambient Life Dashboard integration (Envy x360 repurpose)

---

## PROGRESS SUMMARY

| Phase | Tasks | Status |
|-------|-------|--------|
| P0 Environment | 10 | ☐ Not started |
| P1 Scaffold | 9 | ▓▓▓▓▓▓░░ 6/9 done |
| P2 Generator | 16 | ▓▓▓▓▓▓▓░ 14/16 done |
| P3 Core Lab | 24 | ☐ Not started |
| P4 Routing | 21 | ☐ Not started |
| P5 Observability | 26 | ☐ Not started |
| P6 Chaos | 14 | ☐ Not started |
| P7 Validation | 30 | ☐ Not started |
| Post-build | 11 | ☐ Not started |
| **TOTAL** | **161** | **20/161 (12%)** |
