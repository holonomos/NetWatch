"""Emit a valid NetWatch topology.yml from the canonical model.

Generates YAML that the existing generator pipeline consumes unchanged.
"""

from __future__ import annotations

from collections import defaultdict
from pathlib import Path

import yaml

from .model import (
    CanonicalDevice,
    CanonicalEdge,
    CanonicalTopology,
    DeviceRole,
    IPMapping,
)


# NetWatch defaults for fields not derivable from prod configs
DEFAULT_DILATION = 10
DEFAULT_BFD_TX = 1000
DEFAULT_BFD_RX = 1000
DEFAULT_BFD_MULT = 3
DEFAULT_BGP_KEEPALIVE = 30
DEFAULT_BGP_HOLDTIME = 90

METALLB_ASN = 65200
SERVICES_CIDR = "10.100.0.0/24"


def emit_topology(
    topo: CanonicalTopology,
    ip_mappings: list[IPMapping],
    output_path: Path,
    fragment_dir: Path | None = None,
    snapshot_name: str = "imported",
) -> None:
    """Write topology.yml from the canonical model.

    Args:
        topo: Fully processed topology (roles assigned, IPs remapped).
        ip_mappings: IP mapping table (for documentation).
        output_path: Where to write topology.yml.
        fragment_dir: Path to FRR fragment files (relative to topology.yml).
        snapshot_name: Name for the project metadata.
    """
    # Collect active devices by role
    borders = _sorted_by_name(topo, DeviceRole.BORDER)
    spines = _sorted_by_name(topo, DeviceRole.SPINE)
    leafs = _sorted_by_name(topo, DeviceRole.LEAF)
    servers = _sorted_by_name(topo, DeviceRole.SERVER)

    # Extract ASN info
    border_asn = borders[0].bgp_asn if borders else 65000
    spine_asn = spines[0].bgp_asn if spines else 65001
    rack_asns = _collect_rack_asns(leafs)

    # Timers
    timers = topo.bgp_timers
    keepalive = timers.keepalive_s if timers else DEFAULT_BGP_KEEPALIVE
    holdtime = timers.holdtime_s if timers else DEFAULT_BGP_HOLDTIME
    bfd_tx = timers.bfd_tx_ms if timers else DEFAULT_BFD_TX
    bfd_rx = timers.bfd_rx_ms if timers else DEFAULT_BFD_RX
    bfd_mult = timers.bfd_multiplier if timers else DEFAULT_BFD_MULT

    # Build the topology dict
    doc: dict = {
        "project": {
            "name": f"netwatch-{snapshot_name}",
            "version": "1.0",
            "description": f"Imported from production snapshot '{snapshot_name}'",
        },
        "timers": {
            "dilation_factor": DEFAULT_DILATION,
            "bfd": {
                "tx_interval_ms": bfd_tx * DEFAULT_DILATION if bfd_tx < 500 else bfd_tx,
                "rx_interval_ms": bfd_rx * DEFAULT_DILATION if bfd_rx < 500 else bfd_rx,
                "detect_multiplier": bfd_mult,
            },
            "bgp": {
                "keepalive_s": keepalive,
                "holdtime_s": holdtime,
            },
        },
        "asn": {
            "border": border_asn,
            "spine": spine_asn,
            "metallb": METALLB_ASN,
            "racks": rack_asns,
        },
        "addressing": {
            "loopback": {"cidr": "10.0.0.0/16"},
            "fabric": {
                "cidr": "172.16.0.0/16",
                "pools": _build_fabric_pools(rack_asns),
            },
            "services": {"cidr": SERVICES_CIDR},
            "management": {
                "cidr": "192.168.0.0/24",
                "gateway": "192.168.0.1",
            },
        },
        "nodes": {
            "borders": [_node_entry(d, fragment_dir) for d in borders],
            "spines": [_node_entry(d, fragment_dir) for d in spines],
            "leafs": [_node_entry(d, fragment_dir) for d in leafs],
            "servers": [_node_entry(d, fragment_dir) for d in servers],
            "infrastructure": _infra_nodes(),
        },
        "links": _build_links(topo),
        "management": {
            "bridge": "virbr2",
            "cidr": "192.168.0.0/24",
            "gateway": "192.168.0.1",
            "dhcp_server": "obs",
            "dns_domain": "netwatch.lab",
        },
        "observability": _observability_section(borders, spines, leafs, servers),
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w") as f:
        yaml.dump(doc, f, default_flow_style=False, sort_keys=False, width=120)

    print(f"[emit] Wrote topology.yml to {output_path}")


# ---------------------------------------------------------------------------
# Builders
# ---------------------------------------------------------------------------

def _node_entry(device: CanonicalDevice, fragment_dir: Path | None) -> dict:
    """Build a single node entry for topology.yml."""
    nw_name = device.netwatch_name or device.hostname
    loopback = device.loopback_ip or "10.0.0.1/32"
    if not loopback.endswith("/32"):
        loopback = loopback.split("/")[0] + "/32"

    mgmt_ip = getattr(device, "_mgmt_ip", None)
    if not mgmt_ip:
        mgmt_ip = "192.168.0.100"

    entry: dict = {
        "name": nw_name,
        "type": "frr-vm" if device.role in (DeviceRole.BORDER, DeviceRole.SPINE, DeviceRole.LEAF) else "fedora-vm",
        "role": device.role.value,
        "asn": device.bgp_asn,
        "loopback": loopback,
        "mgmt_ip": mgmt_ip,
        "metrics_port": 9342 if device.role in (DeviceRole.BORDER, DeviceRole.SPINE, DeviceRole.LEAF) else 9100,
    }

    if device.rack:
        entry["rack"] = device.rack

    if device.role == DeviceRole.LEAF:
        entry["evpn_vtep"] = True

    # Add fragment reference if the file exists
    if fragment_dir:
        frag_path = fragment_dir / f"{nw_name}.conf"
        if frag_path.exists():
            entry["frr_fragments"] = [str(frag_path.relative_to(fragment_dir.parent.parent))]

    # Comment with original hostname
    entry["_imported_from"] = device.hostname

    return entry


def _infra_nodes() -> list[dict]:
    """Generate infrastructure node entries (bastion, mgmt, obs)."""
    return [
        {
            "name": "bastion",
            "type": "fedora-vm",
            "role": "bastion",
            "mgmt_ip": "192.168.0.2",
            "metrics_port": 9100,
        },
        {
            "name": "mgmt",
            "type": "fedora-vm",
            "role": "mgmt",
            "mgmt_ip": "192.168.0.3",
            "services": [
                {"k3s": 6443},
            ],
        },
        {
            "name": "obs",
            "type": "fedora-vm",
            "role": "obs",
            "mgmt_ip": "192.168.0.4",
            "services": [
                {"prometheus": 9090},
                {"grafana": 3000},
                {"loki": 3100},
                {"dnsmasq": 53},
            ],
        },
    ]


def _build_links(topo: CanonicalTopology) -> dict:
    """Organize edges into link tiers for topology.yml."""
    tiers: dict[str, list[dict]] = {
        "border_bastion": [],
        "border_spine": [],
        "spine_leaf": [],
        "leaf_server": [],
    }

    for edge in topo.edges:
        a_dev = topo.devices.get(edge.a_hostname)
        b_dev = topo.devices.get(edge.b_hostname)
        if not a_dev or not b_dev or a_dev.dropped or b_dev.dropped:
            continue

        tier = _link_tier(a_dev.role, b_dev.role)
        if tier not in tiers:
            continue

        # Ensure 'a' is the higher-tier device
        a_name = a_dev.netwatch_name or a_dev.hostname
        b_name = b_dev.netwatch_name or b_dev.hostname

        tiers[tier].append({
            "a": a_name,
            "b": b_name,
            "subnet": edge.subnet,
            "a_ip": edge.a_ip.split("/")[0],
            "b_ip": edge.b_ip.split("/")[0],
        })

    # Add bastion links to borders
    borders = topo.devices_by_role(DeviceRole.BORDER)
    for i, border in enumerate(borders):
        if border.dropped:
            continue
        nw_name = border.netwatch_name or border.hostname
        # Allocate from border_bastion pool
        base = i * 4
        tiers["border_bastion"].append({
            "a": nw_name,
            "b": "bastion",
            "subnet": f"172.16.0.{base}/30",
            "a_ip": f"172.16.0.{base + 1}",
            "b_ip": f"172.16.0.{base + 2}",
        })

    return tiers


def _link_tier(role_a: DeviceRole, role_b: DeviceRole) -> str:
    pair = frozenset([role_a, role_b])
    return {
        frozenset([DeviceRole.BORDER, DeviceRole.SPINE]): "border_spine",
        frozenset([DeviceRole.SPINE, DeviceRole.LEAF]): "spine_leaf",
        frozenset([DeviceRole.LEAF, DeviceRole.SERVER]): "leaf_server",
    }.get(pair, "unknown")


def _collect_rack_asns(leafs: list[CanonicalDevice]) -> dict:
    """Build rack → ASN mapping from leaf devices."""
    rack_asns = {}
    for leaf in leafs:
        if leaf.rack and leaf.bgp_asn:
            rack_asns[leaf.rack] = leaf.bgp_asn
    return rack_asns if rack_asns else {"rack-1": 65101}


def _build_fabric_pools(rack_asns: dict) -> dict:
    """Build fabric address pool entries."""
    pools = {
        "border_bastion": "172.16.0.0/24",
        "border_spine": "172.16.1.0/24",
        "spine_leaf": "172.16.2.0/24",
    }
    for i, rack in enumerate(sorted(rack_asns.keys()), start=1):
        pools[f"leaf_server_rack{i}"] = f"172.16.{2 + i}.0/24"
    return pools


def _observability_section(borders, spines, leafs, servers) -> dict:
    """Build the observability section."""
    frr_names = [d.netwatch_name for d in borders + spines + leafs if d.netwatch_name]
    vm_names = [d.netwatch_name for d in servers if d.netwatch_name]
    vm_names.extend(["bastion", "mgmt", "obs"])

    return {
        "prometheus": {
            "host": "obs",
            "port": 9090,
            "scrape_interval_s": 15,
            "targets": {
                "frr_nodes": {
                    "port": 9342,
                    "nodes": frr_names,
                },
                "vm_nodes": {
                    "port": 9100,
                    "nodes": vm_names,
                },
            },
        },
        "grafana": {
            "host": "obs",
            "port": 3000,
        },
        "loki": {
            "host": "obs",
            "port": 3100,
        },
    }


def _sorted_by_name(topo: CanonicalTopology, role: DeviceRole) -> list[CanonicalDevice]:
    """Return active devices of a role, sorted by netwatch_name."""
    return sorted(
        [d for d in topo.devices_by_role(role) if not d.dropped],
        key=lambda d: d.netwatch_name or d.hostname,
    )
