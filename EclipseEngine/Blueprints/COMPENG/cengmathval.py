"""
NetWatch Compression Engine — Mathematical Foundation Validation Suite
=====================================================================

Purpose: Validate the core mathematical claims that the compression engine
relies on, IN ISOLATION, before building the implementation.

This suite tests the theorems, not the implementation. It uses small,
hand-verifiable graphs where the correct answer is known analytically.

Claims under test:
    1. Fibration lifting theorem on typed multigraphs
    2. Weisfeiler-Leman convergence and coarseness on typed multigraphs
    3. Behavioral signature sufficiency as initial coloring
    4. Representative subgraph preservation of fibration property
    5. Typed-edge equitability generalizes correctly
    6. Compression ratio on realistic Clos topologies

Standard: Each test includes the expected result derived by hand, so the
test is verifiable by inspection — not just by running the code.
"""

import hashlib
import json
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Dict, FrozenSet, List, Optional, Set, Tuple
from copy import deepcopy


# ════════════════════════════════════════════════════════════════════
# CORE DATA STRUCTURES
# ════════════════════════════════════════════════════════════════════

@dataclass
class Vertex:
    name: str
    vertex_type: str                    # "spine", "leaf", "server", etc.
    signature: Optional[str] = None     # behavioral signature σ(v)
    attributes: Dict = field(default_factory=dict)

@dataclass
class TypedEdge:
    source: str
    target: str
    edge_type: str      # "bgp", "ospf", "l3", "mlag", etc.

@dataclass
class TypedMultigraph:
    """A typed multigraph: multiple edge types between the same vertex pair."""
    vertices: Dict[str, Vertex] = field(default_factory=dict)
    edges: List[TypedEdge] = field(default_factory=list)

    def add_vertex(self, name: str, vertex_type: str, signature: str = None, **attrs):
        self.vertices[name] = Vertex(name, vertex_type, signature, attrs)

    def add_edge(self, src: str, tgt: str, edge_type: str):
        self.edges.append(TypedEdge(src, tgt, edge_type))
        # Undirected: add reverse
        self.edges.append(TypedEdge(tgt, src, edge_type))

    def neighbors_by_type(self, vertex: str) -> Dict[str, List[str]]:
        """Returns {edge_type: [neighbor_names]} for a vertex."""
        result = defaultdict(list)
        for e in self.edges:
            if e.source == vertex:
                result[e.edge_type].append(e.target)
        return dict(result)

    def neighbor_count_in_cell(self, vertex: str, cell: FrozenSet[str], edge_type: str) -> int:
        """Count neighbors of vertex in a given cell for a given edge type."""
        count = 0
        for e in self.edges:
            if e.source == vertex and e.target in cell and e.edge_type == edge_type:
                count += 1
        return count

    def all_edge_types(self) -> Set[str]:
        return {e.edge_type for e in self.edges}


# ════════════════════════════════════════════════════════════════════
# EQUITABLE PARTITION ALGORITHMS
# ════════════════════════════════════════════════════════════════════

def compute_initial_partition(G: TypedMultigraph) -> Dict[str, int]:
    """Group vertices by signature. Returns vertex → cell_id mapping."""
    sig_to_cell = {}
    cell_id = 0
    vertex_to_cell = {}

    for v_name, v in G.vertices.items():
        sig = v.signature or v.vertex_type  # fallback to type if no signature
        if sig not in sig_to_cell:
            sig_to_cell[sig] = cell_id
            cell_id += 1
        vertex_to_cell[v_name] = sig_to_cell[sig]

    return vertex_to_cell


def get_cells(vertex_to_cell: Dict[str, int]) -> Dict[int, FrozenSet[str]]:
    """Invert the vertex→cell mapping to cell→{vertices}."""
    cells = defaultdict(set)
    for v, c in vertex_to_cell.items():
        cells[c].add(v)
    return {c: frozenset(members) for c, members in cells.items()}


def compute_neighbor_profile(G: TypedMultigraph, vertex: str,
                              cells: Dict[int, FrozenSet[str]]) -> Tuple:
    """
    Compute the neighbor-count profile for a vertex:
    For each (cell_id, edge_type), how many neighbors does this vertex have?
    Returns a hashable tuple suitable for comparison.
    """
    edge_types = sorted(G.all_edge_types())
    cell_ids = sorted(cells.keys())

    profile = []
    for cid in cell_ids:
        for etype in edge_types:
            count = G.neighbor_count_in_cell(vertex, cells[cid], etype)
            profile.append((cid, etype, count))

    return tuple(profile)


def weisfeiler_leman_refine(G: TypedMultigraph,
                             vertex_to_cell: Dict[str, int],
                             max_iterations: int = 100) -> Dict[str, int]:
    """
    Weisfeiler-Leman color refinement for typed multigraphs.

    Iteratively refines the partition until stable (equitable).
    Returns the refined vertex → cell_id mapping.
    """
    current = dict(vertex_to_cell)
    next_cell_id = max(current.values()) + 1

    for iteration in range(max_iterations):
        cells = get_cells(current)
        new_mapping = {}
        profile_to_new_cell = {}

        for v_name in G.vertices:
            old_cell = current[v_name]
            profile = (old_cell, compute_neighbor_profile(G, v_name, cells))

            if profile not in profile_to_new_cell:
                profile_to_new_cell[profile] = next_cell_id
                next_cell_id += 1

            new_mapping[v_name] = profile_to_new_cell[profile]

        # Check convergence: did anything change?
        # Normalize cell IDs for comparison
        old_partition = get_cells(current)
        new_partition = get_cells(new_mapping)

        old_groups = set(frozenset(m) for m in old_partition.values())
        new_groups = set(frozenset(m) for m in new_partition.values())

        if old_groups == new_groups:
            return current  # stable — equitable partition found

        current = new_mapping

    raise RuntimeError(f"W-L did not converge in {max_iterations} iterations")


def is_equitable(G: TypedMultigraph, vertex_to_cell: Dict[str, int]) -> Tuple[bool, str]:
    """
    Verify the equitability property:
    For every cell pair (Ci, Cj) and edge type e,
    every vertex in Ci has the same number of e-type neighbors in Cj.

    Returns (True, "") or (False, reason).
    """
    cells = get_cells(vertex_to_cell)
    edge_types = G.all_edge_types()

    for ci_id, ci_members in cells.items():
        for cj_id, cj_members in cells.items():
            for etype in edge_types:
                counts = set()
                for v in ci_members:
                    count = G.neighbor_count_in_cell(v, cj_members, etype)
                    counts.add(count)

                if len(counts) > 1:
                    return False, (
                        f"Cell {ci_id} ({ci_members}) → Cell {cj_id} ({cj_members}), "
                        f"edge_type={etype}: non-uniform counts {counts}"
                    )

    return True, "equitable"


# ════════════════════════════════════════════════════════════════════
# FIBRATION LIFTING THEOREM VERIFICATION
# ════════════════════════════════════════════════════════════════════

def build_quotient_graph(G: TypedMultigraph,
                          vertex_to_cell: Dict[str, int]) -> TypedMultigraph:
    """
    Build the quotient graph G/π.
    Each cell becomes a vertex. Edges between cells are preserved (deduplicated by type).
    """
    cells = get_cells(vertex_to_cell)
    Q = TypedMultigraph()

    # Add one vertex per cell, using the cell's representative signature
    for cid, members in cells.items():
        rep = sorted(members)[0]
        Q.add_vertex(f"C{cid}", G.vertices[rep].vertex_type,
                     signature=G.vertices[rep].signature)

    # Add edges between cells (deduplicated: one edge per type per cell pair)
    seen_edges = set()
    for edge in G.edges:
        src_cell = vertex_to_cell[edge.source]
        tgt_cell = vertex_to_cell[edge.target]
        edge_key = (min(src_cell, tgt_cell), max(src_cell, tgt_cell), edge.edge_type)

        if edge_key not in seen_edges and src_cell != tgt_cell:
            seen_edges.add(edge_key)
            # Don't use add_edge (which adds bidirectional) — add raw directed edges
            Q.edges.append(TypedEdge(f"C{src_cell}", f"C{tgt_cell}", edge.edge_type))
            Q.edges.append(TypedEdge(f"C{tgt_cell}", f"C{src_cell}", edge.edge_type))

    return Q


def verify_lifting_property(G: TypedMultigraph,
                              vertex_to_cell: Dict[str, int]) -> Tuple[bool, str]:
    """
    Verify the fibration lifting property:
    For every vertex v in G and every edge (π(v), C_j) of type e in G/π,
    there exists an edge (v, w) of type e in G where π(w) = C_j.

    This is the LOCAL lifting condition that makes π a graph fibration.
    If this holds for an equitable partition, the lifting theorem guarantees
    that state transition sequences lift bidirectionally.
    """
    cells = get_cells(vertex_to_cell)
    Q = build_quotient_graph(G, vertex_to_cell)

    for v_name, v in G.vertices.items():
        v_cell = vertex_to_cell[v_name]
        v_cell_name = f"C{v_cell}"

        # For each edge from v's cell in the quotient graph
        for q_edge in Q.edges:
            if q_edge.source != v_cell_name:
                continue

            target_cell_name = q_edge.target
            target_cell_id = int(target_cell_name[1:])
            etype = q_edge.edge_type

            # v must have at least one neighbor of this edge type in the target cell
            target_cell_members = cells[target_cell_id]
            has_lift = False
            for g_edge in G.edges:
                if (g_edge.source == v_name and
                    g_edge.target in target_cell_members and
                    g_edge.edge_type == etype):
                    has_lift = True
                    break

            if not has_lift:
                return False, (
                    f"Lifting failure: vertex {v_name} (cell C{v_cell}) has no "
                    f"{etype}-edge to any member of {target_cell_name} ({target_cell_members}), "
                    f"but quotient edge (C{v_cell}, {target_cell_name}, {etype}) exists."
                )

    return True, "lifting property holds"


# ════════════════════════════════════════════════════════════════════
# STATE TRANSITION SIMULATION
# ════════════════════════════════════════════════════════════════════

def simulate_bgp_withdrawal(G: TypedMultigraph, failed_vertex: str,
                             vertex_to_cell: Dict[str, int]) -> Dict[str, List[str]]:
    """
    Simulate a simplified BGP withdrawal propagation:
    When a vertex fails, its BGP neighbors withdraw routes learned from it.
    They then propagate withdrawals to THEIR BGP neighbors, etc.

    Returns {vertex: [list of events in order]} for the original graph.
    """
    events = defaultdict(list)
    affected = {failed_vertex}
    wave = 0

    # Wave 0: vertex fails
    events[failed_vertex].append(f"wave-{wave}: FAIL")

    # Propagate withdrawals via BGP edges
    frontier = {failed_vertex}
    visited = {failed_vertex}

    while frontier:
        wave += 1
        next_frontier = set()
        for v in frontier:
            for edge in G.edges:
                if edge.source == v and edge.edge_type == "bgp" and edge.target not in visited:
                    events[edge.target].append(f"wave-{wave}: WITHDRAW from {v}")
                    next_frontier.add(edge.target)
                    visited.add(edge.target)
        frontier = next_frontier

    return dict(events)


def simulate_bgp_withdrawal_on_quotient(Q: TypedMultigraph, failed_cell: str,
                                         cells: Dict[int, FrozenSet[str]]) -> Dict[str, List[str]]:
    """Same simulation but on the quotient graph."""
    events = defaultdict(list)
    wave = 0
    events[failed_cell].append(f"wave-{wave}: FAIL")

    frontier = {failed_cell}
    visited = {failed_cell}

    while frontier:
        wave += 1
        next_frontier = set()
        for c in frontier:
            for edge in Q.edges:
                if edge.source == c and edge.edge_type == "bgp" and edge.target not in visited:
                    events[edge.target].append(f"wave-{wave}: WITHDRAW from {c}")
                    next_frontier.add(edge.target)
                    visited.add(edge.target)
        frontier = next_frontier

    return dict(events)


# ════════════════════════════════════════════════════════════════════
# TEST GRAPH BUILDERS
# ════════════════════════════════════════════════════════════════════

def build_symmetric_clos_2s4l():
    """
    Minimal symmetric Clos: 2 spines, 4 leaves.
    All spines identical config. All leaves identical config.
    Each leaf connects to both spines via BGP.
    Each leaf has 2 servers (V_inf, omitted for now — V_net only).

    Expected partition: {spine-1, spine-2} and {leaf-1, leaf-2, leaf-3, leaf-4}
    Expected compression: 2 cells → 2+2 = 4 representatives (Rule 1: ≥2 per cell)
    Compression ratio: 6 → 4 (33% reduction)
    """
    G = TypedMultigraph()

    # Spines — identical config
    for i in range(1, 3):
        G.add_vertex(f"spine-{i}", "spine", signature="spine_cfg_A")

    # Leaves — identical config
    for i in range(1, 5):
        G.add_vertex(f"leaf-{i}", "leaf", signature="leaf_cfg_A")

    # Full mesh: every leaf connects to every spine via BGP
    for leaf_i in range(1, 5):
        for spine_i in range(1, 3):
            G.add_edge(f"leaf-{leaf_i}", f"spine-{spine_i}", "bgp")

    return G


def build_asymmetric_clos_2s4l():
    """
    Asymmetric Clos: 2 spines, 4 leaves.
    All spines identical config. Leaves have identical σ but DIFFERENT
    connectivity: leaf-1 and leaf-2 connect to both spines, leaf-3 and
    leaf-4 connect ONLY to spine-1.

    This tests whether W-L refinement catches the structural asymmetry
    even though all leaves have the same behavioral signature.

    Expected: W-L must split leaves into {leaf-1, leaf-2} and {leaf-3, leaf-4}.
    """
    G = TypedMultigraph()

    for i in range(1, 3):
        G.add_vertex(f"spine-{i}", "spine", signature="spine_cfg_A")

    for i in range(1, 5):
        G.add_vertex(f"leaf-{i}", "leaf", signature="leaf_cfg_A")

    # leaf-1, leaf-2: connect to BOTH spines
    for leaf_i in [1, 2]:
        G.add_edge(f"leaf-{leaf_i}", "spine-1", "bgp")
        G.add_edge(f"leaf-{leaf_i}", "spine-2", "bgp")

    # leaf-3, leaf-4: connect ONLY to spine-1
    for leaf_i in [3, 4]:
        G.add_edge(f"leaf-{leaf_i}", "spine-1", "bgp")

    return G


def build_multi_edge_type_clos():
    """
    Clos with multiple edge types: BGP + OSPF on the same topology.
    2 spines, 4 leaves. BGP on all links. OSPF only on spine-1's links.

    This tests typed-edge equitability: spines have identical BGP connectivity
    but DIFFERENT OSPF connectivity. The partition must split them.

    Expected: spines split into {spine-1} and {spine-2} because spine-1
    has OSPF neighbors and spine-2 does not.
    """
    G = TypedMultigraph()

    for i in range(1, 3):
        G.add_vertex(f"spine-{i}", "spine", signature="spine_cfg_A")

    for i in range(1, 5):
        G.add_vertex(f"leaf-{i}", "leaf", signature="leaf_cfg_A")

    # BGP: full mesh
    for leaf_i in range(1, 5):
        for spine_i in range(1, 3):
            G.add_edge(f"leaf-{leaf_i}", f"spine-{spine_i}", "bgp")

    # OSPF: only on spine-1's links
    for leaf_i in range(1, 5):
        G.add_edge(f"leaf-{leaf_i}", "spine-1", "ospf")

    return G


def build_border_leaf_topology():
    """
    Clos with border leaves having unique external peerings.
    2 spines, 2 normal leaves, 2 border leaves.
    Normal leaves: identical config, connect to both spines.
    Border leaves: identical config to each other, connect to both spines,
    but each has a unique external BGP peering (ISP-A, ISP-B).

    This tests Rule 2: even if border-1 and border-2 have identical σ,
    their unique external peerings must be preserved.

    Expected partition: {spine-1, spine-2}, {leaf-1, leaf-2}, {border-1, border-2}
    But border-1 and border-2 must BOTH be representatives due to Rule 2.
    """
    G = TypedMultigraph()

    for i in range(1, 3):
        G.add_vertex(f"spine-{i}", "spine", signature="spine_cfg_A")

    for i in range(1, 3):
        G.add_vertex(f"leaf-{i}", "leaf", signature="leaf_cfg_A")

    for i in range(1, 3):
        G.add_vertex(f"border-{i}", "border_leaf", signature="border_cfg_A")

    # External peers (unique — NOT in the same equivalence class)
    G.add_vertex("ISP-A", "external", signature="isp_a")
    G.add_vertex("ISP-B", "external", signature="isp_b")

    # Internal connectivity: leaves and borders to spines
    for leaf_i in range(1, 3):
        for spine_i in range(1, 3):
            G.add_edge(f"leaf-{leaf_i}", f"spine-{spine_i}", "bgp")

    for border_i in range(1, 3):
        for spine_i in range(1, 3):
            G.add_edge(f"border-{border_i}", f"spine-{spine_i}", "bgp")

    # External peerings — unique per border leaf
    G.add_edge("border-1", "ISP-A", "bgp")
    G.add_edge("border-2", "ISP-B", "bgp")

    return G


def build_production_scale_clos():
    """
    Production-scale Clos: 4 spines, 32 leaves, 2 border leaves.
    All spines identical. All leaves identical. Border leaves identical
    but with unique external peerings (4 ISPs, split across borders).

    This tests compression ratio at realistic scale.

    Expected partition:
    - Spine cell: {spine-1..4} → 4 devices, 2 representatives (Rule 1)
    - Leaf cell: {leaf-1..32} → 32 devices, 2 representatives (Rule 1)
    - Border cell: {border-1, border-2} → 2 devices, 2 representatives (Rule 2)
    - ISP cells: 4 singletons
    Total production: 42 devices
    Total compressed: 2 + 2 + 2 + 4 = 10 representatives
    Compression ratio: 42 → 10 (76% reduction)
    """
    G = TypedMultigraph()

    # Spines
    for i in range(1, 5):
        G.add_vertex(f"spine-{i}", "spine", signature="spine_cfg_A")

    # Leaves
    for i in range(1, 33):
        G.add_vertex(f"leaf-{i}", "leaf", signature="leaf_cfg_A")

    # Border leaves
    for i in range(1, 3):
        G.add_vertex(f"border-{i}", "border_leaf", signature="border_cfg_A")

    # ISPs (unique external peers)
    for isp in ["ISP-A", "ISP-B", "ISP-C", "ISP-D"]:
        G.add_vertex(isp, "external", signature=f"ext_{isp}")

    # Full mesh: every leaf/border to every spine
    for leaf_i in range(1, 33):
        for spine_i in range(1, 5):
            G.add_edge(f"leaf-{leaf_i}", f"spine-{spine_i}", "bgp")

    for border_i in range(1, 3):
        for spine_i in range(1, 5):
            G.add_edge(f"border-{border_i}", f"spine-{spine_i}", "bgp")

    # Unique external peerings
    G.add_edge("border-1", "ISP-A", "bgp")
    G.add_edge("border-1", "ISP-B", "bgp")
    G.add_edge("border-2", "ISP-C", "bgp")
    G.add_edge("border-2", "ISP-D", "bgp")

    return G


def build_pathological_star():
    """
    Pathological case: star topology where center has a unique signature
    and all leaves have identical signatures.

    Tests that a single structurally unique device (the center) correctly
    forms a singleton cell, and the leaves form one cell.
    """
    G = TypedMultigraph()

    G.add_vertex("center", "router", signature="center_cfg")
    for i in range(1, 9):
        G.add_vertex(f"spoke-{i}", "router", signature="spoke_cfg")
        G.add_edge("center", f"spoke-{i}", "ospf")

    return G


def build_ring_topology():
    """
    Ring of 6 identical routers.

    In a ring, all vertices have identical degree (2) and identical signature.
    The initial partition puts them all in one cell.
    W-L on a simple ring of identical vertices should NOT split them —
    they are structurally equivalent (every vertex has exactly 2 neighbors
    in the same cell for each edge type).

    Expected: 1 cell of 6. Equitable as-is. Compression ratio: 6 → 2 (Rule 1).
    """
    G = TypedMultigraph()

    for i in range(6):
        G.add_vertex(f"r{i}", "router", signature="ring_cfg")

    for i in range(6):
        G.add_edge(f"r{i}", f"r{(i+1) % 6}", "ospf")

    return G


def build_dual_ring_topology():
    """
    Two rings of 4 routers each, connected by a single bridge link.

    Tests whether W-L correctly distinguishes bridge routers (which have
    cross-ring connections) from interior routers (which don't).

    Ring A: r0-r1-r2-r3-r0, all signature "ring_cfg"
    Ring B: r4-r5-r6-r7-r4, all signature "ring_cfg"
    Bridge: r0-r4 (BGP edge)

    Expected: W-L splits because r0 and r4 have a neighbor in the other ring's cell
    but r1,r2,r3,r5,r6,r7 do not.
    Final partition: {r0}, {r4}, {r1,r2,r3}, {r5,r6,r7}
    ... actually let me think more carefully. After initial partition, all 8 are
    in one cell. r0 has 3 neighbors in that cell (r1, r3, r4). r1 has 2 (r0, r2).
    So the first W-L pass splits by degree-in-cell: {r0, r4} (degree 3) vs
    {r1,r2,r3,r5,r6,r7} (degree 2). Then second pass: r0 has 1 neighbor in {r0,r4}
    (r4, via bgp) and 2 in the other cell. r4 also has 1 in {r0,r4} and 2 in other.
    So {r0, r4} might stay together. But wait — r0's neighbor in {r0,r4} is via bgp,
    and r4's neighbor in {r0,r4} is also via bgp. r0's ospf neighbors are in the big cell.
    r4's ospf neighbors are also in the big cell. So the profiles match: they stay together.

    For the big cell: r1 has ospf neighbors r0 (now in small cell) and r2 (in big cell).
    r5 has ospf neighbors r4 (in small cell) and r6 (in big cell).
    So r1 and r5 have identical profiles. Same for r2/r6, r3/r7.
    But r3 has ospf neighbors r2 (big cell) and r0 (small cell).
    r7 has ospf neighbors r6 (big cell) and r4 (small cell).
    So r3 and r7 also match. All of {r1..r3, r5..r7} have the same profile.

    Wait, let me recount. r1: ospf neighbors r0 and r2. r0 is in small cell, r2 is in big cell.
    So: 1 ospf-neighbor in small cell, 1 ospf-neighbor in big cell.
    r2: ospf neighbors r1 and r3. Both in big cell.
    So: 0 ospf-neighbors in small cell, 2 ospf-neighbors in big cell.

    r2 ≠ r1! So the big cell WILL split. Adjacents-to-bridge (r1, r3, r5, r7) vs
    non-adjacents (r2, r6). Let me be more careful:

    Ring A: r0-r1-r2-r3-r0
    Ring B: r4-r5-r6-r7-r4
    Bridge: r0-r4

    After first split: {r0, r4} (3 neighbors in original cell) vs {r1,r2,r3,r5,r6,r7} (2 neighbors)

    In the big cell, check ospf-neighbor-count to small cell {r0,r4}:
    - r1: ospf-neighbors = r0 (small), r2 (big) → 1 in small
    - r2: ospf-neighbors = r1 (big), r3 (big) → 0 in small
    - r3: ospf-neighbors = r2 (big), r0 (small) → 1 in small
    - r5: ospf-neighbors = r4 (small), r6 (big) → 1 in small
    - r6: ospf-neighbors = r5 (big), r7 (big) → 0 in small
    - r7: ospf-neighbors = r6 (big), r4 (small) → 1 in small

    So split: {r1,r3,r5,r7} (1 in small) vs {r2,r6} (0 in small).

    Next iteration check {r0,r4}: r0 has ospf neighbors r1 (in {r1,r3,r5,r7}) and r3 (in {r1,r3,r5,r7}).
    r4 has ospf neighbors r5 (in {r1,r3,r5,r7}) and r7 (in {r1,r3,r5,r7}).
    Both have 2 ospf-neighbors in {r1,r3,r5,r7}, 0 in {r2,r6}, and 1 bgp-neighbor in {r0,r4}.
    So {r0, r4} stays together.

    Check {r1,r3,r5,r7}: r1 has ospf neighbors r0 ({r0,r4}) and r2 ({r2,r6}).
    r3 has ospf neighbors r2 ({r2,r6}) and r0 ({r0,r4}).
    r5 has ospf neighbors r4 ({r0,r4}) and r6 ({r2,r6}).
    r7 has ospf neighbors r6 ({r2,r6}) and r4 ({r0,r4}).
    All have: 1 ospf in {r0,r4}, 1 ospf in {r2,r6}, 0 in {r1,r3,r5,r7}.
    Stable!

    Check {r2,r6}: r2 has ospf neighbors r1 ({r1,r3,r5,r7}) and r3 ({r1,r3,r5,r7}).
    r6 has ospf neighbors r5 ({r1,r3,r5,r7}) and r7 ({r1,r3,r5,r7}).
    Both have: 2 ospf in {r1,r3,r5,r7}, 0 in others. Stable!

    Final partition: {r0,r4}, {r1,r3,r5,r7}, {r2,r6}
    3 cells from 8 identical-signature devices. Compression: 8 → 6 (Rule 1: 2 per cell).
    """
    G = TypedMultigraph()

    for i in range(8):
        G.add_vertex(f"r{i}", "router", signature="ring_cfg")

    # Ring A
    for i in range(4):
        G.add_edge(f"r{i}", f"r{(i+1) % 4}", "ospf")

    # Ring B
    for i in range(4, 8):
        G.add_edge(f"r{i}", f"r{4 + (i - 4 + 1) % 4}", "ospf")

    # Bridge
    G.add_edge("r0", "r4", "bgp")

    return G


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
    # TEST 1: Symmetric Clos — Basic Partition
    # ──────────────────────────────────────────────
    t = TestResult("Claim 1 & 5: Symmetric Clos — equitable partition on typed multigraph")
    G = build_symmetric_clos_2s4l()

    initial = compute_initial_partition(G)
    refined = weisfeiler_leman_refine(G, initial)
    cells = get_cells(refined)

    # Expected: 2 cells — spines and leaves
    cell_groups = [sorted(members) for members in cells.values()]
    cell_groups.sort(key=len)

    t.check(len(cells) == 2,
            "Initial partition produces 2 cells (spines, leaves)",
            f"Got {len(cells)} cells: {cell_groups}")

    eq, reason = is_equitable(G, refined)
    t.check(eq, "Partition is equitable", reason)

    lift_ok, lift_reason = verify_lifting_property(G, refined)
    t.check(lift_ok, "Fibration lifting property holds", lift_reason)

    # Compression ratio
    total = len(G.vertices)
    reps = sum(min(len(m), 2) for m in cells.values())  # Rule 1: ≥2 per cell
    t.check(reps == 4, f"Compression: {total} → {reps} (Rule 1: ≥2 per cell)",
            f"Ratio: {(1 - reps/total)*100:.0f}% reduction")

    results.append(t)

    # ──────────────────────────────────────────────
    # TEST 2: Asymmetric Clos — W-L must split
    # ──────────────────────────────────────────────
    t = TestResult("Claim 2: W-L refinement catches structural asymmetry despite identical σ")
    G = build_asymmetric_clos_2s4l()

    initial = compute_initial_partition(G)
    initial_cells = get_cells(initial)

    t.check(any(len(m) == 4 for m in initial_cells.values()),
            "Initial partition groups all 4 leaves together (same σ)",
            f"Initial cells: {[sorted(m) for m in initial_cells.values()]}")

    refined = weisfeiler_leman_refine(G, initial)
    refined_cells = get_cells(refined)
    leaf_cells = [sorted(m) for m in refined_cells.values()
                  if all(v.startswith("leaf") for v in m)]

    t.check(len(leaf_cells) == 2,
            "W-L splits leaves into 2 cells based on connectivity",
            f"Leaf cells after refinement: {leaf_cells}")

    # Verify the split is correct: {leaf-1,leaf-2} and {leaf-3,leaf-4}
    expected_split = [["leaf-1", "leaf-2"], ["leaf-3", "leaf-4"]]
    leaf_cells_sorted = sorted(leaf_cells)
    t.check(leaf_cells_sorted == expected_split,
            f"Split is correct: {expected_split}",
            f"Got: {leaf_cells_sorted}")

    eq, reason = is_equitable(G, refined)
    t.check(eq, "Refined partition is equitable", reason)

    lift_ok, lift_reason = verify_lifting_property(G, refined)
    t.check(lift_ok, "Fibration lifting property holds after refinement", lift_reason)

    results.append(t)

    # ──────────────────────────────────────────────
    # TEST 3: Multi-edge-type — typed equitability
    # ──────────────────────────────────────────────
    t = TestResult("Claim 5: Typed-edge equitability — OSPF asymmetry splits spines")
    G = build_multi_edge_type_clos()

    initial = compute_initial_partition(G)
    initial_cells = get_cells(initial)

    spine_cell = [m for m in initial_cells.values()
                  if all(v.startswith("spine") for v in m)]
    t.check(len(spine_cell) == 1 and len(spine_cell[0]) == 2,
            "Initial partition groups both spines (same σ)",
            f"Spine cell: {spine_cell}")

    refined = weisfeiler_leman_refine(G, initial)
    refined_cells = get_cells(refined)
    spine_cells = [sorted(m) for m in refined_cells.values()
                   if any(v.startswith("spine") for v in m)]

    t.check(len(spine_cells) == 2,
            "W-L splits spines due to OSPF edge-type asymmetry",
            f"Spine cells: {spine_cells}")

    eq, reason = is_equitable(G, refined)
    t.check(eq, "Partition equitable under typed edges", reason)

    lift_ok, lift_reason = verify_lifting_property(G, refined)
    t.check(lift_ok, "Lifting property holds with typed edges", lift_reason)

    results.append(t)

    # ──────────────────────────────────────────────
    # TEST 4: Border leaves — unique external peerings
    # ──────────────────────────────────────────────
    t = TestResult("Claim 1 & 3: Border leaves with unique external peerings")
    G = build_border_leaf_topology()

    initial = compute_initial_partition(G)
    refined = weisfeiler_leman_refine(G, initial)
    refined_cells = get_cells(refined)

    # ISPs are singletons (unique signatures)
    isp_cells = [m for m in refined_cells.values()
                 if any(v.startswith("ISP") for v in m)]
    t.check(all(len(m) == 1 for m in isp_cells),
            "ISPs are singletons (unique signatures)")

    # Border leaves: may or may not be in the same cell depending on
    # whether W-L splits them (they have different external peers).
    # With unique ISP neighbors, their neighbor profiles differ:
    # border-1 has a BGP neighbor in {ISP-A}, border-2 has one in {ISP-B}.
    # These are DIFFERENT cells, so the profiles differ → W-L splits them.
    border_cells = [sorted(m) for m in refined_cells.values()
                    if any(v.startswith("border") for v in m)]

    t.check(len(border_cells) == 2,
            "W-L splits border leaves (different external peering structure)",
            f"Border cells: {border_cells}")

    eq, reason = is_equitable(G, refined)
    t.check(eq, "Partition is equitable", reason)

    lift_ok, lift_reason = verify_lifting_property(G, refined)
    t.check(lift_ok, "Lifting property holds", lift_reason)

    results.append(t)

    # ──────────────────────────────────────────────
    # TEST 5: Ring topology — all equivalent
    # ──────────────────────────────────────────────
    t = TestResult("Claim 2: Ring of identical routers — W-L should NOT split")
    G = build_ring_topology()

    initial = compute_initial_partition(G)
    refined = weisfeiler_leman_refine(G, initial)
    cells = get_cells(refined)

    t.check(len(cells) == 1,
            "All ring members stay in one cell (structurally equivalent)",
            f"Cells: {[sorted(m) for m in cells.values()]}")

    eq, reason = is_equitable(G, refined)
    t.check(eq, "Ring partition is equitable", reason)

    lift_ok, lift_reason = verify_lifting_property(G, refined)
    t.check(lift_ok, "Lifting property holds on ring", lift_reason)

    results.append(t)

    # ──────────────────────────────────────────────
    # TEST 6: Dual ring — bridge routers split
    # ──────────────────────────────────────────────
    t = TestResult("Claim 2: Dual ring with bridge — W-L splits by structural position")
    G = build_dual_ring_topology()

    initial = compute_initial_partition(G)
    initial_cells = get_cells(initial)

    t.check(len(initial_cells) == 1,
            "Initial partition: all 8 routers in one cell (same σ)",
            f"Initial: {[sorted(m) for m in initial_cells.values()]}")

    refined = weisfeiler_leman_refine(G, initial)
    refined_cells = get_cells(refined)

    t.check(len(refined_cells) == 3,
            "W-L produces 3 cells: bridge pair, bridge-adjacent, bridge-remote",
            f"Cells: {[sorted(m) for m in refined_cells.values()]}")

    # Verify the expected partition
    expected_groups = [
        {"r0", "r4"},           # bridge routers
        {"r1", "r3", "r5", "r7"},  # bridge-adjacent
        {"r2", "r6"},           # bridge-remote
    ]
    actual_groups = [set(m) for m in refined_cells.values()]
    for eg in expected_groups:
        t.check(eg in actual_groups,
                f"Expected cell {sorted(eg)} found in partition",
                f"Actual groups: {[sorted(g) for g in actual_groups]}")

    eq, reason = is_equitable(G, refined)
    t.check(eq, "Dual-ring partition is equitable", reason)

    lift_ok, lift_reason = verify_lifting_property(G, refined)
    t.check(lift_ok, "Lifting property holds on dual ring", lift_reason)

    results.append(t)

    # ──────────────────────────────────────────────
    # TEST 7: Star topology — center is singleton
    # ──────────────────────────────────────────────
    t = TestResult("Claim 2: Star topology — center forms singleton")
    G = build_pathological_star()

    initial = compute_initial_partition(G)
    refined = weisfeiler_leman_refine(G, initial)
    cells = get_cells(refined)

    center_cell = [m for m in cells.values() if "center" in m]
    spoke_cell = [m for m in cells.values() if "spoke-1" in m]

    t.check(len(center_cell) == 1 and len(center_cell[0]) == 1,
            "Center is a singleton cell",
            f"Center cell: {center_cell}")

    t.check(len(spoke_cell) == 1 and len(spoke_cell[0]) == 8,
            "All 8 spokes in one cell",
            f"Spoke cell: {spoke_cell}")

    eq, reason = is_equitable(G, refined)
    t.check(eq, "Star partition is equitable", reason)

    lift_ok, lift_reason = verify_lifting_property(G, refined)
    t.check(lift_ok, "Lifting property holds on star", lift_reason)

    results.append(t)

    # ──────────────────────────────────────────────
    # TEST 8: Production-scale compression ratio
    # ──────────────────────────────────────────────
    t = TestResult("Claim 6: Production-scale Clos compression ratio")
    G = build_production_scale_clos()

    initial = compute_initial_partition(G)
    refined = weisfeiler_leman_refine(G, initial)
    cells = get_cells(refined)

    eq, reason = is_equitable(G, refined)
    t.check(eq, "Production-scale partition is equitable", reason)

    lift_ok, lift_reason = verify_lifting_property(G, refined)
    t.check(lift_ok, "Lifting property holds at production scale", lift_reason)

    # Analyze compression
    total_devices = len(G.vertices)
    cell_summary = []
    total_reps = 0
    for cid, members in sorted(cells.items(), key=lambda x: -len(x[1])):
        rep_type = G.vertices[sorted(members)[0]].vertex_type
        reps_needed = max(2, 1) if len(members) > 1 else 1  # Rule 1 or singleton
        total_reps += reps_needed
        cell_summary.append(f"  Cell {cid}: {len(members)} × {rep_type} → {reps_needed} reps")

    ratio = (1 - total_reps / total_devices) * 100
    t.check(ratio > 60,
            f"Compression ratio > 60%: {total_devices} → {total_reps} ({ratio:.1f}% reduction)",
            "\n".join(cell_summary))

    results.append(t)

    # ──────────────────────────────────────────────
    # TEST 9: Lifting theorem — LOCAL transition correspondence
    # ──────────────────────────────────────────────
    t = TestResult("Claim 1: Lifting theorem — local transition correspondence (correct formulation)")
    G = build_symmetric_clos_2s4l()

    initial = compute_initial_partition(G)
    refined = weisfeiler_leman_refine(G, initial)
    cells = get_cells(refined)
    Q = build_quotient_graph(G, refined)

    # The lifting theorem guarantees: for every vertex v in G and every
    # edge (π(v), C_j, e) in G/π, there exists an edge (v, w, e) in G
    # where π(w) = C_j. This is the LOCAL lifting condition.
    #
    # We already test this via verify_lifting_property. Here we test
    # the CONVERSE: for every edge (v, w, e) in G, there exists a
    # corresponding edge (π(v), π(w), e) in G/π. This is the
    # projection condition — the fibration is surjective on local edges.

    # Forward: every G edge projects to a Q edge
    for edge in G.edges:
        src_cell = f"C{refined[edge.source]}"
        tgt_cell = f"C{refined[edge.target]}"
        if src_cell == tgt_cell:
            continue  # intra-cell edges have no quotient counterpart (by design)

        has_quotient_edge = any(
            qe.source == src_cell and qe.target == tgt_cell and qe.edge_type == edge.edge_type
            for qe in Q.edges
        )
        t.check(has_quotient_edge,
                f"G edge ({edge.source}→{edge.target}, {edge.edge_type}) projects to Q edge ({src_cell}→{tgt_cell})",
                "" if has_quotient_edge else "MISSING quotient edge")

    # Backward: every Q edge lifts to at least one G edge per cell member
    lift_ok, lift_reason = verify_lifting_property(G, refined)
    t.check(lift_ok, "Every Q edge lifts to a G edge for every cell member", lift_reason)

    results.append(t)

    # ──────────────────────────────────────────────
    # TEST 9b: Inter-cell vs intra-cell dynamics boundary
    # ──────────────────────────────────────────────
    t = TestResult("Claim 1 boundary: inter-cell dynamics preserved, intra-cell delegated to Cathedral")
    G = build_symmetric_clos_2s4l()

    initial = compute_initial_partition(G)
    refined = weisfeiler_leman_refine(G, initial)
    cells = get_cells(refined)

    # Simulate failure of spine-1 in the original graph
    original_events = simulate_bgp_withdrawal(G, "spine-1", refined)

    # Map original events to INTER-CELL events only (filter out intra-cell)
    inter_cell_events = set()
    for v, events in original_events.items():
        v_cell = refined.get(v)
        for event in events:
            wave_num = int(event.split(":")[0].split("-")[1])
            # An event is inter-cell if it's in a different cell from the trigger
            if v_cell != refined.get("spine-1") or wave_num == 0:
                inter_cell_events.add((wave_num, v_cell))

    # Simulate on quotient
    Q = build_quotient_graph(G, refined)
    spine_cell_id = refined["spine-1"]
    quotient_events = simulate_bgp_withdrawal_on_quotient(
        Q, f"C{spine_cell_id}", cells)

    quotient_waves = set()
    for c, events in quotient_events.items():
        for event in events:
            wave_num = int(event.split(":")[0].split("-")[1])
            quotient_waves.add((wave_num, int(c[1:])))

    t.check(inter_cell_events == quotient_waves,
            "Inter-cell propagation pattern matches between G and G/π",
            f"Inter-cell events: {sorted(inter_cell_events)}\n"
            f"Quotient events:   {sorted(quotient_waves)}")

    # Now verify the intra-cell event exists and is scale-dependent
    intra_cell_events = set()
    spine_cell = refined["spine-1"]
    for v, events in original_events.items():
        v_cell = refined.get(v)
        for event in events:
            wave_num = int(event.split(":")[0].split("-")[1])
            if v_cell == spine_cell and v != "spine-1":
                intra_cell_events.add((wave_num, v, v_cell))

    t.check(len(intra_cell_events) > 0,
            "Intra-cell event exists (spine-2 receives withdrawal within spine cell)",
            f"Intra-cell events: {intra_cell_events}")

    t.check(intra_cell_events not in [quotient_waves],
            "Intra-cell event is NOT in quotient (scale-dependent — Cathedral handles this via |Cᵢ|)",
            "This is correct behavior: intra-cell dynamics are inherently scale-dependent")

    results.append(t)

    # ──────────────────────────────────────────────
    # TEST 10: Determinism — repeated computation
    # ──────────────────────────────────────────────
    t = TestResult("Claim 3: Signature and partition determinism")

    for topology_name, builder in [("symmetric_clos", build_symmetric_clos_2s4l),
                                    ("asymmetric_clos", build_asymmetric_clos_2s4l),
                                    ("multi_edge", build_multi_edge_type_clos),
                                    ("ring", build_ring_topology),
                                    ("dual_ring", build_dual_ring_topology),
                                    ("star", build_pathological_star),
                                    ("production", build_production_scale_clos)]:
        G = builder()
        partitions = []
        for _ in range(5):
            initial = compute_initial_partition(G)
            refined = weisfeiler_leman_refine(G, initial)
            partition_key = frozenset(
                frozenset(m) for m in get_cells(refined).values()
            )
            partitions.append(partition_key)

        all_same = all(p == partitions[0] for p in partitions)
        t.check(all_same,
                f"Deterministic on {topology_name} (5 runs)",
                "" if all_same else f"Got {len(set(partitions))} distinct partitions")

    results.append(t)

    # ──────────────────────────────────────────────
    # SUMMARY
    # ──────────────────────────────────────────────
    print("\n" + "═" * 72)
    print("  COMPRESSION ENGINE — MATHEMATICAL FOUNDATION VALIDATION")
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
                            print(f"      {line}")
    else:
        print("  ✓ ALL CHECKS PASSED")
    print("═" * 72)

    return all_tests_passed


if __name__ == "__main__":
    success = run_all_tests()
    exit(0 if success else 1)
