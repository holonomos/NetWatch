# NetWatch — FRR VM Refactor Manifest

> Replace all 12 FRR Docker containers with Vagrant/libvirt VMs.
> Eliminates Docker as a dependency. Minimum spec: Linux + KVM + Vagrant + KSM.
>
> This is an architectural refactor, not a feature addition.

---

## Key Design Decisions

### 1. FRR VM base: Fedora (same golden image, not Alpine)
Install FRR into the existing `netwatch-golden.box`. One box serves all 30 VMs.
FRR RPM adds ~30-50MB. FRR daemons disabled by default, enabled only on FRR VMs.
Keeps everything on systemd — no OpenRC, no second init system, no second package manager.

### 2. Single Vagrantfile for all 30 VMs
One `vagrant up` brings up everything. Boot order: mgmt → FRR switches → bastion → servers.
FRR VMs defined between mgmt and bastion (the fabric must exist before anything connects to it).

### 3. FRR configs via rsync synced folders
Each FRR VM gets `generated/frr/<node-name>` synced to `/tmp/netwatch-config/frr/`.
Provisioner copies to `/etc/frr/`. Same pattern as mgmt VM.

### 4. Host bridges stay as-is
`setup-bridges.sh` still creates raw Linux bridges via `ip link add`. Libvirt networks
add DHCP/iptables/dnsmasq overhead we don't want on P2P fabric links.

### 5. Interface naming via udev rules
**This is the biggest gotcha.** Docker containers had explicit interface names (`eth-spine-1`).
VMs get kernel-assigned names (`ens6`, `ens7`). FRR configs reference `eth-*` names.
Fix: generate udev rules per node that rename interfaces by MAC address.
Rules written during Vagrant provisioning, before NICs are attached.

---

## Resource Budget (minimum spec: 8 threads, 16-32GB RAM)

```
Memory (KSM enabled):
  12 FRR VMs × 256 MB allocated        = 3,072 MB raw → ~922 MB effective
  16 Server VMs × 512 MB allocated      = 8,192 MB raw → ~2,294 MB effective (idle)
  Bastion (512 MB) + Mgmt (1024 MB)     = 1,536 MB
  QEMU overhead (30 × 15 MB)            = 450 MB
  Total effective at idle:               ~5.2 GB
  16 GB host: ~10.8 GB free
  32 GB host: ~26.8 GB free

CPU (steady state):
  30 VMs mostly sleeping                 ~2.3 cores (~29% of 8 threads)
  Peak during chaos convergence          ~3.6 cores (~45%) for ~5 seconds

BFD safety:
  31 vCPUs on 8 threads, CFS worst case: 96ms jitter
  BFD detection window: 3000ms (1000ms × 3)
  Noise: 3.2% — will never false-flap
```

---

## Phase R0 — Preparation

- [ ] **R0.01** Verify KSM enabled: `cat /sys/kernel/mm/ksm/run` → 1
- [ ] **R0.02** Snapshot current state: `git tag pre-vm-refactor`
- [ ] **R0.03** Verify FRR RPM availability for Fedora 43
      Check `https://rpm.frrouting.org/repo/` for Fedora 43 packages.
      Fallback: RHEL 9 RPM (often compatible) or build from source.
      ```bash
      # Test inside a VM:
      sudo dnf config-manager --add-repo https://rpm.frrouting.org/repo/frr-stable-repo-1-0.el9.noarch.rpm
      sudo dnf info frr
      ```

---

## Phase R1 — Golden Image Update

- [ ] **R1.01** Extend `bake-golden-image.sh` to install FRR
      Add FRR stable repo, install `frr frr-pythontools`.
      Add frr_exporter systemd unit (disabled by default).
      Verify: `vtysh --version` inside bake VM.

- [ ] **R1.02** Disable FRR services by default
      `systemctl disable frr` — enabled only on FRR VMs at provision time.
      Ensure `/etc/frr/` exists with correct ownership (`frr:frr`).

- [ ] **R1.03** Rebuild golden image
      ```bash
      bash scripts/bake-golden-image.sh
      vagrant box add --name netwatch-golden netwatch-golden.box --force
      ```

- [ ] **R1.04** Verify FRR in golden image
      Boot a throwaway VM, confirm: `vtysh --version`, `systemctl list-unit-files | grep frr`,
      `/usr/local/bin/frr_exporter --version`.

**Gotcha — FRR RPM version:** Docker image uses Alpine FRR 9.1.0. Fedora RPM may be a
different patch level. FRR config syntax is stable across 9.1.x — verify generated
`frr.conf` files work with the Fedora build.

**Gotcha — Docker/libvirt FORWARD conflict:** Same as before when baking. Must insert
nft FORWARD accept rules for virbr1 before the bake VM can reach the internet.

---

## Phase R2 — topology.yml Update

- [ ] **R2.01** Change FRR node type: `frr-container` → `frr-vm`
      Add `vcpu: 1` and `memory_mb: 256` to all 12 FRR nodes.

- [ ] **R2.02** Add server loopback IPs
      Each server gets a `/32` loopback (e.g., `10.0.4.x` for rack-1, `10.0.5.x` for rack-2, etc.).
      Add `loopback:` field to server node definitions.

- [ ] **R2.03** Update header comments
      "30 VMs: 12 FRR + 16 server + 1 bastion + 1 mgmt. No Docker."

- [ ] **R2.04** Remove `FRR_IMAGE` from `repo/versions.env`
      No longer pulling a Docker image. Keep FRR version pinned for the RPM.

---

## Phase R3 — Generator Refactor

- [ ] **R3.01** Update `generate.py`: change all `frr-container` → `frr-vm`
      Affects node type checks in link registry, BGP neighbor detection, Prometheus context,
      FRR config rendering, bridge context, stats.

- [ ] **R3.02** Add deterministic MAC generation for FRR fabric interfaces
      Each FRR VM's fabric NICs need explicit MACs for `virsh attach-interface`.
      Extend the MAC scheme: `02:4E:57:TT:PP:II` where PP = peer index.
      Must not collide with server fabric MACs (`02:4E:57:06:XX:YY`).

- [ ] **R3.03** Generate udev rules per FRR node
      New output: `generated/frr/<node>/70-netwatch-fabric.rules`
      Maps MAC → interface name (`eth-spine-1`, `eth-leaf-1a`, etc.)
      Preserves existing `frr.conf` interface naming convention.

- [ ] **R3.04** Delete `setup-frr-containers.sh.j2`, create `setup-frr-links.sh.j2`
      New template uses `attach_nic` + `configure_frr` pattern (virsh + vagrant ssh).
      Same architecture as `setup-server-links.sh`.

- [ ] **R3.05** Create `configure-frr-fabric.sh`
      Runs inside FRR VM. Accepts: loopback IP + variable-length MAC/IP/prefix triplets.
      Configures interfaces, loopback, sysctls. Restarts FRR + frr_exporter.
      Writes NetworkManager profiles for IP persistence.

- [ ] **R3.06** Rewrite `teardown.sh.j2`
      `docker rm -f` → `virsh -c qemu:///system shutdown NetWatch_<node>`
      Remove veth cleanup (VMs use tap devices, managed by libvirt).

- [ ] **R3.07** Rewrite `status.sh.j2`
      `docker inspect` → `virsh -c qemu:///system domstate`
      `docker exec vtysh` → `vagrant ssh <node> -c "sudo vtysh ..."`

- [ ] **R3.08** Update `generate.py` render_templates to produce new scripts
      Register `setup-frr-links.sh.j2` template. Remove `setup-frr-containers.sh.j2`.

- [ ] **R3.09** Regenerate all configs
      `python3 generator/generate.py`
      Verify: `grep -r "docker" scripts/fabric/ generated/` → zero results.

---

## Phase R4 — Vagrantfile Rewrite

- [ ] **R4.01** Add `define_frr_switch` helper
      ```ruby
      def define_frr_switch(config, name, mgmt_ip, frr_config_dir)
        # 256MB, 1 vCPU, netwatch-mgmt network
        # Synced folder: generated/frr/<name> → /tmp/netwatch-config/frr
        # Provisioner: copy FRR configs, udev rules, enable FRR + frr_exporter
      end
      ```

- [ ] **R4.02** Add 12 FRR VM definitions (after mgmt, before bastion)
      Boot order: mgmt → FRR switches → bastion → servers.
      The fabric switches must be running before anything connects to them.

- [ ] **R4.03** Write udev rules during provisioning
      The provisioner copies `generated/frr/<node>/70-netwatch-fabric.rules` to
      `/etc/udev/rules.d/` and reloads udev. This ensures that when `setup-frr-links.sh`
      later attaches a NIC, it gets the correct name automatically.

- [ ] **R4.04** FRR service start timing
      Provisioner enables FRR but it starts with only loopback + mgmt interfaces.
      After `setup-frr-links.sh` attaches fabric NICs and configures IPs,
      it restarts FRR so BGP sessions come up on the new interfaces.

- [ ] **R4.05** Validate: `ruby -c Vagrantfile`

---

## Phase R5 — Wiring Scripts

- [ ] **R5.01** Create `scripts/fabric/configure-frr-fabric.sh`
      Variable-length argument handling for N fabric interfaces.
      Writes NetworkManager profiles for persistence.

- [ ] **R5.02** Verify `setup-frr-links.sh` generated output
      Bridge attachment, MAC lookup, IP assignment, FRR restart.
      Test on one FRR node (e.g., border-1 with 3 interfaces: 2 spine + 1 bastion).

- [ ] **R5.03** Update `setup-server-links.sh` for server loopbacks
      Configure `/32` loopback IP on each server's `lo` interface.
      Write NM profile for loopback persistence.
      Add static routes on leaf switches pointing loopbacks to server /30 IPs.

- [ ] **R5.04** Update `Makefile`
      `fabric:` target runs `setup-frr-links.sh` instead of `setup-frr-containers.sh`.
      `vms:` target includes FRR VMs in boot sequence.
      Add `frr-restart:` target.

---

## Phase R6 — Chaos Script Updates

- [ ] **R6.01** Rewrite `node-kill.sh`
      `docker stop/start` → `virsh destroy/start`
      After restore: re-run configure script for that node (IPs, FRR restart).

- [ ] **R6.02** Update `lib.sh`
      Rename `FRR_CONTAINERS` → `FRR_NODES`.
      Remove any Docker references.

- [ ] **R6.03** Verify bridge-based chaos scripts still work
      `link-down.sh`, `link-flap.sh`, `latency-inject.sh`, `packet-loss.sh`, `rack-partition.sh`
      — all operate on bridges/veths, not containers. Should work with tap devices.
      Verify: `tc qdisc show dev vnetX` after latency injection.

---

## Phase R7 — Teardown and Nuke

- [ ] **R7.01** Rewrite `teardown.sh` (generated from template)
      Halt FRR VMs gracefully. Remove bridges. No Docker references.

- [ ] **R7.02** Rewrite `nuke.sh`
      Destroy FRR VMs via virsh. Detach all fabric NICs from all VMs.
      Remove bridges. Prune vagrant state.
      Remove Docker container/image references.

---

## Phase R8 — Logging

- [ ] **R8.01** Verify FRR logs flow to Loki via rsyslog
      FRR logs to syslog (`log syslog informational` in frr.conf).
      COMMON_CLIENT configures rsyslog forwarding to mgmt:514.
      Promtail on mgmt reads `/var/log/remote.log`.
      No Docker Loki driver needed.

- [ ] **R8.02** Remove Docker Loki driver setup from bake script
      Delete the `docker plugin install grafana/loki-docker-driver` section.

---

## Phase R9 — IP Persistence

- [ ] **R9.01** FRR VMs: NetworkManager profiles for fabric interfaces
      `configure-frr-fabric.sh` writes `/etc/NetworkManager/system-connections/fabric-*.nmconnection`
      for each fabric interface. IPs survive reboot.

- [ ] **R9.02** Server VMs: NetworkManager profiles for fabric interfaces
      `configure-vm-fabric.sh` writes NM connection profiles.
      ECMP routes and default route configured via NM routing rules.

- [ ] **R9.03** Server loopback persistence
      Loopback IP configured via NM keyfile on `lo`.

- [ ] **R9.04** Verify: reboot a server VM, confirm fabric IPs and routes survive
      ```bash
      vagrant reload srv-1-1
      vagrant ssh srv-1-1 -c "ip route show default"
      # Should still show ECMP through both leafs
      ```

---

## Phase R10 — Integration Testing

- [ ] **R10.01** Clean slate test
      `make nuke && vagrant destroy -f`
      `vagrant box add --name netwatch-golden netwatch-golden.box --force`
      `python3 generator/generate.py`

- [ ] **R10.02** Full boot sequence
      `vagrant up mgmt`
      `vagrant up border-1 border-2 spine-1 spine-2 leaf-{1..4}{a,b}`
      `vagrant up bastion`
      `vagrant up`

- [ ] **R10.03** Wire fabric
      `make up` (bridges + FRR wiring + server wiring)

- [ ] **R10.04** Status check: `make status` → all checks pass

- [ ] **R10.05** BGP verification
      `vagrant ssh spine-1 -c "sudo vtysh -c 'show bgp summary'"` → 10 peers Established

- [ ] **R10.06** North-south verification
      `vagrant ssh srv-1-1 -c "traceroute -n 8.8.8.8"` → full Clos path

- [ ] **R10.07** East-west verification
      `vagrant ssh srv-1-1 -c "traceroute -n 172.16.6.26"` → leaf-spine-leaf (no hairpin)

- [ ] **R10.08** Observability verification
      30/30 Prometheus targets UP. FRR VMs export both frr_exporter (9342) AND node_exporter (9100).

- [ ] **R10.09** Chaos verification
      Kill spine-1 via `bash scripts/chaos/node-kill.sh spine-1`.
      Restore. Verify BGP re-establishes.

- [ ] **R10.10** Docker independence verification
      ```bash
      sudo systemctl stop docker
      make status
      # Everything should still work
      ```

- [ ] **R10.11** Reboot persistence verification
      ```bash
      vagrant halt srv-1-1 && vagrant up srv-1-1
      vagrant ssh srv-1-1 -c "ip route show default"
      # Fabric IPs and routes survive
      ```

---

## Phase R11 — Documentation

- [ ] **R11.01** Update MEMORY.md — remove Docker references, update architecture
- [ ] **R11.02** Update manifest.md — remove Docker from P0 prerequisites
- [ ] **R11.03** Update docs/ — architecture.md, reference.md, current_state
- [ ] **R11.04** Remove dead code
      - `generator/templates/scripts/setup-frr-containers.sh.j2`
      - `scripts/repo/build-repo.sh`, `scripts/repo/serve-repo.sh`
      - `scripts/provision-extras.sh`
      - `repo/fedora/` directory
- [ ] **R11.05** Update README quick start — no Docker in prerequisites

---

## Risk Summary

| Risk | Severity | Mitigation |
|------|----------|------------|
| **Interface naming (ensX vs eth-peer)** | CRITICAL | udev rules generated per node, written during provisioning |
| **FRR RPM unavailable for Fedora 43** | High | Fallback: RHEL 9 RPM or source build |
| **IPs lost on VM reboot** | High | NetworkManager connection profiles (R9) |
| **FRR starts before fabric NICs attached** | Medium | FRR handles missing interfaces; restart after wiring |
| **node-kill restore needs IP reconfig** | Medium | NM profiles persist IPs; re-run configure script as backup |
| **30 VMs boot time** | Low | Parallel boot, FRR VMs are lightweight |

---

## Progress Summary

| Phase | Description | Est. Time |
|-------|-------------|-----------|
| R0 | Preparation | 30 min |
| R1 | Golden image update | 2 hrs |
| R2 | topology.yml | 15 min |
| R3 | Generator refactor | 3 hrs |
| R4 | Vagrantfile rewrite | 2 hrs |
| R5 | Wiring scripts | 2 hrs |
| R6 | Chaos updates | 1 hr |
| R7 | Teardown/nuke | 30 min |
| R8 | Logging | 15 min |
| R9 | IP persistence | 1 hr |
| R10 | Integration testing | 2 hrs |
| R11 | Documentation | 1 hr |
| **Total** | | **~15 hrs** |
