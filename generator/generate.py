#!/usr/bin/env python3
"""
NetWatch Config Generator
=========================
Reads topology.yml (single source of truth) and produces all configuration
files for the fabric: FRR configs, udev rules, Prometheus scrape targets,
dnsmasq DHCP/DNS, Loki config, and wiring/teardown/status scripts.

Usage:
    python3 generator/generate.py [--topology topology.yml] [--outdir generated]
"""

import argparse
import os
import sys
from pathlib import Path

import yaml
from jinja2 import Environment, FileSystemLoader


# ---------------------------------------------------------------------------
# MAC address generation (deterministic, locally-administered)
# ---------------------------------------------------------------------------
# Format: 02:4E:57:TT:II:II
#   02    = locally administered, unicast
#   4E:57 = "NW" in ASCII
#   TT    = tier code
#   II:II = node index within tier (for mgmt MACs)
#
# Fabric interface MACs (FRR nodes):
#   02:4E:57:TT:PP:II
#   TT = tier code (01=border, 02=spine, 03=leaf)
#   PP = peer index (1-based, per node)
#   II = node index within tier (1-based)

TIER_CODES = {
    "border": 0x01,
    "spine": 0x02,
    "leaf": 0x03,
    "server": 0x04,
    "bastion": 0x05,
    "mgmt": 0x06,
}


def generate_mac(role: str, index: int) -> str:
    """Generate a deterministic MAC address for a node's management interface."""
    tier = TIER_CODES.get(role, 0xFF)
    return f"02:4E:57:{tier:02X}:{(index >> 8) & 0xFF:02X}:{index & 0xFF:02X}"


def generate_fabric_mac(role: str, node_index: int, peer_index: int) -> str:
    """Generate a deterministic MAC for a fabric interface on an FRR node.

    Scheme: 02:4E:57:TT:PP:II
      TT = tier code (01=border, 02=spine, 03=leaf)
      PP = peer index (1-based per node, 01..FF)
      II = node index within tier (1-based, 01..FF)

    This never collides with:
      - Mgmt MACs (TT:II:II pattern, different byte positions)
      - Server fabric MACs (TT=06)
      - Bastion fabric MACs (TT=05)
    """
    tier = TIER_CODES.get(role, 0xFF)
    return f"02:4E:57:{tier:02X}:{peer_index & 0xFF:02X}:{node_index & 0xFF:02X}"


# ---------------------------------------------------------------------------
# Topology loader
# ---------------------------------------------------------------------------

def load_topology(path: str) -> dict:
    """Load and validate topology.yml."""
    with open(path, "r") as f:
        topo = yaml.safe_load(f)

    required = ["project", "timers", "asn", "addressing", "nodes", "links",
                "management", "observability"]
    for key in required:
        if key not in topo:
            print(f"ERROR: topology.yml missing required key: {key}",
                  file=sys.stderr)
            sys.exit(1)

    return topo


# ---------------------------------------------------------------------------
# Node registry builder
# ---------------------------------------------------------------------------

def build_node_registry(topo: dict) -> dict:
    """
    Build a flat dict of all nodes keyed by name.
    Each node gets: name, type, role, asn, loopback, mgmt_ip, metrics_port,
                    rack (if applicable), interfaces (populated later),
                    bgp_neighbors (populated later), mac
    """
    nodes = {}
    counters = {}  # per-role counters for MAC generation

    def register(node_def, role_override=None):
        name = node_def["name"]
        role = role_override or node_def.get("role", "unknown")

        counters.setdefault(role, 0)
        counters[role] += 1

        nodes[name] = {
            "name": name,
            "type": node_def.get("type"),
            "role": role,
            "asn": node_def.get("asn"),
            "loopback": node_def.get("loopback"),
            "mgmt_ip": node_def.get("mgmt_ip"),
            "metrics_port": node_def.get("metrics_port"),
            "rack": node_def.get("rack"),
            "evpn_vtep": node_def.get("evpn_vtep", False),
            "vcpu": node_def.get("vcpu"),
            "memory_mb": node_def.get("memory_mb"),
            "services": node_def.get("services"),
            "mac": generate_mac(role, counters[role]),
            "role_index": counters[role],  # 1-based index within role
            "interfaces": [],       # populated by build_link_registry
            "bgp_neighbors": [],    # populated by build_link_registry
        }

    n = topo["nodes"]

    for b in n.get("borders", []):
        register(b, "border")
    for s in n.get("spines", []):
        register(s, "spine")
    for l in n.get("leafs", []):
        register(l, "leaf")
    for s in n.get("servers", []):
        register(s, "server")
    for i in n.get("infrastructure", []):
        register(i)

    return nodes


# ---------------------------------------------------------------------------
# Link registry builder
# ---------------------------------------------------------------------------

def build_link_registry(topo: dict, nodes: dict) -> list:
    """
    Parse all links from topology. For each link:
    - Create interface entries on both endpoint nodes
    - For FRR-to-FRR links, create BGP neighbor entries
    - Generate deterministic fabric MACs for FRR node interfaces
    - Return flat list of all links for bridge creation scripts

    Interface naming inside VMs:
        eth-<peer_name>   (e.g., eth-spine-1, eth-leaf-1a)
    """
    all_links = []
    link_index = 0

    # Track per-node peer index for fabric MAC generation
    node_peer_counters = {}

    for tier_name in ["border_bastion", "border_spine", "spine_leaf", "leaf_server"]:
        for link in topo["links"].get(tier_name, []):
            a_name = link["a"]
            b_name = link["b"]
            subnet = link["subnet"]
            a_ip = link["a_ip"]
            b_ip = link["b_ip"]

            bridge = f"br{link_index:03d}"
            link_index += 1

            a_ifname = f"eth-{b_name}"
            b_ifname = f"eth-{a_name}"

            # Generate fabric MACs for FRR node interfaces
            a_node = nodes.get(a_name, {})
            b_node = nodes.get(b_name, {})

            a_fabric_mac = ""
            b_fabric_mac = ""

            if a_node.get("type") == "frr-vm":
                node_peer_counters.setdefault(a_name, 0)
                node_peer_counters[a_name] += 1
                a_fabric_mac = generate_fabric_mac(
                    a_node["role"], a_node["role_index"],
                    node_peer_counters[a_name])

            if b_node.get("type") == "frr-vm":
                node_peer_counters.setdefault(b_name, 0)
                node_peer_counters[b_name] += 1
                b_fabric_mac = generate_fabric_mac(
                    b_node["role"], b_node["role_index"],
                    node_peer_counters[b_name])

            # Register interfaces on both nodes
            a_iface = {
                "name": a_ifname,
                "ip": a_ip,
                "peer_ip": b_ip,
                "prefix_len": int(subnet.split("/")[1]),
                "subnet": subnet,
                "peer": b_name,
                "bridge": bridge,
                "mac": a_fabric_mac,
            }
            b_iface = {
                "name": b_ifname,
                "ip": b_ip,
                "peer_ip": a_ip,
                "prefix_len": int(subnet.split("/")[1]),
                "subnet": subnet,
                "peer": a_name,
                "bridge": bridge,
                "mac": b_fabric_mac,
            }

            if a_name in nodes:
                nodes[a_name]["interfaces"].append(a_iface)
            if b_name in nodes:
                nodes[b_name]["interfaces"].append(b_iface)

            # BGP neighbors (only between FRR nodes)
            if (a_node.get("type") == "frr-vm" and
                    b_node.get("type") == "frr-vm"):
                nodes[a_name]["bgp_neighbors"].append({
                    "ip": b_ip,
                    "remote_asn": b_node["asn"],
                    "name": b_name,
                    "interface": a_ifname,
                })
                nodes[b_name]["bgp_neighbors"].append({
                    "ip": a_ip,
                    "remote_asn": a_node["asn"],
                    "name": a_name,
                    "interface": b_ifname,
                })

            all_links.append({
                "bridge": bridge,
                "a_name": a_name,
                "b_name": b_name,
                "a_ip": a_ip,
                "b_ip": b_ip,
                "a_ifname": a_ifname,
                "b_ifname": b_ifname,
                "a_mac": a_fabric_mac,
                "b_mac": b_fabric_mac,
                "subnet": subnet,
                "tier": tier_name,
            })

    return all_links


# ---------------------------------------------------------------------------
# Context builders (per template type)
# ---------------------------------------------------------------------------

def build_frr_context(node: dict, topo: dict, all_nodes: dict = None) -> dict:
    """Build the template context for a single FRR node's frr.conf."""
    timers = topo["timers"]
    loopback_ip = node["loopback"].split("/")[0]

    needs_allowas_in = node["role"] in ("border", "leaf")

    bastion_gateways = []
    if node["role"] == "border":
        for iface in node["interfaces"]:
            if iface["peer"] == "bastion":
                bastion_gateways.append(iface["peer_ip"])

    # For leaf nodes: build static routes to server loopbacks
    # Each server has a loopback /32 reachable via its P2P address
    server_static_routes = []
    if node["role"] == "leaf" and all_nodes:
        for iface in node["interfaces"]:
            peer = all_nodes.get(iface["peer"])
            if peer and peer["role"] == "server" and peer.get("loopback"):
                # Server loopback reachable via the server's P2P IP
                server_static_routes.append({
                    "prefix": peer["loopback"],
                    "nexthop": iface["peer_ip"],
                    "server": peer["name"],
                })

    return {
        "hostname": node["name"],
        "role": node["role"],
        "asn": node["asn"],
        "router_id": loopback_ip,
        "loopback": node["loopback"],
        "interfaces": node["interfaces"],
        "bgp_neighbors": node["bgp_neighbors"],
        "needs_allowas_in": needs_allowas_in,
        "evpn_vtep": node["evpn_vtep"],
        "bfd_tx": timers["bfd"]["tx_interval_ms"],
        "bfd_rx": timers["bfd"]["rx_interval_ms"],
        "bfd_mult": timers["bfd"]["detect_multiplier"],
        "bgp_keepalive": timers["bgp"]["keepalive_s"],
        "bgp_holdtime": timers["bgp"]["holdtime_s"],
        "is_spine": node["role"] == "spine",
        "bastion_gateways": bastion_gateways,
        "server_static_routes": server_static_routes,
    }


def build_prometheus_context(nodes: dict, topo: dict) -> dict:
    """Build context for prometheus.yml template."""
    obs = topo["observability"]["prometheus"]

    frr_targets = []
    vm_targets = []

    for name, node in sorted(nodes.items()):
        target = {
            "name": name,
            "ip": node["mgmt_ip"],
            "port": node["metrics_port"],
            "role": node["role"],
            "rack": node.get("rack", ""),
        }
        if node["type"] == "frr-vm":
            frr_targets.append(target)
        elif node["type"] == "fedora-vm":
            vm_targets.append(target)

    return {
        "scrape_interval": obs["scrape_interval_s"],
        "frr_targets": frr_targets,
        "vm_targets": vm_targets,
    }


def build_dnsmasq_context(nodes: dict, topo: dict) -> dict:
    """Build context for dnsmasq.conf template."""
    mgmt = topo["management"]

    reservations = []
    for name, node in sorted(nodes.items()):
        reservations.append({
            "name": name,
            "mac": node["mac"],
            "ip": node["mgmt_ip"],
        })

    return {
        "domain": mgmt["dns_domain"],
        "cidr": mgmt["cidr"],
        "gateway": mgmt["gateway"],
        "reservations": reservations,
    }


def build_loki_context(topo: dict) -> dict:
    """Build context for loki-config.yml template."""
    loki = topo["observability"]["loki"]
    return {
        "port": loki["port"],
    }


# ---------------------------------------------------------------------------
# Bridge/link context for shell scripts
# ---------------------------------------------------------------------------

def build_bridge_context(all_links: list, nodes: dict, topo: dict) -> dict:
    """Build context for setup-bridges.sh, setup-frr-links.sh, etc."""
    mgmt = topo["management"]

    frr_nodes = []
    for name, node in sorted(nodes.items()):
        if node["type"] == "frr-vm":
            frr_nodes.append({
                "name": name,
                "mac": node["mac"],
                "mgmt_ip": node["mgmt_ip"],
                "loopback": node.get("loopback", ""),
                "interfaces": node["interfaces"],
            })

    server_nodes = []
    srv_index = 0
    for name, node in sorted(nodes.items()):
        if node["role"] == "server":
            srv_index += 1
            leaf_a_mac = f"02:4E:57:04:{srv_index:02X}:01"
            leaf_b_mac = f"02:4E:57:04:{srv_index:02X}:02"

            # Validate: each server must have exactly 2 fabric interfaces
            ifaces = node["interfaces"]
            if len(ifaces) != 2:
                print(f"ERROR: server {name} has {len(ifaces)} fabric interfaces "
                      f"(expected 2)", file=sys.stderr)
                sys.exit(1)

            # Sort interfaces: leaf-Xa first (the "a" leaf), leaf-Xb second
            # This ensures interfaces[0] is always the "a" leaf regardless
            # of link ordering in topology.yml
            sorted_ifaces = sorted(ifaces, key=lambda i: i["peer"])

            server_nodes.append({
                "name": name,
                "mgmt_ip": node["mgmt_ip"],
                "loopback": node.get("loopback", ""),
                "interfaces": sorted_ifaces,
                "leaf_a_mac": leaf_a_mac,
                "leaf_b_mac": leaf_b_mac,
            })

    bastion_node = None
    if "bastion" in nodes:
        bastion = nodes["bastion"]
        bastion_node = {
            "name": "bastion",
            "mgmt_ip": bastion["mgmt_ip"],
            "interfaces": bastion.get("interfaces", []),
        }

    return {
        "links": all_links,
        "mgmt_bridge": mgmt["bridge"],
        "mgmt_cidr": mgmt["cidr"],
        "mgmt_gateway": mgmt["gateway"],
        "frr_nodes": frr_nodes,
        "server_nodes": server_nodes,
        "bastion_node": bastion_node,
    }


# ---------------------------------------------------------------------------
# Udev rules generator
# ---------------------------------------------------------------------------

def generate_udev_rules(node: dict) -> str:
    """Generate udev rules that rename interfaces by MAC address.

    Each fabric interface on an FRR VM gets a rule like:
      SUBSYSTEM=="net", ACTION=="add", ATTR{address}=="02:4e:57:01:01:01", NAME="eth-spine-1"
    """
    lines = [
        f"# NetWatch — udev interface naming rules for {node['name']}",
        "# Generated from topology.yml — DO NOT HAND-EDIT",
        "# Maps deterministic MACs to FRR interface names.",
        "",
    ]
    for iface in node["interfaces"]:
        if iface.get("mac"):
            mac_lower = iface["mac"].lower()
            lines.append(
                f'SUBSYSTEM=="net", ACTION=="add", '
                f'ATTR{{address}}=="{mac_lower}", '
                f'NAME="{iface["name"]}"'
            )
    lines.append("")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Rendering engine
# ---------------------------------------------------------------------------

def render_templates(topo: dict, nodes: dict, all_links: list,
                     template_dir: str, out_dir: str):
    """Render all templates and write output files."""
    env = Environment(
        loader=FileSystemLoader(template_dir),
        keep_trailing_newline=True,
        trim_blocks=True,
        lstrip_blocks=True,
    )

    # --- FRR configs + udev rules (per-node) ---
    frr_conf_tmpl = env.get_template("frr/frr.conf.j2")
    daemons_tmpl = env.get_template("frr/daemons.j2")
    vtysh_tmpl = env.get_template("frr/vtysh.conf.j2")

    for name, node in sorted(nodes.items()):
        if node["type"] != "frr-vm":
            continue

        ctx = build_frr_context(node, topo, nodes)
        node_dir = os.path.join(out_dir, "frr", name)
        os.makedirs(node_dir, exist_ok=True)

        with open(os.path.join(node_dir, "frr.conf"), "w") as f:
            f.write(frr_conf_tmpl.render(ctx))
        with open(os.path.join(node_dir, "daemons"), "w") as f:
            f.write(daemons_tmpl.render(ctx))
        with open(os.path.join(node_dir, "vtysh.conf"), "w") as f:
            f.write(vtysh_tmpl.render(ctx))

        # Udev rules for interface renaming
        udev_content = generate_udev_rules(node)
        with open(os.path.join(node_dir, "70-netwatch-fabric.rules"), "w") as f:
            f.write(udev_content)

    print(f"  [FRR]        12 node configs + udev rules -> {out_dir}/frr/")

    # --- Prometheus ---
    prom_tmpl = env.get_template("prometheus/prometheus.yml.j2")
    prom_ctx = build_prometheus_context(nodes, topo)
    prom_dir = os.path.join(out_dir, "prometheus")
    os.makedirs(prom_dir, exist_ok=True)
    with open(os.path.join(prom_dir, "prometheus.yml"), "w") as f:
        f.write(prom_tmpl.render(prom_ctx))
    print(f"  [Prometheus] scrape config   -> {out_dir}/prometheus/")

    # --- dnsmasq ---
    dns_tmpl = env.get_template("dnsmasq/dnsmasq.conf.j2")
    dns_ctx = build_dnsmasq_context(nodes, topo)
    dns_dir = os.path.join(out_dir, "dnsmasq")
    os.makedirs(dns_dir, exist_ok=True)
    with open(os.path.join(dns_dir, "dnsmasq.conf"), "w") as f:
        f.write(dns_tmpl.render(dns_ctx))
    print(f"  [dnsmasq]    DHCP/DNS config -> {out_dir}/dnsmasq/")

    # --- Loki ---
    loki_tmpl = env.get_template("loki/loki-config.yml.j2")
    loki_ctx = build_loki_context(topo)
    loki_dir = os.path.join(out_dir, "loki")
    os.makedirs(loki_dir, exist_ok=True)
    with open(os.path.join(loki_dir, "loki-config.yml"), "w") as f:
        f.write(loki_tmpl.render(loki_ctx))
    print(f"  [Loki]       log config      -> {out_dir}/loki/")

    # --- Bridge setup script ---
    bridge_tmpl = env.get_template("scripts/setup-bridges.sh.j2")
    bridge_ctx = build_bridge_context(all_links, nodes, topo)
    scripts_dir = os.path.join(out_dir, "..", "scripts", "fabric")
    os.makedirs(scripts_dir, exist_ok=True)
    with open(os.path.join(scripts_dir, "setup-bridges.sh"), "w") as f:
        f.write(bridge_tmpl.render(bridge_ctx))
    os.chmod(os.path.join(scripts_dir, "setup-bridges.sh"), 0o755)
    print(f"  [Scripts]    setup-bridges   -> scripts/fabric/")

    # --- FRR links setup script ---
    frr_links_tmpl = env.get_template("scripts/setup-frr-links.sh.j2")
    with open(os.path.join(scripts_dir, "setup-frr-links.sh"), "w") as f:
        f.write(frr_links_tmpl.render(bridge_ctx))
    os.chmod(os.path.join(scripts_dir, "setup-frr-links.sh"), 0o755)
    print(f"  [Scripts]    setup-frr-links -> scripts/fabric/")

    # --- Teardown script ---
    teardown_tmpl = env.get_template("scripts/teardown.sh.j2")
    with open(os.path.join(scripts_dir, "teardown.sh"), "w") as f:
        f.write(teardown_tmpl.render(bridge_ctx))
    os.chmod(os.path.join(scripts_dir, "teardown.sh"), 0o755)
    print(f"  [Scripts]    teardown        -> scripts/fabric/")

    # --- Status script ---
    status_tmpl = env.get_template("scripts/status.sh.j2")
    with open(os.path.join(scripts_dir, "status.sh"), "w") as f:
        f.write(status_tmpl.render(bridge_ctx))
    os.chmod(os.path.join(scripts_dir, "status.sh"), 0o755)
    print(f"  [Scripts]    status          -> scripts/fabric/")

    # --- Server links script ---
    server_links_tmpl = env.get_template("scripts/setup-server-links.sh.j2")
    with open(os.path.join(scripts_dir, "setup-server-links.sh"), "w") as f:
        f.write(server_links_tmpl.render(bridge_ctx))
    os.chmod(os.path.join(scripts_dir, "setup-server-links.sh"), 0o755)
    print(f"  [Scripts]    server-links    -> scripts/fabric/")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="NetWatch Config Generator")
    parser.add_argument("--topology", default="topology.yml",
                        help="Path to topology.yml")
    parser.add_argument("--outdir", default="generated",
                        help="Output directory")
    args = parser.parse_args()

    project_root = Path(__file__).resolve().parent.parent
    topo_path = project_root / args.topology
    template_dir = Path(__file__).resolve().parent / "templates"
    out_dir = project_root / args.outdir

    print(f"NetWatch Config Generator")
    print(f"  topology:  {topo_path}")
    print(f"  templates: {template_dir}")
    print(f"  output:    {out_dir}")
    print()

    topo = load_topology(str(topo_path))
    print(f"Loaded topology: {topo['project']['name']} v{topo['project']['version']}")

    nodes = build_node_registry(topo)
    all_links = build_link_registry(topo, nodes)

    frr_count = sum(1 for n in nodes.values() if n["type"] == "frr-vm")
    vm_count = sum(1 for n in nodes.values() if n["type"] == "fedora-vm")
    bgp_sessions = sum(len(n["bgp_neighbors"]) for n in nodes.values()) // 2
    print(f"  {len(nodes)} nodes ({frr_count} FRR VMs, {vm_count} Fedora VMs)")
    print(f"  {len(all_links)} fabric links")
    print(f"  {bgp_sessions} BGP sessions")
    print()

    print("Generating configs:")
    render_templates(topo, nodes, all_links, str(template_dir), str(out_dir))
    print()
    print("Done.")


if __name__ == "__main__":
    main()
