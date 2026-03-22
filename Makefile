.PHONY: up down nuke vms vms-halt vms-destroy frr-up frr-down frr-restart \
       bridges fabric evpn wire status teardown generate dashboard help \
       chaos-link-down chaos-link-up chaos-flap chaos-latency chaos-loss \
       chaos-partition chaos-kill

# ==========================================================================
# Full lifecycle
# ==========================================================================

up: bridges fabric evpn wire status  ## Full fabric bring-up (bridges → FRR → EVPN → servers → verify)

down: teardown                       ## Graceful fabric teardown (halts FRR VMs, removes bridges)

nuke:                                ## Nuclear: remove bridges, detach NICs, clean orphans (keeps ALL VMs)
	bash scripts/nuke.sh

# ==========================================================================
# VMs
# ==========================================================================

vms:                                 ## Boot all 30 VMs in correct order (mgmt → FRR → bastion → servers)
	vagrant up mgmt
	@echo "Waiting for mgmt services to start..." && sleep 5
	vagrant up border-1 border-2 spine-1 spine-2 \
	         leaf-1a leaf-1b leaf-2a leaf-2b \
	         leaf-3a leaf-3b leaf-4a leaf-4b
	@echo "Waiting for FRR VMs to settle..." && sleep 5
	vagrant up bastion
	@echo "Waiting for bastion NAT..." && sleep 3
	vagrant up

vms-halt:                            ## Halt all VMs (preserves state)
	vagrant halt

vms-destroy:                         ## Destroy ALL 30 VMs
	vagrant destroy -f

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
# Fabric (individual steps — run in order, or just use 'make up')
# ==========================================================================

bridges:                             ## Step 1: Create 54 fabric bridges on host
	bash scripts/fabric/setup-bridges.sh

fabric:                              ## Step 2: Attach NICs + configure IPs on 12 FRR VMs
	bash scripts/fabric/setup-frr-links.sh

evpn:                                ## Step 3: Configure EVPN/VxLAN overlay on leaf VTEPs
	bash scripts/fabric/setup-evpn.sh

wire:                                ## Step 4: Attach NICs + configure IPs on servers + bastion
	bash scripts/fabric/setup-server-links.sh

status:                              ## Health check (31 checks)
	bash scripts/fabric/status.sh

teardown:                            ## Graceful teardown: halt FRR VMs + remove bridges
	bash scripts/fabric/teardown.sh

# ==========================================================================
# Tools
# ==========================================================================

generate:                            ## Regenerate all configs from topology.yml
	python3 generator/generate.py

dashboard:                           ## SSH tunnel to Grafana/Prometheus/Loki
	vagrant ssh mgmt -- -L 3000:localhost:3000 -L 9090:localhost:9090 -L 3100:localhost:3100

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
