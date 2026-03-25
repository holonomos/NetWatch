# NetWatch — First Run Issues (2026-03-25)

## 1. Bastion fabric routes not applied by setup-server-links.sh

**Symptom:** After `make up`, bastion has fabric IPs (172.16.0.2/30, 172.16.0.6/30) but NO routes to 10.0.0.0/8 or 172.16.0.0/12. Host can't reach k8s API (10.0.4.1:6443) via bastion.

**Root cause:** `configure-bastion-fabric.sh` runs via subshell + file redirect in setup-server-links.sh. The `ip route replace` ECMP commands likely fail because the nexthop IPs (border routers on 172.16.0.1/172.16.0.5) aren't ARP-resolvable at the moment the script runs. The `ip addr add` succeeds (local operation), but `ip route replace` with nexthops requires the gateway to respond to ARP.

**Workaround:** Manually apply routes after `make up`:
```bash
vagrant ssh bastion -c "sudo bash -c '
ip route replace 10.0.0.0/8 nexthop via 172.16.0.1 dev ens7 weight 1 nexthop via 172.16.0.5 dev ens8 weight 1
ip route replace 172.16.0.0/12 nexthop via 172.16.0.1 dev ens7 weight 1 nexthop via 172.16.0.5 dev ens8 weight 1
'"
```

**Fix needed:** Add ARP wait/retry logic to configure-bastion-fabric.sh, or add a post-wire fixup step that verifies bastion routes. Alternatively, move bastion route setup to a later step when borders are guaranteed reachable.

**Status:** Workaround applied. Root cause NOT fixed.

---

## 2. kubeconfig control characters from vagrant ssh

**Symptom:** `kubectl get nodes` fails with "yaml: control characters are not allowed". kubeconfig from `vagrant ssh -c "sudo cat ..."` contains terminal escape sequences.

**Root cause:** vagrant ssh allocates a PTY by default, injecting ANSI escape codes into stdout.

**Fix applied:** Changed `setup-host-kubectl.sh` to use `vagrant ssh "$VM" -- -T "sudo cat ..."` (disables PTY) + `tr -d '\r'` to strip carriage returns.

**Residual issue:** The script has a branch that copies to `~/.kube/config` if no existing kubeconfig exists. If this runs before the `-T` fix, the bad file persists. User must `rm ~/.kube/config` and `export KUBECONFIG=~/.kube/netwatch-config`.

**Status:** Fixed in code. Residual bad file must be cleaned manually on first run.

---

## 3. k3s CNI not ready loop (expected)

**Symptom:** All nodes show "NetworkPluginNotReady: cni plugin not initialized" in a loop.

**Root cause:** Expected. k3s started with `--flannel-backend=none`. Nodes stay NotReady until Cilium installs.

**Status:** Not a bug. Clears when Cilium pods reach Running state.

---

## 4. k3s agent join "not authorized"

**Symptom:** Agents fail with "failed to retrieve configuration from server: not authorized" in a loop.

**Root cause:** Join token fetched via `vagrant ssh -c` included terminal escape sequences (same PTY issue as #2). The token was mangled, so agents couldn't authenticate.

**Fix applied:** Changed `join-agents.sh` to use `vagrant ssh "$VM" -- -T` and `tr -d '[:space:][:cntrl:]'` to strip all control characters.

**Status:** Fixed in code.

---

## 5. Cilium image pull takes 10+ minutes (unacceptable for UX)

**Symptom:** `helm install cilium` times out at 300s. Cilium pods stuck in `Init:0/6` and `ContainerCreating` for 10+ minutes. Images (~200MB per node) pulled from quay.io via fabric → bastion → internet path.

**Root cause:** 16 nodes simultaneously pulling ~200MB images through a single bastion NAT. Total bandwidth: ~3.2GB of image data flowing through bastion.

**Impact:** First-time deployment takes 10-15 minutes just for Cilium. Unacceptable for a tool that's supposed to "just work."

**Solution needed:** Pre-download Cilium container images and bundle them with the project. On `make k3s-up`, import images locally on each node BEFORE helm install. No internet pull, instant install.

**Approach:**
1. Create `artifacts/` directory in project root
2. On the developer machine: `docker pull quay.io/cilium/cilium:v1.16.x && docker save > artifacts/cilium.tar`
3. Also save: cilium-operator, cilium-envoy images
4. During `make k3s-up`, before helm install: distribute tars to all nodes via `k3s ctr images import`
5. helm install finds images already cached — instant pod creation

**Same approach for MetalLB images** — pre-download and bundle.

**Status:** Not fixed. Cilium currently pulls from internet on first install.

---

## 6. kubeconfig default path collision

**Symptom:** `setup-host-kubectl.sh` writes to `~/.kube/netwatch-config` but also conditionally copies to `~/.kube/config`. If the user already has a kubeconfig (e.g., from minikube, cloud k8s), it gets overwritten. If it doesn't exist, the bad copy (pre-PTY-fix) becomes the default.

**Fix needed:** NEVER write to `~/.kube/config`. Always use `~/.kube/netwatch-config`. Print the export command for the user to run. Add `export KUBECONFIG=~/.kube/netwatch-config` to project-level shell init or Makefile.

**Status:** Script needs update. For now, always use `export KUBECONFIG=~/.kube/netwatch-config`.

---

## 7. mgmt VM has no internet — upstream DNS forwarding fails

**Symptom:** Servers can't resolve external hostnames (`registry-1.docker.io`). DNS queries go to mgmt dnsmasq (192.168.0.3) which forwards to `1.1.1.1`/`8.8.8.8`, but responses never come back. Cilium image pulls stuck forever.

**Root cause:** mgmt VM has `mgmt_attach=false` — no direct internet. dnsmasq forwards upstream queries but mgmt has no route to the internet. Added `ip route add default via 192.168.0.2` (bastion) to provision-mgmt.sh.

**But that wasn't enough** — even with the route, pings to `8.8.8.8` from mgmt timed out.

**Actual root cause:** Docker's nftables `FORWARD policy drop` on the HOST. Traffic path: mgmt → virbr1 (mgmt bridge) → bastion VM → virbr2 (vagrant NAT bridge) → internet. The HOST kernel forwards packets between the bridges, but Docker's FORWARD DROP blocks it.

**Fix applied (runtime):**
```bash
sudo nft insert rule ip filter FORWARD iifname "virbr1" accept
sudo nft insert rule ip filter FORWARD oifname "virbr1" accept
sudo nft insert rule ip filter FORWARD iifname "virbr2" accept
sudo nft insert rule ip filter FORWARD oifname "virbr2" accept
```

**Permanent fix needed:** Add these nft rules to `make up` or a host setup step. This is the SAME Docker/libvirt conflict that broke the golden image bake. It affects ANY traffic that traverses two different libvirt bridges through the host kernel. Must be documented as a system prerequisite or automated.

**Affected flows:**
- mgmt → bastion → internet (DNS upstream forwarding)
- server → leaf → spine → border → bastion → internet (north-south, if server hits host bridge)
- Any inter-bridge traffic on the host

**Status:** Runtime fix applied. Permanent fix NOT in codebase.

---

## 8. Docker FORWARD DROP — recurring systemic issue

**This is the third time this has bitten us:**
1. Golden image bake — bake VM can't reach internet (fixed with nft rules in bake script)
2. First run — mgmt can't forward DNS upstream (fixed manually, added to provision-mgmt.sh)
3. Same root cause: Docker sets `nft chain ip filter FORWARD policy drop`

**The real fix:** Add to `make up` (or `make vms` or a host setup target):
```bash
sudo nft insert rule ip filter FORWARD iifname "virbr1" accept 2>/dev/null || true
sudo nft insert rule ip filter FORWARD oifname "virbr1" accept 2>/dev/null || true
sudo nft insert rule ip filter FORWARD iifname "virbr2" accept 2>/dev/null || true
sudo nft insert rule ip filter FORWARD oifname "virbr2" accept 2>/dev/null || true
```

Or add a polkit rule / systemd service that runs on boot. Or document "disable Docker" as a prerequisite (since we no longer use Docker for anything).

---

## TODO

- [ ] Fix bastion route timing issue (ARP wait or retry logic)
- [ ] Pre-bundle Cilium + MetalLB container images in `artifacts/`
- [ ] Remove `~/.kube/config` copy logic from setup-host-kubectl.sh
- [ ] Add `-- -T` to ALL vagrant ssh calls that capture stdout (grep the entire codebase)
- [ ] Consider adding `export KUBECONFIG` to a project `.envrc` or printing it in `make k3s-up` output
- [ ] Add Docker nft FORWARD fix to `make up` permanently
- [ ] Document Docker FORWARD DROP as a system prerequisite warning
- [ ] Add mgmt default route via bastion to provision-mgmt.sh (DONE)
- [ ] Consider removing Docker entirely from the host (no longer needed)
