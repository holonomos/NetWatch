# NetWatch — Runtime Errors Manifest (2026-03-25)

> Comprehensive list of every issue encountered during the first full bring-up.
> Each item includes: what happened, why, what fixed it, and what needs to
> change in the codebase to prevent it permanently.

---

## Systemic Issues (affect everything)

### S1. Docker nftables FORWARD DROP (THE recurring nightmare)

**What:** Docker sets `nft chain ip filter FORWARD policy drop` on the host. This blocks ALL forwarded traffic between VMs on different libvirt bridges.

**Affected flows:**
- mgmt → bastion → internet (DNS upstream forwarding)
- host → bastion → fabric (kubectl to k8s API)
- bake VM → internet (golden image build)
- Any traffic that crosses two libvirt bridges via the host kernel

**Hit count:** 3 times (bake, DNS, kubectl)

**Runtime fix:**
```bash
sudo nft insert rule ip filter FORWARD iifname "virbr1" accept
sudo nft insert rule ip filter FORWARD oifname "virbr1" accept
sudo nft insert rule ip filter FORWARD iifname "virbr2" accept
sudo nft insert rule ip filter FORWARD oifname "virbr2" accept
```

**Permanent fix needed:**
- Add `hostfix` target to `make up` (DONE in Makefile, but needs sudo)
- OR add a polkit rule that inserts these at boot
- OR document "disable Docker" as prerequisite (Docker is no longer used by NetWatch)
- OR create a systemd service that inserts these rules at boot

**Best fix:** Remove Docker entirely from the host. NetWatch no longer uses Docker. Docker's only contribution is breaking nftables FORWARD policy.

---

### S2. vagrant ssh PTY injects terminal escape sequences

**What:** `vagrant ssh <vm> -c "command"` allocates a PTY by default. stdout includes ANSI escape codes, carriage returns, and shell prompt sequences.

**Affected scripts:**
- setup-host-kubectl.sh (kubeconfig corrupted)
- join-agents.sh (token corrupted → "not authorized")
- Any script that captures vagrant ssh output into a variable

**Fix:** Use `vagrant ssh <vm> -- -T "command"` to disable PTY allocation. Add `| tr -d '\r'` to strip carriage returns. Add `| tr -d '[:cntrl:]'` for tokens.

**Codebase fix needed:** Audit EVERY `vagrant ssh` call that captures output. Add `-- -T` flag to all of them.

---

### S3. Bastion fabric routes never applied by setup-server-links.sh

**What:** configure-bastion-fabric.sh sets IPs correctly but `ip route replace` ECMP commands fail silently. Bastion has fabric IPs but no routes to 10.0.0.0/8 or 172.16.0.0/12.

**Hit count:** Every single `make up` run.

**Likely cause:** ECMP routes require ARP resolution of nexthop IPs (172.16.0.1, 172.16.0.5 — border routers). At the moment configure-bastion-fabric.sh runs, the border VMs may not have responded to ARP on the newly-attached interfaces.

**Workaround:**
```bash
vagrant ssh bastion -c "sudo bash -c '
ip route replace 10.0.0.0/8 nexthop via 172.16.0.1 dev ens7 weight 1 nexthop via 172.16.0.5 dev ens8 weight 1
ip route replace 172.16.0.0/12 nexthop via 172.16.0.1 dev ens7 weight 1 nexthop via 172.16.0.5 dev ens8 weight 1
'"
```

**Permanent fix needed:** Add retry logic with ARP check, or add a dedicated `make bastion-routes` fixup target that runs after `make wire` with a 5-second delay.

---

### S4. mgmt VM has no internet — upstream DNS fails

**What:** dnsmasq on mgmt forwards to 1.1.1.1/8.8.8.8 but mgmt has no internet path (mgmt_attach=false, no default route).

**Fix applied:** Added `ip route add default via 192.168.0.2` to provision-mgmt.sh (DONE).

**But:** Also requires S1 (nft FORWARD rules) to be applied on the host, otherwise bastion can't forward mgmt's traffic to the internet.

---

## k3s-Specific Issues

### K1. k3s bootstrap runs as background process, not systemd

**What:** bootstrap-server.sh started k3s with `k3s server ... &`. No systemd unit. Process dies on any error, no auto-restart, no `systemctl` management.

**Fix applied (manual):** Created /etc/systemd/system/k3s.service on srv-1-1 manually.

**Permanent fix needed:** bootstrap-server.sh must create a systemd unit, not run k3s in background. Same for join-agents.sh — agents should be systemd services too.

---

### K2. srv-1-1 OOMs as k3s control plane at 768MB

**What:** k3s server + containerd + kubelet + Cilium DaemonSet = ~500-600MB. On a 768MB VM, OOM kills k3s repeatedly. The process crash-loops, API becomes unreachable.

**Fix applied (manual):** Increased srv-1-1 RAM to 1.5GB via `virsh edit`.

**Permanent fix needed:** The Vagrantfile should give the k3s control plane node (srv-1-1) more RAM. Either:
- Hardcode srv-1-1 at 1536MB in Vagrantfile
- Or make the control plane node configurable

---

### K3. Cilium image pull takes 10+ minutes

**What:** 16 nodes simultaneously pulling ~200MB Cilium images through bastion NAT. Overwhelms the single exit point. helm install times out at 300s.

**Fix needed:** Pre-bundle Cilium + MetalLB container images in `artifacts/` directory. Import locally on each node before helm install:
```bash
vagrant ssh srv-X-Y -c "sudo k3s ctr images import -" < artifacts/cilium-images.tar
```

---

### K4. kubeconfig path collision

**What:** setup-host-kubectl.sh writes to ~/.kube/netwatch-config but also conditionally copies to ~/.kube/config. Overwrites existing kubeconfig or creates a bad copy.

**Fix needed:** Never write to ~/.kube/config. Always use ~/.kube/netwatch-config. Print export command. Consider a .envrc file.

---

### K5. kubectl requires KUBECONFIG export in every terminal

**What:** `export KUBECONFIG=~/.kube/netwatch-config` is lost when opening a new terminal.

**Fix needed:** Either:
- Add export to ~/.bashrc (invasive)
- Create a project .envrc (requires direnv)
- Print a reminder in every make target that uses kubectl
- Or symlink: `ln -sf ~/.kube/netwatch-config ~/.kube/config` (if no other clusters)

---

### K6. CNI not initialized loop (expected, not a bug)

**What:** All nodes show "NetworkPluginNotReady" until Cilium installs.

**Status:** Expected behavior with --flannel-backend=none. Not a bug.

---

### K7. k3s agent "not authorized" with mangled token

**What:** join-agents.sh fetched token via vagrant ssh -c which included PTY escape sequences. Agents failed authentication.

**Fix applied:** Added `-- -T` and `tr -d '[:cntrl:]'` to token fetch. (See S2)

---

## Operational Issues (make up flow)

### O1. make routes needs sudo

**What:** `sudo ip route replace 10.0.0.0/8 via 192.168.0.2` requires root. The Makefile target uses sudo but if the user doesn't have password-less sudo, it prompts mid-pipeline.

**Fix needed:** Document that `make up` requires sudo for the routes step. Or use a polkit rule to allow route modifications without sudo.

---

### O2. hostfix target needs sudo

**What:** nft insert rules require root.

**Same issue as O1.** Both `hostfix` and `routes` need sudo.

---

### O3. make up sequence doesn't verify connectivity

**What:** After `make wire`, there's no check that bastion can actually reach the fabric, that DNS works, or that the host can reach server loopbacks. Silent failures propagate to k3s-up.

**Fix needed:** Add a connectivity check step between `wire` and `routes`:
- ping bastion fabric nexthops
- dig a hostname from a server
- curl the k8s API if k3s is running

---

## Priority Fix Order

1. **S1** — Docker FORWARD DROP (add to boot-time systemd or remove Docker)
2. **K2** — srv-1-1 RAM (change Vagrantfile, rebuild one VM)
3. **K1** — k3s systemd units (rewrite bootstrap + join scripts)
4. **K3** — Pre-bundle Cilium/MetalLB images (create artifacts/ workflow)
5. **S2** — vagrant ssh PTY (audit all scripts, add -- -T)
6. **S3** — Bastion routes (add retry or fixup step)
7. **S4** — mgmt internet route (DONE in provision-mgmt.sh)
8. **K4/K5** — kubeconfig handling (cleanup script)
9. **O3** — Connectivity verification in make up
