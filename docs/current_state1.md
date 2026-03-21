# NetWatch — Session State (2026-03-20)

## What we accomplished

### Golden Image (netwatch-golden.box)
Built a fully-loaded Vagrant box so VMs never install anything at boot. The previous session's agent had built a local RPM mirror with an HTTP server (build-repo.sh, serve-repo.sh) — completely wrong approach. We nuked that and baked a golden image instead.

**How it works:**
1. `scripts/bake-golden-image.sh` boots a temp VM from `fedora_43.box`
2. Installs all RPMs, k3s binary, observability binaries (node_exporter, frr_exporter, promtail, loki, prometheus, grafana)
3. Creates systemd units (all disabled), config directories, sysctls
4. Cleans up, halts, `vagrant package` → `netwatch-golden.box` (1.1GB)

**RPMs baked in:** chrony, rsyslog, conntrack-tools, container-selinux, ethtool, ipset, socat, iproute-tc, nfs-utils, python3, python3-libselinux, policycoreutils, audit, iptables-services, dnsmasq, logrotate, bash-completion, + debug tools (curl, wget, jq, vim, tmux, htop, tcpdump, traceroute, mtr, etc.)

**Binaries baked in:** k3s v1.31.4+k3s1 (+kubectl/crictl/ctr symlinks), node_exporter 1.7.0, frr_exporter 1.10.1, promtail 2.9.3, loki 2.9.3, prometheus 2.47.0, grafana 10.0.3

**Versions pinned in:** `repo/versions.env` (added K3S_VERSION)

### Gotchas discovered during bake
1. **Docker/libvirt forward conflict:** Docker sets nftables FORWARD policy to DROP, blocking libvirt NAT. Must insert `sudo nft insert rule ip filter FORWARD iifname "virbr1" accept` before baking. The bake script handles this but sudo may fail silently without a TTY.
2. **virt-sysprep needed:** `vagrant package` requires `virt-sysprep` from `guestfs-tools`. Had to `sudo dnf install -y guestfs-tools`.
3. **virt-sysprep mislabels binaries:** Sets SELinux context on `/usr/local/bin/*` to `user_tmp_t` instead of `bin_t`. Systemd can't exec them. Fix: `restorecon -R /usr/local/bin` — added to Vagrantfile COMMON_BASE.

### Vagrantfile Rewrite
Rewrote from 448 lines (mixed install+config) to 173 lines (config only).

**Structure:**
- `COMMON_BASE` (all 18 VMs): DNS resolv.conf, NM dns=none override, sysctl activation, SELinux restorecon, enable node_exporter, add static IP as secondary address
- `COMMON_CLIENT` (servers + bastion): chrony client → 192.168.0.3, rsyslog forwarding → 192.168.0.3:514
- **mgmt** (2048MB/2cpu): defined first for boot order, 4 synced folders (prometheus, loki, grafana, dnsmasq), delegates to `scripts/provision-mgmt.sh`
- **bastion** (384MB/1cpu): COMMON_BASE + COMMON_CLIENT + IP forwarding + NAT masquerade, `mgmt_attach = true`
- **servers** (768MB/1cpu × 16): COMMON_BASE + COMMON_CLIENT, that's it

**Resource changes from original:**
- Servers: 512 → 768 MB (k3s needs it at P7)
- Bastion: 512 → 384 MB (lightweight NAT box)
- Mgmt: 1024 → 2048 MB (Prometheus + Grafana + Loki headroom)
- Total: 14.7GB allocated, ~9.8GB effective with KSM

### provision-mgmt.sh (new file)
External script for mgmt VM configuration:
- Copies generated configs from synced folders to final paths
- Disables systemd-resolved (conflicts with dnsmasq on port 53)
- Writes chrony server config (stratum 10, allows 192.168.0.0/24)
- Writes rsyslog receiver config (UDP+TCP on 514)
- Writes promtail config
- Writes Grafana provisioning YAML (datasources + dashboard provider)
- Configures logrotate for /var/log/remote.log
- Enables all services in dependency order

### dnsmasq changes
Changed from DHCP+DNS to DNS-only. Reason: we enabled libvirt DHCP (`libvirt__dhcp_enabled: true`) on the netwatch-mgmt network so Vagrant can discover VM IPs. Having two DHCP servers on the same network would conflict. dnsmasq now only serves DNS (30 A records for *.netwatch.lab).

### Prometheus alerts.yml fix
The `HighBGPConvergenceTime` alert had a broken expression: `changes(frr_bgp_peer_state)` — `changes()` requires a range vector but got an instant vector. `promtool check` passes it (too lenient) but Prometheus fails at runtime. Replaced with `BGPSessionFlapping`: `changes(frr_bgp_peer_state[10m]) > 3`.

### Grafana node-detail dashboard fix
All panels used `nodename="$node"` filter but node_exporter metrics only have `instance` label, not `nodename`. Changed variable query to `label_values(up{job="node"}, instance)` and all panel expressions to `instance="$node"`. Also fixed Grafana 10.x templating format (datasource object format, empty current, refresh/sort fields).

### Static IP issue
With `mgmt_attach=false` + `libvirt__dhcp_enabled=true`, VMs get random DHCP IPs from libvirt. Vagrant can't reconfigure the IP on the same NIC it SSH'd in on. Fix: Vagrantfile adds static IP as secondary address (`ip addr add <ip>/24 dev ens5`) in the provisioner. Both DHCP and static IPs coexist on ens5.

### Fabric scripts — sudo removal
All scripts updated to use `sudo` internally only for commands that need root (`ip link`, `nsenter`). Docker and virsh work as the regular user (docker group membership + qemu:///system). No script needs to be run with `sudo` on the outside.

**Changed files:**
- `scripts/fabric/setup-bridges.sh` — `sudo ip link add/set`, `sudo bash -c 'echo 0 > stp_state'`
- `scripts/fabric/setup-frr-containers.sh` — `sudo ip link`, `sudo nsenter`
- `scripts/fabric/setup-server-links.sh` — `virsh -c qemu:///system` (no sudo), `vagrant ssh` instead of raw SSH
- `scripts/fabric/teardown.sh` — `sudo ip link set/del`
- All corresponding `.j2` templates updated to match

### setup-server-links.sh rewrite
Old approach: raw SSH with `$PROJECT_ROOT/.vagrant/machines/$vm/libvirt/private_key` — key file doesn't exist (Vagrant stores keys differently now). Also `set -e` killed the script at the first failure.

New approach: `vagrant ssh "$vm" -c "sudo bash -s"` for guest-side config, `virsh -c qemu:///system` for NIC attachment. Changed `set -euo pipefail` to `set -uo pipefail` (no exit-on-error, so all 16 servers get processed even if one fails).

**Two-pass reality:** NIC attachment (`virsh attach-interface`) and IP configuration (`vagrant ssh`) both work as regular user now, but if running the script fresh, you get one `sudo` prompt for the first `ip link` operation and then sudo caches the password for subsequent calls.

### topology.yml cleanup
- Removed obsolete `local_repo` section (lines 20-30, referenced dead HTTP server)
- Updated memory values: servers 768, bastion 384, mgmt 2048

### docs updated
- `docs/reference.md` — memory values
- `docs/coh1.md` — memory values
- `docs/manifest.md` — complete rewrite reflecting golden image approach, actual progress, all gotchas

### Makefile (new file)
Entry point for all operations:
```
make up          # bridges + FRR + server wiring
make down        # teardown fabric
make status      # health check
make vms         # boot all 18 VMs
make dashboard   # SSH tunnel to Grafana
make generate    # regenerate configs
make help        # list all commands
```

## Current state

### What's running
- 18/18 VMs: all running (golden image, config-only provisioning)
- 12/12 FRR containers: all running, fabric wired
- 52/52 bridges: all up, STP disabled
- 20/20 BGP sessions: all Established
- 10/10 BFD sessions: all Up (1000ms dilated timers)
- 30/30 Prometheus targets: all UP
- Grafana: live dashboards, node-detail working
- DNS: all 30 hostnames resolving
- Server data-plane: all 16 servers dual-homed with ECMP

### Phase status
- P0 Environment: DONE
- P1 Scaffold: DONE
- P2 Generator: DONE
- P3 Golden image + core lab: DONE
- P4 Routing: DONE
- P5 Observability: DONE
- P6 Chaos: not started
- P7 Validation: not started

### Files changed this session
```
NEW:
  scripts/bake-golden-image.sh
  scripts/provision-mgmt.sh
  netwatch-golden.box (1.1GB, registered as vagrant box)
  Makefile
  docs/current_state1.md

REWRITTEN:
  Vagrantfile (448 → 173 lines)
  docs/manifest.md (complete rewrite)

MODIFIED:
  repo/versions.env (added K3S_VERSION)
  topology.yml (removed local_repo, updated memory values)
  generated/dnsmasq/dnsmasq.conf (DNS-only, removed DHCP)
  generated/prometheus/alerts.yml (fixed broken expression)
  generated/grafana/dashboards/node-detail.json (fixed instance label + templating)
  scripts/fabric/setup-bridges.sh (internal sudo)
  scripts/fabric/setup-frr-containers.sh (internal sudo, frr_exporter from tarball)
  scripts/fabric/setup-server-links.sh (vagrant ssh, internal sudo, no set -e)
  scripts/fabric/teardown.sh (internal sudo)
  generator/templates/dnsmasq/dnsmasq.conf.j2 (DNS-only)
  generator/templates/scripts/setup-bridges.sh.j2 (internal sudo)
  generator/templates/scripts/setup-frr-containers.sh.j2 (internal sudo, frr_exporter tarball)
  generator/templates/scripts/setup-server-links.sh.j2 (vagrant ssh, virsh qemu:///system)
  docs/reference.md (memory values)
  docs/coh1.md (memory values)

OBSOLETE (still exist but no longer used):
  scripts/repo/build-repo.sh
  scripts/repo/serve-repo.sh
  scripts/provision-extras.sh
  repo/fedora/ (RPM mirror directory)
```

### Known issues / TODO for next session
1. **Golden image rebuild needed:** should bake in dnf-makecache disable + systemd-resolved disable + restorecon fix (currently done at provision time)
2. **setup-server-links.sh two-pass:** works but first run triggers a sudo prompt mid-script for ip link. Not broken, just not seamless.
3. **Stale repo/ directory:** `repo/fedora/` and `repo/binaries/` still exist from the old approach. The binaries are still useful (frr_exporter tarball used by setup-frr-containers.sh). The RPM mirror in `repo/fedora/` is dead weight.
4. **Old scripts still exist:** `scripts/repo/build-repo.sh`, `scripts/repo/serve-repo.sh`, `scripts/provision-extras.sh` are obsolete. Archive or delete.
5. **EVPN next-hop-unchanged on border-facing spine sessions:** harmless but unnecessary (known issue #8)
6. **nginx anti-affinity topologyKey:** uses hostname, should use rack label (known issue #5, fix at P7)
