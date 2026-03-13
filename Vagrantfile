# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# NetWatch — Vagrantfile
# 18 VMs: 16 compute servers + 1 bastion + 1 mgmt
# All use Fedora Cloud, libvirt provider, KSM-friendly.
#
# Usage:
#   vagrant up              # bring up all 18 VMs
#   vagrant up srv-1-1      # bring up a single VM
#   vagrant ssh srv-1-1     # SSH into a VM
#   vagrant destroy -f      # tear down all VMs

Vagrant.configure("2") do |config|
  config.vm.box = "fedora/40-cloud-base"
  config.vm.box_version = ">= 0"

  # Disable default synced folder (not needed, saves overhead)
  config.vm.synced_folder ".", "/vagrant", disabled: true

  # Common libvirt settings
  config.vm.provider :libvirt do |libvirt|
    libvirt.driver = "kvm"
    libvirt.storage_pool_name = "default"
    libvirt.memorybacking :nosharepages, :locked => false
    # KSM is enabled at the host level, not per-VM
  end

  # ========================================================================
  # Helper: define a server VM
  # ========================================================================
  def define_server(config, name, rack, mgmt_ip, memory: 512, cpus: 1)
    config.vm.define name do |node|
      node.vm.hostname = name

      node.vm.provider :libvirt do |lv|
        lv.memory = memory
        lv.cpus = cpus
      end

      # Management network (will be wired to br-mgmt by provisioning)
      node.vm.network :private_network,
        ip: mgmt_ip,
        libvirt__network_name: "netwatch-mgmt",
        libvirt__dhcp_enabled: false,
        libvirt__forward_mode: "none"

      # Provisioning: install node_exporter, configure rp_filter
      node.vm.provision "shell", inline: <<-SHELL
        set -e
        # Sysctls
        sysctl -w net.ipv4.conf.all.rp_filter=2
        sysctl -w net.ipv4.conf.default.rp_filter=2
        echo 'net.ipv4.conf.all.rp_filter=2' >> /etc/sysctl.d/99-netwatch.conf
        echo 'net.ipv4.conf.default.rp_filter=2' >> /etc/sysctl.d/99-netwatch.conf

        # node_exporter
        if ! command -v node_exporter &>/dev/null; then
          dnf install -y golang-github-prometheus-node-exporter 2>/dev/null || {
            curl -sL https://github.com/prometheus/node_exporter/releases/download/v1.7.0/node_exporter-1.7.0.linux-amd64.tar.gz | tar xz -C /usr/local/bin --strip-components=1
          }
        fi
        # Enable and start
        cat > /etc/systemd/system/node_exporter.service <<EOF
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
ExecStart=/usr/local/bin/node_exporter
Restart=always

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now node_exporter
      SHELL
    end
  end

  # ========================================================================
  # Bastion VM
  # ========================================================================
  config.vm.define "bastion" do |node|
    node.vm.hostname = "bastion"

    node.vm.provider :libvirt do |lv|
      lv.memory = 512
      lv.cpus = 1
    end

    node.vm.network :private_network,
      ip: "192.168.0.2",
      libvirt__network_name: "netwatch-mgmt",
      libvirt__dhcp_enabled: false,
      libvirt__forward_mode: "none"

    node.vm.provision "shell", inline: <<-SHELL
      set -e
      # Enable IP forwarding for NAT gateway
      sysctl -w net.ipv4.ip_forward=1
      echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.d/99-netwatch.conf
      sysctl -w net.ipv4.conf.all.rp_filter=2
      echo 'net.ipv4.conf.all.rp_filter=2' >> /etc/sysctl.d/99-netwatch.conf

      # NAT masquerade (fabric -> outside)
      dnf install -y iptables-services 2>/dev/null || true
      iptables -t nat -A POSTROUTING -s 192.168.0.0/24 -o eth0 -j MASQUERADE
      iptables-save > /etc/sysconfig/iptables
    SHELL
  end

  # ========================================================================
  # Management VM (Prometheus, Grafana, Loki, dnsmasq, chrony)
  # ========================================================================
  config.vm.define "mgmt" do |node|
    node.vm.hostname = "mgmt"

    node.vm.provider :libvirt do |lv|
      lv.memory = 1024
      lv.cpus = 2
    end

    node.vm.network :private_network,
      ip: "192.168.0.3",
      libvirt__network_name: "netwatch-mgmt",
      libvirt__dhcp_enabled: false,
      libvirt__forward_mode: "none"

    node.vm.provision "shell", inline: <<-SHELL
      set -e
      sysctl -w net.ipv4.conf.all.rp_filter=2
      echo 'net.ipv4.conf.all.rp_filter=2' >> /etc/sysctl.d/99-netwatch.conf

      # Observability stack will be deployed in P5
      echo "mgmt VM provisioned. Observability stack deployed in P5."
    SHELL
  end

  # ========================================================================
  # Compute Servers (4 racks × 4 servers = 16 VMs)
  # ========================================================================

  # Rack 1
  define_server(config, "srv-1-1", "rack-1", "192.168.0.50")
  define_server(config, "srv-1-2", "rack-1", "192.168.0.51")
  define_server(config, "srv-1-3", "rack-1", "192.168.0.52")
  define_server(config, "srv-1-4", "rack-1", "192.168.0.53")

  # Rack 2
  define_server(config, "srv-2-1", "rack-2", "192.168.0.54")
  define_server(config, "srv-2-2", "rack-2", "192.168.0.55")
  define_server(config, "srv-2-3", "rack-2", "192.168.0.56")
  define_server(config, "srv-2-4", "rack-2", "192.168.0.57")

  # Rack 3
  define_server(config, "srv-3-1", "rack-3", "192.168.0.58")
  define_server(config, "srv-3-2", "rack-3", "192.168.0.59")
  define_server(config, "srv-3-3", "rack-3", "192.168.0.60")
  define_server(config, "srv-3-4", "rack-3", "192.168.0.61")

  # Rack 4
  define_server(config, "srv-4-1", "rack-4", "192.168.0.62")
  define_server(config, "srv-4-2", "rack-4", "192.168.0.63")
  define_server(config, "srv-4-3", "rack-4", "192.168.0.64")
  define_server(config, "srv-4-4", "rack-4", "192.168.0.65")

end
