# NetWatch Known Issues

What's currently broken or quirky on the running fabric. For how it works see [ARCHITECTURE.md](ARCHITECTURE.md); for operating it see [RUNBOOK.md](RUNBOOK.md).

One data-plane limitation is open (EVPN inter-subnet IRB). Everything else here is operational behaviour worth knowing before you go digging.

---

## EVPN inter-subnet IRB does not forward on a fresh bring-up

Same-subnet L2 over the VXLAN overlay works and is validated at 0% loss (cross-rack, ARP resolving to the peer server's real NIC MAC, ~14 remote MACs learned on VNI 10000). Inter-subnet routing through the distributed anycast gateway does not.

The symmetric-IRB control plane is correct: L3VNI 10999 in VRF `Tenant-A`, per-VNI RD/RT (`65000:<vni>`), anycast SVIs on the L2VNI bridge interfaces, and the leaves learn remote MACs plus EVPN Type-2 MAC/IP routes for the other tenant's hosts (the ingress leaf carries `[2]…[10.99.1.41]` via the egress VTEP). The data plane does not follow.

- **Symptom:** a member cannot reach its anycast gateway (`.1`) or any host in the other tenant subnet. The gateway SVI (the VRF-enslaved L2VNI bridge interface) does not answer ARP/ICMP for its own IP and does not route between subnets, even though the anycast IP is present in VRF `Tenant-A`, `arp_ignore=0` is set, and the control plane (including the remote Type-2 routes) is in place.
- **Scope:** same-subnet L2 is unaffected and stays validated at 0% loss. Only inter-subnet / anycast-gateway forwarding is broken. The routed `/30` underlay is untouched throughout (cross-rack loopback ping and ECMP still pass, and `10.99.0.0/16` is never injected into the underlay BGP).
- **Why it reads as a data-plane/state issue rather than a config bug:** the same config and EVPN control plane forwarded correctly on a long-lived instance but does not reproduce on a clean build. The suspect is VRF-enslaved-bridge SVI behaviour on the Fedora 44 / kernel 7.x build.
- **Tried, no change on a fresh build:** anycast IP+MAC on the bridge interface itself (not a VLAN sub-interface); `neigh_suppress` toggling on the VXLAN device; FRR restart; priming a static neighbor for the gateway.

`ARCHITECTURE.md` §5 and the EVPN section of the runbook describe the design and keep this caveat explicit. If you pick it up, that's the thread to pull: why a VRF-enslaved bridge SVI stops answering for its own anycast IP on a from-scratch boot but not on a warm one.

## Transient libvirt DHCP flake on a full VM recreate

After a `nuke`/teardown followed by `make vms`, libvirt's dnsmasq sometimes fails to hand a freshly-created domain its management lease, so a node is briefly unreachable over `vagrant ssh`. It's a lease-timing race on the management network, not a fabric defect. Reload the bastion (it re-serves `netwatch-mgmt`) or retry the affected step; the lease settles and `make up` reaches 31/31.

---

## Gotchas

**Five fabric scripts are generated.** `setup-bridges.sh`, `setup-frr-links.sh`, `setup-server-links.sh`, `status.sh`, and `teardown.sh` are rendered by `make generate` and overwritten on every run. Fix them through their Jinja templates under `generator/templates/scripts/`, not the file in `scripts/fabric/`. The hand-maintained scripts (`configure-*`, `setup-evpn.sh`, `configure-evpn-vtep.sh`, `evpn-metrics-collector.sh`, `chaos/*`, `nuke.sh`) are edited directly. See [ARCHITECTURE.md §6](ARCHITECTURE.md).

**`make overlay` runs after `make wire` on purpose.** `setup-evpn.sh` runs twice in `make up`: once at `evpn` to build the VRF/VNIs/SVIs before the server access NICs exist, and again at `overlay` to enslave the leaf `eth-ovl`/`eth-ovl-b` ports once `wire` has created the servers' `tnt0`/`tnt1` NICs. If you run the steps by hand and skip the second pass, the overlay carries no L2 traffic. It's idempotent, so just run `make overlay` again.

**Re-running `make up` / `make wire` is safe.** The fabric-configure scripts use `ip addr replace`, so a re-run doesn't trip over an address that's already assigned.

**`chaos-kill` and `nuke` target `NetWatch-main_<node>`.** Both derive the libvirt domain prefix from the project-root basename (`$(basename "$PROJECT_ROOT")`), matching the fabric scripts. If your clone directory isn't named `NetWatch-main`, the domains follow the directory name; confirm with `virsh -c qemu:///system list --all`.

---

## EVPN overlay verification

After a bring-up, these re-confirm overlay state. Same-subnet L2 (steps 1-4, 6, 7) passes; the inter-subnet step is the open limitation above. Tenant-A access IPs: `srv-1-1 = 10.99.0.11/24`, `srv-2-1 = 10.99.0.21/24` (same L2VNI 10000, different racks — the cross-rack L2 case), `srv-3-1` (tenant-a); tenant-b `srv-4-1 = 10.99.1.41/24`; gateway `10.99.0.1`.

```bash
# 0. Bring up including the post-wire overlay enslave step
make vms && make up                       # 'up' ends: … evpn wire routes overlay status
make overlay                              # (idempotent) re-run if servers came up after the first evpn pass

# 1. VNIs present and L2VNI<->L3VNI mapping correct on a leaf
vagrant ssh leaf-1a -c "sudo vtysh -c 'show evpn vni'"          # 10000, 10001 (L2) + 10999 (L3, VRF Tenant-A)
vagrant ssh leaf-1a -c "sudo vtysh -c 'show evpn vni 10000'"    # Type: L2, with a remote VTEP list

# 2. EVPN BGP converged: Type-2 (MAC/IP), Type-3 (IMET), Type-5 (prefix) routes present
vagrant ssh leaf-1a -c "sudo vtysh -c 'show bgp l2vpn evpn summary'"   # spine RR neighbors Established
vagrant ssh leaf-1a -c "sudo vtysh -c 'show bgp l2vpn evpn'"           # [2]/[3]/[5] route-types present

# 3. Kernel datapath: bridges, vxlan devices, anycast GW on the bridge, server access NIC
vagrant ssh leaf-1a -c "ip -d link show vxlan10000; ip -br addr show br-vni10000"    # vxlan id 10000; GW 10.99.0.1/24 on the bridge
vagrant ssh leaf-1a -c "bridge fdb show | grep -i 00:00:5e:00:01:99"                 # anycast MAC programmed
vagrant ssh srv-1-1 -c "ip -br addr show tnt0"                                        # 10.99.0.11/24, MTU 1450

# 4. Same-subnet L2 across racks over the overlay (not the underlay) — ARP resolves to the PEER's real NIC MAC
vagrant ssh srv-1-1 -c "ping -c3 10.99.0.21"      # srv-1-1 (rack-1) -> srv-2-1 (rack-2), same /24 — 0% loss

# 5. Inter-subnet symmetric IRB over L3VNI 10999 — tenant-a -> tenant-b
#    Control plane is correct (Type-2 route present); data-plane forwarding is the open limitation on a clean build:
vagrant ssh leaf-1a -c "sudo vtysh -c 'show bgp l2vpn evpn'" | grep 10.99.1.41   # [2]...[10.99.1.41] via egress leaf VTEP
vagrant ssh srv-1-1 -c "ping -c3 10.99.1.41"      # srv-1-1 -> srv-4-1 (tenant-b): inter-subnet forwarding does not work on a fresh build

# 6. Remote MAC learned over VXLAN (Type-2) — ~14 remotes on VNI 10000
vagrant ssh leaf-2a -c "sudo vtysh -c 'show evpn mac vni 10000'"   # srv-1-1's MAC shows as 'remote' here
cat /var/lib/node_exporter/textfile/evpn.prom 2>/dev/null | grep -E 'netwatch_evpn_mac_remote|netwatch_evpn_vni_info'

# 7. Underlay invariant — routed /30 ECMP path unaffected, supernet NOT in underlay BGP
vagrant ssh srv-1-1 -c "ping -c3 10.0.7.1"        # cross-rack loopback via the routed underlay — 0% loss
make status                                        # 31/31 checks
```

If step 4 fails but the underlay (step 7) is fine, the usual cause is the post-`wire` enslave not having run: re-run `make overlay` and check `bridge link show | grep eth-ovl` on the leaves.
