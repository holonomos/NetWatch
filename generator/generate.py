#!/usr/bin/env python3
"""NetWatch config generator.

Renders all fabric config from topology.yml (single source of truth): FRR configs,
udev rules, Prometheus scrape targets, dnsmasq DHCP/DNS, Loki, wiring/teardown/status
scripts.

Usage:
    python3 generator/generate.py [--topology topology.yml] [--outdir generated]
"""

import argparse
import os
import shutil
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
    "overlay": 0x07,   # EVPN tenant overlay access NICs (tnt0/tnt1, eth-ovl[-b])
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

    # --- EVPN overlay context ---
    # All nodes receive overlay_supernet so the CONNECTED-FILTER deny line is
    # emitted uniformly. Only EVPN leaves receive the VRF/L3VNI/anycast SVI +
    # per-tenant material that drives the symmetric-IRB stanzas in frr.conf.j2.
    ev = topo.get("evpn", {})
    is_evpn_leaf = bool(node["role"] == "leaf" and node.get("evpn_vtep")
                        and ev.get("tenants"))
    overlay_supernet = ev.get("overlay_supernet", "10.99.0.0/16")
    anycast_gw_mac = ev.get("anycast_gw_mac", "00:00:5e:00:01:99")
    l3vni = ev.get("l3vni", 10999)
    l3vni_vrf = ev.get("l3vni_vrf", "Tenant-A")
    l3vni_rt = ev.get("l3vni_rt", "65000:{}".format(l3vni))
    tenants = ev.get("tenants", []) if is_evpn_leaf else []

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
        # --- EVPN overlay (additive) ---
        "is_evpn_leaf": is_evpn_leaf,
        "overlay_supernet": overlay_supernet,
        "anycast_gw_mac": anycast_gw_mac,
        "l3vni": l3vni,
        "l3vni_vrf": l3vni_vrf,
        "l3vni_rt": l3vni_rt,
        "tenants": tenants,
    }


def build_prometheus_context(nodes: dict, topo: dict) -> dict:
    """Build context for prometheus.yml template.

    Node registry is authoritative for scrape targets (real mgmt_ip / metrics_port
    per node, including obs). The optional observability.targets block is cross-checked
    against it: a node in one but not the other prints a drift warning.
    """
    obs = topo["observability"]["prometheus"]

    frr_targets = []
    vm_targets = []

    for name, node in sorted(nodes.items()):
        # A node is scrapeable only if it actually exposes a metrics endpoint.
        if not node.get("metrics_port"):
            continue
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

    # --- Cross-check against the declared observability.targets block ---
    # The declared scrape targets live under observability.prometheus.targets
    # (not directly under observability), so descend through 'prometheus' first.
    declared = topo["observability"].get("prometheus", {}).get("targets", {})
    declared_names = set()
    for group in declared.values():
        if isinstance(group, dict):
            declared_names.update(group.get("nodes", []) or [])
    if declared_names:
        rendered_names = {t["name"] for t in frr_targets} | \
                         {t["name"] for t in vm_targets}
        missing_from_declared = rendered_names - declared_names
        missing_from_registry = declared_names - rendered_names
        for nm in sorted(missing_from_registry):
            print(f"  WARNING: observability.targets lists '{nm}' but it has no "
                  f"scrapeable node in the registry (drift)",
                  file=sys.stderr)
        for nm in sorted(missing_from_declared):
            print(f"  WARNING: node '{nm}' is scraped (from registry) but is "
                  f"absent from observability.targets (drift)",
                  file=sys.stderr)

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

def _server_index_map(nodes: dict) -> dict:
    """Return {server_name: 1-based srv_index} using sorted-name order.

    Must match the enumeration in build_bridge_context (sorted server
    nodes), because the server fabric MACs (02:4E:57:04:<idx>:0X) and the
    overlay-derived names (br-ovl-<idx>, tnt MAC 02:4E:57:07:<idx>:0X) all key
    off the same index.
    """
    idx = {}
    n = 0
    for name, node in sorted(nodes.items()):
        if node["role"] == "server":
            n += 1
            idx[name] = n
    return idx


def build_overlay_context(nodes: dict, topo: dict) -> dict:
    """Derive EVPN overlay wiring lists from evpn.tenants[].members.

    Returns three lists (empty when evpn.tenants is absent, so no overlay
    wiring is emitted):
      overlay_bridges      : unique host bridge names (br-ovl-<idx>[-b])
      leaf_overlay_nics     : [{leaf, bridge, mac, name}]  (leaf access NIC, NO IP)
      server_overlay_nics   : [{server, bridge, mac, ip, name}]

    Also returns leaf_overlay_udev: {leaf_name: [{mac, name}, ...]} so udev
    rules can rename the leaf access NIC (02:4e:57:03:f0:NN → eth-ovl[-b]).

    The leaf access-NIC sequence byte (0xF0:<seq>) is allocated globally in a
    deterministic order (tenant order, then member order) so it never collides
    with real fabric peer MACs (peer index <= 6) or across tenants.
    """
    ev = topo.get("evpn", {})
    tenants = ev.get("tenants", [])

    overlay_bridges = []
    seen_bridges = set()
    leaf_overlay_nics = []
    server_overlay_nics = []
    leaf_overlay_udev = {}

    if not tenants:
        return {
            "overlay_bridges": overlay_bridges,
            "leaf_overlay_nics": leaf_overlay_nics,
            "server_overlay_nics": server_overlay_nics,
            "leaf_overlay_udev": leaf_overlay_udev,
        }

    srv_idx = _server_index_map(nodes)
    leaf_nic_seq = 0  # global 1-based counter for 02:4E:57:03:F0:<seq>

    for tenant in tenants:
        for member in tenant.get("members", []):
            server = member["server"]
            leaf = member["leaf"]
            nic = member.get("nic", "tnt0")
            overlay_ip = member["overlay_ip"]
            server_mac = member["mac"]

            if server not in srv_idx:
                print(f"ERROR: evpn tenant member references unknown server "
                      f"'{server}'", file=sys.stderr)
                sys.exit(1)
            ii = srv_idx[server]

            # Tenant-B (the second NIC on a server) → "-b" suffixed objects.
            is_secondary = nic != "tnt0"
            host_bridge = f"br-ovl-{ii:02X}" + ("-b" if is_secondary else "")
            leaf_nic_name = "eth-ovl-b" if is_secondary else "eth-ovl"

            # Leaf access NIC MAC: tier 03 (leaf), peer-byte 0xF0 (well above the
            # real per-leaf peer count of <=6, so no collision with fabric MACs),
            # global seq in the last byte.
            leaf_nic_seq += 1
            leaf_nic_mac = f"02:4E:57:03:F0:{leaf_nic_seq:02X}"

            if host_bridge not in seen_bridges:
                seen_bridges.add(host_bridge)
                overlay_bridges.append(host_bridge)

            leaf_overlay_nics.append({
                "leaf": leaf,
                "bridge": host_bridge,
                "mac": leaf_nic_mac,
                "name": leaf_nic_name,
            })
            leaf_overlay_udev.setdefault(leaf, []).append({
                "mac": leaf_nic_mac,
                "name": leaf_nic_name,
            })
            server_overlay_nics.append({
                "server": server,
                "bridge": host_bridge,
                "mac": server_mac,
                "ip": overlay_ip,
                "name": nic,
            })

    return {
        "overlay_bridges": overlay_bridges,
        "leaf_overlay_nics": leaf_overlay_nics,
        "server_overlay_nics": server_overlay_nics,
        "leaf_overlay_udev": leaf_overlay_udev,
    }


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

    overlay = build_overlay_context(nodes, topo)

    return {
        "links": all_links,
        "mgmt_bridge": mgmt["bridge"],
        "mgmt_cidr": mgmt["cidr"],
        "mgmt_gateway": mgmt["gateway"],
        "frr_nodes": frr_nodes,
        "server_nodes": server_nodes,
        "bastion_node": bastion_node,
        # --- EVPN overlay wiring ---
        "overlay_bridges": overlay["overlay_bridges"],
        "leaf_overlay_nics": overlay["leaf_overlay_nics"],
        "server_overlay_nics": overlay["server_overlay_nics"],
    }


# ---------------------------------------------------------------------------
# Udev rules generator
# ---------------------------------------------------------------------------

def generate_udev_rules(node: dict, overlay_nics: list = None) -> str:
    """Generate udev rules that rename interfaces by MAC address.

    Each fabric interface on an FRR VM gets a rule like:
      SUBSYSTEM=="net", ACTION=="add", ATTR{address}=="02:4e:57:01:01:01", NAME="eth-spine-1"

    overlay_nics (optional) is a list of {mac, name} for EVPN leaf overlay
    access NICs (eth-ovl / eth-ovl-b), which are attached outside the link
    registry and so are not present in node["interfaces"].
    """
    lines = [
        f"# NetWatch: udev interface naming rules for {node['name']}",
        "# Generated from topology.yml: DO NOT HAND-EDIT",
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
    if overlay_nics:
        lines.append("")
        lines.append("# EVPN overlay access NICs (tenant L2 access ports, no IP)")
        for nic in overlay_nics:
            mac_lower = nic["mac"].lower()
            lines.append(
                f'SUBSYSTEM=="net", ACTION=="add", '
                f'ATTR{{address}}=="{mac_lower}", '
                f'NAME="{nic["name"]}"'
            )
    lines.append("")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Chaos bridge-map emitter (single-source-of-truth for scripts/chaos/lib.sh)
# ---------------------------------------------------------------------------

def write_chaos_bridge_map(nodes: dict, all_links: list, topo: dict,
                           out_dir: str) -> None:
    """Emit generated/chaos/bridge-map.sh consumed by scripts/chaos/lib.sh.

    Contains, all derived from the same registries the fabric scripts use:
      BRIDGE_MAP   : "nodeA:nodeB" -> bridge (both directions), from all_links
      FRR_NODES    : sorted frr-vm node names
      RACK_LEAFS   : "rack-N" -> "leaf-Na leaf-Nb"
      overlay aliases: leaf<->br-ovl-* and an overlay-suffixed leaf<->server key
                       (the bare leaf:server key stays the /30 underlay link).

    lib.sh sources this file AFTER its hardcoded fallbacks so generated values
    win when present and the fallbacks stand when it is absent.
    """
    out = os.path.join(out_dir, "chaos")
    os.makedirs(out, exist_ok=True)

    frr_names = sorted(n for n, nd in nodes.items() if nd["type"] == "frr-vm")

    # rack -> "leaf-Na leaf-Nb" (leaf nodes carry a rack tag)
    rack_leafs = {}
    for name, nd in sorted(nodes.items()):
        if nd["role"] == "leaf" and nd.get("rack"):
            rack_leafs.setdefault(nd["rack"], []).append(name)

    overlay = build_overlay_context(nodes, topo)
    # server_overlay_nics carries {server, bridge}; leaf_overlay_nics {leaf, bridge}.
    bridge_to_server = {x["bridge"]: x["server"]
                        for x in overlay["server_overlay_nics"]}

    lines = []
    lines.append("#!/usr/bin/env bash")
    lines.append("# NetWatch chaos bridge map")
    lines.append("# Generated from topology.yml: DO NOT HAND-EDIT")
    lines.append("# Sourced by scripts/chaos/lib.sh (overrides its hardcoded fallback).")
    lines.append("")
    lines.append("declare -A BRIDGE_MAP=(")
    for lk in all_links:
        a, b, br = lk["a_name"], lk["b_name"], lk["bridge"]
        lines.append('    [%s:%s]=%s    [%s:%s]=%s' % (a, b, br, b, a, br))
    lines.append("")
    lines.append("    # EVPN overlay access links (leaf <-> host bridge). The bare")
    lines.append("    # leaf:server key above stays the /30 underlay link; overlay is")
    lines.append("    # reachable via the bridge key and an -ovl suffixed leaf:server key.")
    for x in overlay["leaf_overlay_nics"]:
        leaf, br = x["leaf"], x["bridge"]
        lines.append('    [%s:%s]=%s    [%s:%s]=%s' % (leaf, br, br, br, leaf, br))
        srv = bridge_to_server.get(br)
        if srv:
            lines.append('    [%s:%s-ovl]=%s    [%s-ovl:%s]=%s'
                         % (leaf, srv, br, srv, leaf, br))
    lines.append(")")
    lines.append("")
    lines.append("FRR_NODES=(")
    lines.append("    " + " ".join(frr_names))
    lines.append(")")
    lines.append("")
    lines.append("declare -A RACK_LEAFS=(")
    for rack in sorted(rack_leafs):
        lines.append('    [%s]="%s"' % (rack, " ".join(sorted(rack_leafs[rack]))))
    lines.append(")")
    lines.append("")

    path = os.path.join(out, "bridge-map.sh")
    with open(path, "w") as fh:
        fh.write("\n".join(lines))
    print(f"  [Scripts]    chaos bridge-map -> {out_dir}/chaos/")


# ---------------------------------------------------------------------------
# EVPN params emitter (single-source-of-truth for scripts/fabric/setup-evpn.sh)
# ---------------------------------------------------------------------------

def write_evpn_params(nodes: dict, topo: dict, out_dir: str) -> None:
    """Emit generated/evpn/evpn-params.sh consumed by scripts/fabric/setup-evpn.sh.

    Derives the leaf->loopback map, the tenantspec strings, the per-server
    overlay member "nic,gw" pairs, and the EVPN scalars straight from evpn.*
    + leaf loopbacks. setup-evpn.sh sources it AFTER its literal definitions so
    the generated values win when present and the literals stand when absent.
    Empty (header-only data) when evpn.tenants is absent.
    """
    ev = topo.get("evpn", {})
    out = os.path.join(out_dir, "evpn")
    os.makedirs(out, exist_ok=True)

    l3vni = ev.get("l3vni", 10999)
    vrf = ev.get("l3vni_vrf", "Tenant-A")
    l3vlan = ev.get("l3vni_vlan", 999)
    anycast_mac = ev.get("anycast_gw_mac", "00:00:5e:00:01:99")
    tenants = ev.get("tenants", [])

    # Primary L2VNI = the first tenant's l2vni (matches setup-evpn.sh VNI=).
    primary_vni = tenants[0]["l2vni"] if tenants else ""

    # leaf -> loopback (strip /32)
    leafs = {}
    for name, nd in sorted(nodes.items()):
        if nd["role"] == "leaf" and nd.get("loopback"):
            leafs[name] = nd["loopback"].split("/")[0]

    # tenantspec list: "l2vni:vlan:gwcidr:sviname"
    tenant_specs = []
    for t in tenants:
        tenant_specs.append("%s:%s:%s:%s" % (
            t["l2vni"], t["access_vlan"], t["anycast_gw"], t["svi"]))

    # OVERLAY_MEMBERS: server -> space-separated "nic,gw" (gw = bare .1 host)
    members = {}
    for t in tenants:
        gw_host = t["anycast_gw"].split("/")[0]
        for m in t.get("members", []):
            members.setdefault(m["server"], []).append(
                "%s,%s" % (m.get("nic", "tnt0"), gw_host))

    lines = []
    lines.append("#!/usr/bin/env bash")
    lines.append("# NetWatch EVPN params")
    lines.append("# Generated from topology.yml: DO NOT HAND-EDIT")
    lines.append("# Sourced by scripts/fabric/setup-evpn.sh (overrides its literals).")
    lines.append("")
    lines.append('VNI=%s' % primary_vni)
    lines.append('L3VNI=%s' % l3vni)
    lines.append('VRF=%s' % vrf)
    lines.append('L3VLAN=%s' % l3vlan)
    lines.append('ANYCAST_MAC=%s' % anycast_mac)
    lines.append('TENANTS="%s"' % " ".join(tenant_specs))
    lines.append("")
    lines.append("declare -A LEAFS=(")
    for leaf in sorted(leafs):
        lines.append('    [%s]=%s' % (leaf, leafs[leaf]))
    lines.append(")")
    lines.append("")
    lines.append("declare -A OVERLAY_MEMBERS=(")
    for srv in sorted(members):
        lines.append('    [%s]="%s"' % (srv, " ".join(members[srv])))
    lines.append(")")
    lines.append("")

    path = os.path.join(out, "evpn-params.sh")
    with open(path, "w") as fh:
        fh.write("\n".join(lines))
    print(f"  [Scripts]    evpn params      -> {out_dir}/evpn/")


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

    # EVPN leaf overlay access-NIC udev map (empty when evpn.tenants is absent).
    overlay_udev = build_overlay_context(nodes, topo)["leaf_overlay_udev"]

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

        # Udev rules for interface renaming (+ overlay access NICs on member leaves)
        udev_content = generate_udev_rules(node, overlay_udev.get(name))
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

    # Alert rules (referenced by prometheus.yml rule_files; copied by provision-obs.sh).
    alerts_tmpl = env.get_template("prometheus/alerts.yml.j2")
    with open(os.path.join(prom_dir, "alerts.yml"), "w") as f:
        f.write(alerts_tmpl.render(prom_ctx))
    print(f"  [Prometheus] alert rules     -> {out_dir}/prometheus/")

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

    # --- Grafana dashboards (copied verbatim from templates/grafana/dashboards) ---
    # Dashboards are authored as source under templates/ and rendered (copied) into
    # generated/ so the "never hand-edit generated/" rule holds for them too. The
    # obs VM rsyncs generated/grafana and a file provider loads every *.json.
    grafana_src = os.path.join(template_dir, "grafana", "dashboards")
    grafana_dst = os.path.join(out_dir, "grafana", "dashboards")
    os.makedirs(grafana_dst, exist_ok=True)
    # Templates are authoritative: clear any stale *.json in the dest first so a
    # dashboard deleted from templates/ does not linger as a generated file (and
    # keep loading on the obs VM). Only *.json files are removed; nothing else.
    for fn in os.listdir(grafana_dst):
        if fn.endswith(".json"):
            os.remove(os.path.join(grafana_dst, fn))
    dash_count = 0
    if os.path.isdir(grafana_src):
        for fn in sorted(os.listdir(grafana_src)):
            if fn.endswith(".json"):
                shutil.copyfile(os.path.join(grafana_src, fn),
                                os.path.join(grafana_dst, fn))
                dash_count += 1
    print(f"  [Grafana]    {dash_count} dashboards    -> {out_dir}/grafana/dashboards/")

    # Cross-check the declared observability.grafana.dashboards list against the
    # *.json files actually copied (registry/disk authoritative; declared list
    # cross-checked for drift, mirroring the prometheus targets drift check).
    declared_dash = set(
        topo.get("observability", {}).get("grafana", {}).get("dashboards", []) or [])
    if declared_dash:
        disk_dash = set()
        if os.path.isdir(grafana_src):
            disk_dash = {fn[:-5] for fn in os.listdir(grafana_src)
                         if fn.endswith(".json")}
        for nm in sorted(declared_dash - disk_dash):
            print(f"  WARNING: grafana dashboard '{nm}' is declared in topology.yml "
                  f"but has no .json on disk (drift)", file=sys.stderr)
        for nm in sorted(disk_dash - declared_dash):
            print(f"  WARNING: grafana dashboard '{nm}.json' exists on disk but is "
                  f"absent from observability.grafana.dashboards (drift)",
                  file=sys.stderr)

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

    # --- Chaos bridge map + EVPN params (generated data for hand-maintained scripts) ---
    write_chaos_bridge_map(nodes, all_links, topo, out_dir)
    write_evpn_params(nodes, topo, out_dir)


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
