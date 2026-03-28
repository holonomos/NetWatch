"""Extract routing policies and emit FRR config fragments.

Reads CanonicalPolicy objects from devices, translates to FRR syntax,
rewrites IPs using the mapping table, and writes per-device fragment files.
"""

from __future__ import annotations

from pathlib import Path

from .model import (
    CanonicalDevice,
    CanonicalPolicy,
    CanonicalTopology,
    IPMapping,
    PolicyEntry,
    PolicyType,
)


def extract_fragments(
    topo: CanonicalTopology,
    ip_mappings: list[IPMapping] | None,
    output_dir: Path,
) -> int:
    """Write FRR config fragments for all active devices with policies.

    Args:
        topo: Topology with policies populated.
        ip_mappings: IP mapping table for address rewriting.  Pass None or
                     empty list to emit production IPs verbatim (recommended —
                     avoids silent fidelity loss from translated prefix-lists).
        output_dir: Directory to write fragment files into.

    Returns:
        Number of fragment files written.
    """
    output_dir.mkdir(parents=True, exist_ok=True)

    # Build prod→netwatch IP lookup.  Empty map = production IPs pass through
    # unchanged, which is the correct default (prefix-lists, route-maps, and
    # ACLs must reference the same IPs as production).
    ip_map = {m.prod_ip: m.netwatch_ip for m in ip_mappings} if ip_mappings else {}

    count = 0
    for device in topo.active_devices():
        if not device.policies:
            continue

        nw_name = device.netwatch_name or device.hostname
        fragment_path = output_dir / f"{nw_name}.conf"

        lines = [
            f"! Imported routing policies from {device.vendor} device {device.hostname}",
            "!",
        ]

        for policy in device.policies:
            policy_lines = _render_policy(policy, ip_map)
            if policy_lines:
                lines.extend(policy_lines)
                lines.append("!")

        if len(lines) > 2:  # More than just the header
            fragment_path.write_text("\n".join(lines) + "\n")
            count += 1

    print(f"[policy] Wrote {count} FRR fragment files to {output_dir}")
    return count


def _render_policy(policy: CanonicalPolicy, ip_map: dict[str, str]) -> list[str]:
    """Render a single policy object to FRR config lines."""
    if policy.type == PolicyType.PREFIX_LIST:
        return _render_prefix_list(policy, ip_map)
    elif policy.type == PolicyType.ROUTE_MAP:
        return _render_route_map(policy, ip_map)
    elif policy.type == PolicyType.COMMUNITY_LIST:
        return _render_community_list(policy)
    elif policy.type == PolicyType.AS_PATH_LIST:
        return _render_as_path_list(policy)
    return []


def _render_prefix_list(policy: CanonicalPolicy, ip_map: dict[str, str]) -> list[str]:
    """Render a prefix-list to FRR syntax."""
    lines = []
    for entry in sorted(policy.entries, key=lambda e: e.sequence):
        prefix = entry.match_clauses.get("prefix", "")
        if not prefix:
            continue

        # Rewrite IP if it's in our mapping table
        prefix = _rewrite_prefix(prefix, ip_map)

        parts = [f"ip prefix-list {policy.name}"]
        parts.append(f"seq {entry.sequence}")
        parts.append(entry.action)
        parts.append(prefix)

        le = entry.match_clauses.get("le")
        ge = entry.match_clauses.get("ge")
        if ge is not None:
            parts.append(f"ge {ge}")
        if le is not None:
            parts.append(f"le {le}")

        lines.append(" ".join(parts))

    return lines


def _render_route_map(policy: CanonicalPolicy, ip_map: dict[str, str]) -> list[str]:
    """Render a route-map to FRR syntax."""
    lines = []
    for entry in sorted(policy.entries, key=lambda e: e.sequence):
        lines.append(f"route-map {policy.name} {entry.action} {entry.sequence}")

        # Match clauses
        for key, value in entry.match_clauses.items():
            match_line = _render_match_clause(key, value, ip_map)
            if match_line:
                lines.append(f" {match_line}")

        # Set clauses
        for key, value in entry.set_clauses.items():
            set_line = _render_set_clause(key, value)
            if set_line:
                lines.append(f" {set_line}")

        lines.append("exit")

    return lines


def _render_community_list(policy: CanonicalPolicy) -> list[str]:
    """Render a community-list to FRR syntax."""
    lines = []
    for entry in policy.entries:
        community = entry.match_clauses.get("community", "")
        if community:
            lines.append(
                f"ip community-list standard {policy.name} "
                f"{entry.action} {community}"
            )
    return lines


def _render_as_path_list(policy: CanonicalPolicy) -> list[str]:
    """Render an AS-path access-list to FRR syntax."""
    lines = []
    for entry in policy.entries:
        regex = entry.match_clauses.get("regex", "")
        if regex:
            lines.append(
                f"bgp as-path access-list {policy.name} "
                f"seq {entry.sequence} {entry.action} {regex}"
            )
    return lines


def _render_match_clause(key: str, value, ip_map: dict[str, str]) -> str | None:
    """Render a single match clause to FRR syntax."""
    key_lower = key.lower().replace("_", " ").replace("-", " ")

    if "prefix" in key_lower and "list" in key_lower:
        return f"match ip address prefix-list {value}"
    if "community" in key_lower:
        return f"match community {value}"
    if "as" in key_lower and "path" in key_lower:
        return f"match as-path {value}"
    if "metric" in key_lower:
        return f"match metric {value}"
    if "tag" in key_lower:
        return f"match tag {value}"
    if "interface" in key_lower:
        return f"match interface {value}"

    # Generic passthrough for unknown match types
    if isinstance(value, str) and value:
        return f"match {key.replace('_', ' ')} {value}"

    return None


def _render_set_clause(key: str, value) -> str | None:
    """Render a single set clause to FRR syntax."""
    key_lower = key.lower().replace("_", " ").replace("-", " ")

    if "local" in key_lower and "pref" in key_lower:
        return f"set local-preference {value}"
    if "metric" in key_lower:
        return f"set metric {value}"
    if "community" in key_lower:
        return f"set community {value}"
    if "weight" in key_lower:
        return f"set weight {value}"
    if "origin" in key_lower:
        return f"set origin {value}"
    if "prepend" in key_lower:
        return f"set as-path prepend {value}"
    if "next" in key_lower and "hop" in key_lower:
        return f"set ip next-hop {value}"
    if "tag" in key_lower:
        return f"set tag {value}"
    if "med" in key_lower:
        return f"set metric {value}"

    # Generic passthrough
    if isinstance(value, (str, int, float)) and str(value):
        return f"set {key.replace('_', '-')} {value}"

    return None


def _rewrite_prefix(prefix: str, ip_map: dict[str, str]) -> str:
    """Rewrite an IP prefix if the network address is in the mapping table."""
    if "/" not in prefix:
        return ip_map.get(prefix, prefix)

    ip_part, mask = prefix.split("/", 1)
    if ip_part in ip_map:
        return f"{ip_map[ip_part]}/{mask}"

    return prefix
