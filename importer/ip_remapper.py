"""Remap production IPs to NetWatch's addressing scheme.

Allocates loopback, fabric P2P, and management IPs from NetWatch's
address pools.  Produces an IP mapping table used by the policy
extractor to rewrite prefix-lists.
"""

from __future__ import annotations

import ipaddress
from collections import defaultdict
from dataclasses import dataclass, field

from .model import (
    CanonicalDevice,
    CanonicalEdge,
    CanonicalTopology,
    DeviceRole,
    IPMapping,
)


# ---------------------------------------------------------------------------
# NetWatch address pools (matches topology.yml conventions)
# ---------------------------------------------------------------------------

# Loopback pools per role: 10.0.<tier>.x/32
LOOPBACK_POOLS = {
    DeviceRole.BORDER: ipaddress.ip_network("10.0.1.0/24"),
    DeviceRole.SPINE:  ipaddress.ip_network("10.0.2.0/24"),
    DeviceRole.LEAF:   ipaddress.ip_network("10.0.3.0/24"),
    # Servers: 10.0.4-7.x depending on rack
}
SERVER_LOOPBACK_BASE = 4  # rack-1 → 10.0.4.x, rack-2 → 10.0.5.x, etc.

# Fabric P2P pools per link tier
FABRIC_POOLS = {
    "border_bastion": ipaddress.ip_network("172.16.0.0/24"),
    "border_spine":   ipaddress.ip_network("172.16.1.0/24"),
    "spine_leaf":     ipaddress.ip_network("172.16.2.0/24"),
    "leaf_server":    ipaddress.ip_network("172.16.4.0/22", strict=False),  # /22 covers 4 racks
}

# Management pool
MGMT_POOL = ipaddress.ip_network("192.168.0.0/24")
MGMT_RESERVED = {
    1: "gateway",
    2: "bastion",
    3: "mgmt",
    4: "obs",
}


@dataclass
class Allocator:
    """Simple sequential IP allocator from a CIDR pool."""
    network: ipaddress.IPv4Network
    _next: int = 1

    def allocate(self) -> str:
        """Return next available host IP as string."""
        host = self.network.network_address + self._next
        if host not in self.network:
            raise ValueError(f"Pool {self.network} exhausted at index {self._next}")
        self._next += 1
        return str(host)


@dataclass
class P2PAllocator:
    """Allocate /30 subnets from a pool for point-to-point links."""
    network: ipaddress.IPv4Network
    _offset: int = 0

    def allocate_pair(self) -> tuple[str, str, str]:
        """Return (a_ip/30, b_ip/30, subnet/30)."""
        base = int(self.network.network_address) + self._offset
        subnet = ipaddress.ip_network(f"{ipaddress.ip_address(base)}/30", strict=False)
        hosts = list(subnet.hosts())
        if len(hosts) < 2:
            raise ValueError(f"P2P pool {self.network} exhausted at offset {self._offset}")
        self._offset += 4
        return (
            f"{hosts[0]}/30",
            f"{hosts[1]}/30",
            str(subnet),
        )


def remap_ips(topo: CanonicalTopology) -> list[IPMapping]:
    """Assign NetWatch IPs to all active devices and edges (mutates in place).

    Returns:
        List of IPMapping entries for documentation and policy rewriting.
    """
    mappings: list[IPMapping] = []

    # ------------------------------------------------------------------
    # 1. Loopback allocation
    # ------------------------------------------------------------------
    loopback_allocs: dict[DeviceRole, Allocator] = {
        role: Allocator(pool) for role, pool in LOOPBACK_POOLS.items()
    }
    # Server loopback allocators per rack
    server_rack_allocs: dict[str, Allocator] = {}

    for device in _sorted_active(topo):
        if device.role == DeviceRole.SERVER:
            rack_num = _rack_number(device.rack) or 1
            pool_key = f"rack-{rack_num}"
            if pool_key not in server_rack_allocs:
                third_octet = SERVER_LOOPBACK_BASE + rack_num - 1
                server_rack_allocs[pool_key] = Allocator(
                    ipaddress.ip_network(f"10.0.{third_octet}.0/24")
                )
            alloc = server_rack_allocs[pool_key]
        elif device.role in loopback_allocs:
            alloc = loopback_allocs[device.role]
        else:
            continue

        new_lo = alloc.allocate()
        old_lo = device.loopback_ip

        # Update the loopback interface
        for iface in device.interfaces:
            if iface.is_loopback and iface.ip:
                mappings.append(IPMapping(
                    prod_ip=iface.ip.split("/")[0],
                    netwatch_ip=new_lo,
                    device=device.hostname,
                    interface=iface.name,
                    purpose="loopback",
                ))
                iface.ip = f"{new_lo}/32"
                break
        else:
            # No loopback found — create a virtual one
            from .model import CanonicalInterface
            device.interfaces.insert(0, CanonicalInterface(
                name="Loopback0",
                ip=f"{new_lo}/32",
                is_loopback=True,
            ))

    # ------------------------------------------------------------------
    # 2. Management IP allocation
    # ------------------------------------------------------------------
    mgmt_alloc = Allocator(MGMT_POOL)
    mgmt_alloc._next = 10  # Start at .10, reserve .1-.9 for infra

    for device in _sorted_active(topo):
        device._mgmt_ip = mgmt_alloc.allocate()

    # ------------------------------------------------------------------
    # 3. Fabric P2P link allocation
    # ------------------------------------------------------------------
    p2p_allocs = {
        tier: P2PAllocator(pool)
        for tier, pool in FABRIC_POOLS.items()
    }

    for edge in topo.edges:
        a_dev = topo.devices.get(edge.a_hostname)
        b_dev = topo.devices.get(edge.b_hostname)

        if not a_dev or not b_dev or a_dev.dropped or b_dev.dropped:
            continue

        # Determine link tier
        tier = _link_tier(a_dev.role, b_dev.role)
        if tier not in p2p_allocs:
            continue

        a_ip, b_ip, subnet = p2p_allocs[tier].allocate_pair()

        # Record mappings
        old_a = edge.a_ip.split("/")[0] if "/" in edge.a_ip else edge.a_ip
        old_b = edge.b_ip.split("/")[0] if "/" in edge.b_ip else edge.b_ip
        new_a = a_ip.split("/")[0]
        new_b = b_ip.split("/")[0]

        mappings.append(IPMapping(
            prod_ip=old_a, netwatch_ip=new_a,
            device=edge.a_hostname, interface=edge.a_interface,
            purpose="fabric",
        ))
        mappings.append(IPMapping(
            prod_ip=old_b, netwatch_ip=new_b,
            device=edge.b_hostname, interface=edge.b_interface,
            purpose="fabric",
        ))

        # Update the edge
        edge.a_ip = a_ip
        edge.b_ip = b_ip
        edge.subnet = subnet

        # Update the device interfaces
        _update_interface_ip(a_dev, edge.a_interface, a_ip)
        _update_interface_ip(b_dev, edge.b_interface, b_ip)

    mapped_count = sum(1 for d in topo.devices.values() if not d.dropped)
    print(f"[remap] Remapped IPs for {mapped_count} devices, {len(mappings)} total mappings")

    return mappings


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _sorted_active(topo: CanonicalTopology) -> list[CanonicalDevice]:
    """Return active devices sorted by netwatch_name for deterministic allocation."""
    return sorted(
        topo.active_devices(),
        key=lambda d: d.netwatch_name or d.hostname,
    )


def _rack_number(rack: str | None) -> int | None:
    if not rack:
        return None
    for part in reversed(rack.split("-")):
        try:
            return int(part)
        except ValueError:
            continue
    return None


def _link_tier(role_a: DeviceRole, role_b: DeviceRole) -> str:
    """Determine the NetWatch link tier from two device roles."""
    pair = frozenset([role_a, role_b])

    tier_map = {
        frozenset([DeviceRole.BORDER, DeviceRole.SPINE]): "border_spine",
        frozenset([DeviceRole.SPINE, DeviceRole.LEAF]): "spine_leaf",
        frozenset([DeviceRole.LEAF, DeviceRole.SERVER]): "leaf_server",
    }

    return tier_map.get(pair, "unknown")


def _update_interface_ip(device: CanonicalDevice, iface_name: str, new_ip: str) -> None:
    """Update an interface's IP on a device."""
    for iface in device.interfaces:
        if iface.name == iface_name:
            iface.ip = new_ip
            return
