"""Infer device roles (border/spine/leaf/server) from topology graph.

Uses ASN clustering, graph centrality metrics, and connectivity
patterns to classify devices into Clos tiers.  User hints override
automatic inference.
"""

from __future__ import annotations

import fnmatch
from collections import Counter, defaultdict

import networkx as nx

from .model import CanonicalTopology, DeviceRole


def infer_roles(topo: CanonicalTopology, hints: dict | None = None) -> None:
    """Classify all devices in the topology by role (mutates in place).

    Args:
        topo: Topology with devices and edges populated.
        hints: Optional dict from hints.yml with 'roles' and 'asn_roles' keys.
    """
    hints = hints or {}

    # ------------------------------------------------------------------
    # Step 1: Build the NetworkX graph
    # ------------------------------------------------------------------
    G = nx.Graph()
    for device in topo.devices.values():
        G.add_node(device.hostname, asn=device.bgp_asn)

    for edge in topo.edges:
        if edge.a_hostname in G and edge.b_hostname in G:
            G.add_edge(edge.a_hostname, edge.b_hostname)

    # ------------------------------------------------------------------
    # Step 2: Apply user hints first (these always win)
    # ------------------------------------------------------------------
    role_hints = hints.get("roles", {})
    asn_hints = hints.get("asn_roles", {})
    asn_role_map = _parse_asn_hints(asn_hints)

    for hostname, device in topo.devices.items():
        # Direct hostname match (supports glob patterns)
        matched_role = _match_hostname_hint(hostname, role_hints)
        if matched_role:
            device.role = matched_role
            continue

        # ASN-based hint
        if device.bgp_asn and device.bgp_asn in asn_role_map:
            device.role = asn_role_map[device.bgp_asn]

    # If all devices are already assigned via hints, we're done
    unassigned = [d for d in topo.devices.values() if d.role == DeviceRole.UNKNOWN]
    if not unassigned:
        _validate_and_report(topo, G)
        return

    # ------------------------------------------------------------------
    # Step 3: ASN clustering
    # ------------------------------------------------------------------
    asn_groups: dict[int, list[str]] = defaultdict(list)
    for device in topo.devices.values():
        if device.bgp_asn is not None:
            asn_groups[device.bgp_asn].append(device.hostname)

    # ------------------------------------------------------------------
    # Step 4: Compute graph metrics
    # ------------------------------------------------------------------
    centrality = nx.betweenness_centrality(G) if len(G) > 2 else {n: 0 for n in G}
    degree = dict(G.degree())

    device_metrics: dict[str, dict] = {}
    for hostname, device in topo.devices.items():
        peer_asns = {n.peer_asn for n in device.bgp_neighbors if n.peer_asn}
        has_default = any(r.prefix == "0.0.0.0/0" for r in device.static_routes)
        has_external = _has_external_peers(device, asn_groups)

        device_metrics[hostname] = {
            "degree": degree.get(hostname, 0),
            "bgp_peers": len(device.bgp_neighbors),
            "unique_peer_asns": len(peer_asns),
            "centrality": centrality.get(hostname, 0),
            "has_default_route": has_default,
            "has_external_bgp": has_external,
            "asn": device.bgp_asn,
        }

    # ------------------------------------------------------------------
    # Step 5: Classify by connectivity pattern
    # ------------------------------------------------------------------
    # Score each ASN group for each role
    asn_scores: dict[int, dict[str, float]] = {}

    for asn, members in asn_groups.items():
        # Skip if all members already assigned
        if all(topo.devices[m].role != DeviceRole.UNKNOWN for m in members):
            continue

        metrics = [device_metrics[m] for m in members]
        avg_centrality = sum(m["centrality"] for m in metrics) / len(metrics)
        avg_degree = sum(m["degree"] for m in metrics) / len(metrics)
        any_external = any(m["has_external_bgp"] for m in metrics)
        any_default = any(m["has_default_route"] for m in metrics)
        group_size = len(members)

        scores = {
            "border": 0.0,
            "spine": 0.0,
            "leaf": 0.0,
            "server": 0.0,
        }

        # Border signals: external peering, default routes, small group
        if any_external:
            scores["border"] += 5.0
        if any_default:
            scores["border"] += 2.0
        if group_size <= 4:
            scores["border"] += 1.0

        # Spine signals: high centrality, high degree, small group
        scores["spine"] += avg_centrality * 10
        if avg_degree > 4:
            scores["spine"] += 2.0
        if group_size <= 4:
            scores["spine"] += 1.0

        # Leaf signals: medium degree, peers with high-centrality and low-degree nodes
        if 2 <= avg_degree <= 8:
            scores["leaf"] += 2.0
        if group_size >= 2:
            scores["leaf"] += 1.0

        # Server signals: low degree (1-2), no BGP or minimal, large group
        if avg_degree <= 2:
            scores["server"] += 3.0
        if len(metrics) > 0 and all(m["bgp_peers"] <= 2 for m in metrics):
            scores["server"] += 2.0
        if group_size >= 4:
            scores["server"] += 1.0

        asn_scores[asn] = scores

    # Assign roles by highest score, with conflict resolution
    # Process in order: border first (most distinctive), then spine, leaf, server
    assigned_roles: set[str] = set()

    for target_role in ["border", "spine", "leaf", "server"]:
        best_asn = None
        best_score = -1

        for asn, scores in asn_scores.items():
            if asn in assigned_roles:
                continue
            # Skip ASNs already fully assigned
            members = asn_groups[asn]
            if all(topo.devices[m].role != DeviceRole.UNKNOWN for m in members):
                continue

            if scores[target_role] > best_score:
                best_score = scores[target_role]
                best_asn = asn

        if best_asn is not None and best_score > 0:
            role_enum = DeviceRole(target_role)
            for hostname in asn_groups[best_asn]:
                if topo.devices[hostname].role == DeviceRole.UNKNOWN:
                    topo.devices[hostname].role = role_enum
            assigned_roles.add(str(best_asn))

    # Handle remaining ASN groups → default to leaf
    for asn, members in asn_groups.items():
        for hostname in members:
            if topo.devices[hostname].role == DeviceRole.UNKNOWN:
                topo.devices[hostname].role = DeviceRole.LEAF

    # ------------------------------------------------------------------
    # Step 6: Devices with no BGP ASN → likely servers
    # ------------------------------------------------------------------
    for device in topo.devices.values():
        if device.role == DeviceRole.UNKNOWN:
            if device.bgp_asn is None and device_metrics[device.hostname]["degree"] <= 2:
                device.role = DeviceRole.SERVER
            else:
                device.role = DeviceRole.LEAF  # conservative default

    # ------------------------------------------------------------------
    # Step 7: Assign rack labels to leafs
    # ------------------------------------------------------------------
    _assign_racks(topo)

    _validate_and_report(topo, G)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _match_hostname_hint(hostname: str, role_hints: dict) -> DeviceRole | None:
    """Match a hostname against hint patterns (supports glob)."""
    for pattern, role_str in role_hints.items():
        if fnmatch.fnmatch(hostname, pattern) or hostname == pattern:
            try:
                return DeviceRole(role_str)
            except ValueError:
                continue
    return None


def _parse_asn_hints(asn_hints: dict) -> dict[int, DeviceRole]:
    """Parse ASN hint mappings, supporting range notation like '65100-65199'."""
    result = {}
    for asn_spec, role_str in asn_hints.items():
        try:
            role = DeviceRole(role_str)
        except ValueError:
            continue

        asn_spec_str = str(asn_spec)
        if "-" in asn_spec_str:
            parts = asn_spec_str.split("-")
            start, end = int(parts[0]), int(parts[1])
            for asn in range(start, end + 1):
                result[asn] = role
        else:
            result[int(asn_spec_str)] = role

    return result


def _has_external_peers(device, asn_groups: dict[int, list[str]]) -> bool:
    """Check if a device has BGP peers outside the known fabric ASN set."""
    fabric_asns = set(asn_groups.keys())
    for nbr in device.bgp_neighbors:
        if nbr.peer_asn and nbr.peer_asn not in fabric_asns:
            return True
    return False


def _assign_racks(topo: CanonicalTopology) -> None:
    """Assign rack labels to leaf switches based on ASN grouping.

    Leafs sharing an ASN are in the same rack (standard Clos convention).
    """
    leaf_asns: dict[int, list[str]] = defaultdict(list)
    for device in topo.devices.values():
        if device.role == DeviceRole.LEAF and device.bgp_asn is not None:
            leaf_asns[device.bgp_asn].append(device.hostname)

    for i, (asn, members) in enumerate(sorted(leaf_asns.items()), start=1):
        rack_label = f"rack-{i}"
        for hostname in members:
            topo.devices[hostname].rack = rack_label

    # Assign servers to racks based on their leaf peers
    for device in topo.devices.values():
        if device.role == DeviceRole.SERVER and device.rack is None:
            peer_racks = set()
            for nbr in device.bgp_neighbors:
                peer_dev = topo.devices.get(nbr.peer_hostname)
                if peer_dev and peer_dev.rack:
                    peer_racks.add(peer_dev.rack)
            # Also check L3 edge peers
            for iface in device.fabric_interfaces:
                peer_dev = topo.devices.get(iface.peer_hostname)
                if peer_dev and peer_dev.rack:
                    peer_racks.add(peer_dev.rack)

            if len(peer_racks) == 1:
                device.rack = peer_racks.pop()
            elif peer_racks:
                # Multiple racks — pick first (shouldn't happen in proper Clos)
                device.rack = sorted(peer_racks)[0]


def _validate_and_report(topo: CanonicalTopology, G: nx.Graph) -> None:
    """Print role assignment summary and validate connectivity."""
    role_counts = Counter(d.role.value for d in topo.devices.values())
    print(f"[roles] Assignment: {dict(role_counts)}")

    # Check for suspicious patterns
    borders = topo.devices_by_role(DeviceRole.BORDER)
    spines = topo.devices_by_role(DeviceRole.SPINE)
    leafs = topo.devices_by_role(DeviceRole.LEAF)
    servers = topo.devices_by_role(DeviceRole.SERVER)

    if not borders:
        print("[roles] WARNING: No border devices identified")
    if not spines:
        print("[roles] WARNING: No spine devices identified")
    if not leafs:
        print("[roles] WARNING: No leaf devices identified")

    # Validate tier connectivity
    for border in borders:
        spine_peers = [
            n for n in G.neighbors(border.hostname)
            if topo.devices.get(n, CanonicalTopology()).role == DeviceRole.SPINE
        ]
        if not spine_peers:
            print(f"[roles] WARNING: Border {border.hostname} has no spine peers")

    for spine in spines:
        leaf_peers = [
            n for n in G.neighbors(spine.hostname)
            if topo.devices.get(n) and topo.devices[n].role == DeviceRole.LEAF
        ]
        if not leaf_peers:
            print(f"[roles] WARNING: Spine {spine.hostname} has no leaf peers")
