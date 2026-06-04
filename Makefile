.PHONY: up down nuke vms vms-halt vms-destroy suspend resume frr-up frr-down frr-restart \
       bridges fabric evpn wire routes overlay status teardown generate dashboard help \
       artifacts-build artifacts-serve artifacts-stop artifacts-status bake box-register \
       chaos-link-down chaos-link-up chaos-flap chaos-latency chaos-loss \
       chaos-partition chaos-kill

# ==========================================================================
# Full lifecycle
# ==========================================================================

up: hostfix bridges fabric evpn wire routes overlay status  ## Full bring-up (hostfix → bridges → FRR → EVPN → servers → routes → overlay → verify)

hostfix:                             ## Step 0: Fix Docker nftables FORWARD DROP (blocks inter-VM traffic)
	@for br in $$(ip link show type bridge 2>/dev/null | grep -oP 'virbr\d+' | sort -u); do \
		sudo nft insert rule ip filter FORWARD iifname "$$br" accept 2>/dev/null || true; \
		sudo nft insert rule ip filter FORWARD oifname "$$br" accept 2>/dev/null || true; \
	done; echo "  Host nft FORWARD rules applied for all virbr bridges (Docker conflict fix)"

down: teardown                       ## Graceful fabric teardown (halts FRR VMs, removes bridges)

nuke:                                ## Nuclear: remove bridges, detach NICs, clean orphans (keeps ALL VMs)
	bash scripts/nuke.sh

# ==========================================================================
# VMs
# ==========================================================================

vms: bridges                         ## Boot all 31 VMs (bridges FIRST; FRR + servers in batches of 4 to avoid vagrant-libvirt parallel IP-wait flake)
	vagrant up obs
	@echo "Waiting for obs services (DNS, NTP, monitoring)..." && sleep 5
	vagrant up mgmt
	@echo "Waiting for mgmt..." && sleep 5
	@echo "Booting 12 FRR switches in batches of 4..."
	vagrant up border-1 border-2 spine-1 spine-2
	@sleep 4
	vagrant up leaf-1a leaf-1b leaf-2a leaf-2b
	@sleep 4
	vagrant up leaf-3a leaf-3b leaf-4a leaf-4b
	@echo "Waiting for FRR VMs to settle..." && sleep 5
	@echo "Booting bastion (retry for known DHCP-lease flake)..."
	@for i in 1 2 3; do vagrant up bastion && break || { echo "  bastion up failed (try $$i); reloading..."; vagrant reload bastion 2>/dev/null || true; sleep 5; }; done
	@echo "Waiting for bastion NAT..." && sleep 3
	@echo "Booting 16 servers in batches of 4..."
	vagrant up srv-1-1 srv-1-2 srv-1-3 srv-1-4
	@sleep 4
	vagrant up srv-2-1 srv-2-2 srv-2-3 srv-2-4
	@sleep 4
	vagrant up srv-3-1 srv-3-2 srv-3-3 srv-3-4
	@sleep 4
	vagrant up srv-4-1 srv-4-2 srv-4-3 srv-4-4

vms-halt:                            ## Halt all VMs (preserves state)
	vagrant halt

vms-destroy:                         ## Destroy ALL 31 VMs
	vagrant destroy -f

suspend:                             ## Suspend all VMs (saves full state to disk)
	vagrant suspend

resume:                              ## Resume all suspended VMs
	vagrant resume

frr-up:                              ## Boot only the 12 FRR switch VMs
	vagrant up border-1 border-2 spine-1 spine-2 \
	         leaf-1a leaf-1b leaf-2a leaf-2b \
	         leaf-3a leaf-3b leaf-4a leaf-4b

frr-down:                            ## Halt only the 12 FRR switch VMs
	@for node in border-1 border-2 spine-1 spine-2 \
	             leaf-1a leaf-1b leaf-2a leaf-2b \
	             leaf-3a leaf-3b leaf-4a leaf-4b; do \
		vagrant halt $$node 2>/dev/null & \
	done; wait

frr-restart:                         ## Restart FRR service on all switch VMs
	@for node in border-1 border-2 spine-1 spine-2 \
	             leaf-1a leaf-1b leaf-2a leaf-2b \
	             leaf-3a leaf-3b leaf-4a leaf-4b; do \
		echo "Restarting FRR on $$node..."; \
		vagrant ssh $$node -c "sudo systemctl restart frr" 2>/dev/null || echo "  $$node: failed"; \
	done

# ==========================================================================
# Fabric (individual steps, in order; or just use 'make up')
# ==========================================================================

bridges:                             ## Step 1: Create 54 fabric bridges on host
	bash scripts/fabric/setup-bridges.sh

fabric:                              ## Step 2: Attach NICs + configure IPs on 12 FRR VMs
	bash scripts/fabric/setup-frr-links.sh

evpn:                                ## Step 3: Configure EVPN/VxLAN overlay on leaf VTEPs
	bash scripts/fabric/setup-evpn.sh

wire:                                ## Step 4: Attach NICs + configure IPs on servers + bastion
	bash scripts/fabric/setup-server-links.sh

routes:                              ## Step 5: Add host routes for fabric + service IPs via bastion
	@sudo ip route replace 10.0.0.0/8 via 192.168.0.2 2>/dev/null && \
		echo "  Host route: 10.0.0.0/8 via bastion (fabric loopbacks)" || \
		echo "  WARNING: Failed to add host route (need sudo)"

overlay:                             ## Step 6: Bind overlay access ports + finalize IRB datapath (after servers wired)
	bash scripts/fabric/setup-evpn.sh

status:                              ## Health check (31 checks)
	bash scripts/fabric/status.sh

teardown:                            ## Graceful teardown: halt FRR VMs + remove bridges
	bash scripts/fabric/teardown.sh

# ==========================================================================
# Bastion
# ==========================================================================

bastion-ops:                         ## Configure bastion as operations desk (aliases, DNAT, SSH config)
	bash scripts/bastion/setup-ops.sh

bastion-dnat:                        ## Apply/refresh DNAT rules from config/bastion-dnat.conf
	bash scripts/bastion/apply-dnat.sh

# ==========================================================================
# Artifacts
# ==========================================================================

artifacts-build:                     ## Download all artifacts (run once, needs internet + Docker)
	bash scripts/artifacts/build.sh

artifacts-serve:                     ## Start local artifact HTTP server (run before vagrant up)
	bash scripts/artifacts/serve.sh start

artifacts-stop:                      ## Stop artifact HTTP server
	bash scripts/artifacts/serve.sh stop

artifacts-status:                    ## Check artifact server status
	bash scripts/artifacts/serve.sh status

bake:                                ## Build golden Vagrant box (needs artifacts-build first)
	bash scripts/bake-golden-image.sh

box-register:                        ## Register golden box with Vagrant (needs bake first)
	vagrant box add --name netwatch-golden artifacts/boxes/netwatch-golden.box --force

# ==========================================================================
# Tools
# ==========================================================================

generate:                            ## Regenerate all configs from topology.yml
	python3 generator/generate.py

dashboard:                           ## SSH tunnel to Grafana/Prometheus/Loki (on obs VM)
	vagrant ssh obs -- -L 3000:localhost:3000 -L 9090:localhost:9090 -L 3100:localhost:3100

# ==========================================================================
# Chaos
# ==========================================================================

chaos-link-down:                     ## Link down (ARGS="spine-1 leaf-1a")
	bash scripts/chaos/link-down.sh $(ARGS)

chaos-link-up:                       ## Link restore (ARGS="spine-1 leaf-1a")
	bash scripts/chaos/link-down.sh $(ARGS) --restore

chaos-flap:                          ## Link flap (ARGS="spine-1 leaf-1a --interval 5 --count 5")
	bash scripts/chaos/link-flap.sh $(ARGS)

chaos-latency:                       ## Inject latency (ARGS="spine-1 leaf-1a --delay 200ms")
	bash scripts/chaos/latency-inject.sh $(ARGS)

chaos-loss:                          ## Inject packet loss (ARGS="spine-1 leaf-1a --loss 30%")
	bash scripts/chaos/packet-loss.sh $(ARGS)

chaos-partition:                     ## Isolate a rack (ARGS="rack-1")
	bash scripts/chaos/rack-partition.sh $(ARGS)

chaos-kill:                          ## Kill a node (ARGS="spine-1")
	bash scripts/chaos/node-kill.sh $(ARGS)

# ==========================================================================
# Help
# ==========================================================================

help:                                ## Show all commands
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
