# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# NetWatch — Vagrantfile
# 30 VMs: 12 FRR switches + 16 compute servers + 1 bastion + 1 mgmt
# Golden image: everything pre-installed, provisioning only configures.
# No Docker. All VMs use netwatch-golden box.
#
# Prerequisites:
#   1. vagrant box add --name netwatch-golden netwatch-golden.box
#   2. python3 generator/generate.py  (generates configs in generated/)
#
# Boot order: mgmt -> FRR switches -> bastion -> servers
#
# Usage:
#   vagrant up mgmt && vagrant up border-{1,2} spine-{1,2} leaf-{1..4}{a,b} && vagrant up bastion && vagrant up
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
  # Common config: DNS, sysctls, node_exporter (all 30 VMs)
  # ========================================================================
  COMMON_BASE = <<~SHELL
    # DNS — point at mgmt VM (dnsmasq)
    rm -f /etc/resolv.conf
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

    # SSH hardening — disable password auth, key-only access
    sed -i 's/^#\\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#\\?ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
    # Drop any sshd_config.d overrides that re-enable passwords
    for f in /etc/ssh/sshd_config.d/*.conf; do
      [ -f "$f" ] && sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' "$f"
    done
    systemctl reload sshd 2>/dev/null || systemctl restart sshd
  SHELL

  # ========================================================================
  # Client config: chrony + rsyslog forwarding (servers + bastion + FRR VMs)
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
  # FRR switch config: copy FRR configs, udev rules, enable FRR + frr_exporter
  # ========================================================================
  FRR_COMMON = <<~SHELL
    # Copy FRR configs from synced folder to /etc/frr/
    if [ -d /tmp/netwatch-config/frr ]; then
      cp -f /tmp/netwatch-config/frr/frr.conf /etc/frr/frr.conf
      cp -f /tmp/netwatch-config/frr/daemons /etc/frr/daemons
      cp -f /tmp/netwatch-config/frr/vtysh.conf /etc/frr/vtysh.conf
      chown -R frr:frr /etc/frr/
      chmod 640 /etc/frr/frr.conf /etc/frr/daemons /etc/frr/vtysh.conf
    else
      echo "WARNING: /tmp/netwatch-config/frr not found — FRR configs not deployed"
    fi

    # Copy udev rules for interface renaming (MAC -> eth-peer-name)
    if [ -f /tmp/netwatch-config/frr/70-netwatch-fabric.rules ]; then
      cp -f /tmp/netwatch-config/frr/70-netwatch-fabric.rules /etc/udev/rules.d/
      udevadm control --reload-rules
    fi

    # Enable ip_forward (FRR needs this)
    sysctl -w net.ipv4.ip_forward=1
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.d/99-netwatch.conf

    # Enable FRR (starts with loopback + mgmt only; fabric NICs attached later)
    systemctl enable --now frr

    # Enable frr_exporter for Prometheus scraping
    systemctl enable --now frr_exporter 2>/dev/null || true
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
  # FRR Switch VMs (12 nodes: 2 border + 2 spine + 8 leaf)
  # Fabric must exist before anything connects to it.
  # Fabric NICs are hot-plugged post-boot by setup-frr-links.sh.
  # ========================================================================
  def define_frr_switch(config, name, mgmt_ip)
    config.vm.define name do |node|
      node.vm.hostname = name

      node.vm.provider :libvirt do |lv|
        lv.memory = 256
        lv.cpus = 1
      end

      node.vm.network :private_network,
        ip: mgmt_ip,
        libvirt__network_name: "netwatch-mgmt",
        libvirt__dhcp_enabled: true,
        libvirt__forward_mode: "none"

      node.vm.synced_folder "generated/frr/#{name}", "/tmp/netwatch-config/frr", type: "rsync"

      node.vm.provision "shell", inline: <<-SH
        set -e
        #{COMMON_BASE}
        #{COMMON_CLIENT}
        #{FRR_COMMON}

        # Static IP (Vagrant can't reconfigure the NIC it SSH'd in on)
        ip addr add #{mgmt_ip}/24 dev ens5 2>/dev/null || true
      SH
    end
  end

  # Border routers
  define_frr_switch(config, "border-1", "192.168.0.10")
  define_frr_switch(config, "border-2", "192.168.0.11")

  # Spine switches
  define_frr_switch(config, "spine-1", "192.168.0.20")
  define_frr_switch(config, "spine-2", "192.168.0.21")

  # Leaf switches
  define_frr_switch(config, "leaf-1a", "192.168.0.30")
  define_frr_switch(config, "leaf-1b", "192.168.0.31")
  define_frr_switch(config, "leaf-2a", "192.168.0.32")
  define_frr_switch(config, "leaf-2b", "192.168.0.33")
  define_frr_switch(config, "leaf-3a", "192.168.0.34")
  define_frr_switch(config, "leaf-3b", "192.168.0.35")
  define_frr_switch(config, "leaf-4a", "192.168.0.36")
  define_frr_switch(config, "leaf-4b", "192.168.0.37")

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
        # OOB management network
        iptables -t nat -A POSTROUTING -s 192.168.0.0/24 -o "$INET_IF" -j MASQUERADE
        # Fabric source IPs (north-south path: server -> leaf -> spine -> border -> bastion -> internet)
        iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -o "$INET_IF" -j MASQUERADE
        iptables -t nat -A POSTROUTING -s 172.16.0.0/12 -o "$INET_IF" -j MASQUERADE
        iptables-save > /etc/sysconfig/iptables
        systemctl enable iptables
        echo "NAT masquerade on interface: $INET_IF (mgmt + fabric source IPs)"
      else
        echo "WARNING: No internet-facing interface found. NAT not configured."
      fi
    SH
  end

  # ========================================================================
  # Compute Servers (4 racks x 4 servers = 16 VMs)
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
