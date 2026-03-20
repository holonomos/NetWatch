# NetWatch — Build Phases

Serial execution. Hard gates. Don't skip forward.

---

## P0 — Environment

**Goal:** Every tool is installed and verified on the host machine.

### Checklist

```bash
# KVM
egrep -c '(vmx|svm)' /proc/cpuinfo    # must be > 0
lsmod | grep kvm                        # kvm_intel or kvm_amd loaded
virsh list --all                        # libvirtd running

# Vagrant
vagrant --version                       # 2.4+
vagrant plugin list                     # vagrant-libvirt installed

# Docker
docker run --rm hello-world             # daemon running
docker run --rm --network=none alpine echo ok   # --network=none works

# FRR image
docker pull quay.io/frrouting/frr:9.1.0
docker run --rm quay.io/frrouting/frr:9.1.0 vtysh -c "show version"
# FRR 9.1.0 has no native Prometheus exporter — using frr_exporter sidecar
# Verify frr_exporter is working (after setup-frr-containers.sh):
#   curl -s http://192.168.0.10:9342/metrics | head

# Python
python3 --version                       # 3.10+
python3 -c "import yaml; import jinja2; print('ok')"

# KSM
cat /sys/kernel/mm/ksm/run             # 1 = enabled
# If 0: echo 1 | sudo tee /sys/kernel/mm/ksm/run

# Bridge utilities
which brctl || sudo dnf install bridge-utils
which ip                                # iproute2
```

### Gate
All commands pass. FRR Prometheus exporter confirmed working.
If the exporter is missing, identify an alternative FRR image or plan custom build.

---

## P1 — Scaffold

**Goal:** Repo initialized, topology finalized, directory tree created.

### Commands

```bash
cd ~/projects    # or wherever
git init netwatch
cd netwatch

# Copy in: topology.yml, README.md, LICENSE, .gitignore
# Create directory tree (see reference.md section 14)
# Copy docs: architecture.md, reference.md, phases.md

git add -A
git commit -m "P1: scaffold — topology, docs, directory tree"
```

### Gate
`tree` output matches reference.md section 14. `topology.yml` is valid YAML.
README.md renders correctly on GitHub.

---

## P2 — Config Generator

**Goal:** `python3 generator/generate.py` reads topology.yml and produces
all configs in `generated/`.

### What gets generated

```
generated/
├── frr/
│   ├── border-1/
│   │   ├── frr.conf        # BGP neighbors, BFD, loopback, interfaces
│   │   ├── daemons          # bgpd=yes, bfdd=yes, zebra=yes, staticd=yes
│   │   └── vtysh.conf       # hostname
│   ├── border-2/
│   ├── spine-1/
│   ├── spine-2/
│   ├── leaf-1a/ ... leaf-4b/
├── prometheus/
│   └── prometheus.yml       # all 30 scrape targets
├── dnsmasq/
│   └── dnsmasq.conf         # MAC→IP reservations, DNS entries
└── loki/
    └── loki-config.yml
```

### Validation

```bash
python3 generator/generate.py

# Check FRR configs are syntactically valid
for node in generated/frr/*/; do
    echo "--- $(basename $node) ---"
    cat "$node/frr.conf" | head -5
done

# Spot-check: leaf-1a should have:
#   - router bgp 65101
#   - neighbor spine-1 remote-as 65001
#   - neighbor spine-2 remote-as 65001
#   - allowas-in on spine-facing sessions
#   - BFD timers 1000/1000/3
grep -A5 "router bgp" generated/frr/leaf-1a/frr.conf

# Spot-check: prometheus.yml should list all 30 targets
grep -c "targets" generated/prometheus/prometheus.yml

# Spot-check: dnsmasq.conf should have 30 DHCP reservations
grep -c "dhcp-host" generated/dnsmasq/dnsmasq.conf
```

### Gate
Generator runs without errors. All 12 FRR configs have correct ASN,
correct neighbors, correct IPs, BFD enabled, allowas-in where needed.
Prometheus config lists all 30 scrape targets. dnsmasq has all 30 reservations.

### Commit

```bash
git add generator/ docs/
git commit -m "P2: config generator — topology.yml → all FRR, Prometheus, DHCP configs"
```

---

## P3 — Core Lab

**Goal:** All 30 nodes running and reachable on the management network.

### Sequence

1. Create management bridge
2. Bring up 18 VMs via Vagrant
3. Create 52 fabric bridges (STP off)
4. Start 12 FRR containers (--network=none)
5. Create veth pairs and attach to namespaces
6. Apply sysctls (ip_forward, rp_filter)
7. Configure server ECMP default routes
8. Verify OOB connectivity

### Commands

```bash
# Fabric lifecycle
sudo scripts/fabric/setup-bridges.sh
vagrant up
sudo scripts/fabric/setup-frr-containers.sh
scripts/fabric/status.sh

# Verify all nodes on management network
for ip in 192.168.0.{2,3,10,11,20,21,30..37,50..65}; do
    ping -c1 -W1 $ip && echo "$ip OK" || echo "$ip FAIL"
done

# Verify bastion SSH
ssh -J bastion.netwatch.lab srv-1-1.netwatch.lab hostname

# Verify DNS
dig @192.168.0.3 spine-1.netwatch.lab
```

### Gate
All 30 nodes respond to ping on management IPs. Bastion SSH works.
DNS resolves all hostnames. `scripts/fabric/status.sh` shows all
containers running and all bridges up.

### Commit

```bash
git add scripts/fabric/ Vagrantfile
git commit -m "P3: core lab — 30 nodes up, OOB network, bastion SSH, DNS"
```

---

## P4 — Routing

**Goal:** Full BGP convergence across the Clos fabric.

### Deploy configs and start daemons

```bash
# Copy generated FRR configs into containers
for node in border-1 border-2 spine-1 spine-2 \
            leaf-1a leaf-1b leaf-2a leaf-2b \
            leaf-3a leaf-3b leaf-4a leaf-4b; do
    docker cp generated/frr/$node/frr.conf $node:/etc/frr/frr.conf
    docker cp generated/frr/$node/daemons $node:/etc/frr/daemons
    docker cp generated/frr/$node/vtysh.conf $node:/etc/frr/vtysh.conf
    docker exec $node /usr/lib/frr/frrinit.sh restart
done
```

### Verification

```bash
# BGP: all 20 sessions Established
docker exec spine-1 vtysh -c "show bgp summary"
# Look for: 10 peers, all showing Established state

docker exec leaf-1a vtysh -c "show bgp summary"
# Should show 2 peers (spine-1, spine-2), both Established

# BFD: all 20 sessions Up
docker exec spine-1 vtysh -c "show bfd peers"

# ECMP: multiple next-hops for cross-rack prefixes
docker exec leaf-1a vtysh -c "show ip route 10.0.3.7"
# leaf-4a loopback — should show 2 next-hops (via spine-1 and spine-2)

# End-to-end traceroute
docker exec leaf-1a traceroute -n 10.0.3.7
# Expected: leaf-1a → spine-X → leaf-4a (3 hops)

# Server-to-server (through VMs)
vagrant ssh srv-1-1 -c "traceroute -n 172.16.6.2"
# Expected: srv-1-1 → leaf-1X → spine-X → leaf-4X → srv-4-1

# Verify allowas-in: leaf-1a can reach leaf-1b
docker exec leaf-1a ping -c3 10.0.3.2
```

### Gate
20 BGP sessions Established. 20 BFD sessions Up. ECMP paths verified.
End-to-end traceroute shows correct Clos paths. Intra-rack leaf
reachability works (allowas-in verified).

### Commit

```bash
git add -A
git commit -m "P4: routing — 20 BGP sessions, BFD, ECMP, full convergence"
```

---

## P5 — Observability

**Goal:** Prometheus scraping all nodes, Grafana dashboards live, logs flowing.

### Deploy

```bash
# Copy configs to mgmt VM
vagrant ssh mgmt -c "mkdir -p /etc/prometheus /etc/grafana /etc/loki"
# scp generated/prometheus/prometheus.yml mgmt:/etc/prometheus/
# scp generated/loki/loki-config.yml mgmt:/etc/loki/
# Start services (systemd or docker-compose on mgmt VM)
```

### Verification

```bash
# Prometheus targets
curl -s http://192.168.0.3:9090/api/v1/targets | python3 -m json.tool | grep -c '"health":"up"'
# Should be 30

# Grafana
curl -s http://192.168.0.3:3000/api/health
# Should return {"database":"ok"}

# Loki
curl -s http://192.168.0.3:3100/ready
# Should return "ready"

# Test a LogQL query
curl -s 'http://192.168.0.3:3100/loki/api/v1/query?query={job="syslog"}'
```

### Gate
All 30 Prometheus targets showing "up". All 6 Grafana dashboards loaded
and rendering data. Loki receiving logs from all nodes.

### Commit

```bash
git add -A
git commit -m "P5: observability — Prometheus, Grafana, Loki operational"
```

---

## P6 — Chaos (Infrastructure)

**Goal:** Fault injection causes visible protocol responses in dashboards.

### Test sequence

```bash
# 1. Kill a spine link
sudo scripts/chaos/link-down.sh spine-1 leaf-1a
# Watch: BFD timeout in ~3s, BGP withdrawal, traffic shifts to spine-2
# Grafana: BGP Status dashboard shows session drop

# 2. Restore
sudo scripts/chaos/link-down.sh spine-1 leaf-1a --restore
# Watch: BFD Up, BGP re-established, ECMP restored

# 3. Rack partition
sudo scripts/chaos/rack-partition.sh rack-1
# Watch: All rack-1 leaf sessions drop, routes withdraw
# Servers in rack-1 become unreachable from other racks

# 4. Latency injection
sudo scripts/chaos/latency-inject.sh spine-1 leaf-2a 100ms
# Watch: Interface counters show increased RTT

# 5. Node kill
sudo scripts/chaos/node-kill.sh spine-1
# Watch: All 10 spine-1 BGP sessions drop, full reconvergence to spine-2
```

### Gate
Each chaos scenario produces the expected protocol response.
All events visible in Grafana Chaos Events dashboard.
Fabric self-heals after fault removal.

### Commit

```bash
git add scripts/chaos/
git commit -m "P6: chaos — fault injection with dashboard-visible recovery"
```

---

## P7 — Validation

**Goal:** EVPN/VxLAN overlay + Chaos Mesh survival test.

### EVPN/VxLAN (update FRR configs)

```bash
# Regenerate with EVPN enabled (already in topology.yml)
python3 generator/generate.py
# Redeploy FRR configs (same as P4)
# Verify EVPN
docker exec leaf-1a vtysh -c "show evpn vni"
docker exec leaf-1a vtysh -c "show bgp l2vpn evpn summary"
```

### k3s + Cilium

```bash
# Install k3s on server VMs (one control plane, rest as agents)
# Use srv-1-1 as control plane
vagrant ssh srv-1-1 -c "curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='--flannel-backend=none --disable-network-policy' sh -"

# Install Cilium
helm install cilium cilium/cilium --namespace kube-system

# Join other servers
# TOKEN=$(vagrant ssh srv-1-1 -c "sudo cat /var/lib/rancher/k3s/server/node-token")
# On each other server:
# curl -sfL https://get.k3s.io | K3S_URL=https://srv-1-1:6443 K3S_TOKEN=$TOKEN sh -
```

### Chaos Mesh + nginx

```bash
# Install Chaos Mesh
helm install chaos-mesh chaos-mesh/chaos-mesh -n chaos-mesh --create-namespace

# Deploy nginx
kubectl apply -f validation/workloads/nginx-replicated.yml

# Run 10-minute chaos experiment
kubectl apply -f validation/chaos-mesh/experiments/

# Monitor
# Watch Grafana dashboards + kubectl get pods -w
# After 10 minutes, check availability:
# >99% uptime, <3s max single outage
```

### Gate
EVPN routes propagating between all leaf VTEPs.
nginx replicas spread across racks with anti-affinity.
10-minute Chaos Mesh run passes: >99% availability, <3s max outage.

### Final commit

```bash
git add -A
git commit -m "P7: validation — EVPN/VxLAN, k3s, Cilium, Chaos Mesh, nginx survival"
```

---

## Post-Build

- [ ] Ansible playbooks for configuration management
- [ ] Architecture diagram (SVG) for README and resume
- [ ] Clean commit history (squash if needed)
- [ ] GitHub repo public
- [ ] One-pager PDF updated
