.PHONY: up down bridges fabric wire status teardown generate clean

# --- Full lifecycle ---
up: bridges fabric wire         ## Bring up fabric (bridges + FRR + server wiring)
down: teardown                  ## Tear down fabric (keeps VMs)
nuke:                           ## Nuclear teardown — containers, bridges, veths, detach all fabric NICs
	bash scripts/nuke.sh

# --- Individual steps ---
bridges:                        ## Create 52 fabric bridges
	bash scripts/fabric/setup-bridges.sh

fabric:                         ## Start 12 FRR containers and wire fabric
	bash scripts/fabric/setup-frr-containers.sh

wire:                           ## Wire server VMs to leaf switches
	bash scripts/fabric/setup-server-links.sh

status:                         ## Full fabric health check
	bash scripts/fabric/status.sh

teardown:                       ## Remove FRR containers + bridges
	bash scripts/fabric/teardown.sh

generate:                       ## Regenerate configs from topology.yml
	python3 generator/generate.py

# --- VMs ---
vms:                            ## Boot all 18 VMs (mgmt first, then bastion, then servers)
	vagrant up mgmt && vagrant up bastion && vagrant up

vms-halt:                       ## Stop all VMs (preserves state)
	vagrant halt

vms-destroy:                    ## Destroy all VMs
	vagrant destroy -f

# --- Observability access ---
dashboard:                      ## SSH tunnel to Grafana/Prometheus/Loki
	vagrant ssh mgmt -- -L 3000:localhost:3000 -L 9090:localhost:9090 -L 3100:localhost:3100

# --- Chaos ---
chaos-link-down:                ## Chaos: link down (ARGS="spine-1 leaf-1a")
	bash scripts/chaos/link-down.sh $(ARGS)

chaos-link-up:                  ## Chaos: link restore (ARGS="spine-1 leaf-1a")
	bash scripts/chaos/link-down.sh $(ARGS) --restore

chaos-flap:                     ## Chaos: link flap (ARGS="spine-1 leaf-1a --interval 5 --count 5")
	bash scripts/chaos/link-flap.sh $(ARGS)

chaos-latency:                  ## Chaos: inject latency (ARGS="spine-1 leaf-1a --delay 200ms")
	bash scripts/chaos/latency-inject.sh $(ARGS)

chaos-loss:                     ## Chaos: inject packet loss (ARGS="spine-1 leaf-1a --loss 30%")
	bash scripts/chaos/packet-loss.sh $(ARGS)

chaos-partition:                ## Chaos: isolate a rack (ARGS="rack-1")
	bash scripts/chaos/rack-partition.sh $(ARGS)

chaos-kill:                     ## Chaos: kill a node (ARGS="spine-1")
	bash scripts/chaos/node-kill.sh $(ARGS)

# --- Help ---
help:                           ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
