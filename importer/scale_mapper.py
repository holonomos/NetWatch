"""Scale N-device production fabric down to NetWatch's 12+16+3 budget.

Selects representative devices per tier and assigns NetWatch hostnames.
Devices that don't fit are marked as dropped with reasons.
"""

from __future__ import annotations

from collections import defaultdict

from .model import CanonicalTopology, DeviceRole, CanonicalDevice


# NetWatch node budget
MAX_BORDERS = 2
MAX_SPINES = 2
MAX_RACKS = 4
LEAFS_PER_RACK = 2
SERVERS_PER_RACK = 4
MAX_LEAFS = MAX_RACKS * LEAFS_PER_RACK  # 8
MAX_SERVERS = MAX_RACKS * SERVERS_PER_RACK  # 16


def map_to_netwatch(topo: CanonicalTopology) -> None:
    """Assign NetWatch names and drop excess devices (mutates in place).

    After this, each non-dropped device has `netwatch_name` set.
    Dropped devices have `dropped=True` and `drop_reason` set.
    """
    _map_borders(topo)
    _map_spines(topo)
    _map_leafs(topo)
    _map_servers(topo)
    _report(topo)


def _map_borders(topo: CanonicalTopology) -> None:
    """Select up to 2 border devices."""
    borders = topo.devices_by_role(DeviceRole.BORDER)
    # Sort by number of BGP peers (most connected first)
    borders.sort(key=lambda d: len(d.bgp_neighbors), reverse=True)

    for i, device in enumerate(borders):
        if i < MAX_BORDERS:
            device.netwatch_name = f"border-{i + 1}"
        else:
            device.dropped = True
            device.drop_reason = (
                f"Exceeds border budget ({MAX_BORDERS}). "
                f"Keeping {borders[0].hostname} and {borders[1].hostname} "
                f"(most BGP peers)."
            )


def _map_spines(topo: CanonicalTopology) -> None:
    """Select up to 2 spine devices."""
    spines = topo.devices_by_role(DeviceRole.SPINE)
    # Sort by degree (most connected first)
    spines.sort(key=lambda d: len(d.fabric_interfaces), reverse=True)

    for i, device in enumerate(spines):
        if i < MAX_SPINES:
            device.netwatch_name = f"spine-{i + 1}"
        else:
            device.dropped = True
            device.drop_reason = (
                f"Exceeds spine budget ({MAX_SPINES}). "
                f"Picked top-{MAX_SPINES} by connectivity."
            )


def _map_leafs(topo: CanonicalTopology) -> None:
    """Map leaf devices into up to 4 racks × 2 leafs."""
    leafs = topo.devices_by_role(DeviceRole.LEAF)

    # Group by rack
    rack_groups: dict[str, list[CanonicalDevice]] = defaultdict(list)
    unracked: list[CanonicalDevice] = []

    for leaf in leafs:
        if leaf.rack:
            rack_groups[leaf.rack].append(leaf)
        else:
            unracked.append(leaf)

    # Assign unracked leafs to synthetic racks (pairs by ASN)
    asn_buckets: dict[int, list[CanonicalDevice]] = defaultdict(list)
    for leaf in unracked:
        asn_buckets[leaf.bgp_asn or 0].append(leaf)
    for asn, members in asn_buckets.items():
        rack_label = f"rack-auto-{asn}"
        for m in members:
            m.rack = rack_label
            rack_groups[rack_label].append(m)

    # Sort racks by size (largest first — they're likely more important)
    sorted_racks = sorted(rack_groups.keys(), key=lambda r: len(rack_groups[r]), reverse=True)

    rack_index = 0
    for rack_name in sorted_racks:
        members = rack_groups[rack_name]
        if rack_index >= MAX_RACKS:
            # Drop all leafs in this rack
            for leaf in members:
                leaf.dropped = True
                leaf.drop_reason = f"Rack '{rack_name}' exceeds rack budget ({MAX_RACKS})."
            continue

        rack_index += 1
        nw_rack = rack_index

        # Sort leafs within rack for deterministic naming
        members.sort(key=lambda d: d.hostname)

        for j, leaf in enumerate(members):
            if j < LEAFS_PER_RACK:
                suffix = chr(ord("a") + j)  # a, b
                leaf.netwatch_name = f"leaf-{nw_rack}{suffix}"
                leaf.rack = f"rack-{nw_rack}"
            else:
                leaf.dropped = True
                leaf.drop_reason = (
                    f"Exceeds leafs-per-rack budget ({LEAFS_PER_RACK}). "
                    f"Rack '{rack_name}' → rack-{nw_rack}."
                )


def _map_servers(topo: CanonicalTopology) -> None:
    """Map server devices into racks (4 per rack)."""
    servers = topo.devices_by_role(DeviceRole.SERVER)

    # Group by rack
    rack_groups: dict[str, list[CanonicalDevice]] = defaultdict(list)
    unracked: list[CanonicalDevice] = []

    for srv in servers:
        if srv.rack:
            rack_groups[srv.rack].append(srv)
        else:
            unracked.append(srv)

    # Determine which racks exist (from leaf mapping)
    active_racks = set()
    for device in topo.devices.values():
        if device.role == DeviceRole.LEAF and not device.dropped and device.rack:
            active_racks.add(device.rack)

    # Assign unracked servers round-robin to active racks
    active_rack_list = sorted(active_racks)
    for i, srv in enumerate(unracked):
        if active_rack_list:
            srv.rack = active_rack_list[i % len(active_rack_list)]
            rack_groups[srv.rack].append(srv)
        else:
            srv.dropped = True
            srv.drop_reason = "No active racks to assign to."

    # Map servers within each rack
    for rack_name in sorted(rack_groups.keys()):
        members = rack_groups[rack_name]

        if rack_name not in active_racks:
            for srv in members:
                srv.dropped = True
                srv.drop_reason = f"Rack '{rack_name}' was dropped (not in active racks)."
            continue

        # Extract rack number from rack name (e.g., "rack-2" → 2)
        rack_num = _rack_number(rack_name)
        if rack_num is None or rack_num > MAX_RACKS:
            for srv in members:
                srv.dropped = True
                srv.drop_reason = f"Rack '{rack_name}' outside budget."
            continue

        members.sort(key=lambda d: d.hostname)
        for j, srv in enumerate(members):
            if j < SERVERS_PER_RACK:
                srv.netwatch_name = f"srv-{rack_num}-{j + 1}"
                srv.rack = f"rack-{rack_num}"
            else:
                srv.dropped = True
                srv.drop_reason = (
                    f"Exceeds servers-per-rack budget ({SERVERS_PER_RACK}). "
                    f"Rack '{rack_name}'."
                )


def _rack_number(rack_name: str) -> int | None:
    """Extract numeric part from 'rack-N'."""
    parts = rack_name.split("-")
    for p in reversed(parts):
        try:
            return int(p)
        except ValueError:
            continue
    return None


def _report(topo: CanonicalTopology) -> None:
    """Print scale mapping summary."""
    active = topo.active_devices()
    dropped = [d for d in topo.devices.values() if d.dropped]

    by_role = defaultdict(int)
    for d in active:
        by_role[d.role.value] += 1

    print(f"[scale] Mapped {len(active)} devices, dropped {len(dropped)}")
    print(f"[scale] Active: {dict(by_role)}")

    if dropped:
        print(f"[scale] Dropped devices:")
        for d in dropped:
            print(f"  {d.hostname}: {d.drop_reason}")
