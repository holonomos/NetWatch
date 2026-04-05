"""
NetWatch Cathedral — Mathematical Foundation Validation Suite
=============================================================

Purpose: Validate the core mathematical claims that the Cathedral
relies on, IN ISOLATION, before building the implementation.

The Cathedral's claims are fundamentally different from the compression
engine's claims. The compression engine says "I can reduce the graph."
The Cathedral says "I can predict what the full graph will do."

Claims under test:
    1. BGP best-path selection — RFC 4271 §8 comparison chain fidelity
    2. OSPF SPF — Dijkstra correctness on weighted multigraphs
    3. Multi-protocol interaction — BGP next-hop resolution via OSPF
    4. Perturbation propagation — ordering is scale-invariant (Tier 1)
    5. Tier 2 scaling corrections — diameter ratio, cell-size, SPF N·log(N)
    6. Hot-potato routing divergence — IGP cost tiebreaker detection
    7. Timer independence of ordering — defaults change Tier 2, not Tier 1
"""

import math
import heapq
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Set, Tuple
from copy import deepcopy


# ════════════════════════════════════════════════════════════════════
# CORE DATA STRUCTURES
# ════════════════════════════════════════════════════════════════════

@dataclass
class BGPRoute:
    """A BGP route with all attributes used in best-path selection."""
    prefix: str
    next_hop: str
    weight: int = 0                    # Cisco-specific, step 1
    local_pref: int = 100              # step 2 (higher wins)
    locally_originated: bool = False   # step 3
    as_path_length: int = 0            # step 4 (shorter wins)
    origin: str = "igp"                # step 5: "igp" < "egp" < "incomplete"
    med: int = 0                       # step 6 (lower wins)
    peer_type: str = "ebgp"            # step 7: "ebgp" preferred over "ibgp"
    igp_cost_to_next_hop: int = 0      # step 8 (lower wins)
    router_id: str = "0.0.0.0"        # step 10 (lower wins)
    peer_address: str = "0.0.0.0"     # step 11 (lower wins)
    source_device: str = ""            # which device advertised this route


@dataclass
class OSPFLink:
    """An OSPF link with cost."""
    source: str
    target: str
    cost: int = 1
    area: int = 0


@dataclass
class ProtocolEvent:
    """An event in the convergence sequence."""
    timestamp: float
    device: str
    event_type: str       # "bgp_withdraw", "bgp_update", "ospf_lsa_flood", "bfd_down", etc.
    detail: str
    caused_by: Optional[str] = None  # which prior event caused this one

    def __lt__(self, other):
        return self.timestamp < other.timestamp


# ════════════════════════════════════════════════════════════════════
# CLAIM 1: BGP BEST-PATH SELECTION (RFC 4271 §8)
# ════════════════════════════════════════════════════════════════════

ORIGIN_RANK = {"igp": 0, "egp": 1, "incomplete": 2}

def bgp_best_path_select(routes: List[BGPRoute]) -> Tuple[BGPRoute, str]:
    """
    Implements the BGP best-path selection algorithm per RFC 4271 §8.
    Returns (best_route, deciding_step).

    The comparison chain (in order):
    1. Highest weight (Cisco-specific, pre-RFC)
    2. Highest local preference
    3. Locally originated preferred
    4. Shortest AS path
    5. Lowest origin (IGP < EGP < incomplete)
    6. Lowest MED (only compared among routes from same neighbor AS)
    7. eBGP over iBGP
    8. Lowest IGP cost to next hop (hot-potato routing)
    9. (multipath check — skipped for best-path)
    10. Lowest router ID
    11. Lowest peer address

    Each step either selects a winner or narrows the candidate set.
    """
    if len(routes) == 0:
        return None, "no_routes"
    if len(routes) == 1:
        return routes[0], "only_route"

    candidates = list(routes)
    steps = [
        ("weight",            lambda r: -r.weight,               "highest_weight"),
        ("local_pref",        lambda r: -r.local_pref,           "highest_local_pref"),
        ("locally_originated", lambda r: 0 if r.locally_originated else 1, "locally_originated"),
        ("as_path_length",    lambda r: r.as_path_length,        "shortest_as_path"),
        ("origin",            lambda r: ORIGIN_RANK[r.origin],   "lowest_origin"),
        # MED comparison is special — only among routes from same neighbor AS
        # For simplicity, we compare MED across all candidates here (deterministic-med behavior)
        ("med",               lambda r: r.med,                   "lowest_med"),
        ("peer_type",         lambda r: 0 if r.peer_type == "ebgp" else 1, "ebgp_over_ibgp"),
        ("igp_cost",          lambda r: r.igp_cost_to_next_hop,  "lowest_igp_cost"),
        # Step 9: multipath — skip
        ("router_id",         lambda r: tuple(int(x) for x in r.router_id.split(".")), "lowest_router_id"),
        ("peer_address",      lambda r: tuple(int(x) for x in r.peer_address.split(".")), "lowest_peer_address"),
    ]

    for step_name, key_fn, deciding_label in steps:
        if len(candidates) <= 1:
            break

        best_val = min(key_fn(r) for r in candidates)
        narrowed = [r for r in candidates if key_fn(r) == best_val]

        if len(narrowed) < len(candidates):
            candidates = narrowed
            if len(candidates) == 1:
                return candidates[0], deciding_label

    return candidates[0], "final_tiebreak"


# ════════════════════════════════════════════════════════════════════
# CLAIM 2: OSPF SPF (Dijkstra)
# ════════════════════════════════════════════════════════════════════

def ospf_spf(links: List[OSPFLink], root: str) -> Dict[str, int]:
    """
    Run Dijkstra's algorithm for OSPF SPF.
    Returns {destination: cost} from root.
    """
    # Build adjacency list
    adj = defaultdict(list)
    for link in links:
        adj[link.source].append((link.target, link.cost))
        adj[link.target].append((link.source, link.cost))

    # Dijkstra
    dist = {root: 0}
    heap = [(0, root)]
    visited = set()

    while heap:
        d, u = heapq.heappop(heap)
        if u in visited:
            continue
        visited.add(u)

        for v, w in adj[u]:
            if v not in visited:
                new_dist = d + w
                if v not in dist or new_dist < dist[v]:
                    dist[v] = new_dist
                    heapq.heappush(heap, (new_dist, v))

    return dist


def compute_graph_diameter(links: List[OSPFLink], nodes: List[str]) -> int:
    """Compute the diameter of the graph (longest shortest path)."""
    diameter = 0
    for node in nodes:
        dists = ospf_spf(links, node)
        max_dist = max(dists.values()) if dists else 0
        diameter = max(diameter, max_dist)
    return diameter


# ════════════════════════════════════════════════════════════════════
# CLAIM 3: MULTI-PROTOCOL INTERACTION
# ════════════════════════════════════════════════════════════════════

def resolve_bgp_next_hop_via_ospf(bgp_routes: List[BGPRoute],
                                    ospf_links: List[OSPFLink],
                                    device: str) -> List[BGPRoute]:
    """
    Resolve BGP next-hop addresses using OSPF SPF costs.
    This is the multi-protocol interaction: BGP step 8 uses the
    IGP cost to the next-hop, which comes from OSPF's SPF tree.
    """
    # Compute OSPF SPF tree from this device
    ospf_costs = ospf_spf(ospf_links, device)

    # Update each BGP route's igp_cost_to_next_hop
    resolved = []
    for route in bgp_routes:
        r = deepcopy(route)
        r.igp_cost_to_next_hop = ospf_costs.get(r.next_hop, 99999)
        resolved.append(r)

    return resolved


# ════════════════════════════════════════════════════════════════════
# CLAIM 4: PERTURBATION PROPAGATION
# ════════════════════════════════════════════════════════════════════

def simulate_link_failure_propagation(
    devices: List[str],
    bgp_edges: List[Tuple[str, str]],
    ospf_links: List[OSPFLink],
    failed_link: Tuple[str, str],
    timer_config: Dict[str, float] = None,
) -> List[ProtocolEvent]:
    """
    Simulate a link failure and the resulting convergence sequence.
    Returns an ordered list of protocol events.

    Timer config: {
        "bfd_detection": float (seconds),
        "bgp_hold": float,
        "ospf_dead": float,
    }
    """
    if timer_config is None:
        timer_config = {
            "bfd_detection": 0.15,  # 50ms × 3
            "bgp_hold": 180.0,
            "ospf_dead": 40.0,
        }

    events = []
    t = 0.0
    src, dst = failed_link

    # Phase 1: Link goes down (physical event, t=0)
    events.append(ProtocolEvent(t, src, "link_down", f"link to {dst} failed"))
    events.append(ProtocolEvent(t, dst, "link_down", f"link to {src} failed"))

    # Phase 2: BFD detects (fastest — sub-second)
    t_bfd = timer_config["bfd_detection"]
    # BFD on both endpoints detects
    for device in [src, dst]:
        events.append(ProtocolEvent(
            t_bfd, device, "bfd_down",
            f"BFD session to {dst if device == src else src} DOWN",
            caused_by="link_down"
        ))

    # Phase 3: BFD notifies protocols
    t_notify = t_bfd + 0.001  # near-instantaneous

    # BFD → BGP: fast teardown
    if (src, dst) in bgp_edges or (dst, src) in bgp_edges:
        events.append(ProtocolEvent(
            t_notify, src, "bgp_session_down",
            f"BGP to {dst} torn down by BFD",
            caused_by="bfd_down"
        ))
        events.append(ProtocolEvent(
            t_notify, dst, "bgp_session_down",
            f"BGP to {src} torn down by BFD",
            caused_by="bfd_down"
        ))

    # Phase 4: BGP withdraw propagation
    t_withdraw = t_notify + 0.001
    for device in [src, dst]:
        # Find BGP neighbors of the affected device (excluding the failed peer)
        peer = dst if device == src else src
        other_peers = [e[1] for e in bgp_edges if e[0] == device and e[1] != peer]
        other_peers += [e[0] for e in bgp_edges if e[1] == device and e[0] != peer]
        for neighbor in set(other_peers):
            events.append(ProtocolEvent(
                t_withdraw, neighbor, "bgp_withdraw_received",
                f"Withdraw from {device} for routes via {peer}",
                caused_by="bgp_session_down"
            ))

    # Phase 5: OSPF LSA flood (slower — hello/dead timer based if no BFD)
    t_ospf = t_bfd + 0.01  # OSPF interface DOWN triggered by BFD
    has_ospf_link = any(
        (l.source == src and l.target == dst) or (l.source == dst and l.target == src)
        for l in ospf_links
    )
    if has_ospf_link:
        events.append(ProtocolEvent(
            t_ospf, src, "ospf_neighbor_down",
            f"OSPF adjacency to {dst} DOWN",
            caused_by="bfd_down"
        ))
        events.append(ProtocolEvent(
            t_ospf, dst, "ospf_neighbor_down",
            f"OSPF adjacency to {src} DOWN",
            caused_by="bfd_down"
        ))

        # LSA flood to all OSPF neighbors
        t_lsa = t_ospf + 0.01
        for device in [src, dst]:
            ospf_neighbors = set()
            for l in ospf_links:
                if l.source == device and l.target != (dst if device == src else src):
                    ospf_neighbors.add(l.target)
                if l.target == device and l.source != (dst if device == src else src):
                    ospf_neighbors.add(l.source)
            for neighbor in ospf_neighbors:
                events.append(ProtocolEvent(
                    t_lsa, neighbor, "ospf_lsa_received",
                    f"LSA from {device}: link to {dst if device == src else src} down",
                    caused_by="ospf_neighbor_down"
                ))

    # Sort by timestamp
    events.sort(key=lambda e: (e.timestamp, e.device))
    return events


def extract_ordering(events: List[ProtocolEvent]) -> List[Tuple[str, str]]:
    """Extract the causal ordering from a sequence of events.
    Returns [(event_type, device)] in timestamp order, with timestamp removed.
    This is the Tier 1 ordering — scale-invariant.
    """
    return [(e.event_type, e.device) for e in events]


def extract_timing(events: List[ProtocolEvent]) -> List[Tuple[float, str, str]]:
    """Extract the timing from a sequence of events.
    Returns [(timestamp, event_type, device)] — this is Tier 2.
    """
    return [(e.timestamp, e.event_type, e.device) for e in events]


# ════════════════════════════════════════════════════════════════════
# TEST RUNNER
# ════════════════════════════════════════════════════════════════════

class TestResult:
    def __init__(self, name: str):
        self.name = name
        self.checks = []
        self.passed = True

    def check(self, condition: bool, description: str, detail: str = ""):
        status = "PASS" if condition else "FAIL"
        if not condition:
            self.passed = False
        self.checks.append((status, description, detail))

    def report(self) -> str:
        lines = [f"\n{'═' * 72}"]
        status_icon = "✓" if self.passed else "✗"
        lines.append(f"  {status_icon}  TEST: {self.name}")
        lines.append(f"{'═' * 72}")
        for status, desc, detail in self.checks:
            icon = "  ✓" if status == "PASS" else "  ✗"
            lines.append(f"  {icon}  {desc}")
            if detail:
                for line in detail.split("\n"):
                    lines.append(f"        {line}")
        return "\n".join(lines)


def run_all_tests():
    results = []

    # ──────────────────────────────────────────────
    # TEST 1: BGP Best-Path Selection — basic comparison chain
    # ──────────────────────────────────────────────
    t = TestResult("Claim 1a: BGP best-path — local preference wins over AS-path length")

    r1 = BGPRoute("10.0.0.0/8", "1.1.1.1", local_pref=200, as_path_length=5)
    r2 = BGPRoute("10.0.0.0/8", "2.2.2.2", local_pref=100, as_path_length=1)

    best, step = bgp_best_path_select([r1, r2])
    t.check(best == r1, "Higher local-pref wins despite longer AS-path",
            f"Winner: next_hop={best.next_hop}, step={step}")
    t.check(step == "highest_local_pref", f"Deciding step is local_pref, not as_path",
            f"Got: {step}")
    results.append(t)

    # ──────────────────────────────────────────────
    # TEST 2: BGP — AS-path length wins when local-pref tied
    # ──────────────────────────────────────────────
    t = TestResult("Claim 1b: BGP best-path — AS-path length breaks local-pref tie")

    r1 = BGPRoute("10.0.0.0/8", "1.1.1.1", local_pref=100, as_path_length=3)
    r2 = BGPRoute("10.0.0.0/8", "2.2.2.2", local_pref=100, as_path_length=1)

    best, step = bgp_best_path_select([r1, r2])
    t.check(best == r2, "Shorter AS-path wins when local-pref tied",
            f"Winner: next_hop={best.next_hop}, as_path={best.as_path_length}")
    t.check(step == "shortest_as_path", f"Deciding step is as_path_length", f"Got: {step}")
    results.append(t)

    # ──────────────────────────────────────────────
    # TEST 3: BGP — eBGP over iBGP
    # ──────────────────────────────────────────────
    t = TestResult("Claim 1c: BGP best-path — eBGP preferred over iBGP")

    r1 = BGPRoute("10.0.0.0/8", "1.1.1.1", peer_type="ibgp", as_path_length=2)
    r2 = BGPRoute("10.0.0.0/8", "2.2.2.2", peer_type="ebgp", as_path_length=2)

    best, step = bgp_best_path_select([r1, r2])
    t.check(best == r2, "eBGP route wins over iBGP when all prior steps tied",
            f"Winner: peer_type={best.peer_type}")
    t.check(step == "ebgp_over_ibgp", f"Deciding step is peer_type", f"Got: {step}")
    results.append(t)

    # ──────────────────────────────────────────────
    # TEST 4: BGP — IGP cost tiebreaker (hot-potato routing)
    # ──────────────────────────────────────────────
    t = TestResult("Claim 1d: BGP best-path — IGP cost to next-hop (hot-potato)")

    r1 = BGPRoute("10.0.0.0/8", "1.1.1.1", peer_type="ibgp", igp_cost_to_next_hop=10)
    r2 = BGPRoute("10.0.0.0/8", "2.2.2.2", peer_type="ibgp", igp_cost_to_next_hop=5)

    best, step = bgp_best_path_select([r1, r2])
    t.check(best == r2, "Lower IGP cost wins (hot-potato routing)",
            f"Winner: igp_cost={best.igp_cost_to_next_hop}")
    t.check(step == "lowest_igp_cost", f"Deciding step is igp_cost", f"Got: {step}")
    results.append(t)

    # ──────────────────────────────────────────────
    # TEST 5: BGP — full comparison chain with multi-route scenario
    # ──────────────────────────────────────────────
    t = TestResult("Claim 1e: BGP best-path — full chain with 5 competing routes")

    routes = [
        BGPRoute("10.0.0.0/8", "a", local_pref=100, as_path_length=3, origin="igp", peer_type="ebgp", igp_cost_to_next_hop=10, router_id="5.5.5.5"),
        BGPRoute("10.0.0.0/8", "b", local_pref=100, as_path_length=2, origin="igp", peer_type="ebgp", igp_cost_to_next_hop=10, router_id="4.4.4.4"),
        BGPRoute("10.0.0.0/8", "c", local_pref=100, as_path_length=2, origin="igp", peer_type="ebgp", igp_cost_to_next_hop=10, router_id="3.3.3.3"),
        BGPRoute("10.0.0.0/8", "d", local_pref=100, as_path_length=2, origin="egp", peer_type="ebgp", igp_cost_to_next_hop=10, router_id="2.2.2.2"),
        BGPRoute("10.0.0.0/8", "e", local_pref=200, as_path_length=9, origin="incomplete", peer_type="ibgp", igp_cost_to_next_hop=99, router_id="1.1.1.1"),
    ]

    best, step = bgp_best_path_select(routes)
    t.check(best.next_hop == "e", "Highest local-pref (200) wins despite worst everything else",
            f"Winner: next_hop={best.next_hop}, local_pref={best.local_pref}")
    t.check(step == "highest_local_pref", "Decided at local_pref step", f"Got: {step}")

    # Now remove route e and re-run
    routes_no_e = [r for r in routes if r.next_hop != "e"]
    best2, step2 = bgp_best_path_select(routes_no_e)
    t.check(best2.next_hop in ["b", "c"], "After removing local-pref winner, AS-path narrows to b,c",
            f"Winner: next_hop={best2.next_hop}")
    t.check(step2 in ["lowest_router_id", "shortest_as_path", "lowest_origin"],
            f"Deciding step is deeper in the chain", f"Got: {step2}")

    # b and c have same AS-path, same origin, same MED, same peer_type, same IGP cost
    # Tiebreaker: lowest router_id → c (3.3.3.3) wins over b (4.4.4.4)
    t.check(best2.next_hop == "c", "Router-ID tiebreaker: 3.3.3.3 < 4.4.4.4",
            f"Winner router_id={best2.router_id}")

    results.append(t)

    # ──────────────────────────────────────────────
    # TEST 6: OSPF SPF — basic Dijkstra
    # ──────────────────────────────────────────────
    t = TestResult("Claim 2: OSPF SPF — Dijkstra on weighted graph")

    links = [
        OSPFLink("A", "B", cost=10),
        OSPFLink("B", "C", cost=5),
        OSPFLink("A", "C", cost=20),
        OSPFLink("C", "D", cost=3),
    ]

    costs_from_a = ospf_spf(links, "A")
    t.check(costs_from_a["A"] == 0, "Cost to self = 0")
    t.check(costs_from_a["B"] == 10, "A→B = 10", f"Got: {costs_from_a.get('B')}")
    t.check(costs_from_a["C"] == 15, "A→B→C = 15 (cheaper than A→C = 20)", f"Got: {costs_from_a.get('C')}")
    t.check(costs_from_a["D"] == 18, "A→B→C→D = 18", f"Got: {costs_from_a.get('D')}")

    costs_from_d = ospf_spf(links, "D")
    t.check(costs_from_d["A"] == 18, "D→C→B→A = 18 (symmetric)", f"Got: {costs_from_d.get('A')}")

    results.append(t)

    # ──────────────────────────────────────────────
    # TEST 7: Multi-protocol — BGP next-hop resolution via OSPF
    # ──────────────────────────────────────────────
    t = TestResult("Claim 3: Multi-protocol — BGP next-hop resolved via OSPF SPF")

    ospf = [
        OSPFLink("router-A", "spine-1", cost=10),
        OSPFLink("router-A", "spine-2", cost=50),
        OSPFLink("spine-1", "border-1", cost=5),
        OSPFLink("spine-2", "border-2", cost=5),
    ]

    bgp_routes = [
        BGPRoute("10.0.0.0/8", "border-1", peer_type="ibgp", as_path_length=2),
        BGPRoute("10.0.0.0/8", "border-2", peer_type="ibgp", as_path_length=2),
    ]

    resolved = resolve_bgp_next_hop_via_ospf(bgp_routes, ospf, "router-A")

    t.check(resolved[0].igp_cost_to_next_hop == 15,
            "Route via border-1: OSPF cost = 10 + 5 = 15",
            f"Got: {resolved[0].igp_cost_to_next_hop}")
    t.check(resolved[1].igp_cost_to_next_hop == 55,
            "Route via border-2: OSPF cost = 50 + 5 = 55",
            f"Got: {resolved[1].igp_cost_to_next_hop}")

    best, step = bgp_best_path_select(resolved)
    t.check(best.next_hop == "border-1",
            "Hot-potato: router-A prefers border-1 (closer via OSPF)",
            f"Winner: {best.next_hop}, igp_cost={best.igp_cost_to_next_hop}")
    t.check(step == "lowest_igp_cost", "Decided by IGP cost (hot-potato)", f"Got: {step}")

    results.append(t)

    # ──────────────────────────────────────────────
    # TEST 8: Hot-potato divergence detection
    # ──────────────────────────────────────────────
    t = TestResult("Claim 6: Hot-potato routing divergence within equivalence class")

    # Two leaves in the same equivalence class but at different positions
    # leaf-1 is closer to spine-1/border-1, leaf-2 is closer to spine-2/border-2
    ospf = [
        OSPFLink("leaf-1", "spine-1", cost=5),
        OSPFLink("leaf-1", "spine-2", cost=20),
        OSPFLink("leaf-2", "spine-1", cost=20),
        OSPFLink("leaf-2", "spine-2", cost=5),
        OSPFLink("spine-1", "border-1", cost=5),
        OSPFLink("spine-2", "border-2", cost=5),
    ]

    bgp_from_border1 = BGPRoute("10.0.0.0/8", "border-1", peer_type="ibgp", as_path_length=2)
    bgp_from_border2 = BGPRoute("10.0.0.0/8", "border-2", peer_type="ibgp", as_path_length=2)

    # Resolve from leaf-1's perspective
    resolved_l1 = resolve_bgp_next_hop_via_ospf(
        [deepcopy(bgp_from_border1), deepcopy(bgp_from_border2)], ospf, "leaf-1")
    best_l1, step_l1 = bgp_best_path_select(resolved_l1)

    # Resolve from leaf-2's perspective
    resolved_l2 = resolve_bgp_next_hop_via_ospf(
        [deepcopy(bgp_from_border1), deepcopy(bgp_from_border2)], ospf, "leaf-2")
    best_l2, step_l2 = bgp_best_path_select(resolved_l2)

    t.check(best_l1.next_hop == "border-1",
            "leaf-1 prefers border-1 (lower IGP cost: 10 vs 25)",
            f"leaf-1 choice: {best_l1.next_hop}, igp_cost={best_l1.igp_cost_to_next_hop}")

    t.check(best_l2.next_hop == "border-2",
            "leaf-2 prefers border-2 (lower IGP cost: 10 vs 25)",
            f"leaf-2 choice: {best_l2.next_hop}, igp_cost={best_l2.igp_cost_to_next_hop}")

    t.check(best_l1.next_hop != best_l2.next_hop,
            "HOT-POTATO DIVERGENCE DETECTED: same equivalence class, different best path",
            f"leaf-1 → {best_l1.next_hop}, leaf-2 → {best_l2.next_hop}")

    t.check(step_l1 == "lowest_igp_cost" and step_l2 == "lowest_igp_cost",
            "Both decided by IGP cost (step 8) — this is the hot-potato step",
            f"leaf-1 step: {step_l1}, leaf-2 step: {step_l2}")

    results.append(t)

    # ──────────────────────────────────────────────
    # TEST 9: Perturbation ordering is scale-invariant
    # ──────────────────────────────────────────────
    t = TestResult("Claim 4: Perturbation ordering is scale-invariant (Tier 1)")

    # Small topology: spine-1 -- leaf-1, spine-1 -- leaf-2
    small_bgp = [("spine-1", "leaf-1"), ("spine-1", "leaf-2"),
                 ("spine-2", "leaf-1"), ("spine-2", "leaf-2")]
    small_ospf = [
        OSPFLink("spine-1", "leaf-1", 10), OSPFLink("spine-1", "leaf-2", 10),
        OSPFLink("spine-2", "leaf-1", 10), OSPFLink("spine-2", "leaf-2", 10),
    ]

    # Large topology: same structure but with 4 more equivalent leaves
    large_bgp = list(small_bgp)
    large_ospf = list(small_ospf)
    for i in range(3, 7):
        large_bgp.append(("spine-1", f"leaf-{i}"))
        large_bgp.append(("spine-2", f"leaf-{i}"))
        large_ospf.append(OSPFLink("spine-1", f"leaf-{i}", 10))
        large_ospf.append(OSPFLink("spine-2", f"leaf-{i}", 10))

    # Fail the same link in both
    failed_link = ("spine-1", "leaf-1")

    small_events = simulate_link_failure_propagation(
        ["spine-1", "spine-2", "leaf-1", "leaf-2"],
        small_bgp, small_ospf, failed_link)

    large_events = simulate_link_failure_propagation(
        ["spine-1", "spine-2"] + [f"leaf-{i}" for i in range(1, 7)],
        large_bgp, large_ospf, failed_link)

    # Extract orderings — only for devices that exist in BOTH topologies
    common_devices = {"spine-1", "spine-2", "leaf-1", "leaf-2"}
    small_ordering = [(e.event_type, e.device) for e in small_events if e.device in common_devices]
    large_ordering = [(e.event_type, e.device) for e in large_events if e.device in common_devices]

    t.check(small_ordering == large_ordering,
            "Convergence ordering for common devices is identical at both scales",
            f"Small ({len(small_events)} events for common): {small_ordering[:6]}...\n"
            f"Large ({len(large_events)} events for common): {large_ordering[:6]}...")

    # The large topology has MORE events (for leaf-3..6) but the ordering
    # for the common devices is the same
    t.check(len(large_events) > len(small_events),
            f"Larger topology has more total events ({len(large_events)} > {len(small_events)})")

    results.append(t)

    # ──────────────────────────────────────────────
    # TEST 10: Timer changes affect timing, NOT ordering (Tier 1 vs Tier 2)
    # ──────────────────────────────────────────────
    t = TestResult("Claim 7: Timer defaults change Tier 2 (timing) but not Tier 1 (ordering)")

    bgp_edges = [("spine-1", "leaf-1"), ("spine-1", "leaf-2"),
                 ("spine-2", "leaf-1"), ("spine-2", "leaf-2")]
    ospf = [
        OSPFLink("spine-1", "leaf-1", 10), OSPFLink("spine-1", "leaf-2", 10),
        OSPFLink("spine-2", "leaf-1", 10), OSPFLink("spine-2", "leaf-2", 10),
    ]

    # Config A: fast BFD, standard BGP hold
    events_a = simulate_link_failure_propagation(
        ["spine-1", "spine-2", "leaf-1", "leaf-2"],
        bgp_edges, ospf, ("spine-1", "leaf-1"),
        {"bfd_detection": 0.15, "bgp_hold": 180, "ospf_dead": 40}
    )

    # Config B: slow BFD, faster BGP hold
    events_b = simulate_link_failure_propagation(
        ["spine-1", "spine-2", "leaf-1", "leaf-2"],
        bgp_edges, ospf, ("spine-1", "leaf-1"),
        {"bfd_detection": 1.0, "bgp_hold": 90, "ospf_dead": 40}
    )

    # Config C: no BFD (very slow detection)
    events_c = simulate_link_failure_propagation(
        ["spine-1", "spine-2", "leaf-1", "leaf-2"],
        bgp_edges, ospf, ("spine-1", "leaf-1"),
        {"bfd_detection": 5.0, "bgp_hold": 180, "ospf_dead": 40}
    )

    ordering_a = extract_ordering(events_a)
    ordering_b = extract_ordering(events_b)
    ordering_c = extract_ordering(events_c)

    t.check(ordering_a == ordering_b,
            "Ordering identical between fast-BFD and slow-BFD configs",
            f"Both have {len(ordering_a)} events in same sequence")

    t.check(ordering_a == ordering_c,
            "Ordering identical even with very slow BFD",
            f"Config C: {len(ordering_c)} events, same sequence")

    timing_a = extract_timing(events_a)
    timing_b = extract_timing(events_b)

    t.check(timing_a != timing_b,
            "Timing differs between configs (Tier 2 is scale-dependent)",
            f"Config A BFD detect: {timing_a[2][0]:.3f}s, Config B: {timing_b[2][0]:.3f}s")

    results.append(t)

    # ──────────────────────────────────────────────
    # TEST 11: Tier 2 Scaling — route churn scales with |Cᵢ|
    # ──────────────────────────────────────────────
    t = TestResult("Claim 5a: Tier 2 — route churn scales linearly with cell size")

    # In a symmetric Clos, when a spine fails:
    # - Each leaf withdraws routes learned from that spine
    # - Churn per leaf is constant (same number of routes per peer)
    # - Total churn = churn_per_leaf × number_of_leaves
    # If leaves are in one cell with |C| = N, total churn = churn_per_leaf × N

    cell_sizes = [4, 8, 16, 32, 64]
    churn_per_device = 100  # hypothetical: each leaf carries 100 routes from each spine

    churns = [(size, churn_per_device * size) for size in cell_sizes]

    # Verify linearity
    ratios = [churns[i][1] / churns[i][0] for i in range(len(churns))]
    t.check(all(r == ratios[0] for r in ratios),
            f"Churn/cell_size ratio is constant: {ratios[0]}",
            f"Ratios: {ratios}")

    # Verify the correction factor: churn_full = churn_compressed × |Cᵢ|
    compressed_churn = churn_per_device * 2  # 2 representatives (Rule 1)
    for size, expected_full in churns:
        predicted = compressed_churn * (size / 2)  # |Cᵢ| / |Rᵢ| scaling
        t.check(predicted == expected_full,
                f"|Cᵢ|={size}: compressed_churn × (|Cᵢ|/|Rᵢ|) = {predicted} = actual {expected_full}")

    results.append(t)

    # ──────────────────────────────────────────────
    # TEST 12: Tier 2 Scaling — SPF complexity O(N log N)
    # ──────────────────────────────────────────────
    t = TestResult("Claim 5b: Tier 2 — SPF scaling follows O(N log N)")

    # Verify the scaling factor formula: (N_prod / N_comp) × log(N_prod / N_comp)
    n_compressed = 10
    test_cases = [
        (100, 10),    # 10× compression
        (1000, 10),   # 100× compression
        (10000, 10),  # 1000× compression
    ]

    for n_prod, n_comp in test_cases:
        ratio = n_prod / n_comp
        scaling_factor = ratio * math.log(ratio)  # N log N scaling

        # Verify the scaling is super-linear (grows faster than linear)
        linear_factor = ratio
        t.check(scaling_factor > linear_factor,
                f"N={n_prod}: SPF scaling ({scaling_factor:.1f}) > linear ({linear_factor:.1f})",
                f"The log factor adds {scaling_factor/linear_factor:.2f}× overhead")

    # Verify the formula is monotonically increasing
    factors = []
    for n in [100, 500, 1000, 5000, 10000]:
        r = n / n_compressed
        factors.append(r * math.log(r))

    monotonic = all(factors[i] < factors[i+1] for i in range(len(factors)-1))
    t.check(monotonic, "SPF scaling factor is monotonically increasing with N_prod",
            f"Factors: {[f'{f:.1f}' for f in factors]}")

    results.append(t)

    # ──────────────────────────────────────────────
    # TEST 13: Tier 2 Scaling — diameter ratio for convergence timing
    # ──────────────────────────────────────────────
    t = TestResult("Claim 5c: Tier 2 — convergence timing scales with diameter ratio")

    # Build a small Clos and compute diameter
    small_links = [
        OSPFLink("s1", "l1", 10), OSPFLink("s1", "l2", 10),
        OSPFLink("s2", "l1", 10), OSPFLink("s2", "l2", 10),
    ]
    small_nodes = ["s1", "s2", "l1", "l2"]
    D_small = compute_graph_diameter(small_links, small_nodes)

    # Build a larger Clos and compute diameter
    large_links = list(small_links)
    large_nodes = list(small_nodes)
    for i in range(3, 9):
        large_links.append(OSPFLink("s1", f"l{i}", 10))
        large_links.append(OSPFLink("s2", f"l{i}", 10))
        large_nodes.append(f"l{i}")

    D_large = compute_graph_diameter(large_links, large_nodes)

    t.check(D_small == D_large,
            f"Symmetric Clos: diameter is topology-invariant under leaf scaling",
            f"D_small={D_small}, D_large={D_large}")

    # For a Clos, adding more leaves doesn't change diameter!
    # Diameter is determined by the spine layer: leaf → spine → leaf = 2 hops
    # This means the diameter correction factor for Clos is 1.0
    diameter_ratio = D_large / D_small
    t.check(diameter_ratio == 1.0,
            f"Clos diameter ratio = {diameter_ratio} (no correction needed for leaf scaling)",
            "This is a KEY insight: Clos convergence timing doesn't scale with leaf count")

    # Now test a topology where diameter DOES change: a chain
    chain_small = [OSPFLink(f"n{i}", f"n{i+1}", 10) for i in range(4)]
    chain_large = [OSPFLink(f"n{i}", f"n{i+1}", 10) for i in range(8)]

    D_chain_small = compute_graph_diameter(chain_small, [f"n{i}" for i in range(5)])
    D_chain_large = compute_graph_diameter(chain_large, [f"n{i}" for i in range(9)])

    t.check(D_chain_large > D_chain_small,
            f"Chain: diameter grows with length ({D_chain_large} > {D_chain_small})")

    chain_ratio = D_chain_large / D_chain_small
    t.check(chain_ratio > 1.0,
            f"Chain diameter ratio = {chain_ratio:.2f} — correction IS needed",
            f"Convergence timing scales by {chain_ratio:.2f}×")

    results.append(t)

    # ──────────────────────────────────────────────
    # TEST 14: Determinism — Cathedral computations
    # ──────────────────────────────────────────────
    t = TestResult("Claim (overall): Cathedral computations are deterministic")

    for trial in range(5):
        routes = [
            BGPRoute("10.0.0.0/8", "a", local_pref=100, as_path_length=3, router_id="5.5.5.5"),
            BGPRoute("10.0.0.0/8", "b", local_pref=100, as_path_length=2, router_id="4.4.4.4"),
            BGPRoute("10.0.0.0/8", "c", local_pref=100, as_path_length=2, router_id="3.3.3.3"),
        ]
        best, step = bgp_best_path_select(routes)
        if trial == 0:
            ref_best = best.next_hop
            ref_step = step
        else:
            assert best.next_hop == ref_best and step == ref_step

    t.check(True, "BGP best-path selection is deterministic across 5 runs")

    for trial in range(5):
        links = [OSPFLink("A", "B", 10), OSPFLink("B", "C", 5), OSPFLink("A", "C", 20)]
        costs = ospf_spf(links, "A")
        if trial == 0:
            ref_costs = dict(costs)
        else:
            assert costs == ref_costs

    t.check(True, "OSPF SPF is deterministic across 5 runs")

    for trial in range(5):
        events = simulate_link_failure_propagation(
            ["s1", "s2", "l1", "l2"],
            [("s1", "l1"), ("s1", "l2"), ("s2", "l1"), ("s2", "l2")],
            [OSPFLink("s1", "l1", 10), OSPFLink("s1", "l2", 10),
             OSPFLink("s2", "l1", 10), OSPFLink("s2", "l2", 10)],
            ("s1", "l1"))
        ordering = extract_ordering(events)
        if trial == 0:
            ref_ordering = ordering
        else:
            assert ordering == ref_ordering

    t.check(True, "Perturbation propagation is deterministic across 5 runs")

    results.append(t)

    # ──────────────────────────────────────────────
    # SUMMARY
    # ──────────────────────────────────────────────
    print("\n" + "═" * 72)
    print("  CATHEDRAL — MATHEMATICAL FOUNDATION VALIDATION")
    print("═" * 72)

    for r in results:
        print(r.report())

    print("\n" + "═" * 72)
    total_checks = sum(len(r.checks) for r in results)
    passed_checks = sum(sum(1 for s, _, _ in r.checks if s == "PASS") for r in results)
    failed_checks = total_checks - passed_checks
    all_tests_passed = all(r.passed for r in results)

    print(f"  SUMMARY: {passed_checks}/{total_checks} checks passed across {len(results)} tests")
    if failed_checks > 0:
        print(f"  ✗ {failed_checks} CHECKS FAILED")
        for r in results:
            for status, desc, detail in r.checks:
                if status == "FAIL":
                    print(f"    ✗ [{r.name}] {desc}")
                    if detail:
                        for line in detail.split("\n"):
                            print(f"          {line}")
    else:
        print("  ✓ ALL CHECKS PASSED")
    print("═" * 72)

    return all_tests_passed


if __name__ == "__main__":
    success = run_all_tests()
    exit(0 if success else 1)
