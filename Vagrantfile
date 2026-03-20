# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# NetWatch — Vagrantfile
# 18 VMs: 16 compute servers + 1 bastion + 1 mgmt
# Golden image: everything pre-installed, provisioning only configures.
#
# Prerequisites:
#   1. vagrant box add --name netwatch-golden netwatch-golden.box
#   2. python3 generator/generate.py  (generates configs in generated/)
#
# Usage:
#   vagrant up mgmt && vagrant up bastion && vagrant up   # recommended order
#   vagrant up srv-1-1      # bring up a single VM
#   vagrant ssh bastion     # SSH into bastion (jump box)
#   vagrant destroy -f      # tear down all VMs

Vagrant.configure("2") do |config|
  config.vm.box = "netwatch-golden"

  config.vm.synced_folder ".", "/vagrant", disabled: true

  config.vm.provider :libvirt do |libvirt|
    libvirt.driver = "kvm"
    libvirt.storage_pool_name = "default"
    libvirt.memorybacking :nosharepages, :locked => false
    libvirt.mgmt_attach = false
  end

  # ========================================================================
  # Common config: DNS, sysctls, node_exporter (all 18 VMs)
  # ========================================================================
  COMMON_BASE = <<~SHELL
    # DNS — point at mgmt VM (dnsmasq)
    cat > /etc/resolv.conf <<DNSEOF
    nameserver 192.168.0.3
    search netwatch.lab
    DNSEOF

    # Prevent NetworkManager from overwriting resolv.conf
    mkdir -p /etc/NetworkManager/conf.d
    cat > /etc/NetworkManager/conf.d/99-netwatch-dns.conf <<NMEOF
    [main]
    dns=none
    NMEOF

    # Activate sysctls (baked into image, activate at runtime)
    sysctl -p /etc/sysctl.d/99-netwatch.conf

    # Fix SELinux contexts (virt-sysprep mislabels /usr/local/bin as user_tmp_t)
    restorecon -R /usr/local/bin

    # Enable node_exporter (binary + unit baked into image)
    systemctl enable --now node_exporter
  SHELL

  # ========================================================================
  # Client config: chrony + rsyslog forwarding (servers + bastion only)
  # ========================================================================
  COMMON_CLIENT = <<~SHELL
    # Chrony — NTP client, sync from mgmt
    cat > /etc/chrony.conf <<CHEOF
    pool 192.168.0.3 iburst
    stratumweight 0
    driftfile /var/lib/chrony/drift
    rtcsync
    logdir /var/log/chrony
    CHEOF
    systemctl enable --now chronyd

    # Rsyslog — forward to Loki on mgmt
    cat > /etc/rsyslog.d/99-netwatch-forward.conf <<RSEOF
    *.* @@192.168.0.3:514
    RSEOF
    systemctl enable --now rsyslog
  SHELL

  # ========================================================================
  # Management VM — observability, DNS, NTP (define first for boot order)
  # ========================================================================
  config.vm.define "mgmt" do |node|
    node.vm.hostname = "mgmt"

    node.vm.provider :libvirt do |lv|
      lv.memory = 2048
      lv.cpus = 2
    end

    node.vm.network :private_network,
      ip: "192.168.0.3",
      libvirt__network_name: "netwatch-mgmt",
      libvirt__dhcp_enabled: true,
      libvirt__forward_mode: "none"

    node.vm.synced_folder "generated/prometheus", "/tmp/netwatch-config/prometheus", type: "rsync"
    node.vm.synced_folder "generated/loki", "/tmp/netwatch-config/loki", type: "rsync"
    node.vm.synced_folder "generated/grafana", "/tmp/netwatch-config/grafana", type: "rsync"
    node.vm.synced_folder "generated/dnsmasq", "/tmp/netwatch-config/dnsmasq", type: "rsync"

    node.vm.provision "shell", inline: <<-SH
      set -e
      #{COMMON_BASE}

      # Static IP (Vagrant can't reconfigure the NIC it SSH'd in on)
      ip addr add 192.168.0.3/24 dev ens5 2>/dev/null || true
    SH

    node.vm.provision "shell", path: "scripts/provision-mgmt.sh"
  end

  # ========================================================================
  # Bastion VM — sole NAT gateway, north-south boundary
  # ========================================================================
  config.vm.define "bastion" do |node|
    node.vm.hostname = "bastion"

    node.vm.provider :libvirt do |lv|
      lv.memory = 384
      lv.cpus = 1
      lv.mgmt_attach = true
    end

    node.vm.network :private_network,
      ip: "192.168.0.2",
      libvirt__network_name: "netwatch-mgmt",
      libvirt__dhcp_enabled: true,
      libvirt__forward_mode: "none"

    node.vm.provision "shell", inline: <<-SH
      set -e

      #{COMMON_BASE}
      #{COMMON_CLIENT}

      # IP forwarding for NAT gateway
      sysctl -w net.ipv4.ip_forward=1
      echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.d/99-netwatch.conf

      # NAT masquerade — dynamically find the internet-facing interface
      INET_IF=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
      if [ -n "$INET_IF" ]; then
        iptables -t nat -A POSTROUTING -s 192.168.0.0/24 -o "$INET_IF" -j MASQUERADE
        iptables-save > /etc/sysconfig/iptables
        systemctl enable iptables
        echo "NAT masquerade on interface: $INET_IF"
      else
        echo "WARNING: No internet-facing interface found. NAT not configured."
      fi
    SH
  end

  # ========================================================================
  # Compute Servers (4 racks × 4 servers = 16 VMs)
  # k3s pre-installed but disabled — cluster formation happens at P7.
  # Data-plane interfaces wired post-boot by scripts/fabric/setup-server-links.sh
  # ========================================================================
  def define_server(config, name, rack, mgmt_ip)
    config.vm.define name do |node|
      node.vm.hostname = name

      node.vm.provider :libvirt do |lv|
        lv.memory = 768
        lv.cpus = 1
      end

      node.vm.network :private_network,
        ip: mgmt_ip,
        libvirt__network_name: "netwatch-mgmt",
        libvirt__dhcp_enabled: true,
        libvirt__forward_mode: "none"

      node.vm.provision "shell", inline: <<-SH
        set -e
        #{COMMON_BASE}
        #{COMMON_CLIENT}

        # Static IP (Vagrant can't reconfigure the NIC it SSH'd in on)
        ip addr add #{mgmt_ip}/24 dev ens5 2>/dev/null || true
      SH
    end
  end

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
