#!/usr/bin/env python3
"""
NetWatch Config Generator
=========================
Reads topology.yml (single source of truth) and produces all configuration
files for the fabric: FRR configs, Prometheus scrape targets, dnsmasq
DHCP/DNS, and Loki config.

Usage:
    python3 generator/generate.py [--topology topology.yml] [--outdir generated]
"""

import argparse
import ipaddress
import os
import sys
from pathlib import Path

import yaml
from jinja2 import Environment, FileSystemLoader


# ---------------------------------------------------------------------------
# MAC address generation (deterministic, locally-administered)
# ---------------------------------------------------------------------------
# Prefix 02:NW = locally-administered + unicast
# Format: 02:4E:57:TT:II:II
#   02    = locally administered, unicast
#   4E:57 = "NW" in ASCII
#   TT    = tier code (01=border, 02=spine, 03=leaf, 04=server, 05=infra)
#   II:II = node index within tier (0001, 0002, ...)

TIER_CODES = {
    "border": 0x01,
    "spine": 0x02,
    "leaf": 0x03,
    "server": 0x04,
    "bastion": 0x05,
    "mgmt": 0x05,
}


def generate_mac(role: str, index: int) -> str:
    """Generate a deterministic MAC address for a node's management interface."""
    tier = TIER_CODES.get(role, 0xFF)
    return f"02:4E:57:{tier:02X}:{(index >> 8) & 0xFF:02X}:{index & 0xFF:02X}"


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
    - Return flat list of all links for bridge creation scripts

    Interface naming inside containers/VMs:
        eth-<peer_name>   (e.g., eth-spine-1, eth-leaf-1a)
    """
    all_links = []
    link_index = 0

    for tier_name in ["border_spine", "spine_leaf", "leaf_server"]:
        for link in topo["links"].get(tier_name, []):
            a_name = link["a"]
            b_name = link["b"]
            subnet = link["subnet"]
            a_ip = link["a_ip"]
            b_ip = link["b_ip"]

            # Bridge name: br-<index>-<a>-<b> (truncated for 15-char limit)
            bridge = f"br{link_index:03d}"
            link_index += 1

            # Veth names inside namespaces
            a_ifname = f"eth-{b_name}"
            b_ifname = f"eth-{a_name}"

            # Register interfaces on both nodes
            a_iface = {
                "name": a_ifname,
                "ip": a_ip,
                "peer_ip": b_ip,
                "prefix_len": int(subnet.split("/")[1]),
                "subnet": subnet,
                "peer": b_name,
                "bridge": bridge,
            }
            b_iface = {
                "name": b_ifname,
                "ip": b_ip,
                "peer_ip": a_ip,
                "prefix_len": int(subnet.split("/")[1]),
                "subnet": subnet,
                "peer": a_name,
                "bridge": bridge,
            }

            if a_name in nodes:
                nodes[a_name]["interfaces"].append(a_iface)
            if b_name in nodes:
                nodes[b_name]["interfaces"].append(b_iface)

            # BGP neighbors (only between FRR nodes, not servers)
            a_node = nodes.get(a_name, {})
            b_node = nodes.get(b_name, {})

            if (a_node.get("type") == "frr-container" and
                    b_node.get("type") == "frr-container"):
                # A peers with B
                nodes[a_name]["bgp_neighbors"].append({
                    "ip": b_ip,
                    "remote_asn": b_node["asn"],
                    "name": b_name,
                    "interface": a_ifname,
                })
                # B peers with A
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
                "subnet": subnet,
                "tier": tier_name,
            })

    return all_links


# ---------------------------------------------------------------------------
# Context builders (per template type)
# ---------------------------------------------------------------------------

def build_frr_context(node: dict, topo: dict) -> dict:
    """Build the template context for a single FRR node's frr.conf."""
    timers = topo["timers"]
    loopback_ip = node["loopback"].split("/")[0]

    # Determine if this node needs allowas-in:
    # Borders (AS 65000 shared) and leafs (ASN-per-rack shared) need it
    # on sessions facing spines, so peer routes with their own ASN aren't rejected.
    needs_allowas_in = node["role"] in ("border", "leaf")

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
        # Spines need next-hop-unchanged for EVPN
        "is_spine": node["role"] == "spine",
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
        if node["type"] == "frr-container":
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
    """Build context for setup-bridges.sh and setup-frr-containers.sh."""
    mgmt = topo["management"]

    frr_nodes = []
    for name, node in sorted(nodes.items()):
        if node["type"] == "frr-container":
            frr_nodes.append({
                "name": name,
                "mac": node["mac"],
                "mgmt_ip": node["mgmt_ip"],
                "interfaces": node["interfaces"],
            })

    server_nodes = []
    srv_index = 0
    for name, node in sorted(nodes.items()):
        if node["role"] == "server":
            srv_index += 1
            # Generate deterministic MACs for fabric NICs (leaf-a and leaf-b)
            # Format: 02:4E:57:06:XX:01 (leaf-a), 02:4E:57:06:XX:02 (leaf-b)
            leaf_a_mac = f"02:4E:57:06:{srv_index:02X}:01"
            leaf_b_mac = f"02:4E:57:06:{srv_index:02X}:02"
            server_nodes.append({
                "name": name,
                "mgmt_ip": node["mgmt_ip"],
                "interfaces": node["interfaces"],
                "leaf_a_mac": leaf_a_mac,
                "leaf_b_mac": leaf_b_mac,
            })

    return {
        "links": all_links,
        "mgmt_bridge": mgmt["bridge"],
        "mgmt_cidr": mgmt["cidr"],
        "mgmt_gateway": mgmt["gateway"],
        "frr_nodes": frr_nodes,
        "server_nodes": server_nodes,
    }


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

    # --- FRR configs (per-node) ---
    frr_conf_tmpl = env.get_template("frr/frr.conf.j2")
    daemons_tmpl = env.get_template("frr/daemons.j2")
    vtysh_tmpl = env.get_template("frr/vtysh.conf.j2")

    for name, node in sorted(nodes.items()):
        if node["type"] != "frr-container":
            continue

        ctx = build_frr_context(node, topo)
        node_dir = os.path.join(out_dir, "frr", name)
        os.makedirs(node_dir, exist_ok=True)

        with open(os.path.join(node_dir, "frr.conf"), "w") as f:
            f.write(frr_conf_tmpl.render(ctx))
        with open(os.path.join(node_dir, "daemons"), "w") as f:
            f.write(daemons_tmpl.render(ctx))
        with open(os.path.join(node_dir, "vtysh.conf"), "w") as f:
            f.write(vtysh_tmpl.render(ctx))

    print(f"  [FRR]        12 node configs → {out_dir}/frr/")

    # --- Prometheus ---
    prom_tmpl = env.get_template("prometheus/prometheus.yml.j2")
    prom_ctx = build_prometheus_context(nodes, topo)
    prom_dir = os.path.join(out_dir, "prometheus")
    os.makedirs(prom_dir, exist_ok=True)
    with open(os.path.join(prom_dir, "prometheus.yml"), "w") as f:
        f.write(prom_tmpl.render(prom_ctx))
    print(f"  [Prometheus] scrape config   → {out_dir}/prometheus/")

    # --- dnsmasq ---
    dns_tmpl = env.get_template("dnsmasq/dnsmasq.conf.j2")
    dns_ctx = build_dnsmasq_context(nodes, topo)
    dns_dir = os.path.join(out_dir, "dnsmasq")
    os.makedirs(dns_dir, exist_ok=True)
    with open(os.path.join(dns_dir, "dnsmasq.conf"), "w") as f:
        f.write(dns_tmpl.render(dns_ctx))
    print(f"  [dnsmasq]    DHCP/DNS config → {out_dir}/dnsmasq/")

    # --- Loki ---
    loki_tmpl = env.get_template("loki/loki-config.yml.j2")
    loki_ctx = build_loki_context(topo)
    loki_dir = os.path.join(out_dir, "loki")
    os.makedirs(loki_dir, exist_ok=True)
    with open(os.path.join(loki_dir, "loki-config.yml"), "w") as f:
        f.write(loki_tmpl.render(loki_ctx))
    print(f"  [Loki]       log config      → {out_dir}/loki/")

    # --- Bridge setup script ---
    bridge_tmpl = env.get_template("scripts/setup-bridges.sh.j2")
    bridge_ctx = build_bridge_context(all_links, nodes, topo)
    scripts_dir = os.path.join(out_dir, "..", "scripts", "fabric")
    os.makedirs(scripts_dir, exist_ok=True)
    with open(os.path.join(scripts_dir, "setup-bridges.sh"), "w") as f:
        f.write(bridge_tmpl.render(bridge_ctx))
    os.chmod(os.path.join(scripts_dir, "setup-bridges.sh"), 0o755)
    print(f"  [Scripts]    setup-bridges   → scripts/fabric/")

    # --- FRR container setup script ---
    frr_setup_tmpl = env.get_template("scripts/setup-frr-containers.sh.j2")
    with open(os.path.join(scripts_dir, "setup-frr-containers.sh"), "w") as f:
        f.write(frr_setup_tmpl.render(bridge_ctx))
    os.chmod(os.path.join(scripts_dir, "setup-frr-containers.sh"), 0o755)
    print(f"  [Scripts]    setup-frr       → scripts/fabric/")

    # --- Teardown script ---
    teardown_tmpl = env.get_template("scripts/teardown.sh.j2")
    with open(os.path.join(scripts_dir, "teardown.sh"), "w") as f:
        f.write(teardown_tmpl.render(bridge_ctx))
    os.chmod(os.path.join(scripts_dir, "teardown.sh"), 0o755)
    print(f"  [Scripts]    teardown        → scripts/fabric/")

    # --- Status script ---
    status_tmpl = env.get_template("scripts/status.sh.j2")
    with open(os.path.join(scripts_dir, "status.sh"), "w") as f:
        f.write(status_tmpl.render(bridge_ctx))
    os.chmod(os.path.join(scripts_dir, "status.sh"), 0o755)
    print(f"  [Scripts]    status          → scripts/fabric/")

    # --- Server links script ---
    server_links_tmpl = env.get_template("scripts/setup-server-links.sh.j2")
    with open(os.path.join(scripts_dir, "setup-server-links.sh"), "w") as f:
        f.write(server_links_tmpl.render(bridge_ctx))
    os.chmod(os.path.join(scripts_dir, "setup-server-links.sh"), 0o755)
    print(f"  [Scripts]    server-links    → scripts/fabric/")


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

    # Resolve paths relative to project root
    project_root = Path(__file__).resolve().parent.parent
    topo_path = project_root / args.topology
    template_dir = Path(__file__).resolve().parent / "templates"
    out_dir = project_root / args.outdir

    print(f"NetWatch Config Generator")
    print(f"  topology:  {topo_path}")
    print(f"  templates: {template_dir}")
    print(f"  output:    {out_dir}")
    print()

    # Load
    topo = load_topology(str(topo_path))
    print(f"Loaded topology: {topo['project']['name']} v{topo['project']['version']}")

    # Build registries
    nodes = build_node_registry(topo)
    all_links = build_link_registry(topo, nodes)

    # Stats
    frr_count = sum(1 for n in nodes.values() if n["type"] == "frr-container")
    vm_count = sum(1 for n in nodes.values() if n["type"] == "fedora-vm")
    bgp_sessions = sum(len(n["bgp_neighbors"]) for n in nodes.values()) // 2
    print(f"  {len(nodes)} nodes ({frr_count} FRR containers, {vm_count} VMs)")
    print(f"  {len(all_links)} fabric links")
    print(f"  {bgp_sessions} BGP sessions")
    print()

    # Render
    print("Generating configs:")
    render_templates(topo, nodes, all_links, str(template_dir), str(out_dir))
    print()
    print("Done.")


if __name__ == "__main__":
    main()
