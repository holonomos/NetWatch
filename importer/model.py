"""Canonical data model for the topology import pipeline.

Vendor-agnostic dataclasses that decouple Batfish output from
NetWatch topology generation.  Every stage of the pipeline
(extraction → role inference → scale mapping → IP remapping →
policy extraction → topology emission) operates on these types.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Any


# ---------------------------------------------------------------------------
# Enums
# ---------------------------------------------------------------------------

class DeviceRole(Enum):
    """Inferred role of a network device in a Clos fabric."""
    BORDER = "border"
    SPINE = "spine"
    LEAF = "leaf"
    SERVER = "server"
    UNKNOWN = "unknown"


class PolicyType(Enum):
    ROUTE_MAP = "route-map"
    PREFIX_LIST = "prefix-list"
    COMMUNITY_LIST = "community-list"
    AS_PATH_LIST = "as-path-list"


class AddressFamily(Enum):
    IPV4_UNICAST = "ipv4_unicast"
    IPV6_UNICAST = "ipv6_unicast"
    L2VPN_EVPN = "l2vpn_evpn"


# ---------------------------------------------------------------------------
# Core model
# ---------------------------------------------------------------------------

@dataclass
class CanonicalInterface:
    """A single L3 interface on a device."""
    name: str
    ip: str                          # CIDR notation, e.g. "172.16.1.1/30"
    peer_hostname: str | None = None
    peer_interface: str | None = None
    is_loopback: bool = False
    admin_up: bool = True
    description: str = ""


@dataclass
class CanonicalBGPNeighbor:
    """A single BGP peering session."""
    peer_ip: str
    peer_asn: int
    peer_hostname: str | None = None
    address_families: list[AddressFamily] = field(default_factory=list)
    import_policy: str | None = None     # route-map name applied inbound
    export_policy: str | None = None     # route-map name applied outbound


@dataclass
class CanonicalStaticRoute:
    """An ip route statement."""
    prefix: str           # CIDR, e.g. "0.0.0.0/0"
    nexthop: str          # Next-hop IP or interface
    admin_distance: int = 1


@dataclass
class PolicyEntry:
    """A single sequence/entry inside a routing policy object."""
    sequence: int
    action: str                          # "permit" or "deny"
    match_clauses: dict[str, Any] = field(default_factory=dict)
    set_clauses: dict[str, Any] = field(default_factory=dict)
    # For prefix-lists: match_clauses = {"prefix": "10.0.0.0/8", "le": 24}
    # For route-maps: match_clauses = {"ip_prefix_list": "PL-NAME", ...}
    #                 set_clauses   = {"local_preference": 200, ...}


@dataclass
class CanonicalPolicy:
    """A named routing policy object (route-map, prefix-list, etc.)."""
    type: PolicyType
    name: str
    entries: list[PolicyEntry] = field(default_factory=list)
    applied_to: list[str] = field(default_factory=list)  # BGP session refs


@dataclass
class CanonicalDevice:
    """A single network device with all extracted properties."""
    hostname: str
    vendor: str                          # "cisco_ios", "arista_eos", etc.
    interfaces: list[CanonicalInterface] = field(default_factory=list)
    bgp_asn: int | None = None
    bgp_router_id: str | None = None
    bgp_neighbors: list[CanonicalBGPNeighbor] = field(default_factory=list)
    static_routes: list[CanonicalStaticRoute] = field(default_factory=list)
    policies: list[CanonicalPolicy] = field(default_factory=list)

    # Populated by role inference
    role: DeviceRole = DeviceRole.UNKNOWN
    rack: str | None = None              # e.g. "rack-1"

    # Populated by scale mapper
    netwatch_name: str | None = None     # e.g. "border-1", "leaf-2a"
    dropped: bool = False                # True if not mapped to NetWatch
    drop_reason: str | None = None

    @property
    def loopback_ip(self) -> str | None:
        """Return the first loopback interface IP, or None."""
        for iface in self.interfaces:
            if iface.is_loopback and iface.ip:
                return iface.ip
        return None

    @property
    def fabric_interfaces(self) -> list[CanonicalInterface]:
        """Return non-loopback, admin-up interfaces with peers."""
        return [
            i for i in self.interfaces
            if not i.is_loopback and i.admin_up and i.peer_hostname
        ]


@dataclass
class CanonicalEdge:
    """An L3 link between two devices."""
    a_hostname: str
    a_interface: str
    a_ip: str                # CIDR
    b_hostname: str
    b_interface: str
    b_ip: str                # CIDR
    subnet: str              # e.g. "172.16.1.0/30"


@dataclass
class CanonicalTopology:
    """The complete extracted network topology."""
    devices: dict[str, CanonicalDevice] = field(default_factory=dict)
    edges: list[CanonicalEdge] = field(default_factory=list)
    bgp_timers: BGPTimers | None = None

    @property
    def device_list(self) -> list[CanonicalDevice]:
        return list(self.devices.values())

    def devices_by_role(self, role: DeviceRole) -> list[CanonicalDevice]:
        return [d for d in self.devices.values() if d.role == role]

    def active_devices(self) -> list[CanonicalDevice]:
        return [d for d in self.devices.values() if not d.dropped]


@dataclass
class BGPTimers:
    """BGP/BFD timer values extracted from the network."""
    keepalive_s: int = 30
    holdtime_s: int = 90
    bfd_tx_ms: int = 300
    bfd_rx_ms: int = 300
    bfd_multiplier: int = 3


# ---------------------------------------------------------------------------
# IP mapping table (populated by ip_remapper)
# ---------------------------------------------------------------------------

@dataclass
class IPMapping:
    """Maps a production IP to a NetWatch IP."""
    prod_ip: str
    netwatch_ip: str
    device: str              # prod hostname
    interface: str           # prod interface name
    purpose: str             # "loopback", "fabric", "management"


@dataclass
class ImportReport:
    """Human-readable import results."""
    snapshot_name: str
    total_devices: int = 0
    mapped_devices: int = 0
    dropped_devices: int = 0
    total_edges: int = 0
    mapped_edges: int = 0
    total_policies: int = 0
    warnings: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    device_mapping: dict[str, str] = field(default_factory=dict)  # prod → NW
    ip_mappings: list[IPMapping] = field(default_factory=list)

    def add_warning(self, msg: str) -> None:
        self.warnings.append(msg)

    def add_error(self, msg: str) -> None:
        self.errors.append(msg)

    def render(self) -> str:
        lines = [
            f"# NetWatch Import Report — {self.snapshot_name}",
            f"",
            f"Devices: {self.mapped_devices} mapped / {self.total_devices} total "
            f"({self.dropped_devices} dropped)",
            f"Edges:   {self.mapped_edges} mapped / {self.total_edges} total",
            f"Policies: {self.total_policies} extracted",
            f"",
        ]
        if self.device_mapping:
            lines.append("## Device Mapping")
            lines.append(f"{'Production':<30} → {'NetWatch':<20}")
            lines.append("-" * 55)
            for prod, nw in sorted(self.device_mapping.items()):
                lines.append(f"{prod:<30} → {nw:<20}")
            lines.append("")

        if self.warnings:
            lines.append(f"## Warnings ({len(self.warnings)})")
            for w in self.warnings:
                lines.append(f"  - {w}")
            lines.append("")

        if self.errors:
            lines.append(f"## Errors ({len(self.errors)})")
            for e in self.errors:
                lines.append(f"  - {e}")
            lines.append("")

        return "\n".join(lines)
