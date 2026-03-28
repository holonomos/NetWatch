#!/usr/bin/env python3
"""Migrate topology.yml from v1 (grouped sections) to v2 (flat lists).

v1 schema:
  nodes:
    borders: [...]
    spines: [...]
    leafs: [...]
    servers: [...]
    infrastructure: [...]
  links:
    border_bastion: [...]
    border_spine: [...]
    spine_leaf: [...]
    leaf_server: [...]

v2 schema:
  nodes: [flat list, every node has role/type fields]
  edges: [flat list, no tier grouping]
  infrastructure: {bastion: {}, mgmt: {}, obs: {}}

This script is permanent — used for:
  - Test suite regression (reference topology v1 → v2 → generate → diff)
  - Customer migration (early adopters with v1 files)
  - Validation (prove v2 is a proper superset of v1)

Usage:
  python3 scripts/migrate-topology-v1-to-v2.py topology.yml > topology-v2.yml
  python3 scripts/migrate-topology-v1-to-v2.py topology.yml --in-place
"""

from __future__ import annotations

import argparse
import copy
import sys
from pathlib import Path

import yaml


def migrate_v1_to_v2(v1: dict) -> dict:
    """Convert a v1 topology dict to v2 format.

    Preserves all data — just restructures nodes and links.
    """
    v2 = {}

    # ------------------------------------------------------------------
    # Pass through unchanged sections
    # ------------------------------------------------------------------
    v2["project"] = copy.deepcopy(v1.get("project", {}))
    v2["timers"] = copy.deepcopy(v1.get("timers", {}))

    # ------------------------------------------------------------------
    # Flatten nodes: grouped sections → flat list
    # ------------------------------------------------------------------
    flat_nodes = []
    v1_nodes = v1.get("nodes", {})

    # Infrastructure nodes get separated into their own section
    infra = {}

    # Known v1 group keys → iterate all of them
    for group_key, node_list in v1_nodes.items():
        if not isinstance(node_list, list):
            continue

        for node in node_list:
            node_copy = copy.deepcopy(node)

            # Ensure 'role' is set (v1 nodes already have it, but just in case)
            if "role" not in node_copy:
                # Infer from group key
                role_map = {
                    "borders": "border",
                    "spines": "spine",
                    "leafs": "leaf",
                    "servers": "server",
                }
                node_copy["role"] = role_map.get(group_key, group_key.rstrip("s"))

            # Normalize type field
            if "type" not in node_copy:
                if node_copy.get("role") in ("border", "spine", "leaf"):
                    node_copy["type"] = "frr"
                else:
                    node_copy["type"] = "vm"
            elif node_copy["type"] == "frr-vm":
                node_copy["type"] = "frr"
            elif node_copy["type"] == "fedora-vm":
                node_copy["type"] = "vm"

            # Separate infrastructure nodes
            if node_copy.get("role") in ("bastion", "mgmt", "obs"):
                name = node_copy.pop("name")
                node_copy.pop("role", None)
                node_copy.pop("type", None)
                infra[name] = node_copy
            else:
                flat_nodes.append(node_copy)

    v2["nodes"] = flat_nodes

    # ------------------------------------------------------------------
    # Flatten links: tiered sections → flat edge list
    # ------------------------------------------------------------------
    flat_edges = []
    v1_links = v1.get("links", {})

    for tier_key, link_list in v1_links.items():
        if not isinstance(link_list, list):
            continue

        for link in link_list:
            edge = copy.deepcopy(link)
            # v2 edges are identical in structure, just not grouped by tier
            flat_edges.append(edge)

    v2["edges"] = flat_edges

    # ------------------------------------------------------------------
    # Infrastructure
    # ------------------------------------------------------------------
    # Ensure all 3 infra nodes exist (obs may not be in v1 topology.yml)
    defaults = _default_infra()
    for name, default_cfg in defaults.items():
        if name not in infra:
            infra[name] = default_cfg
    v2["infrastructure"] = infra

    # ------------------------------------------------------------------
    # Management (pass through)
    # ------------------------------------------------------------------
    if "management" in v1:
        v2["management"] = copy.deepcopy(v1["management"])

    # ------------------------------------------------------------------
    # Observability (pass through)
    # ------------------------------------------------------------------
    if "observability" in v1:
        v2["observability"] = copy.deepcopy(v1["observability"])

    # ------------------------------------------------------------------
    # Optional sections (pass through)
    # ------------------------------------------------------------------
    for key in ("addressing", "asn", "evpn"):
        if key in v1:
            v2[key] = copy.deepcopy(v1[key])

    return v2


def _default_infra() -> dict:
    return {
        "bastion": {"mgmt_ip": "192.168.0.2", "memory_mb": 384},
        "mgmt": {"mgmt_ip": "192.168.0.3", "memory_mb": 2048},
        "obs": {"mgmt_ip": "192.168.0.4", "memory_mb": 2048},
    }


def is_v1(topo: dict) -> bool:
    """Check if a topology dict is v1 format (grouped node sections)."""
    nodes = topo.get("nodes", {})
    # v1: nodes is a dict with role keys (borders, spines, etc.)
    # v2: nodes is a list
    return isinstance(nodes, dict)


def is_v2(topo: dict) -> bool:
    """Check if a topology dict is v2 format (flat lists)."""
    nodes = topo.get("nodes", [])
    return isinstance(nodes, list)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Migrate topology.yml from v1 (grouped) to v2 (flat lists)",
    )
    parser.add_argument("input", help="Path to v1 topology.yml")
    parser.add_argument("--in-place", action="store_true",
                        help="Overwrite the input file (default: print to stdout)")
    parser.add_argument("--output", "-o", default=None,
                        help="Write to this file instead of stdout")
    args = parser.parse_args()

    input_path = Path(args.input)
    with open(input_path) as f:
        v1 = yaml.safe_load(f)

    if is_v2(v1):
        print(f"Already v2 format: {input_path}", file=sys.stderr)
        sys.exit(0)

    if not is_v1(v1):
        print(f"Unrecognized format: {input_path}", file=sys.stderr)
        sys.exit(1)

    v2 = migrate_v1_to_v2(v1)

    # Count for summary
    node_count = len(v2["nodes"])
    edge_count = len(v2["edges"])
    infra_count = len(v2.get("infrastructure", {}))

    output_text = yaml.dump(v2, default_flow_style=False, sort_keys=False, width=120)

    if args.in_place:
        with open(input_path, "w") as f:
            f.write(output_text)
        print(f"Migrated {input_path}: {node_count} nodes, {edge_count} edges, "
              f"{infra_count} infra", file=sys.stderr)
    elif args.output:
        out_path = Path(args.output)
        with open(out_path, "w") as f:
            f.write(output_text)
        print(f"Wrote {out_path}: {node_count} nodes, {edge_count} edges, "
              f"{infra_count} infra", file=sys.stderr)
    else:
        sys.stdout.write(output_text)
        print(f"\n# Migrated: {node_count} nodes, {edge_count} edges, "
              f"{infra_count} infra", file=sys.stderr)


if __name__ == "__main__":
    main()
