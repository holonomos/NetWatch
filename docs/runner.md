  ---
  Cold Start (from scratch / first time)

  # 1. Prerequisites — golden box must exist and be registered
  vagrant box list | grep netwatch-golden   # verify it's there
  # If not: vagrant box add --name netwatch-golden netwatch-golden.box

  # 2. Generate all configs from topology.yml
  make generate

  # 3. Boot all 30 VMs in correct order (mgmt → FRR → bastion → servers)
  #    Takes ~10-15 min depending on hardware
  make vms

  # 4. Wire the fabric (bridges → FRR NICs → EVPN → server/bastion NICs → verify)
  make up

  # 5. Open Grafana/Prometheus dashboards (optional, in a separate terminal)
  make dashboard
  #    Grafana: http://localhost:3000 (admin/admin)
  #    Prometheus: http://localhost:9090
  #    Loki: http://localhost:3100

  That's it. make vms then make up. Five commands.

  ---
  Resume (picking up where you left off)

  Check what state you're in first:

  vagrant status                    # are VMs running, halted, or destroyed?

  Then pick the right path:

  VMs are running, fabric is down (you ran make down or make nuke)

  make up                           # re-wires everything: bridges → FRR → EVPN → servers → verify

  VMs are halted (you ran make vms-halt or rebooted the laptop)

  vagrant up                        # boots all existing VMs (no provisioning, fast)
  make up                           # re-wires the fabric

  VMs are destroyed (you ran make vms-destroy)

  make vms                          # full boot sequence (slow)
  make up                           # wire the fabric

  Only need to re-wire one layer

  make bridges                      # just recreate the 54 host bridges
  make fabric                       # just re-attach FRR NICs + restart FRR
  make evpn                         # just re-configure EVPN on leafs
  make wire                         # just re-attach server/bastion NICs
  make status                       # just run health checks

  Something is weird / want a clean slate without destroying VMs

  make nuke                         # kills FRR VMs, strips fabric NICs, deletes bridges
  make up                           # rebuild from scratch

  Nuclear option

  make vms-destroy                  # destroy ALL 30 VMs
  make vms                          # recreate from golden image
  make up                           # wire everything

  ---
  Quick reference

  make help                         # show all commands
  make status                       # 31-check health report
  make frr-restart                  # restart FRR on all 12 switches
  make dashboard                    # SSH tunnel to Grafana/Prometheus/Loki