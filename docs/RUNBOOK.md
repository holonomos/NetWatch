# NetWatch Runbook

Operational guide: setup, daily lifecycle, dashboards, chaos, troubleshooting, and the regenerate workflow. For *how it works*, see [ARCHITECTURE.md](ARCHITECTURE.md); for *what's broken*, see [KNOWN-ISSUES.md](KNOWN-ISSUES.md).

All commands run from the repository root (referred to as `~/NetWatch-main` or `<repo-root>` throughout). libvirt domains are on the **`qemu:///system`** connection and named `NetWatch-main_<node>`.

---

## 1. Host prerequisites

- Linux + KVM (developed on Fedora, kernel 7.x), `libvirt`/`qemu-kvm`, `virsh` usable on `qemu:///system`.
- `vagrant` + the `vagrant-libvirt` plugin.
- `python3` with `pyyaml` and `jinja2`.
- `sudo` (bridges, nft/iptables, host routes), ~19 GB free RAM, several GB disk.
- If Docker is present, its `FORWARD DROP` policy will silently break inter-VM traffic. `make up`'s `hostfix` step handles it, but be aware.

Quick sanity check:

```bash
virsh -c qemu:///system list --all | grep NetWatch-main | wc -l   # expect 31 once built
vagrant box list | grep netwatch-golden                           # expect the golden box
python3 -c "import yaml, jinja2; print('gen deps ok')"
```

---

## 2. First-time build (once per host)

```bash
make artifacts-build     # download Fedora box + RPMs + binaries (needs internet + Docker for dnf in a container)
make artifacts-serve     # local HTTP repo on :8080 — leave running during bake & vagrant up
make bake                # build the golden image (~10-15 min) → artifacts/boxes/netwatch-golden.box
make box-register        # register as vagrant box "netwatch-golden"
make generate            # render all configs from topology.yml
```

`make artifacts-serve` must be **running** before `make bake` and `make vms` so VMs install RPMs/binaries from `http://<host>:8080` instead of the internet. Check/stop with `make artifacts-status` / `make artifacts-stop`.

You only repeat this when you change pinned versions (`artifacts/versions.env`) or the golden image contents.

---

## 3. Daily lifecycle

### Bring up

```bash
make vms        # boot all 31 VMs in order: obs → mgmt → 12 FRR → bastion → 16 servers (~3-4 min)
make up         # wire fabric: hostfix → bridges → fabric → evpn → wire → routes → overlay → status
```

- `make up` and `make wire` are idempotent; safe to re-run if a step fails or partially completed. (The `configure-*-fabric.sh` scripts use `ip addr replace`, so a re-run no longer aborts on "Address already assigned" and skips the overlay step.)
- `make up` ends with `status.sh` (**31/31 checks pass** on a healthy fabric). BGP needs up to ~30 s more (keepalive/hold 30/90 s) to fully converge after FRR restarts. Re-run `make status` to confirm.
- To run only part of the fabric: `make bridges`, `make fabric`, `make evpn`, `make wire`, `make routes` in that order.

### Inspect

```bash
make status                         # 31-check health report
vagrant ssh bastion                 # operator desk; then use the aliases:
#   bgp            – BGP summary on spine-1 & spine-2
#   bfd            – BFD peers on spine-1
#   fabric-status  – BGP on borders + spines
#   routes         – route summaries on spine-1/leaf-1a/border-1
vagrant ssh spine-1 -c "vtysh -c 'show bgp summary'"
vagrant ssh spine-1 -c "vtysh -c 'show bfd peers'"
vagrant ssh leaf-1a -c "vtysh -c 'show evpn vni'"          # expect L2VNI 10000+10001 + L3VNI 10999
```

If you haven't set up the bastion aliases yet: `make bastion-ops`.

For proving the EVPN overlay carries real L2 traffic (remote MACs, cross-rack L2 over VXLAN, and the inter-subnet IRB limitation), see [§5a](#5a-evpn-overlay-validation).

### Pause / resume / stop

```bash
make suspend     # save full RAM state to disk (fast resume, large disk use)
make resume
make vms-halt    # graceful shutdown, preserves disks (slower restart, re-run `make up` after)
make down        # graceful FABRIC teardown: halt the 12 FRR VMs + remove host bridges
make vms-destroy # delete all 31 VMs (keeps the golden box)
```

After `make vms-halt` + reboot, the fabric NICs persist in domain XML but the host bridges are gone; re-run `make up` (or at least `make bridges`) before expecting traffic. Teardown also detaches the NIC definitions.

---

## 4. Dashboards & service access

The stack runs on the **`obs`** VM (`192.168.0.4`): Grafana :3000, Prometheus :9090, Loki :3100.

**Option A: SSH tunnel (from the host):**
```bash
make dashboard      # forwards 3000/9090/3100 from obs to localhost
# then open http://localhost:3000 (Grafana), http://localhost:9090 (Prometheus)
```

**Option B: via the bastion's forwarded ports:**
```bash
make bastion-dnat                       # apply/refresh DNAT from config/bastion-dnat.conf
# http://192.168.0.2:3000  Grafana
# http://192.168.0.2:9090  Prometheus
# http://192.168.0.2:3100  Loki
```

To expose another port, add a line to `config/bastion-dnat.conf` (`ext_port internal_ip:internal_port proto`) and re-run `make bastion-dnat`.

**NOC dashboards.** Grafana is auto-provisioned by `provision-obs.sh` with two datasources (fixed UIDs `netwatch-prometheus` and `netwatch-loki`) and a file provider that loads everything in `/var/lib/grafana/dashboards`. **All 8 dashboards are built and load on the obs VM** (sourced from `generator/templates/grafana/dashboards/`, rendered to `generated/grafana/dashboards/` by `make generate`, which prints `[Grafana] 8 dashboards`):

| Dashboard | uid | What it shows |
|---|---|---|
| **NetWatch — NOC Overview** | `netwatch-noc-overview` | top-level health: fabric/node up-counts, BGP sessions, EVPN remote MACs, recent logs |
| **NetWatch — Fabric Overview** | `netwatch-fabric-overview` | spine/leaf/border topology health, BGP + BFD state across the fabric |
| **NetWatch — BGP Status** | `netwatch-bgp-status` | per-peer session state, prefix counts, message rate, session flaps |
| **NetWatch — Node Detail** | `netwatch-node-detail` | per-node CPU / memory / load / disk / NIC throughput (node_exporter) |
| **NetWatch — Interface Counters** | `netwatch-interface-counters` | per-interface rx/tx bytes, packets, errors, drops |
| **NetWatch — Chaos Events** | `netwatch-chaos-events` | availability, peer/target drops, and EVPN remote-MAC dips during chaos |
| **NetWatch — EVPN / VXLAN** | `netwatch-evpn-vxlan` | VNI inventory, per-VNI MAC local/remote + ARP, remote VTEPs; surfaces `netwatch_evpn_mac_remote` (the L2 data-path proof) |
| **NetWatch — Smoke** | `netwatch-smoke` | FRR/node/target up-counts, target-health-over-time, per-peer BGP message rate, recent-logs Loki panel |

After `make dashboard`, open `http://localhost:3000` → *Dashboards* and pick one (default admin login unless changed). Metric names match the live `frr_exporter` / `node_exporter` series and the per-leaf `netwatch_evpn_*` textfile collector. Logs: in Grafana's Loki datasource, try `{host="leaf-1a"}` or `{job="remote-syslog"}`.

To add another dashboard, drop a new `*.json` into `generator/templates/grafana/dashboards/` using datasource UID `netwatch-prometheus` (or `netwatch-loki` for logs), `make generate`, then `vagrant provision obs`. **Never hand-edit `generated/grafana/dashboards/`**; templates are the source.

---

## 5. Chaos cookbook

Inject in one terminal; measure in another with `validation/monitor.sh <target-ip> [interval_s]` (reports running availability % and the longest outage gap in ms). Point it at a loopback (e.g. `10.0.4.1`, srv-1-1) reachable through the fabric.

```bash
# Terminal 1 — measure
bash validation/monitor.sh 10.0.4.1 1

# Terminal 2 — break things
make chaos-link-down ARGS="spine-1 leaf-1a"          # drop one link
make chaos-link-up   ARGS="spine-1 leaf-1a"          # restore

make chaos-latency   ARGS="spine-1 leaf-1a --delay 200ms --jitter 50ms"
make chaos-latency   ARGS="spine-1 leaf-1a --restore"

make chaos-loss      ARGS="spine-1 leaf-1a --loss 30%"
make chaos-loss      ARGS="spine-1 leaf-1a --restore"

make chaos-flap      ARGS="spine-1 leaf-1a --interval 5 --count 5"   # self-restores

make chaos-partition ARGS="rack-1"                   # isolate a rack (4 spine↔leaf links down)
make chaos-partition ARGS="rack-1 --restore"
```

What to expect: BFD drops the session in ~3 s, BGP reconverges over the surviving ECMP path; a single link/latency/loss event on one of two paths should keep availability ~100 % (the other path absorbs it). A rack partition makes that rack's servers unreachable from other racks until restored.

**Node kill.** `make chaos-kill` and `make nuke` derive the `NetWatch-main_<node>` prefix from the project-root basename:

```bash
make chaos-kill ARGS="spine-1"            # hard power-off via virsh destroy (lib.sh)
make chaos-kill ARGS="spine-1 --restore"  # virsh start + wait for SSH
```

The equivalent manual form still works if you prefer it:
```bash
virsh -c qemu:///system destroy NetWatch-main_spine-1     # hard kill
virsh -c qemu:///system start   NetWatch-main_spine-1     # restore
```

**Goal** (`topology.yml` §validation): >99 % availability over a 10-minute chaos run, max outage < 3 s.

---

## 5a. EVPN overlay validation

> **Status:** same-subnet L2-over-VXLAN is validated; inter-subnet IRB is a known limitation on a clean bring-up. The overlay carries real L2 traffic for same-subnet, cross-rack hosts at 0% loss: the peer ARP resolves to the remote server's real NIC MAC, and a leaf shows ~14 remote MACs learned on VNI 10000. The control plane for the distributed anycast IRB + symmetric L3VNI 10999 is built and verified (leaves learn remote MACs and Type-2 MAC/IP routes for the other tenant's hosts). Inter-subnet / inter-tenant routing through the distributed anycast gateway does not forward on a clean from-scratch bring-up (the gateway SVI does not answer ARP/ICMP for its own IP nor route between subnets); see [KNOWN-ISSUES.md](KNOWN-ISSUES.md). Same-subnet and underlay checks (steps 1-3, 5-7) pass; inter-subnet (steps 4, 4b) is the known limitation. See [ARCHITECTURE.md §5](ARCHITECTURE.md) for the design and constants.

**The overlay at a glance** (what you are validating):

| Tenant | L2VNI | Subnet | Anycast GW | Member servers (overlay IP) |
|---|---|---|---|---|
| tenant-a | 10000 | 10.99.0.0/24 | 10.99.0.1 | srv-1-1 (.11), srv-2-1 (.21), srv-3-1 (.31), srv-4-1 (.41) — all `tnt0` |
| tenant-b | 10001 | 10.99.1.0/24 | 10.99.1.1 | srv-4-1 (.41) — `tnt1` |

L3VNI **10999** / VRF **Tenant-A** provides inter-subnet routing; anycast MAC `00:00:5e:00:01:99` is identical on all 8 leaves.

**Prerequisite:** the overlay access ports are enslaved by the second `setup-evpn.sh` pass. If you ran the steps individually rather than `make up`, run it now (idempotent):

```bash
make overlay        # = setup-evpn.sh pass 2: enslaves eth-ovl/eth-ovl-b once tnt0 exists
```

**1. Control plane: VNIs and EVPN sessions are up on the leaves:**
```bash
vagrant ssh leaf-1a -c "sudo vtysh -c 'show evpn vni'"
#   expect VNI 10000 (L2), 10001 (L2), 10999 (L3, VRF Tenant-A)
vagrant ssh leaf-1a -c "sudo vtysh -c 'show bgp l2vpn evpn summary'"   # peers Established to both spines
vagrant ssh leaf-1a -c "sudo vtysh -c 'show evpn vni detail'"         # type/VRF/RD/RT per VNI
```

**2. The server is on the overlay segment (access NIC, tenant /24, no gateway leak):**
```bash
vagrant ssh srv-1-1 -c "ip -br addr show tnt0"          # 10.99.0.11/24, MTU 1450
vagrant ssh srv-1-1 -c "ip route show default"          # still ECMP via the two /30 fabric NICs — NOT via tnt0
```

**3. Same-subnet cross-rack reachability (the headline L2-over-VXLAN proof):**
```bash
# srv-1-1 (rack 1, 10.99.0.11) -> srv-2-1 (rack 2, 10.99.0.21), both tenant-a / VNI 10000:
vagrant ssh srv-1-1 -c "ping -c3 10.99.0.21"            # expect 0% loss
# the ARP neighbor for the peer resolves to srv-2-1's REAL NIC MAC (not the anycast GW MAC) —
# proof an L2 frame crossed VXLAN, this was NOT routed:
vagrant ssh srv-1-1 -c "ip neigh show 10.99.0.21 dev tnt0"   # lladdr = srv-2-1's tnt0 MAC, state REACHABLE
# and confirm the peer's MAC was learned REMOTELY (over VXLAN/Type-2) on srv-1-1's leaf:
vagrant ssh leaf-1a -c "sudo vtysh -c 'show evpn mac vni 10000'"   # ~14 MACs; peer shows type 'remote', via the peer leaf's VTEP IP
vagrant ssh leaf-1a -c "sudo vtysh -c 'show evpn arp-cache vni 10000'"
```
A `remote` MAC entry (pointing at the remote leaf's loopback as the VTEP), and a peer ARP entry that is the peer server's own NIC MAC, together prove the L2 frame crossed the **overlay**, not the routed underlay.

**4. Inter-subnet routing via symmetric IRB (anycast gateway + L3VNI 10999): KNOWN LIMITATION on a clean bring-up.**

> This does not succeed on a fresh from-scratch bring-up. The EVPN control plane below is correct (the ingress leaf learns the egress host's Type-2 MAC/IP route via the egress leaf's VTEP, and the L3VNI is programmed), but the data plane does not forward inter-subnet traffic: the anycast gateway SVI (the VRF-enslaved L2VNI bridge interface) does not answer ARP/ICMP for its own `.1` and does not route between subnets, even though the IP is present in VRF Tenant-A and `arp_ignore=0`. It was observed working on a long-lived instance, so it is a data-plane/state issue (suspected VRF-enslaved-bridge SVI behaviour on the Fedora 44 / kernel 7.x build). Things tried without success on a fresh build: putting the anycast IP+MAC on the bridge interface, toggling `neigh_suppress`, FRR restart, static GW neighbor priming. Same-subnet L2 (step 3) is unaffected. See [KNOWN-ISSUES.md](KNOWN-ISSUES.md).

```bash
# srv-4-1 has both tnt0 (10.99.0.41, tenant-a) and tnt1 (10.99.1.41, tenant-b).
# Intent: a tenant-a host -> a tenant-b host routed by the INGRESS leaf into VRF Tenant-A over L3VNI 10999.
# CONTROL PLANE — verified correct (the leaf has the route and the remote MAC/IP):
vagrant ssh leaf-3a -c "sudo vtysh -c 'show bgp l2vpn evpn route type macip'"   # Type-2 [2]...[10.99.1.41] via leaf-4a's VTEP
vagrant ssh leaf-3a -c "sudo vtysh -c 'show ip route vrf Tenant-A'"             # 10.99.1.0/24 resolved over the L3VNI
vagrant ssh leaf-1a -c "sudo vtysh -c 'show evpn mac vni 10001'"                # tenant-b MACs (srv-4-1's tnt1) learned remote
vagrant ssh leaf-1a -c "sudo vtysh -c 'show bgp l2vpn evpn route type prefix'"  # Type-5 (IP prefix, L3VNI)
# DATA PLANE — does NOT reliably pass on a fresh bring-up (this is the known limitation, NOT a passing step):
vagrant ssh srv-3-1 -c "ping -c3 10.99.1.41"           # 10.99.0.31 (tenant-a) -> 10.99.1.41 (tenant-b): currently fails on a clean build
```

**4b. Distributed anycast gateway (identical IP+MAC on every leaf): control plane built; data plane is the KNOWN LIMITATION above.**
```bash
# Every leaf is configured with the same gateway IP + MAC 00:00:5e:00:01:99 (the SVI is present in VRF Tenant-A):
vagrant ssh leaf-1a -c "ip -br addr show br-vni10000"  # 10.99.0.1/24 on the bridge interface (the IRB SVI), MAC 00:00:5e:00:01:99
# Reaching the anycast GW from a member does NOT reliably succeed on a fresh bring-up (the SVI does not answer for its own .1):
vagrant ssh srv-1-1 -c "ping -c3 10.99.0.1"            # tenant-a anycast GW — currently fails on a clean build (known limitation)
vagrant ssh srv-4-1 -c "ping -c3 10.99.1.1"            # tenant-b anycast GW — currently fails on a clean build (known limitation)
```

**5. Underlay regression: the overlay did NOT disturb the routed fabric:**
```bash
# Routed cross-rack loopback ping over the underlay is unaffected (e.g. srv-4-1's loopback):
vagrant ssh srv-1-1 -c "ping -c3 10.0.7.1"             # expect 0% loss
# The server default is still ECMP over its two /30 fabric NICs — NOT via tnt0:
vagrant ssh srv-1-1 -c "ip route show default"         # two nexthops (172.16.x), no tnt0
# The overlay supernet is NOT leaked into the underlay BGP (CONNECTED-FILTER denies it):
vagrant ssh spine-1 -c "vtysh -c 'show ip route 10.99.0.0/16'"   # not present in the underlay table
```

**6. On-the-wire VXLAN confirmation (optional, definitive):** capture UDP/4789 on the host fabric bridge a leaf VTEP egresses through while pinging across racks, and confirm the inner Ethernet frame is encapsulated with the expected VNI:
```bash
# e.g. spine-1<->leaf-1a underlay bridge (find it via `virsh domiflist NetWatch-main_leaf-1a`):
sudo tcpdump -ni br000 udp port 4789 -vv
```

**7. Metrics proof (Prometheus/Grafana):** the per-leaf collector exports the data-path counters every 15 s. On the live fabric these are non-zero. Query in Grafana/Prometheus, or open the **NetWatch — EVPN / VXLAN** dashboard (§4):
```promql
netwatch_evpn_mac_remote{vni="10000"}    # > 0 on leaves after cross-rack traffic = frames crossed the overlay
netwatch_evpn_mac_remote_total
netwatch_evpn_vni_info                    # presence/type/vrf per VNI (10000/10001 L2, 10999 L3)
```

If a VNI is missing or no remote MACs appear, allow BGP-EVPN to converge (~30 s after the FRR restarts), confirm `make overlay` ran after `make wire`, then re-check (see [§7](#7-troubleshooting)).

---

## 6. Changing the fabric (regenerate workflow)

```
edit topology.yml  ─►  make generate  ─►  re-provision / re-wire affected nodes
```

1. **Edit `topology.yml`:** the single source of truth (add a node, change an ASN, re-IP a link, retune timers).
2. **`make generate`:** re-renders `generated/**` and the 5 generated fabric scripts in `scripts/fabric/`.
3. **Apply:**
   - FRR config changes: `vagrant provision <node>` (re-rsyncs + recopies configs) or `make frr-restart`, or full `make vms` + `make up`.
   - Topology/link changes (new NICs/bridges): full `make down` → `make up` (or `make vms-destroy` → `make vms` → `make up` for node add/remove).
   - EVPN/overlay changes (`topology.yml` `evpn:` block: tenants, members, VNIs, anycast): re-render, re-provision the affected leaves for the FRR side, then re-run the datapath with `make evpn` and `make overlay` (the latter must run after `make wire` so the server access NICs exist). A full `make down` → `make up` does all of this in order.
   - Prometheus/Loki/Grafana/dnsmasq changes: `vagrant provision obs`.

### Golden rules

- **Never hand-edit anything in `generated/`.** It is overwritten by `make generate`.
- **Never hand-edit the generated fabric scripts:** `setup-bridges.sh`, `setup-frr-links.sh`, `setup-server-links.sh`, `status.sh`, `teardown.sh`. Fix the Jinja template in `generator/templates/scripts/` instead, then `make generate`.
- **Hand-maintained scripts are safe to edit directly:** `configure-*.sh` (including `configure-overlay-if.sh`), `setup-evpn.sh`, `configure-evpn-vtep.sh`, `evpn-metrics-collector.sh`, everything in `scripts/chaos/`, `scripts/bastion/`, `scripts/artifacts/`, the provision scripts, and `nuke.sh`.

When in doubt, check the top of the file: generated files carry a `DO NOT HAND-EDIT` banner.

---

## 7. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Inter-VM traffic dropped even though bridges are up | Docker `FORWARD DROP` on the host | `make hostfix` (run automatically by `make up`) |
| `make up` reports NIC/bridge failures | bridges missing, or a VM not running | re-run `make bridges`, confirm `virsh list` shows the domain running, then `make up` again |
| `make vms` fails with libvirt DHCP `no available address` (mgmt net) on a full destroy+recreate | a just-destroyed domain's old DHCP lease on `netwatch-mgmt` (`192.168.0.0/24`) hasn't been released yet, so libvirt thinks the pool is exhausted | transient: `vagrant reload bastion` (or the affected node) and/or retry `make vms`; the stale lease clears and the address is reassigned |
| `make fabric` hangs | `vagrant ssh` can't reach a VM over mgmt net | check `192.168.0.0/24` reachability; `vagrant ssh <node>` manually; there is no timeout on these calls |
| BGP neighbors stuck `Active`/`Connect` | fabric NIC not attached or no IP; FRR started before NICs | `vagrant ssh <node> -c "ip -br a"` to confirm `eth-*` IPs; `make fabric` re-runs attach+configure; `make frr-restart` |
| A node configured 0 fabric interfaces | udev hadn't renamed the hot-plugged NIC when `configure-*` ran (race) | re-run `make fabric` / `make wire` for that node |
| `make chaos-kill` / `make nuke` don't seem to touch the VMs | domain-name mismatch | both derive `NetWatch-main_<node>` automatically; confirm the domain name with `virsh -c qemu:///system list --all` |
| Grafana/Prometheus unreachable | tunnel/DNAT not set; obs not up | `make dashboard`, or `make bastion-dnat`; confirm `vagrant status obs` |
| EVPN "VNI not aware" right after `make up` | BGP-EVPN hadn't converged when the VNI check ran | `setup-evpn.sh` now gates on convergence, but allow ~30 s after the FRR restarts and re-run `make evpn`; check `vtysh -c 'show evpn vni'` |
| L2VNI 10000/10001 or L3VNI 10999 missing on a leaf | FRR restart hadn't ingested the kernel VNIs, or convergence pending | re-run `make evpn`; verify the kernel side with `vagrant ssh leaf-1a -c "ip -d link show vxlan10000"` and `bridge vlan show` |
| No `remote` MACs on VNI 10000 (overlay not carrying traffic) | overlay access NICs not enslaved (`make overlay` skipped, or run before `make wire`), or no cross-rack traffic yet | confirm order `wire` → `overlay`; check `vagrant ssh leaf-1a -c "ip link show eth-ovl"` is `master br-vni10000`; generate traffic (ping across racks), then `show evpn mac vni 10000` |
| Server `tnt0`/`tnt1` overlay NIC missing or no IP | overlay access NIC not attached/configured during `make wire` | re-run `make wire`; check `vagrant ssh srv-1-1 -c "ip -br addr show tnt0"` (expect the tenant /24, MTU 1450) |
| Server lost a path after reboot | ECMP routes not reapplied | the NM dispatcher should re-add them; otherwise re-run `make wire` |

Useful low-level checks:

```bash
virsh -c qemu:///system list --all | grep NetWatch-main      # domain states
virsh -c qemu:///system domiflist NetWatch-main_spine-1      # attached NICs/bridges
ip -br link show type bridge | grep -E 'br[0-9]{3}'          # host /30 fabric bridges (expect 54)
ip -br link show type bridge | grep -E 'br-ovl'             # host overlay bridges (expect 5)
vagrant ssh spine-1 -c "vtysh -c 'show bgp summary'"
vagrant ssh spine-1 -c "vtysh -c 'show bfd peers brief'"
vagrant ssh leaf-1a -c "sudo vtysh -c 'show evpn vni'"       # L2VNI 10000/10001 + L3VNI 10999
vagrant ssh leaf-1a -c "sudo vtysh -c 'show evpn mac vni 10000'"  # local + remote (over-VXLAN) MACs
vagrant ssh leaf-1a -c "ip link show eth-ovl"               # expect: master br-vni10000
```

---

## 8. Common one-liners

```bash
make help                                   # list every target with its description
make generate && make frr-restart           # push FRR config edits fast
for n in border-1 border-2 spine-1 spine-2; do vagrant ssh $n -c "vtysh -c 'show ip bgp summary'"; done
virsh -c qemu:///system domstate NetWatch-main_leaf-1a
bash validation/monitor.sh 10.0.4.1 1       # availability probe to srv-1-1's loopback
```
