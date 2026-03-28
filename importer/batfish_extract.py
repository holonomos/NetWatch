"""Extract topology data from Batfish into the canonical model.

Queries Batfish for L3 edges, BGP sessions, interfaces, routing
policies, and static routes, then populates CanonicalTopology.
"""

from __future__ import annotations

import ipaddress
from typing import Any

from pybatfish.client.session import Session

from .model import (
    AddressFamily,
    BGPTimers,
    CanonicalBGPNeighbor,
    CanonicalDevice,
    CanonicalEdge,
    CanonicalInterface,
    CanonicalPolicy,
    CanonicalStaticRoute,
    CanonicalTopology,
    PolicyEntry,
    PolicyType,
)


def _ip_to_subnet(ip_a: str, ip_b: str, prefix_len: int) -> str:
    """Compute the subnet CIDR from two IPs on the same /prefix_len link."""
    net = ipaddress.ip_network(f"{ip_a}/{prefix_len}", strict=False)
    return str(net)


def _strip_prefix_len(cidr: str) -> str:
    """'10.0.1.1/30' → '10.0.1.1'"""
    return cidr.split("/")[0] if "/" in cidr else cidr


def extract_topology(bf: Session) -> CanonicalTopology:
    """Run all Batfish queries and build a CanonicalTopology.

    Args:
        bf: A pybatfish Session with an initialized snapshot.

    Returns:
        Fully populated CanonicalTopology.
    """
    topo = CanonicalTopology()

    # ------------------------------------------------------------------
    # 1. Device + interface discovery
    # ------------------------------------------------------------------
    print("[extract] Querying node properties...")
    node_props = bf.q.nodeProperties().answer().frame()

    for _, row in node_props.iterrows():
        hostname = row["Node"]
        vendor = _normalize_vendor(row.get("Configuration_Format", "unknown"))
        topo.devices[hostname] = CanonicalDevice(
            hostname=hostname,
            vendor=vendor,
        )

    print(f"[extract] Found {len(topo.devices)} devices")

    print("[extract] Querying interface properties...")
    iface_props = bf.q.interfaceProperties().answer().frame()

    for _, row in iface_props.iterrows():
        hostname = row["Interface"].hostname
        iface_name = row["Interface"].interface

        if hostname not in topo.devices:
            continue

        # Batfish returns primary addresses as list of "ip/prefix"
        primary_addresses = row.get("All_Prefixes", [])
        if not primary_addresses:
            continue

        ip_cidr = str(primary_addresses[0]) if primary_addresses else ""
        is_loopback = "loopback" in iface_name.lower() or "lo" in iface_name.lower()
        admin_up = row.get("Admin_Up", True)
        description = row.get("Description", "") or ""

        topo.devices[hostname].interfaces.append(CanonicalInterface(
            name=iface_name,
            ip=ip_cidr,
            is_loopback=is_loopback,
            admin_up=admin_up,
            description=str(description),
        ))

    # ------------------------------------------------------------------
    # 2. L3 edge discovery (topology graph)
    # ------------------------------------------------------------------
    print("[extract] Querying L3 edges...")
    edges = bf.q.layer3Edges().answer().frame()

    seen_edges = set()
    for _, row in edges.iterrows():
        a_host = row["Interface"].hostname
        a_iface = row["Interface"].interface
        b_host = row["Remote_Interface"].hostname
        b_iface = row["Remote_Interface"].interface

        # Deduplicate (A→B and B→A are the same edge)
        edge_key = tuple(sorted([(a_host, a_iface), (b_host, b_iface)]))
        if edge_key in seen_edges:
            continue
        seen_edges.add(edge_key)

        # Look up IPs from interface properties
        a_ip = _find_interface_ip(topo.devices.get(a_host), a_iface)
        b_ip = _find_interface_ip(topo.devices.get(b_host), b_iface)

        if not a_ip or not b_ip:
            continue

        # Compute subnet
        a_prefix_len = int(a_ip.split("/")[1]) if "/" in a_ip else 30
        subnet = _ip_to_subnet(_strip_prefix_len(a_ip), _strip_prefix_len(b_ip), a_prefix_len)

        topo.edges.append(CanonicalEdge(
            a_hostname=a_host,
            a_interface=a_iface,
            a_ip=a_ip,
            b_hostname=b_host,
            b_interface=b_iface,
            b_ip=b_ip,
            subnet=subnet,
        ))

        # Annotate peer info on interfaces
        _set_peer(topo.devices.get(a_host), a_iface, b_host, b_iface)
        _set_peer(topo.devices.get(b_host), b_iface, a_host, a_iface)

    print(f"[extract] Found {len(topo.edges)} L3 edges")

    _l3_edge_count = len(topo.edges)

    # ------------------------------------------------------------------
    # 3. BGP session discovery
    # ------------------------------------------------------------------
    print("[extract] Querying BGP sessions...")
    try:
        bgp_sessions = bf.q.bgpSessionStatus().answer().frame()
    except Exception:
        bgp_sessions = bf.q.bgpSessionCompatibility().answer().frame()

    for _, row in bgp_sessions.iterrows():
        hostname = row["Node"].node if hasattr(row["Node"], "node") else str(row["Node"])
        device = topo.devices.get(hostname)
        if not device:
            continue

        local_as = _safe_int(row.get("Local_AS"))
        remote_as = _safe_int(row.get("Remote_AS"))
        remote_ip = str(row.get("Remote_IP", ""))
        remote_node = row.get("Remote_Node")
        if hasattr(remote_node, "node"):
            remote_node = remote_node.node
        remote_node = str(remote_node) if remote_node else None

        if device.bgp_asn is None and local_as:
            device.bgp_asn = local_as

        # Parse address families
        afs = []
        af_raw = row.get("Address_Families", [])
        if af_raw:
            for af in af_raw:
                af_str = str(af).lower()
                if "ipv4" in af_str and "unicast" in af_str:
                    afs.append(AddressFamily.IPV4_UNICAST)
                elif "l2vpn" in af_str or "evpn" in af_str:
                    afs.append(AddressFamily.L2VPN_EVPN)

        device.bgp_neighbors.append(CanonicalBGPNeighbor(
            peer_ip=remote_ip,
            peer_asn=remote_as or 0,
            peer_hostname=remote_node,
            address_families=afs if afs else [AddressFamily.IPV4_UNICAST],
        ))

    # Set BGP ASN from sessions if not already set
    for device in topo.devices.values():
        if device.bgp_asn is None and device.bgp_neighbors:
            # All neighbors should report the same local AS
            pass  # ASN stays None — role inference handles this

    _count_bgp = sum(len(d.bgp_neighbors) for d in topo.devices.values())
    print(f"[extract] Found {_count_bgp} BGP neighbor entries")

    # ------------------------------------------------------------------
    # 3b. Infer edges if Batfish didn't find physical topology
    # ------------------------------------------------------------------
    if not topo.edges:
        print("[extract] No L3 edges from Batfish — inferring edges from BGP neighbor IPs...")
        topo.edges = _infer_edges_from_bgp_ips(topo)
        print(f"[extract] Inferred {len(topo.edges)} edges")

    # ------------------------------------------------------------------
    # 4. Static routes
    # ------------------------------------------------------------------
    print("[extract] Querying static routes...")
    try:
        routes = bf.q.routes(protocols="static").answer().frame()
        for _, row in routes.iterrows():
            hostname = row.get("Node", "")
            if hasattr(hostname, "node"):
                hostname = hostname.node
            device = topo.devices.get(str(hostname))
            if not device:
                continue

            prefix = str(row.get("Network", ""))
            nexthop = str(row.get("Next_Hop", ""))
            ad = _safe_int(row.get("Admin_Distance", 1))

            device.static_routes.append(CanonicalStaticRoute(
                prefix=prefix,
                nexthop=nexthop,
                admin_distance=ad or 1,
            ))
    except Exception as e:
        print(f"[extract] Warning: Could not query static routes: {e}")

    # ------------------------------------------------------------------
    # 5. BGP timers (sample from first device with BGP)
    # ------------------------------------------------------------------
    topo.bgp_timers = _extract_timers(bf)

    # ------------------------------------------------------------------
    # 6. Routing policies (route-maps, prefix-lists, community-lists)
    # ------------------------------------------------------------------
    _extract_policies(bf, topo)

    return topo


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _infer_edges_from_bgp_ips(topo: CanonicalTopology) -> list[CanonicalEdge]:
    """Infer edges by matching BGP neighbor IPs across devices.

    If device A has neighbor IP X, and device B has a fabric interface with IP X,
    then A and B are connected. When Batfish doesn't resolve Remote_Node (common
    with FRR configs), we do the matching ourselves.
    """
    edges = []
    seen = set()

    # Build a map: BGP neighbor IP → (local_hostname, local_ip, remote_asn)
    # Each BGP session has a local side and a remote IP
    # The remote IP is the interface IP on the peer device
    # So we need: for each device, what IPs does it own on fabric interfaces?

    # Since Batfish only found loopback interfaces for FRR, we need to
    # reconstruct fabric interfaces from the FRR config BGP neighbor statements.
    # The key insight: if border-1 has neighbor 172.16.1.2 (remote-as 65001),
    # and spine-1 has neighbor 172.16.1.1 (remote-as 65000), then these are
    # on the same /30 and form an edge.

    # Collect all (device, local_ip_implied, remote_ip, remote_asn) from BGP
    sessions = []
    for hostname, device in topo.devices.items():
        for nbr in device.bgp_neighbors:
            sessions.append((hostname, nbr.peer_ip, nbr.peer_asn))

    # For each pair of sessions, check if they form a /30 pair
    # i.e., session from A to IP X, and session from B to IP Y,
    # where X and Y are on the same /30 subnet
    for i, (host_a, remote_ip_a, remote_asn_a) in enumerate(sessions):
        for j, (host_b, remote_ip_b, remote_asn_b) in enumerate(sessions):
            if i >= j:
                continue
            if host_a == host_b:
                continue

            # Check if remote_ip_a (which should be on host_b) and
            # remote_ip_b (which should be on host_a) are on the same /30
            try:
                net_a = ipaddress.ip_network(f"{remote_ip_a}/30", strict=False)
                net_b = ipaddress.ip_network(f"{remote_ip_b}/30", strict=False)
            except ValueError:
                continue

            if net_a != net_b:
                continue

            # Verify ASN cross-match: A peers with B's ASN, B peers with A's ASN
            dev_a = topo.devices[host_a]
            dev_b = topo.devices[host_b]
            if remote_asn_a != dev_b.bgp_asn or remote_asn_b != dev_a.bgp_asn:
                continue

            edge_key = tuple(sorted([host_a, host_b, str(net_a)]))
            if edge_key in seen:
                continue
            seen.add(edge_key)

            # remote_ip_a is B's interface IP, remote_ip_b is A's interface IP
            a_ip = remote_ip_b  # A's IP (what B sees as its neighbor)
            b_ip = remote_ip_a  # B's IP (what A sees as its neighbor)

            edges.append(CanonicalEdge(
                a_hostname=host_a,
                a_interface=f"eth-{host_b}",
                a_ip=f"{a_ip}/30",
                b_hostname=host_b,
                b_interface=f"eth-{host_a}",
                b_ip=f"{b_ip}/30",
                subnet=str(net_a),
            ))

            # Create fabric interfaces
            _ensure_fabric_interface(dev_a, f"eth-{host_b}", f"{a_ip}/30", host_b)
            _ensure_fabric_interface(dev_b, f"eth-{host_a}", f"{b_ip}/30", host_a)

            # Update BGP neighbor peer_hostname
            for nbr in dev_a.bgp_neighbors:
                if nbr.peer_ip == b_ip:
                    nbr.peer_hostname = host_b
            for nbr in dev_b.bgp_neighbors:
                if nbr.peer_ip == a_ip:
                    nbr.peer_hostname = host_a

    return edges


def _infer_edges_from_bgp(topo: CanonicalTopology, bf: Session) -> list[CanonicalEdge]:
    """Infer L3 edges from BGP session pairs (A peers with B, B peers with A)."""
    edges = []
    seen = set()

    # Build hostname → device lookup for quick access
    # For each BGP session, find the matching reverse session
    for hostname, device in topo.devices.items():
        for nbr in device.bgp_neighbors:
            peer_host = nbr.peer_hostname
            if not peer_host or peer_host not in topo.devices:
                continue

            edge_key = tuple(sorted([hostname, peer_host]))
            if edge_key in seen:
                continue
            seen.add(edge_key)

            # Try to find the P2P subnet from BGP session IPs
            # BGP neighbor IPs are typically on /30 subnets
            peer_dev = topo.devices[peer_host]

            # Find the reverse BGP session to get the local IP
            local_ip = None
            for rev_nbr in peer_dev.bgp_neighbors:
                if rev_nbr.peer_hostname == hostname:
                    local_ip = rev_nbr.peer_ip
                    break

            if not local_ip:
                # Use the neighbor IP and construct a synthetic /30
                local_ip = nbr.peer_ip

            # Construct edge with BGP neighbor IPs
            a_ip = local_ip if local_ip else "0.0.0.0"
            b_ip = nbr.peer_ip

            try:
                subnet = str(ipaddress.ip_network(f"{a_ip}/30", strict=False))
            except ValueError:
                subnet = "0.0.0.0/30"

            edges.append(CanonicalEdge(
                a_hostname=hostname,
                a_interface=f"eth-{peer_host}",
                a_ip=f"{a_ip}/30",
                b_hostname=peer_host,
                b_interface=f"eth-{hostname}",
                b_ip=f"{b_ip}/30",
                subnet=subnet,
            ))

            # Set peer info on device interfaces (or create synthetic ones)
            _ensure_fabric_interface(device, f"eth-{peer_host}", f"{a_ip}/30", peer_host)
            _ensure_fabric_interface(peer_dev, f"eth-{hostname}", f"{b_ip}/30", hostname)

    return edges


def _ensure_fabric_interface(device: CanonicalDevice, iface_name: str,
                              ip: str, peer_host: str) -> None:
    """Ensure a fabric interface exists on the device, creating if needed."""
    for iface in device.interfaces:
        if iface.name == iface_name:
            iface.peer_hostname = peer_host
            return
    # Create synthetic interface
    device.interfaces.append(CanonicalInterface(
        name=iface_name,
        ip=ip,
        peer_hostname=peer_host,
        peer_interface=f"eth-{device.hostname}",
        is_loopback=False,
        admin_up=True,
    ))


def _infer_edges_from_ips(topo: CanonicalTopology) -> list[CanonicalEdge]:
    """Infer L3 edges by matching interface IPs on the same /30 subnet."""
    edges = []
    seen = set()

    # Build IP → (hostname, interface) lookup for non-loopback interfaces
    ip_lookup: dict[str, tuple[str, str, str]] = {}  # bare_ip → (hostname, iface_name, cidr)
    for device in topo.devices.values():
        for iface in device.interfaces:
            if iface.is_loopback or not iface.ip:
                continue
            bare_ip = iface.ip.split("/")[0]
            ip_lookup[bare_ip] = (device.hostname, iface.name, iface.ip)

    # For each interface, find the peer on the same /30
    for bare_ip, (hostname, iface_name, cidr) in ip_lookup.items():
        prefix_len = int(cidr.split("/")[1]) if "/" in cidr else 30
        try:
            network = ipaddress.ip_network(f"{bare_ip}/{prefix_len}", strict=False)
        except ValueError:
            continue

        hosts = list(network.hosts())
        for host in hosts:
            peer_ip = str(host)
            if peer_ip == bare_ip:
                continue
            if peer_ip in ip_lookup:
                peer_host, peer_iface, peer_cidr = ip_lookup[peer_ip]
                if peer_host == hostname:
                    continue

                edge_key = tuple(sorted([hostname, peer_host]))
                iface_key = tuple(sorted([(hostname, iface_name), (peer_host, peer_iface)]))
                if iface_key in seen:
                    continue
                seen.add(iface_key)

                edges.append(CanonicalEdge(
                    a_hostname=hostname,
                    a_interface=iface_name,
                    a_ip=cidr,
                    b_hostname=peer_host,
                    b_interface=peer_iface,
                    b_ip=peer_cidr,
                    subnet=str(network),
                ))

                # Set peer info
                _set_peer(topo.devices.get(hostname), iface_name, peer_host, peer_iface)
                _set_peer(topo.devices.get(peer_host), peer_iface, hostname, iface_name)

    return edges


def _normalize_vendor(config_format: str) -> str:
    """Normalize Batfish config format to a short vendor string."""
    fmt = str(config_format).lower()
    if "cisco" in fmt or "ios" in fmt:
        return "cisco_ios"
    if "arista" in fmt:
        return "arista_eos"
    if "juniper" in fmt:
        return "juniper_junos"
    if "palo" in fmt:
        return "paloalto"
    if "frr" in fmt or "cumulus" in fmt:
        return "frr"
    return fmt


def _find_interface_ip(device: CanonicalDevice | None, iface_name: str) -> str | None:
    """Find the IP of a specific interface on a device."""
    if not device:
        return None
    for iface in device.interfaces:
        if iface.name == iface_name:
            return iface.ip
    return None


def _set_peer(device: CanonicalDevice | None, iface_name: str,
              peer_host: str, peer_iface: str) -> None:
    """Annotate an interface with its peer info."""
    if not device:
        return
    for iface in device.interfaces:
        if iface.name == iface_name:
            iface.peer_hostname = peer_host
            iface.peer_interface = peer_iface
            return


def _safe_int(val: Any) -> int | None:
    """Safely convert a value to int."""
    if val is None:
        return None
    try:
        return int(val)
    except (ValueError, TypeError):
        return None


def _extract_timers(bf: Session) -> BGPTimers:
    """Extract BGP/BFD timers from the first BGP-speaking device."""
    timers = BGPTimers()

    try:
        bgp_proc = bf.q.bgpProcessConfiguration().answer().frame()
        if not bgp_proc.empty:
            row = bgp_proc.iloc[0]
            keepalive = _safe_int(row.get("Keep_Alive_Timer"))
            holdtime = _safe_int(row.get("Hold_Timer"))
            if keepalive:
                timers.keepalive_s = keepalive
            if holdtime:
                timers.holdtime_s = holdtime
    except Exception:
        pass  # Use defaults

    return timers


def _extract_policies(bf: Session, topo: CanonicalTopology) -> None:
    """Extract routing policy definitions from Batfish."""
    print("[extract] Querying routing policies...")

    try:
        structures = bf.q.definedStructures().answer().frame()
    except Exception as e:
        print(f"[extract] Warning: Could not query defined structures: {e}")
        return

    policy_count = 0
    for _, row in structures.iterrows():
        # Extract hostname — Batfish may use various column names
        hostname = ""
        for col in ["Node", "Source_Lines"]:
            val = row.get(col)
            if val is not None:
                hostname = str(val).split("/")[-1].replace(".cfg", "").replace(".conf", "")
                if hasattr(val, "node"):
                    hostname = val.node
                break
        struct_type = str(row.get("Structure_Type", "")).lower()
        struct_name = str(row.get("Structure_Name", ""))

        if not struct_name:
            continue

        # Map Batfish structure types to our PolicyType
        policy_type = None
        if "route-map" in struct_type or "route_map" in struct_type:
            policy_type = PolicyType.ROUTE_MAP
        elif "prefix-list" in struct_type or "prefix_list" in struct_type:
            policy_type = PolicyType.PREFIX_LIST
        elif "community" in struct_type:
            policy_type = PolicyType.COMMUNITY_LIST
        elif "as-path" in struct_type:
            policy_type = PolicyType.AS_PATH_LIST
        else:
            continue

        # Find the device this policy belongs to
        device = _find_device_by_config(topo, hostname)
        if not device:
            continue

        # Check if we already have this policy on this device
        existing = next(
            (p for p in device.policies if p.name == struct_name and p.type == policy_type),
            None,
        )
        if not existing:
            device.policies.append(CanonicalPolicy(
                type=policy_type,
                name=struct_name,
                entries=[],
            ))
            policy_count += 1

    print(f"[extract] Found {policy_count} routing policy structures")

    # Try to get detailed policy content via namedStructures
    try:
        named = bf.q.namedStructures().answer().frame()
        for _, row in named.iterrows():
            hostname = str(row.get("Node", ""))
            if hasattr(row.get("Node"), "node"):
                hostname = row["Node"].node
            struct_type = str(row.get("Structure_Type", "")).lower()
            struct_name = str(row.get("Structure_Name", ""))
            definition = row.get("Structure_Definition", {})

            device = topo.devices.get(hostname)
            if not device:
                continue

            policy = next(
                (p for p in device.policies if p.name == struct_name),
                None,
            )
            if policy and isinstance(definition, dict):
                _parse_policy_definition(policy, definition)

    except Exception as e:
        print(f"[extract] Warning: Could not get detailed policy content: {e}")


def _find_device_by_config(topo: CanonicalTopology, config_ref: str) -> CanonicalDevice | None:
    """Find a device by its config filename (Batfish uses filenames as keys)."""
    # Strip .cfg extension
    name = config_ref.replace(".cfg", "").replace(".conf", "")
    if name in topo.devices:
        return topo.devices[name]
    # Try case-insensitive match
    for hostname, device in topo.devices.items():
        if hostname.lower() == name.lower():
            return device
    return None


def _parse_policy_definition(policy: CanonicalPolicy, definition: dict) -> None:
    """Parse a Batfish policy definition dict into PolicyEntry objects."""
    if policy.type == PolicyType.PREFIX_LIST:
        lines = definition.get("lines", [])
        for i, line in enumerate(lines):
            if isinstance(line, dict):
                policy.entries.append(PolicyEntry(
                    sequence=line.get("line", i * 5 + 5),
                    action=line.get("action", "permit").lower(),
                    match_clauses={
                        "prefix": line.get("prefix", ""),
                        "le": line.get("lengthRange", {}).get("end"),
                        "ge": line.get("lengthRange", {}).get("start"),
                    },
                ))

    elif policy.type == PolicyType.ROUTE_MAP:
        clauses = definition.get("clauses", {})
        for seq_str, clause in clauses.items():
            seq = _safe_int(seq_str) or 0
            action = str(clause.get("action", "permit")).lower()

            match_clauses = {}
            for match in clause.get("matchList", []):
                if isinstance(match, dict):
                    match_clauses.update(match)

            set_clauses = {}
            for set_item in clause.get("setList", []):
                if isinstance(set_item, dict):
                    set_clauses.update(set_item)

            policy.entries.append(PolicyEntry(
                sequence=seq,
                action=action,
                match_clauses=match_clauses,
                set_clauses=set_clauses,
            ))
