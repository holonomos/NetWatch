"""Stage 2 Predicate Registry — 97 predicates for Batfish evaluation.

Each predicate has a unique ID, tier assignment, category, and the
Batfish queries required to evaluate it. The evaluation logic is
implemented in evaluator.py; this module is the catalog.

Ref: State Space Stage 2.md v4.3
Ref: State Space Stage 4.md v4.3 (tier assignments)
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Any


class Category(Enum):
    """Predicate category from Stage 2."""
    FF = "full_fidelity"
    VD = "vendor_divergence"
    PM = "proprietary_mapping"
    TE = "topology_edge_case"
    PI = "protocol_interaction"
    LE = "legacy_environment"
    CV = "cross_validation"
    DEF = "deferred"


@dataclass(frozen=True)
class PredicateSpec:
    """Specification for a single Stage 2 predicate.

    Attributes:
        predicate_id: Unique ID (e.g., "FF-1.1.01")
        name: Human-readable name
        category: Predicate category
        tier: Stage 4 tier assignment (0-3)
        batfish_queries: List of pybatfish query method names
        stage1_trace: Reference to Stage 1 section
        description: Brief description of what is being validated
    """
    predicate_id: str
    name: str
    category: Category
    tier: int
    batfish_queries: tuple[str, ...]
    stage1_trace: str = ""
    description: str = ""


# ═══════════════════════════════════════════════════════════════════════
# TIER 0 — Structural Graph Predicates (7)
# Compression Engine graph construction + partition cross-validation
# R = RED (pipeline halt)
# ═══════════════════════════════════════════════════════════════════════

TIER_0: tuple[PredicateSpec, ...] = (
    PredicateSpec(
        predicate_id="FF-1.1.01",
        name="BGP Finite State Machine",
        category=Category.FF, tier=0,
        batfish_queries=("bgpPeerConfiguration", "bgpSessionStatus", "bgpSessionCompatibility", "bgpEdges"),
        stage1_trace="§1.1 row 1",
        description="BGP edge set + session status. Structural input to compressed graph.",
    ),
    PredicateSpec(
        predicate_id="FF-1.1.02",
        name="OSPF Neighbor Finite State Machine",
        category=Category.FF, tier=0,
        batfish_queries=("ospfEdges", "ospfSessionCompatibility", "ospfProcessConfiguration", "ospfInterfaceConfiguration"),
        stage1_trace="§1.1 row 2",
        description="OSPF adjacency set. Structural input to compressed graph.",
    ),
    PredicateSpec(
        predicate_id="FF-1.1.08",
        name="LLDP Discovery",
        category=Category.FF, tier=0,
        batfish_queries=("layer1Edges", "layer3Edges"),
        stage1_trace="§1.1 row 8",
        description="Physical and logical topology. G = (V, E) construction.",
    ),
    PredicateSpec(
        predicate_id="FF-1.2.01",
        name="BGP Best-Path Selection Algorithm",
        category=Category.FF, tier=0,
        batfish_queries=("bgpRib", "bgpProcessConfiguration"),
        stage1_trace="§1.2 row 1",
        description="RIB data for partition cross-validation.",
    ),
    PredicateSpec(
        predicate_id="FF-1.2.02",
        name="Dijkstra / SPF Algorithm",
        category=Category.FF, tier=0,
        batfish_queries=("routes",),
        stage1_trace="§1.2 row 2",
        description="OSPF route metrics for IGP cost consistency within equivalence classes.",
    ),
    PredicateSpec(
        predicate_id="PM-2.3.01",
        name="vPC/MLAG → EVPN Multihoming Mapping",
        category=Category.PM, tier=0,
        batfish_queries=("mlagProperties",),
        stage1_trace="§2.3",
        description="MLAG detection for dual-homing topology inference.",
    ),
    PredicateSpec(
        predicate_id="CV-4.5.01",
        name="BGP Next-Hop Resolves via IGP",
        category=Category.CV, tier=0,
        batfish_queries=("bgpRib", "routes"),
        stage1_trace="§4.5",
        description="Overlay/underlay consistency. Graph-level integrity check.",
    ),
)

# ═══════════════════════════════════════════════════════════════════════
# TIER 1 — Behavioral Signature Predicates (26)
# Compression Engine σ(v) computation + extraction gate
# R = force singleton, K = field exclusion
# ═══════════════════════════════════════════════════════════════════════

TIER_1: tuple[PredicateSpec, ...] = (
    PredicateSpec("FF-1.1.03", "OSPF Interface FSM", Category.FF, 1,
                  ("ospfInterfaceConfiguration",), "§1.1 row 3",
                  "OSPF interface types in σ(v)."),
    PredicateSpec("FF-1.1.04", "BFD Finite State Machine", Category.FF, 1,
                  ("namedStructures",), "§1.1 row 4",
                  "BFD enablement in σ(v). Intervals excluded."),
    PredicateSpec("FF-1.1.07", "LACP Finite State Machine", Category.FF, 1,
                  ("interfaceProperties",), "§1.1 row 7",
                  "Port-channel structure for V_inf compression."),
    PredicateSpec("FF-1.2.03", "Route Redistribution and AD", Category.FF, 1,
                  ("routes",), "§1.2 row 3",
                  "Static route AD in σ(v)."),
    PredicateSpec("FF-1.3.01", "Route-Map Evaluation", Category.FF, 1,
                  ("namedStructures",), "§1.3 row 1",
                  "Route-map content — primary σ(v) dimension."),
    PredicateSpec("FF-1.3.02", "Prefix-List Matching", Category.FF, 1,
                  ("namedStructures",), "§1.3 row 2",
                  "Prefix-list content in σ(v)."),
    PredicateSpec("FF-1.3.03", "Community Handling", Category.FF, 1,
                  ("namedStructures", "bgpRib"), "§1.3 row 3",
                  "Community-list content in σ(v)."),
    PredicateSpec("FF-1.3.04", "AS-Path Manipulation", Category.FF, 1,
                  ("namedStructures", "bgpRib"), "§1.3 row 4",
                  "AS-path ACL content in σ(v)."),
    PredicateSpec("FF-1.3.05", "Administrative Distance", Category.FF, 1,
                  ("routes",), "§1.3 row 5",
                  "AD as part of route selection behavior."),
    PredicateSpec("FF-1.3.06", "Route Redistribution Between Protocols", Category.FF, 1,
                  ("namedStructures", "routes"), "§1.3 row 6",
                  "Redistribution config in σ(v)."),
    PredicateSpec("FF-1.3.07", "Route Summarization", Category.FF, 1,
                  ("namedStructures", "bgpRib"), "§1.3 row 7",
                  "BGP aggregation config in σ(v)."),
    PredicateSpec("FF-1.3.08", "Default Route Origination", Category.FF, 1,
                  ("namedStructures", "routes"), "§1.3 row 8",
                  "Default origination policy in σ(v)."),
    PredicateSpec("FF-1.3.09", "Route-Target Import/Export", Category.FF, 1,
                  ("vxlanVniProperties", "namedStructures", "evpnRib"), "§1.3 row 9",
                  "VRF config structure in σ(v)."),
    PredicateSpec("FF-1.3.10", "ACL / Firewall Rule Evaluation", Category.FF, 1,
                  ("namedStructures", "filterLineReachability"), "§1.3 row 10",
                  "ACL content on server-facing interfaces in σ(v)."),
    PredicateSpec("FF-1.3.11", "maximum-prefix", Category.FF, 1,
                  ("bgpPeerConfiguration", "namedStructures"), "§1.3 row 11",
                  "maximum-prefix config — scale-dependent policy."),
    PredicateSpec("FF-1.7.01", "CLI/API Configuration Parsing", Category.FF, 1,
                  ("fileParseStatus",), "§1.7 row 1",
                  "Extraction gate — parse status determines σ(v) entry."),
    PredicateSpec("FF-1.7.02", "Reference Integrity", Category.FF, 1,
                  ("undefinedReferences", "unusedStructures"), "§1.7 row 2",
                  "Undefined references change effective σ(v)."),
    PredicateSpec("FF-1.7.03", "VRF Isolation and Route Leaking Config", Category.FF, 1,
                  ("nodeProperties", "routes", "namedStructures"), "§1.7 row 3",
                  "VRF config structure in σ(v)."),
    PredicateSpec("FF-1.9.02", "OSPF Dead Interval", Category.FF, 1,
                  ("ospfInterfaceConfiguration",), "§1.9 row 2",
                  "OSPF hello/dead timers in σ(v)."),
    PredicateSpec("FF-1.9.03", "BGP Hold Time Negotiation", Category.FF, 1,
                  ("namedStructures",), "§1.9 row 3",
                  "BGP keepalive/hold timers in σ(v). MRAI excluded."),
    PredicateSpec("VD-2.1.02", "Parser Behavior Edge Cases", Category.VD, 1,
                  ("parseWarning",), "§2.1 row 2",
                  "Parse warnings trigger signature robustness rule."),
    PredicateSpec("VD-2.1.03", "Best-Path Tiebreaking Extensions", Category.VD, 1,
                  ("bgpProcessConfiguration",), "§2.1 row 3",
                  "Tiebreaking flags in BGP process config."),
    PredicateSpec("TE-3.3.01", "IGP Cost Asymmetry Within Equivalence Class", Category.TE, 1,
                  ("routes",), "§3.3 row 1",
                  "Gap 4 detection — IGP cost asymmetry."),
    PredicateSpec("TE-3.3.03", "Route Reflector Topology Sensitivity", Category.TE, 1,
                  ("bgpPeerConfiguration", "bgpProcessConfiguration"), "§3.3 row 3",
                  "RR-client designation in σ(v)."),
    PredicateSpec("CV-4.5.04", "Route-Map References Resolve", Category.CV, 1,
                  ("undefinedReferences",), "§4.5 row 4",
                  "Undefined route-maps change effective σ(v)."),
    PredicateSpec("CV-4.5.05", "ACLs Applied to Interfaces Exist", Category.CV, 1,
                  ("namedStructures",), "§4.5 row 5",
                  "Undefined ACLs change forwarding behavior."),
)

# ═══════════════════════════════════════════════════════════════════════
# TIER 2 — Analytical Prediction Predicates (48)
# Cathedral / Mirror Box inputs
# R = analytical degradation, K = no impact
# ═══════════════════════════════════════════════════════════════════════

TIER_2: tuple[PredicateSpec, ...] = (
    PredicateSpec("FF-1.1.05", "STP FSM", Category.FF, 2,
                  ("namedStructures",), "§1.1 row 5", "Cathedral STP analysis."),
    PredicateSpec("FF-1.1.06", "RSTP FSM", Category.FF, 2,
                  ("namedStructures",), "§1.1 row 6", "Cathedral RSTP analysis."),
    PredicateSpec("FF-1.1.09", "Graceful Restart (BGP/OSPF)", Category.FF, 2,
                  ("bgpPeerConfiguration", "ospfProcessConfiguration"), "§1.1 row 9",
                  "GR behavior modeling."),
    PredicateSpec("FF-1.4.01", "BGP Message Encoding", Category.FF, 2,
                  ("bgpPeerConfiguration",), "§1.4 row 1", "Cathedral signaling model."),
    PredicateSpec("FF-1.4.02", "OSPF LSA Types", Category.FF, 2,
                  ("ospfProcessConfiguration",), "§1.4 row 2", "Cathedral OSPF LSA model."),
    PredicateSpec("FF-1.4.03", "EVPN Route Types", Category.FF, 2,
                  ("evpnRib",), "§1.4 row 3", "Cathedral EVPN overlay model."),
    PredicateSpec("FF-1.4.04", "VXLAN Encap/Decap", Category.FF, 2,
                  ("vxlanVniProperties",), "§1.4 row 4", "Cathedral VXLAN tunnel analysis."),
    PredicateSpec("FF-1.4.05", "Adjacency and Session Management", Category.FF, 2,
                  ("bgpSessionStatus", "ospfEdges"), "§1.4 row 5",
                  "Composite — Cathedral session mgmt."),
    PredicateSpec("FF-1.4.06", "Protocol Capability Negotiation", Category.FF, 2,
                  ("bgpPeerConfiguration",), "§1.4 row 6", "Cathedral capability analysis."),
    PredicateSpec("FF-1.5.01", "BFD-Triggered Failover Chain", Category.FF, 2,
                  ("namedStructures", "bgpPeerConfiguration"), "§1.5 row 1",
                  "Cathedral failover chain modeling."),
    PredicateSpec("FF-1.5.02", "Convergence Sequencing", Category.FF, 2,
                  ("routes", "bgpRib"), "§1.5 row 2",
                  "Cathedral convergence prediction."),
    PredicateSpec("FF-1.5.03", "Multi-Failure Blast Radius", Category.FF, 2,
                  ("routes",), "§1.5 row 3",
                  "Cathedral cascade analysis (Tier 4)."),
    PredicateSpec("FF-1.5.04", "Next-Hop Tracking", Category.FF, 2,
                  ("routes", "bgpRib"), "§1.5 row 4",
                  "Cathedral NHT model."),
    PredicateSpec("FF-1.5.05", "Graceful Restart Behavior", Category.FF, 2,
                  ("bgpPeerConfiguration",), "§1.5 row 5",
                  "Cathedral/Mirror Box GR modeling."),
    PredicateSpec("FF-1.6.01", "ECMP Path Count", Category.FF, 2,
                  ("routes",), "§1.6 row 1", "Cathedral ECMP enumeration."),
    PredicateSpec("FF-1.6.02", "Bisection Bandwidth Ratio", Category.FF, 2,
                  ("layer3Edges",), "§1.6 row 2", "Cathedral graph property."),
    PredicateSpec("FF-1.6.03", "Hop Count", Category.FF, 2,
                  ("routes",), "§1.6 row 3", "Cathedral graph property."),
    PredicateSpec("FF-1.6.04", "k-Connectivity", Category.FF, 2,
                  ("layer3Edges",), "§1.6 row 4", "Cathedral graph property."),
    PredicateSpec("FF-1.6.05", "Diameter", Category.FF, 2,
                  ("layer3Edges",), "§1.6 row 5", "Cathedral graph property."),
    PredicateSpec("FF-1.6.06", "Symmetry", Category.FF, 2,
                  ("layer3Edges",), "§1.6 row 6", "Cathedral graph property."),
    PredicateSpec("FF-1.9.01", "BFD Detection Time Formula", Category.FF, 2,
                  ("namedStructures",), "§1.9 row 1",
                  "Cathedral BFD timing model. Intervals excluded from σ."),
    PredicateSpec("VD-2.1.01", "Default Timer Values", Category.VD, 2,
                  ("bgpProcessConfiguration", "ospfProcessConfiguration"), "§2.1 row 1",
                  "Cathedral timer divergence analysis."),
    PredicateSpec("VD-2.1.04", "OSPF Implementation Quirks", Category.VD, 2,
                  ("ospfProcessConfiguration",), "§2.1 row 4",
                  "Cathedral SPF throttle modeling."),
    PredicateSpec("VD-2.1.05", "BGP Attribute Handling Edge Cases", Category.VD, 2,
                  ("bgpProcessConfiguration",), "§2.1 row 5",
                  "Cathedral attribute handling."),
    PredicateSpec("VD-2.1.06", "Graceful Restart Implementation", Category.VD, 2,
                  ("bgpPeerConfiguration",), "§2.1 row 6",
                  "Cathedral/Mirror Box GR vendor edge cases."),
    PredicateSpec("TE-3.3.02", "DR/BDR Election on Broadcast Segments", Category.TE, 2,
                  ("ospfInterfaceConfiguration",), "§3.3 row 2",
                  "Cathedral DR election modeling."),
    PredicateSpec("TE-3.3.04", "Confederation Boundary", Category.TE, 2,
                  ("bgpProcessConfiguration",), "§3.3 row 4",
                  "Cathedral confederation analysis."),
    PredicateSpec("TE-3.3.05", "Asymmetric Policy Detection", Category.TE, 2,
                  ("namedStructures",), "§3.3 row 5",
                  "Cathedral asymmetric policy analysis."),
    PredicateSpec("TE-3.3.06", "Multi-Area OSPF (ABR/ASBR)", Category.TE, 2,
                  ("ospfProcessConfiguration", "ospfInterfaceConfiguration"), "§3.3 row 6",
                  "Cathedral multi-area analysis."),
    PredicateSpec("TE-3.3.07", "VRF Route Leaking Loop Detection", Category.TE, 2,
                  ("namedStructures", "routes"), "§3.3 row 7",
                  "Cathedral route-leaking loop detection."),
    PredicateSpec("TE-3.3.08", "STP Root Bridge Placement", Category.TE, 2,
                  ("namedStructures",), "§3.3 row 8",
                  "Cathedral STP root analysis."),
    PredicateSpec("PI-4.2.01", "IGP-BGP Next-Hop Resolution Race", Category.PI, 2,
                  ("routes", "bgpRib"), "§4.2 row 1",
                  "Cathedral convergence race analysis."),
    PredicateSpec("PI-4.2.02", "BFD-BGP-OSPF Detection Hierarchy", Category.PI, 2,
                  ("namedStructures", "bgpPeerConfiguration"), "§4.2 row 2",
                  "Cathedral detection hierarchy."),
    PredicateSpec("PI-4.2.03", "EVPN Type-2/Type-5 Route Interaction", Category.PI, 2,
                  ("evpnRib",), "§4.2 row 3",
                  "Cathedral overlay model."),
    PredicateSpec("PI-4.2.04", "VRF RT Interaction", Category.PI, 2,
                  ("namedStructures", "routes"), "§4.2 row 4",
                  "Cathedral VRF analysis."),
    PredicateSpec("PI-4.2.05", "Redistribution Loop Detection", Category.PI, 2,
                  ("namedStructures", "routes"), "§4.2 row 5",
                  "Cathedral redistribution loop detection."),
    PredicateSpec("PI-4.2.06", "GR+BFD Conflict", Category.PI, 2,
                  ("bgpPeerConfiguration", "namedStructures"), "§4.2 row 6",
                  "Cathedral/Mirror Box GR+BFD analysis."),
    PredicateSpec("PI-4.2.07", "ECMP+Route-Map Interaction", Category.PI, 2,
                  ("routes", "namedStructures"), "§4.2 row 7",
                  "Cathedral ECMP+policy interaction."),
    PredicateSpec("LE-4.4.01", "L2-Heavy Networks with STP", Category.LE, 2,
                  ("namedStructures",), "§4.4 row 1",
                  "Cathedral L2 analysis. Singletons by default."),
    PredicateSpec("LE-4.4.02", "Mixed L2/L3 Boundary", Category.LE, 2,
                  ("interfaceProperties", "namedStructures"), "§4.4 row 2",
                  "Cathedral SVI/trunk boundary."),
    PredicateSpec("LE-4.4.03", "NAT at Enterprise Edge", Category.LE, 2,
                  ("namedStructures",), "§4.4 row 3",
                  "Cathedral NAT modeling. Singletons by default."),
    PredicateSpec("LE-4.4.04", "Legacy Timer Configurations", Category.LE, 2,
                  ("bgpProcessConfiguration", "ospfProcessConfiguration"), "§4.4 row 4",
                  "Cathedral timer model."),
    PredicateSpec("LE-4.4.05", "Dual-Stack IPv4/IPv6", Category.LE, 2,
                  ("interfaceProperties", "bgpPeerConfiguration"), "§4.4 row 5",
                  "Cathedral dual-stack analysis."),
    PredicateSpec("LE-4.4.06", "Out-of-Band Management Networks", Category.LE, 2,
                  ("nodeProperties",), "§4.4 row 6",
                  "Cathedral OOB analysis."),
    PredicateSpec("LE-4.4.07", "Stateful Firewalls in Routing Path", Category.LE, 2,
                  ("namedStructures", "interfaceProperties"), "§4.4 row 7",
                  "Cathedral firewall analysis. Singletons by default."),
    PredicateSpec("LE-4.4.08", "Load Balancers", Category.LE, 2,
                  ("f5BigipVipConfiguration",), "§4.4 row 8",
                  "Cathedral LB analysis. Singletons by default."),
    PredicateSpec("CV-4.5.02", "EVPN VTEP Reachability via Underlay", Category.CV, 2,
                  ("vxlanVniProperties", "routes"), "§4.5 row 2",
                  "Cathedral overlay integrity."),
    PredicateSpec("CV-4.5.03", "BFD Session Parameters Consistent", Category.CV, 2,
                  ("namedStructures", "bgpPeerConfiguration"), "§4.5 row 3",
                  "Cathedral timer consistency."),
)

# ═══════════════════════════════════════════════════════════════════════
# TIER 3 — Documentation Predicates (16)
# Certification report only. No disposition impact.
# ═══════════════════════════════════════════════════════════════════════

TIER_3: tuple[PredicateSpec, ...] = (
    PredicateSpec("FF-1.8.01", "DNS", Category.FF, 3, (), "§1.8 row 1", "Informational."),
    PredicateSpec("FF-1.8.02", "DHCP Relay", Category.FF, 3, (), "§1.8 row 2", "Informational."),
    PredicateSpec("FF-1.8.03", "NTP", Category.FF, 3, (), "§1.8 row 3", "Informational."),
    PredicateSpec("FF-1.8.04", "SNMP", Category.FF, 3, (), "§1.8 row 4", "Informational."),
    PredicateSpec("FF-1.8.05", "Syslog", Category.FF, 3, (), "§1.8 row 5", "Informational."),
    PredicateSpec("FF-1.8.06", "AAA", Category.FF, 3, (), "§1.8 row 6", "Informational."),
    PredicateSpec("DEF-01", "IS-IS", Category.DEF, 3, (), "", "Deferred — not in v1."),
    PredicateSpec("DEF-02", "PIM/Multicast", Category.DEF, 3, (), "", "Deferred."),
    PredicateSpec("DEF-03", "MPLS/LDP", Category.DEF, 3, (), "", "Deferred."),
    PredicateSpec("DEF-04", "MSDP", Category.DEF, 3, (), "", "Deferred."),
    PredicateSpec("DEF-05", "VRRP", Category.DEF, 3, (), "", "Deferred."),
    PredicateSpec("DEF-06", "SR-MPLS/SRv6/PCEP", Category.DEF, 3, (), "", "Deferred."),
    PredicateSpec("DEF-07", "BGP Flowspec", Category.DEF, 3, (), "", "Deferred."),
    PredicateSpec("DEF-08", "RPKI/ROA", Category.DEF, 3, (), "", "Deferred."),
    PredicateSpec("DEF-09", "RIP", Category.DEF, 3, (), "", "Deferred."),
    PredicateSpec("DEF-10", "BMP", Category.DEF, 3, (), "", "Deferred."),
)

# ═══════════════════════════════════════════════════════════════════════
# ALL PREDICATES — unified registry
# ═══════════════════════════════════════════════════════════════════════

ALL_PREDICATES: tuple[PredicateSpec, ...] = TIER_0 + TIER_1 + TIER_2 + TIER_3

# Lookup by ID
PREDICATE_BY_ID: dict[str, PredicateSpec] = {p.predicate_id: p for p in ALL_PREDICATES}

# Lookup by tier
PREDICATES_BY_TIER: dict[int, tuple[PredicateSpec, ...]] = {
    0: TIER_0,
    1: TIER_1,
    2: TIER_2,
    3: TIER_3,
}


def validate_registry() -> None:
    """Verify registry integrity. Call during tests."""
    # Count verification
    assert len(ALL_PREDICATES) == 97, f"Expected 97 predicates, got {len(ALL_PREDICATES)}"
    assert len(TIER_0) == 7, f"Expected 7 Tier 0, got {len(TIER_0)}"
    assert len(TIER_1) == 26, f"Expected 26 Tier 1, got {len(TIER_1)}"
    assert len(TIER_2) == 48, f"Expected 48 Tier 2, got {len(TIER_2)}"
    assert len(TIER_3) == 16, f"Expected 16 Tier 3, got {len(TIER_3)}"

    # ID uniqueness
    ids = [p.predicate_id for p in ALL_PREDICATES]
    assert len(ids) == len(set(ids)), f"Duplicate predicate IDs: {[i for i in ids if ids.count(i) > 1]}"

    # Every predicate has a tier
    for p in ALL_PREDICATES:
        assert p.tier in (0, 1, 2, 3), f"Invalid tier {p.tier} for {p.predicate_id}"
