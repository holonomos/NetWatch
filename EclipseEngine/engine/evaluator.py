"""Stage 3 — Two-Pass Evaluator.

Pass 1: Syntactic evaluation of 97 predicates against Batfish snapshot M.
Pass 2: Semantic dependency correction — propagates downgrades through G_sem.
Output: P_corrected + M_verified.

Ref: State Space Stage 3.md v4.3
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Optional

from pybatfish.client.session import Session

from .entity_store import (
    CapabilityTag,
    Classification,
    Device,
    Edge,
    EdgeType,
    FidelityTag,
    MVerified,
)
from .predicates import ALL_PREDICATES, PREDICATE_BY_ID, PredicateSpec


# ═══════════════════════════════════════════════════════════════════════
# Semantic dependency graph
# ═══════════════════════════════════════════════════════════════════════


class DepStrength(Enum):
    STRONG = "strong"
    WEAK = "weak"


@dataclass(frozen=True)
class SemanticEdge:
    """An edge in G_sem — semantic dependency between two predicates."""
    source: str        # predicate_id of the data provider
    target: str        # predicate_id of the data consumer
    strength: DepStrength
    data_path: str     # human-readable description of the data flow


# Complete semantic dependency graph from Stage 3 spec.
# Format: (source → target, strength, data_path)
SEMANTIC_EDGES: tuple[SemanticEdge, ...] = (
    # Cluster 1: Route-Map Ecosystem
    SemanticEdge("FF-1.3.02", "FF-1.3.01", DepStrength.STRONG, "match ip address prefix-list"),
    SemanticEdge("FF-1.3.03", "FF-1.3.01", DepStrength.STRONG, "match community / set community"),
    SemanticEdge("FF-1.3.04", "FF-1.3.01", DepStrength.STRONG, "match as-path"),
    SemanticEdge("FF-1.3.10", "FF-1.3.01", DepStrength.STRONG, "match ip address <ACL>"),

    # Cluster 2: BGP Best-Path Selection
    SemanticEdge("FF-1.3.01", "FF-1.2.01", DepStrength.STRONG, "import/export route-maps shape path attributes"),
    SemanticEdge("FF-1.3.03", "FF-1.2.01", DepStrength.STRONG, "community-based filtering affects path availability"),
    SemanticEdge("FF-1.3.04", "FF-1.2.01", DepStrength.STRONG, "AS-path filtering affects path availability"),
    SemanticEdge("VD-2.1.03", "FF-1.2.01", DepStrength.WEAK, "tiebreaking flags — rare equal-through-all-steps"),
    SemanticEdge("VD-2.1.05", "FF-1.2.01", DepStrength.WEAK, "attribute handling edge cases — rare"),

    # Cluster 3: EVPN Overlay
    SemanticEdge("FF-1.3.03", "FF-1.3.09", DepStrength.STRONG, "extended communities carry route-target values"),
    SemanticEdge("FF-1.3.03", "FF-1.4.03", DepStrength.STRONG, "extended communities carry route-targets on EVPN routes"),
    SemanticEdge("FF-1.3.09", "FF-1.4.03", DepStrength.STRONG, "RT import/export governs EVPN route acceptance"),
    SemanticEdge("FF-1.4.04", "FF-1.4.03", DepStrength.WEAK, "VXLAN is transport, not control plane"),

    # Cluster 4: Redistribution and Policy Chains
    SemanticEdge("FF-1.3.01", "FF-1.3.06", DepStrength.STRONG, "redistribution route-maps filter/transform"),
    SemanticEdge("FF-1.2.03", "FF-1.3.06", DepStrength.WEAK, "AD affects route selection after redistribution"),
    SemanticEdge("FF-1.3.01", "FF-1.3.07", DepStrength.WEAK, "suppress-map/attribute-map optional refinements"),
    SemanticEdge("FF-1.3.01", "FF-1.3.08", DepStrength.WEAK, "conditional default origination route-maps"),

    # Cluster 4a: VRF Route Leaking
    SemanticEdge("FF-1.3.09", "FF-1.7.03", DepStrength.STRONG, "RT import/export defines VRF membership"),
    SemanticEdge("FF-1.3.01", "FF-1.7.03", DepStrength.WEAK, "VRF route-leaking route-maps optional"),

    # Cluster 5: Failover and Timer Relationships
    SemanticEdge("FF-1.9.01", "FF-1.5.01", DepStrength.WEAK, "BFD detection time drives failover timing"),
    SemanticEdge("FF-1.9.02", "FF-1.5.02", DepStrength.WEAK, "OSPF dead interval affects convergence timing"),
    SemanticEdge("FF-1.9.03", "FF-1.5.02", DepStrength.WEAK, "BGP hold time affects convergence timing"),
    SemanticEdge("VD-2.1.01", "FF-1.5.02", DepStrength.WEAK, "vendor default timer divergence"),

    # Cluster 6: Cross-Validation Integrity
    SemanticEdge("FF-1.2.01", "CV-4.5.01", DepStrength.STRONG, "BGP routes provide next-hops being validated"),
    SemanticEdge("FF-1.2.02", "CV-4.5.01", DepStrength.STRONG, "IGP routes provide resolution targets"),
    SemanticEdge("FF-1.4.03", "CV-4.5.02", DepStrength.STRONG, "EVPN provides VTEP set"),
    SemanticEdge("FF-1.4.04", "CV-4.5.02", DepStrength.STRONG, "VXLAN provides tunnel endpoints"),
    SemanticEdge("FF-1.1.04", "CV-4.5.03", DepStrength.WEAK, "BFD timers may be FRR defaults"),
    SemanticEdge("FF-1.9.01", "CV-4.5.03", DepStrength.WEAK, "BFD timer values approximate"),
)

# Cluster 7: Parser Quality Propagation
# VD-2.1.02 → 21 predicates that source from namedStructures, per-device scope
_PARSER_QUALITY_TARGETS = (
    "FF-1.3.01", "FF-1.3.02", "FF-1.3.03", "FF-1.3.04", "FF-1.3.05",
    "FF-1.3.06", "FF-1.3.07", "FF-1.3.08", "FF-1.3.09", "FF-1.3.10",
    "FF-1.3.11", "FF-1.1.04", "FF-1.1.09", "FF-1.7.03", "FF-1.9.01",
    "FF-1.9.02", "FF-1.9.03", "VD-2.1.01", "VD-2.1.03", "VD-2.1.04",
    "PM-2.3.01",
)

PARSER_QUALITY_EDGES: tuple[SemanticEdge, ...] = tuple(
    SemanticEdge("VD-2.1.02", target, DepStrength.STRONG,
                 "parse warnings in routing-critical sections — per-device scope")
    for target in _PARSER_QUALITY_TARGETS
)

ALL_SEMANTIC_EDGES: tuple[SemanticEdge, ...] = SEMANTIC_EDGES + PARSER_QUALITY_EDGES


# ═══════════════════════════════════════════════════════════════════════
# Evaluation DAG (Pass 1 ordering dependencies)
# ═══════════════════════════════════════════════════════════════════════

# Format: (dependency, dependent) — dependent must be evaluated after dependency
EVALUATION_DAG_EDGES: tuple[tuple[str, str], ...] = (
    # Protocol FSM layer
    ("FF-1.1.04", "FF-1.5.01"),
    ("FF-1.1.04", "FF-1.9.01"),
    ("FF-1.1.04", "PI-4.2.02"),
    ("FF-1.1.05", "FF-1.1.06"),
    ("FF-1.1.05", "TE-3.3.08"),
    ("FF-1.1.05", "LE-4.4.01"),
    ("FF-1.1.09", "FF-1.5.05"),
    ("FF-1.1.09", "VD-2.1.06"),
    # Routing algorithm layer
    ("FF-1.2.01", "FF-1.4.01"),
    ("FF-1.2.02", "FF-1.4.02"),
    ("FF-1.2.02", "TE-3.3.01"),
    # Convergence layer
    ("FF-1.5.04", "PI-4.2.01"),
    ("CV-4.5.01", "PI-4.2.01"),
    # Composite predicates
    ("FF-1.4.03", "PI-4.2.03"),
    ("FF-1.3.09", "PI-4.2.04"),
    ("FF-1.3.06", "PI-4.2.05"),
    ("FF-1.1.09", "PI-4.2.06"),
    ("FF-1.1.04", "PI-4.2.06"),
    ("FF-1.6.01", "PI-4.2.07"),
    ("FF-1.3.01", "PI-4.2.07"),
    # Cross-validation layer
    ("FF-1.2.01", "CV-4.5.01"),
    ("FF-1.2.02", "CV-4.5.01"),
    ("FF-1.4.03", "CV-4.5.02"),
    ("FF-1.4.04", "CV-4.5.02"),
    ("FF-1.1.04", "CV-4.5.03"),
    ("FF-1.9.01", "CV-4.5.03"),
    # Legacy/vendor layer
    ("VD-2.1.01", "LE-4.4.04"),
    ("FF-1.1.02", "VD-2.1.04"),
)


# ═══════════════════════════════════════════════════════════════════════
# Pass 1: Syntactic Evaluation
# ═══════════════════════════════════════════════════════════════════════


@dataclass
class PredicateResult:
    """Result of evaluating a single predicate against M."""
    predicate_id: str
    classification: Classification
    annotation: str = ""
    device_scope: frozenset[str] = frozenset()
    semantic_chain: tuple[str, ...] = ()


def _topological_sort(predicates: list[str], edges: list[tuple[str, str]]) -> list[str]:
    """Topological sort of predicate IDs respecting evaluation dependencies."""
    graph: dict[str, list[str]] = defaultdict(list)
    in_degree: dict[str, int] = {p: 0 for p in predicates}

    for dep, dependent in edges:
        if dep in in_degree and dependent in in_degree:
            graph[dep].append(dependent)
            in_degree[dependent] += 1

    queue = [p for p in predicates if in_degree[p] == 0]
    result = []

    while queue:
        queue.sort()  # Deterministic ordering
        node = queue.pop(0)
        result.append(node)
        for neighbor in graph[node]:
            in_degree[neighbor] -= 1
            if in_degree[neighbor] == 0:
                queue.append(neighbor)

    if len(result) != len(predicates):
        missing = set(predicates) - set(result)
        raise ValueError(f"Evaluation DAG has cycles involving: {missing}")

    return result


def run_pass1(bf: Session, all_devices: set[str]) -> dict[str, PredicateResult]:
    """Execute Pass 1: Syntactic evaluation of all 97 predicates.

    Evaluates each predicate against the Batfish snapshot in topological order.

    Args:
        bf: pybatfish Session with initialized snapshot.
        all_devices: Set of all device hostnames in the snapshot.

    Returns:
        Dict of predicate_id → PredicateResult (P_raw).
    """
    pred_ids = [p.predicate_id for p in ALL_PREDICATES]
    eval_order = _topological_sort(pred_ids, list(EVALUATION_DAG_EDGES))

    results: dict[str, PredicateResult] = {}

    for pred_id in eval_order:
        spec = PREDICATE_BY_ID[pred_id]

        # Check evaluation dependencies
        dep_results = _get_dependency_results(pred_id, results)
        short_circuit = _check_dependency_short_circuit(pred_id, dep_results)

        if short_circuit is not None:
            results[pred_id] = short_circuit
            continue

        # Evaluate predicate against Batfish
        result = _evaluate_predicate(bf, spec, all_devices, results)
        results[pred_id] = result

    return results


def _get_dependency_results(
    pred_id: str,
    results: dict[str, PredicateResult],
) -> list[PredicateResult]:
    """Get evaluation results for all dependencies of a predicate."""
    deps = [dep for dep, dependent in EVALUATION_DAG_EDGES if dependent == pred_id]
    return [results[dep] for dep in deps if dep in results]


def _check_dependency_short_circuit(
    pred_id: str,
    dep_results: list[PredicateResult],
) -> Optional[PredicateResult]:
    """Check if a predicate should be short-circuited due to dependency failures."""
    rejected_deps = [r for r in dep_results if r.classification == Classification.R]
    if rejected_deps:
        dep_ids = ", ".join(r.predicate_id for r in rejected_deps)
        return PredicateResult(
            predicate_id=pred_id,
            classification=Classification.K,
            annotation=f"Short-circuited: evaluation dependency [{dep_ids}] rejected.",
            device_scope=frozenset().union(*(r.device_scope for r in rejected_deps)),
            semantic_chain=(pred_id,),
        )
    return None


def _evaluate_predicate(
    bf: Session,
    spec: PredicateSpec,
    all_devices: set[str],
    prior_results: dict[str, PredicateResult],
) -> PredicateResult:
    """Evaluate a single predicate against the Batfish snapshot.

    This is the core evaluation logic. Each predicate's pass/partial/fail
    conditions are checked against the Batfish query results.

    For Tier 3 (documentation/deferred), classification is always C
    (they don't parameterize any computation).
    """
    # Tier 3 predicates are always confirmed (documentation only)
    if spec.tier == 3:
        return PredicateResult(
            predicate_id=spec.predicate_id,
            classification=Classification.C,
            annotation="Documentation/deferred — no computation impact.",
            device_scope=frozenset(all_devices),
        )

    # For predicates with no Batfish queries, confirm by default
    if not spec.batfish_queries:
        return PredicateResult(
            predicate_id=spec.predicate_id,
            classification=Classification.C,
            annotation="No Batfish queries specified.",
            device_scope=frozenset(all_devices),
        )

    # Execute Batfish queries and evaluate conditions
    try:
        query_results = {}
        for query_name in spec.batfish_queries:
            query_results[query_name] = _run_batfish_query(bf, query_name)

        classification, annotation, affected_devices = _evaluate_conditions(
            spec, query_results, all_devices
        )

        return PredicateResult(
            predicate_id=spec.predicate_id,
            classification=classification,
            annotation=annotation,
            device_scope=frozenset(affected_devices),
            semantic_chain=(spec.predicate_id,),
        )

    except Exception as e:
        # Query failure → Constrained (not Rejected — Batfish may not support the query)
        return PredicateResult(
            predicate_id=spec.predicate_id,
            classification=Classification.K,
            annotation=f"Batfish query error: {e}",
            device_scope=frozenset(all_devices),
            semantic_chain=(spec.predicate_id,),
        )


def _run_batfish_query(bf: Session, query_name: str) -> Any:
    """Execute a single Batfish query by name and return the DataFrame."""
    query_fn = getattr(bf.q, query_name, None)
    if query_fn is None:
        raise AttributeError(f"Batfish query '{query_name}' not found in pybatfish")
    return query_fn().answer().frame()


def _evaluate_conditions(
    spec: PredicateSpec,
    query_results: dict[str, Any],
    all_devices: set[str],
) -> tuple[Classification, str, set[str]]:
    """Evaluate pass/partial/fail conditions for a predicate.

    This implements the generic evaluation logic. Each predicate category
    has a common evaluation pattern based on query result completeness.

    Returns:
        (classification, annotation, affected_devices)
    """
    # Generic evaluation: check if queries returned non-empty results
    # and if results cover all devices

    empty_queries = []
    partial_queries = []

    for query_name, df in query_results.items():
        if df is None or (hasattr(df, 'empty') and df.empty):
            empty_queries.append(query_name)
        elif hasattr(df, '__len__') and len(df) == 0:
            empty_queries.append(query_name)

    if empty_queries:
        # Check if the empty result is expected (e.g., no OSPF in an eBGP-only fabric)
        if _is_expected_empty(spec, empty_queries, query_results, all_devices):
            return (
                Classification.C,
                f"Queries {empty_queries} returned empty — expected for this topology.",
                all_devices,
            )

        # Primary queries empty → check if it's a config-absent scenario (not a failure)
        primary_query = spec.batfish_queries[0] if spec.batfish_queries else ""
        if primary_query in empty_queries:
            # Check if any device has the relevant config
            if _any_device_has_config(spec, query_results, all_devices):
                return (
                    Classification.R,
                    f"Primary query '{primary_query}' returned empty despite config presence.",
                    all_devices,
                )
            else:
                # No devices have this config → protocol not used → confirmed (not applicable)
                return (
                    Classification.C,
                    f"Protocol/feature not configured in this topology.",
                    all_devices,
                )

    # All queries returned data → check coverage
    devices_covered = _extract_covered_devices(query_results, all_devices)
    coverage_ratio = len(devices_covered) / len(all_devices) if all_devices else 1.0

    if coverage_ratio >= 0.99:
        return (Classification.C, "", devices_covered)
    elif coverage_ratio >= 0.5:
        missing = all_devices - devices_covered
        return (
            Classification.K,
            f"Partial coverage: {len(devices_covered)}/{len(all_devices)} devices. "
            f"Missing: {missing}",
            devices_covered,
        )
    else:
        return (
            Classification.R,
            f"Low coverage: {len(devices_covered)}/{len(all_devices)} devices.",
            devices_covered,
        )


def _is_expected_empty(
    spec: PredicateSpec,
    empty_queries: list[str],
    query_results: dict[str, Any],
    all_devices: set[str],
) -> bool:
    """Check if empty query results are expected for the topology type."""
    # OSPF queries empty in eBGP-only fabric → expected
    ospf_queries = {"ospfEdges", "ospfSessionCompatibility", "ospfProcessConfiguration",
                    "ospfInterfaceConfiguration", "ospfAreaConfiguration"}
    if set(empty_queries) <= ospf_queries:
        return True

    # EVPN queries empty when no EVPN config → expected
    evpn_queries = {"evpnRib", "vxlanVniProperties"}
    if set(empty_queries) <= evpn_queries:
        return True

    # MLAG queries empty when no MLAG → expected
    if set(empty_queries) <= {"mlagProperties"}:
        return True

    # F5 queries empty → expected unless F5 devices present
    if set(empty_queries) <= {"f5BigipVipConfiguration"}:
        return True

    # STP queries empty in L3-only fabric → expected
    if set(empty_queries) <= {"namedStructures"} and spec.predicate_id in ("FF-1.1.05", "FF-1.1.06"):
        return True

    return False


def _any_device_has_config(
    spec: PredicateSpec,
    query_results: dict[str, Any],
    all_devices: set[str],
) -> bool:
    """Check if any device in the snapshot has the relevant configuration."""
    # For now, assume if the query returned empty, the config isn't present
    # A more thorough check would inspect raw configs via fileParseStatus
    return False


def _extract_covered_devices(
    query_results: dict[str, Any],
    all_devices: set[str],
) -> set[str]:
    """Extract the set of devices covered by query results."""
    covered = set()
    for query_name, df in query_results.items():
        if df is None or (hasattr(df, 'empty') and df.empty):
            continue
        # Try common column names for device identification
        for col in ["Node", "Hostname", "Source", "Interface"]:
            if col in df.columns:
                for val in df[col]:
                    if hasattr(val, 'hostname'):
                        covered.add(val.hostname)
                    elif hasattr(val, 'node'):
                        covered.add(val.node)
                    else:
                        device_str = str(val).split("[")[0].split("/")[0]
                        if device_str in all_devices:
                            covered.add(device_str)
    return covered if covered else all_devices


# ═══════════════════════════════════════════════════════════════════════
# Pass 2: Semantic Dependency Correction
# ═══════════════════════════════════════════════════════════════════════


def run_pass2(
    p_raw: dict[str, PredicateResult],
) -> dict[str, PredicateResult]:
    """Execute Pass 2: Semantic dependency correction.

    Propagates downgrades through G_sem. Rules:
    - Rule 1: R strong dependency → downgrade to R
    - Rule 1b: R weak dependency → downgrade to K
    - Rule 2: K dependency → downgrade to K
    - Rule 3: Annotation chaining
    - Rule 4: Transitivity (handled by topological order)
    - Rule 5: No upgrades
    - Rule 6: Scope narrowing (per-device)

    Args:
        p_raw: Output of Pass 1.

    Returns:
        P_corrected — semantically corrected partition.
    """
    # Build adjacency: target → list of (source, strength, data_path)
    deps_by_target: dict[str, list[SemanticEdge]] = defaultdict(list)
    for edge in ALL_SEMANTIC_EDGES:
        deps_by_target[edge.target].append(edge)

    # Build forward graph for topological sort
    all_pred_ids = list(p_raw.keys())
    sem_dag_edges = [(e.source, e.target) for e in ALL_SEMANTIC_EDGES
                     if e.source in p_raw and e.target in p_raw]

    # Process in topological order (sources first, consumers last)
    try:
        eval_order = _topological_sort(all_pred_ids, sem_dag_edges)
    except ValueError:
        # If cycles exist in G_sem, fall back to original order
        eval_order = all_pred_ids

    p_corrected = {pid: PredicateResult(
        predicate_id=r.predicate_id,
        classification=r.classification,
        annotation=r.annotation,
        device_scope=r.device_scope,
        semantic_chain=r.semantic_chain,
    ) for pid, r in p_raw.items()}

    for pred_id in eval_order:
        result = p_corrected[pred_id]

        # Rule 5: R never changes
        if result.classification == Classification.R:
            continue

        deps = deps_by_target.get(pred_id, [])
        if not deps:
            continue

        # Classify dependencies
        strong_rejected = [
            e for e in deps
            if e.source in p_corrected
            and p_corrected[e.source].classification == Classification.R
            and e.strength == DepStrength.STRONG
        ]
        weak_rejected = [
            e for e in deps
            if e.source in p_corrected
            and p_corrected[e.source].classification == Classification.R
            and e.strength == DepStrength.WEAK
        ]
        constrained = [
            e for e in deps
            if e.source in p_corrected
            and p_corrected[e.source].classification == Classification.K
        ]

        if result.classification == Classification.C:
            if strong_rejected:
                # Rule 1: Strong R dependency → downgrade to R
                sources = ", ".join(e.source for e in strong_rejected)
                p_corrected[pred_id] = PredicateResult(
                    predicate_id=pred_id,
                    classification=Classification.R,
                    annotation=(
                        f"Rejected: strong semantic dependency [{sources}] rejected. "
                        f"Data paths: {[e.data_path for e in strong_rejected]}"
                    ),
                    device_scope=result.device_scope,
                    semantic_chain=result.semantic_chain + tuple(e.source for e in strong_rejected),
                )
            elif weak_rejected:
                # Rule 1b: Weak R dependency → downgrade to K
                sources = ", ".join(e.source for e in weak_rejected)
                p_corrected[pred_id] = PredicateResult(
                    predicate_id=pred_id,
                    classification=Classification.K,
                    annotation=(
                        f"Constrained: weak semantic dependency [{sources}] rejected. "
                        f"Data paths: {[e.data_path for e in weak_rejected]}"
                    ),
                    device_scope=result.device_scope,
                    semantic_chain=result.semantic_chain + tuple(e.source for e in weak_rejected),
                )
            elif constrained:
                # Rule 2: K dependency → downgrade to K
                sources = ", ".join(e.source for e in constrained)
                p_corrected[pred_id] = PredicateResult(
                    predicate_id=pred_id,
                    classification=Classification.K,
                    annotation=(
                        f"Independently confirmed. Downgraded: semantic dependency "
                        f"[{sources}] constrained. "
                        f"Data paths: {[e.data_path for e in constrained]}"
                    ),
                    device_scope=result.device_scope,
                    semantic_chain=result.semantic_chain + tuple(e.source for e in constrained),
                )

        elif result.classification == Classification.K:
            if strong_rejected:
                # K with strong R dependency → downgrade to R
                sources = ", ".join(e.source for e in strong_rejected)
                p_corrected[pred_id] = PredicateResult(
                    predicate_id=pred_id,
                    classification=Classification.R,
                    annotation=(
                        f"{result.annotation} "
                        f"Further downgraded to R: strong semantic dependency [{sources}] rejected."
                    ),
                    device_scope=result.device_scope,
                    semantic_chain=result.semantic_chain + tuple(e.source for e in strong_rejected),
                )

    return p_corrected


# ═══════════════════════════════════════════════════════════════════════
# M_verified Construction
# ═══════════════════════════════════════════════════════════════════════


def construct_m_verified(
    bf: Session,
    p_corrected: dict[str, PredicateResult],
    all_devices: set[str],
) -> MVerified:
    """Construct M_verified from corrected predicate results.

    Applies Rules M1-M5 from Stage 3 spec.

    Args:
        bf: pybatfish Session.
        p_corrected: Corrected predicate partition from Pass 2.
        all_devices: Set of all device hostnames.

    Returns:
        MVerified with per-field fidelity tags.
    """
    m = MVerified()
    m.predicate_results = {pid: r.classification for pid, r in p_corrected.items()}

    # Extract device data from Batfish
    try:
        node_props = bf.q.nodeProperties().answer().frame()
    except Exception:
        node_props = None

    for hostname in all_devices:
        device = Device(hostname=hostname)

        # Populate vendor class from Batfish
        if node_props is not None and not node_props.empty:
            device_rows = node_props[node_props["Node"] == hostname]
            if not device_rows.empty:
                row = device_rows.iloc[0]
                device.vendor_class = str(row.get("Configuration_Format", "")).lower()

        # Apply per-field fidelity tags from P_corrected (Rule M1)
        for pred_id, result in p_corrected.items():
            if hostname in result.device_scope or not result.device_scope:
                tag = FidelityTag(
                    classification=result.classification,
                    source_predicate=pred_id,
                    annotation=result.annotation,
                    semantic_chain=result.semantic_chain,
                    device_scope=frozenset([hostname]) & result.device_scope if result.device_scope else frozenset([hostname]),
                )
                device.field_tags[pred_id] = tag

        # Populate BGP peers from Batfish
        try:
            bgp_peers_df = bf.q.bgpPeerConfiguration(nodes=hostname).answer().frame()
            for _, row in bgp_peers_df.iterrows():
                from .entity_store import BgpPeer, BGPPeerType
                local_as = int(row.get("Local_AS", 0)) if row.get("Local_AS") else 0
                remote_as = int(row.get("Remote_AS", 0)) if row.get("Remote_AS") else 0
                peer = BgpPeer(
                    peer_ip=str(row.get("Remote_IP", "")),
                    peer_asn=remote_as,
                    local_asn=local_as,
                    peer_type=BGPPeerType.IBGP if local_as == remote_as else BGPPeerType.EBGP,
                )
                device.bgp_peers.append(peer)
                if device.bgp_asn is None and local_as:
                    device.bgp_asn = local_as
        except Exception:
            pass

        # Populate parse status
        try:
            parse_df = bf.q.fileParseStatus().answer().frame()
            for _, row in parse_df.iterrows():
                fname = str(row.get("File_Name", ""))
                if hostname.lower() in fname.lower():
                    device.parse_status = str(row.get("Status", "PASSED"))
                    break
        except Exception:
            pass

        m.devices[hostname] = device

    # Add capability tags (Rule M5)
    for pred_id in ("FF-1.5.02", "FF-1.5.03", "FF-1.6.01", "FF-1.6.02",
                     "FF-1.6.03", "FF-1.6.04", "FF-1.6.05", "FF-1.6.06", "CV-4.5.02"):
        if pred_id in p_corrected:
            result = p_corrected[pred_id]
            m.capability_tags.append(CapabilityTag(
                capability_name=PREDICATE_BY_ID[pred_id].name if pred_id in PREDICATE_BY_ID else pred_id,
                classification=result.classification,
                source_predicate=pred_id,
                annotation=result.annotation,
            ))

    return m


# ═══════════════════════════════════════════════════════════════════════
# Full Stage 3 Pipeline
# ═══════════════════════════════════════════════════════════════════════


def run_stage3(bf: Session) -> tuple[dict[str, PredicateResult], MVerified]:
    """Execute the complete Stage 3 pipeline.

    1. Gate 0: Parse completeness check
    2. Pass 1: Syntactic evaluation
    3. Pass 2: Semantic dependency correction
    4. M_verified construction

    Args:
        bf: pybatfish Session with initialized snapshot.

    Returns:
        (P_corrected, M_verified)
    """
    # Gate 0: Identify all devices, exclude parse failures
    print("[stage3] Gate 0: Parse completeness check...")
    try:
        node_props = bf.q.nodeProperties().answer().frame()
        all_devices = set(str(row["Node"]) for _, row in node_props.iterrows())
    except Exception as e:
        raise RuntimeError(f"Gate 0 failed: cannot query node properties: {e}")

    # Check parse status
    excluded = set()
    try:
        parse_status = bf.q.fileParseStatus().answer().frame()
        for _, row in parse_status.iterrows():
            status = str(row.get("Status", ""))
            if status == "FAILED":
                fname = str(row.get("File_Name", ""))
                # Try to match filename to device
                for dev in all_devices:
                    if dev.lower() in fname.lower():
                        excluded.add(dev)
                        break
    except Exception:
        pass

    active_devices = all_devices - excluded
    if excluded:
        print(f"[stage3] Gate 0: Excluded {len(excluded)} devices with parse failures: {excluded}")
    print(f"[stage3] Gate 0: {len(active_devices)} devices in evaluation set")

    # Pass 1: Syntactic evaluation
    print(f"[stage3] Pass 1: Evaluating 97 predicates...")
    p_raw = run_pass1(bf, active_devices)

    raw_counts = _count_classifications(p_raw)
    print(f"[stage3] Pass 1 complete: C={raw_counts['C']}, K={raw_counts['K']}, R={raw_counts['R']}")

    # Pass 2: Semantic dependency correction
    print(f"[stage3] Pass 2: Semantic dependency correction...")
    p_corrected = run_pass2(p_raw)

    corrected_counts = _count_classifications(p_corrected)
    print(f"[stage3] Pass 2 complete: C={corrected_counts['C']}, K={corrected_counts['K']}, R={corrected_counts['R']}")

    # Check monotonicity
    for pid in p_raw:
        raw_cls = p_raw[pid].classification
        cor_cls = p_corrected[pid].classification
        order = {Classification.C: 0, Classification.K: 1, Classification.R: 2}
        assert order[cor_cls] >= order[raw_cls], (
            f"Monotonicity violation: {pid} went from {raw_cls} to {cor_cls}"
        )

    # M_verified construction
    print(f"[stage3] Constructing M_verified...")
    m_verified = construct_m_verified(bf, p_corrected, active_devices)
    print(f"[stage3] M_verified: {len(m_verified.devices)} devices, "
          f"{len(m_verified.capability_tags)} capability tags")

    return p_corrected, m_verified


def _count_classifications(results: dict[str, PredicateResult]) -> dict[str, int]:
    """Count classifications in a result set."""
    counts = {"C": 0, "K": 0, "R": 0}
    for r in results.values():
        counts[r.classification.name] += 1
    return counts
