# NetWatch v1.0 — Workload Layer Manifest

> The fabric is done. This manifest covers everything from k3s cluster formation
> to the survival test. No infrastructure refactoring. Ship it.
>
> **Prerequisite:** Fabric fully operational (31/31 status, north-south verified,
> EVPN overlay active, all bug fixes applied).

---

## 1. MetalLB + BGP (service ingress)

MetalLB speakers on server VMs peer with their rack's leaf switches via BGP.
When a `Service type=LoadBalancer` is created, MetalLB assigns an IP from
`10.100.0.0/24` and announces it as a /32 into the fabric.

- [ ] **1.01** Add MetalLB service IP pool to topology.yml
      `10.100.0.0/24` under addressing section.

- [ ] **1.02** Update FRR leaf configs to accept BGP from server loopbacks
      Each leaf needs a BGP peer-group `METALLB` that accepts connections
      from its rack's server loopback IPs (10.0.4-7.x).
      Dynamic neighbors via `bgp listen range` or explicit peer entries.
      Update frr.conf.j2 template + regenerate.

- [ ] **1.03** Add host route for MetalLB service IPs
      `sudo ip route add 10.100.0.0/24 via 192.168.0.2`
      Add to `make up` flow or a `make routes` target.

- [ ] **1.04** Prepare MetalLB Helm values + ConfigMap
      BGP mode, peer with leaf loopback IPs, address pool 10.100.0.0/24.
      Store in `config/metallb/` — applied after k3s is up.

- [ ] **1.05** Verify: after k3s + MetalLB deployed, create a test LoadBalancer service.
      `curl http://10.100.0.x` from host → reaches pod through fabric.

## 2. k3s Cluster Formation

k3s binary is baked into the golden image. Not started, not configured.

- [ ] **2.01** Create k3s bootstrap script (`scripts/k3s/bootstrap-server.sh`)
      Runs on srv-1-1 (control plane). Starts k3s server with:
      - `--bind-address <srv-1-1 loopback>` (cluster traffic on fabric)
      - `--flannel-backend=none` (Cilium handles CNI)
      - `--disable-network-policy` (Cilium handles this)
      - `--disable=traefik` (we use MetalLB for ingress)
      - `--node-ip <loopback>` (advertise fabric IP to cluster)
      Outputs join token.

- [ ] **2.02** Create k3s agent join script (`scripts/k3s/join-agent.sh`)
      Runs on remaining 15 servers. Starts k3s agent with:
      - `--server https://<srv-1-1-loopback>:6443`
      - `--token <token>`
      - `--node-ip <own loopback>` (advertise fabric IP)

- [ ] **2.03** Label nodes with rack topology
      ```
      kubectl label node srv-1-1 topology.kubernetes.io/zone=rack-1
      ```
      Read from `/etc/netwatch-rack` (written by Vagrantfile).

- [ ] **2.04** Verify: `kubectl get nodes` → 16 nodes Ready

- [ ] **2.05** Copy kubeconfig to bastion
      Bastion needs kubectl access to the cluster via fabric.
      `scp srv-1-1:/etc/rancher/k3s/k3s.yaml bastion:~/.kube/config`
      Update server URL to srv-1-1 loopback IP.

## 3. Cilium CNI

- [ ] **3.01** Install Cilium via Helm (from bastion)
      ```
      helm install cilium cilium/cilium --namespace kube-system \
        --set tunnel=vxlan \
        --set ipam.mode=kubernetes \
        --set bpf.masquerade=true
      ```
      Helm + cilium CLI already baked into golden image.

- [ ] **3.02** Verify: `cilium status` → all agents healthy

- [ ] **3.03** Verify pod-to-pod cross-rack networking
      Deploy two test pods on different racks, ping between them.

## 4. MetalLB Deployment

Depends on: k3s cluster up (#2), Cilium running (#3), leaf FRR configs updated (#1.02).

- [ ] **4.01** Install MetalLB via Helm
      ```
      helm install metallb metallb/metallb --namespace metallb-system --create-namespace
      ```

- [ ] **4.02** Apply BGP configuration (ConfigMap or CRDs)
      - Address pool: 10.100.0.0/24
      - Peers: leaf loopback IPs (each server peers with its 2 leaf switches)

- [ ] **4.03** Verify: create a test `Service type=LoadBalancer`
      Check that MetalLB assigns an IP and the leaf learns the /32 via BGP.
      `vagrant ssh leaf-1a -c "sudo vtysh -c 'show ip route 10.100.0.0/24'"`

- [ ] **4.04** Verify from host: `curl http://10.100.0.x` reaches the service

## 5. Bastion as Operations Desk

- [ ] **5.01** Configure kubectl on bastion
      Copy kubeconfig, set server URL to fabric IP.
      Verify: `kubectl get nodes` from bastion.

- [ ] **5.02** Set up container registry on bastion
      Simple registry (k3s can use its built-in containerd for local imports,
      or we run a lightweight registry like `distribution/distribution`).
      Bastion listens on :5000, servers pull from `bastion.netwatch.lab:5000`.

- [ ] **5.03** Create DNAT config framework
      `config/bastion-dnat.conf` — format: `<host_port> <internal_ip> <internal_port>`
      `scripts/bastion/apply-dnat.sh` — reads config, applies iptables DNAT rules.
      For non-k3s users who run services directly on servers.

- [ ] **5.04** Configure Grafana/Prometheus access from bastion
      Bastion can already reach mgmt (192.168.0.3) via mgmt network.
      Add convenience aliases or a reverse proxy for `localhost:3000` → `mgmt:3000`.

## 6. Chaos Mesh

Depends on: k3s cluster up (#2), Cilium running (#3).

- [ ] **6.01** Install Chaos Mesh via Helm
      ```
      helm install chaos-mesh chaos-mesh/chaos-mesh \
        --namespace chaos-mesh --create-namespace \
        --set chaosDaemon.runtime=containerd \
        --set chaosDaemon.socketPath=/run/k3s/containerd/containerd.sock
      ```

- [ ] **6.02** Verify: controller + daemon pods running on all nodes

- [ ] **6.03** Create chaos experiment manifests in `validation/chaos-mesh/`
      - pod-kill.yml
      - pod-failure.yml
      - network-partition.yml
      - network-delay.yml

## 7. Validation Workload + Survival Test

The point of everything. Deploy nginx, break things, measure availability.

- [ ] **7.01** Create nginx deployment manifest (`validation/workloads/nginx-replicated.yml`)
      - 4 replicas
      - Anti-affinity across racks: `topologyKey: topology.kubernetes.io/zone`
      - Service type=LoadBalancer (MetalLB assigns IP)

- [ ] **7.02** Deploy: `kubectl apply -f validation/workloads/nginx-replicated.yml`

- [ ] **7.03** Verify replicas spread across racks
      `kubectl get pods -o wide` → pods on nodes in different racks

- [ ] **7.04** Create availability monitor script (`validation/monitor.sh`)
      Continuous curl loop against the LoadBalancer IP.
      Logs: timestamp, response code, latency.

- [ ] **7.05** Start availability monitor

- [ ] **7.06** Run chaos — both layers simultaneously:
      **Infrastructure (bash scripts):**
      ```
      bash scripts/chaos/node-kill.sh spine-1
      bash scripts/chaos/rack-partition.sh rack-2
      bash scripts/chaos/latency-inject.sh spine-2 leaf-3a --delay 200ms
      ```
      **Application (Chaos Mesh):**
      ```
      kubectl apply -f validation/chaos-mesh/pod-kill.yml
      kubectl apply -f validation/chaos-mesh/network-delay.yml
      ```

- [ ] **7.07** Wait 10 minutes

- [ ] **7.08** Collect results:
      - Availability > 99%?
      - Max single outage < 3 seconds?
      - All events captured in Grafana with chaos annotations?

- [ ] **7.09** If FAIL: debug, adjust, re-run

## 8. Data Sculpture (Capstone)

- [ ] **8.01** Build the Refik Anadol-inspired container image
      Real-time particle physics visualization driven by Prometheus metrics.

- [ ] **8.02** Push to bastion registry (or import directly)

- [ ] **8.03** Deploy on k3s cluster

- [ ] **8.04** Expose via MetalLB LoadBalancer service

- [ ] **8.05** Access from host browser → live data sculpture rendering fabric metrics

## 9. Ship

- [ ] **9.01** Delete obsolete files
      `scripts/repo/build-repo.sh`, `scripts/repo/serve-repo.sh`,
      `scripts/provision-extras.sh`, `repo/fedora/`

- [ ] **9.02** Create README Quick Start (10 commands from clone to running fabric)

- [ ] **9.03** Create SVG architecture diagram

- [ ] **9.04** Add Grafana screenshots to docs/

- [ ] **9.05** Write results section (survival test numbers)

- [ ] **9.06** Write Ansible playbook for one-command deployment

- [ ] **9.07** Clean commit history, tag v1.0

- [ ] **9.08** Make repo public

---

## Dependencies

```
1. MetalLB BGP config (leaf FRR changes)
        │
2. k3s cluster ──── 3. Cilium ──── 4. MetalLB deploy
        │                               │
5. Bastion ops desk                     │
        │                               │
        └───────── 6. Chaos Mesh ───────┘
                        │
                   7. Survival test
                        │
                   8. Data sculpture
                        │
                   9. Ship
```

## Estimated Effort

| Section | Estimate |
|---------|----------|
| 1. MetalLB BGP prep | 2 hrs |
| 2. k3s cluster | 2 hrs |
| 3. Cilium | 1 hr |
| 4. MetalLB deploy | 1 hr |
| 5. Bastion ops | 2 hrs |
| 6. Chaos Mesh | 1 hr |
| 7. Survival test | 2 hrs |
| 8. Data sculpture | ??? |
| 9. Ship | 3 hrs |
| **Total** | **~14 hrs + data sculpture** |
