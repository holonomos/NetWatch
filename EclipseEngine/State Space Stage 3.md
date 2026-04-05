Version - 4.3
# Stage 3 — Evaluator: Predicate Evaluation and M_verified Construction

> The evaluator is a two-pass model-checker over finite structures. Pass 1 evaluates each predicate independently against the Batfish snapshot. Pass 2 propagates semantic dependencies to correct fidelity tags before writing M_verified. The output is a pre-qualified topology database where every element carries a provably correct fidelity tag.
>
> **This stage is fully mechanizable.** No human judgment in the evaluation loop. The judgment was exercised in Stage 1 (domain definition) and Stage 2 (predicate specification). Stage 3 executes.

---

## Version Pin

Per Stage 2 authoritative artifact identifiers:

| Dependency | Version | Artifact |
|------------|---------|----------|
| Batfish Docker image | 2025.07.07.2423 | commit 7a0efda |
| pybatfish | 2025.7.7.2423 | pybatfish-2025.7.7.2423-py3-none-any.whl |
| FRR | 10.6.0 | frr-10.6.0.tar.gz |

- **Stage 1 reference:** `State_Space_Stage_1.md`, post-filtration universal set
- **Stage 2 reference:** `State_Space_Stage_2.md`, 97 predicates across 9 categories
- **Dependency policy:** All three dependencies are vendored in the project directory and version-locked to the exact artifacts above. A version change to any dependency invalidates all 97 predicates and requires full re-evaluation. Version upgrades are release events, not maintenance.

---

## Position in Pipeline

```
Customer configs
    │
    ▼
Batfish parse ──► M (finite relational structure)
    │
    ▼
Stage 3, Pass 1 ──► raw partition {C, K, R}⁹⁷
    │
    ▼
Stage 3, Pass 2 ──► corrected partition {C, K, R}⁹⁷
    │
    ▼
M_verified (topology database with correct fidelity tags)
    │
    ▼
Stage 4 (qualification gate) ──► GREEN / YELLOW / RED + constraint directives
    │
    ▼
Compression Engine
```

---

## Input: The Finite Relational Structure M

M is the Batfish snapshot viewed as a database. Each pybatfish question populates a relation in M:

| Relation | Source | Domain |
|----------|--------|--------|
| R_bgpPeers | `bgpPeerConfiguration()` | Per-peer BGP config (local/remote AS, IP, AFs, policies) |
| R_bgpStatus | `bgpSessionStatus()` | Per-peer session state |
| R_bgpCompat | `bgpSessionCompatibility()` | Per-peer compatibility assessment |
| R_bgpEdges | `bgpEdges()` | BGP edge set |
| R_bgpProcess | `bgpProcessConfiguration()` | Per-process BGP config (multipath, tiebreaking) |
| R_bgpRib | `bgpRib()` | BGP RIB (paths, attributes) |
| R_evpnRib | `evpnRib()` | EVPN RIB (route types, RD, RT) |
| R_ospfInterfaces | `ospfInterfaceConfiguration()` | Per-interface OSPF config (area, type, timers) |
| R_ospfProcess | `ospfProcessConfiguration()` | Per-process OSPF config |
| R_ospfArea | `ospfAreaConfiguration()` | Per-area OSPF config (stub, NSSA) |
| R_ospfEdges | `ospfEdges()` | OSPF adjacency set |
| R_ospfCompat | `ospfSessionCompatibility()` | Per-adjacency compatibility |
| R_routes | `routes()` | Converged routing table (all protocols) |
| R_interfaces | `interfaceProperties()` | Per-interface properties (IPs, VLANs, channel-groups, STP) |
| R_named | `namedStructures()` | Named config objects (route-maps, ACLs, community-lists, etc.) |
| R_vxlan | `vxlanVniProperties()` | VNI-to-VLAN-to-VRF mappings |
| R_node | `nodeProperties()` | Per-node properties (hostname, VRFs, vendor) |
| R_parseStatus | `fileParseStatus()` | Per-file parse result |
| R_parseWarnings | `parseWarning()` | Per-file parse warnings |
| R_undefinedRefs | `undefinedReferences()` | Undefined named structure references |
| R_unusedStructs | `unusedStructures()` | Defined but unreferenced named structures |
| R_mlag | `mlagProperties()` | MLAG/vPC configuration |
| R_l1Edges | `layer1Edges()` | Physical topology (supplemental) |
| R_l3Edges | `layer3Edges()` | L3 topology (inferred) |
| R_filterLines | `filterLineReachability()` | ACL line reachability |
| R_f5Vips | `f5BigipVipConfiguration()` | F5 VIP/pool config |

M = (D, R_bgpPeers, R_bgpStatus, ..., R_f5Vips) where D is the set of all devices in the snapshot.

**Gate 0 — Parse completeness.** Before constructing M, verify: ∀ d ∈ D, R_parseStatus(d) ≠ FAILED. Any device with R_parseStatus(d) = FAILED is excluded from D. The evaluator logs excluded devices with their parse failure reason. Devices with R_parseStatus(d) = PARTIALLY_UNRECOGNIZED remain in D — their partial parse status is handled by VD-2.1.02 (Parser Behavior Edge Cases) and FF-1.7.01 (CLI/API Configuration Parsing) during Pass 1 evaluation. This is a pre-condition, not a predicate — it gates entry into the evaluation, not the evaluation itself.

---

## Pass 1: Syntactic Evaluation

### Algorithm

**Input:** M, Σ = {σ₁, ..., σ₉₇} (the Stage 2 predicate set)

**Step 1: Construct the evaluation DAG.**

The evaluation DAG G_eval = (Σ, E_eval) has an edge (σᵢ, σⱼ) when σⱼ's pass/partial/fail conditions explicitly reference σᵢ's outcome. These dependencies are statically defined — they are literal references in the Stage 2 predicate definitions (e.g., "FF-1.4.01 passes if FF-1.2.01 passes").

**Step 2: Topologically sort Σ according to G_eval.**

Produce an evaluation order where every predicate is evaluated after all its evaluation dependencies. G_eval is a DAG (no cycles — verified by the Stage 2 completeness check). The sort is not unique; any valid topological order suffices.

**Step 3: Evaluate each σᵢ in topological order.**

For each σᵢ:

1. **Check evaluation dependencies.** If any dependency σⱼ (where (σⱼ, σᵢ) ∈ E_eval) is in R, apply the pre-decided disposition from Stage 2. Most composite predicates inherit the most restrictive constituent disposition ("follows FF-1.2.02 rejection"). This may short-circuit σᵢ to K or R without evaluating its own conditions.

2. **If not short-circuited, evaluate φᵢ (pass condition) against M.** If M ⊨ φᵢ, classify σᵢ as C.

3. **If M ⊭ φᵢ, evaluate ψᵢ (partial condition).** If M ⊨ ψᵢ, classify σᵢ as K with the constraint annotation from Stage 2's pre-decided disposition.

4. **If M ⊭ ψᵢ, classify σᵢ as R** with the rejection reason from Stage 2's pre-decided disposition.

**Output of Pass 1:** The raw partition P_raw = {C_raw, K_raw, R_raw} over Σ. Each predicate carries its classification and, for K and R, the constraint annotation or rejection reason.

### Evaluation DAG: Complete Edge Set

The following edges are derived from explicit references in Stage 2 predicate definitions. Format: `(dependency → dependent)`.

**Protocol FSM layer:**
- (FF-1.1.04 → FF-1.5.01): BFD failover chain requires BFD extraction
- (FF-1.1.04 → FF-1.9.01): BFD detection time requires BFD timer extraction
- (FF-1.1.04 → PI-4.2.02): BFD-BGP-OSPF hierarchy requires BFD extraction
- (FF-1.1.05 → FF-1.1.06): RSTP follows STP
- (FF-1.1.05 → TE-3.3.08): STP root bridge follows STP extraction
- (FF-1.1.05 → LE-4.4.01): L2-heavy STP follows STP extraction
- (FF-1.1.09 → FF-1.5.05): GR behavior follows GR config extraction
- (FF-1.1.09 → VD-2.1.06): GR vendor edge cases follow GR extraction

**Routing algorithm layer:**
- (FF-1.2.01 → FF-1.4.01): BGP signaling follows BGP best-path
- (FF-1.2.02 → FF-1.4.02): OSPF LSAs follow SPF
- (FF-1.2.02 → TE-3.3.01): IGP cost asymmetry follows SPF

**Convergence layer:**
- (FF-1.5.04 → PI-4.2.01): IGP-BGP NH race requires NHT
- (CV-4.5.01 → PI-4.2.01): IGP-BGP NH race requires NH resolution validation

**Composite predicates (inherit most restrictive constituent):**
- (FF-1.1.01, FF-1.1.02, FF-1.9.01, FF-1.9.02, FF-1.9.03 → FF-1.4.05): Session management
- (FF-1.4.03 → PI-4.2.03): EVPN Type-2/5 interaction follows EVPN extraction
- (FF-1.3.09, FF-1.6.01, FF-1.1.03, FF-1.7.03 → TE-3.3.04 through TE-3.3.07): Topology edge cases
- (FF-1.5.04, CV-4.5.01 → PI-4.2.01): IGP-BGP NH race
- (FF-1.1.04, FF-1.9.01, FF-1.9.02, FF-1.9.03 → PI-4.2.02): Detection hierarchy
- (FF-1.3.09 → PI-4.2.04): VRF RT interaction
- (FF-1.3.06 → PI-4.2.05): Redistribution loops
- (FF-1.1.09, FF-1.1.04 → PI-4.2.06): GR+BFD conflict
- (FF-1.6.01, FF-1.3.01 → PI-4.2.07): ECMP+route-map

**Cross-validation layer:**
- (FF-1.2.01, FF-1.2.02 → CV-4.5.01): BGP NH resolves via IGP
- (FF-1.4.03, FF-1.4.04 → CV-4.5.02): EVPN VTEP reachability
- (FF-1.1.04, FF-1.9.01 → CV-4.5.03): BFD/protocol timer consistency

**Legacy/vendor layer:**
- (VD-2.1.01 → LE-4.4.04): Legacy timers follow vendor timer divergence
- (FF-1.1.02 → VD-2.1.04): OSPF quirks follow OSPF extraction

---

## Pass 2: Semantic Dependency Correction

### The Problem Pass 2 Solves

Pass 1 evaluates each predicate against M independently. But predicates share underlying data. A route-map (FF-1.3.01) references community-lists (FF-1.3.03). If the route-map predicate passes but the community-list predicate is constrained, the route-map's C classification is syntactically valid but semantically misleading — the route-map's match clauses operate on degraded data. If this reaches M_verified uncorrected, the fidelity tag on the route-map field says "confirmed" when it should say "constrained," and the compression engine may use degraded data in behavioral signatures.

Pass 2 resolves this by propagating semantic downgrades before M_verified is constructed.

### Semantic Dependency Graph: Definition

The semantic dependency graph G_sem = (Σ, E_sem) has an edge (σᵢ, σⱼ) when σⱼ's confirmed meaning depends on data that σᵢ validates. Unlike the evaluation DAG, semantic edges represent data-flow dependencies through the Batfish model, not evaluation-order dependencies between predicates.

**Criterion for a semantic edge (σᵢ, σⱼ):** σⱼ's extraction method produces results that reference, consume, or operate on data structures that σᵢ's extraction method validates. If σᵢ is constrained (the data it validates is incomplete), then σⱼ's result — even if its own predicate conditions are satisfied — may be operating on incomplete inputs.

### Semantic Dependency Graph: Complete Edge Set

Each edge is annotated with the data-flow path that creates the dependency. Format: `(data source → data consumer): data path`.

#### Cluster 1: The Route-Map Ecosystem

Route-maps reference named structures. If any referenced structure is degraded, the route-map's confirmed status is semantically hollow.

- **(FF-1.3.02 → FF-1.3.01): `match ip address prefix-list` / `match ip address`**
  Prefix-lists are match targets in route-maps. If prefix-list extraction is constrained (ge/le operators missing), route-map match behavior is uncertain.

- **(FF-1.3.03 → FF-1.3.01): `match community` / `set community`**
  Community-lists are match and set targets. If community extraction is constrained (extended/large communities missing), route-map community operations are operating on incomplete data.

- **(FF-1.3.04 → FF-1.3.01): `match as-path`**
  AS-path ACLs are match targets. If AS-path regex parsing is constrained (vendor regex syntax divergence), route-map AS-path matching is uncertain.

- **(FF-1.3.10 → FF-1.3.01): `match ip address <ACL>`**
  Some route-maps use ACLs as match targets (matching prefix by ACL rather than prefix-list). If ACL extraction is constrained for a vendor, the route-map match clause is degraded.

#### Cluster 2: BGP Best-Path Selection

Best-path selection operates on attributes that are shaped by policies. If the policies are degraded, the best-path result may be coincidentally correct rather than provably correct.

- **(FF-1.3.01 → FF-1.2.01): import/export route-maps shape path attributes**
  BGP peers apply import and export route-maps that modify local-preference, MED, community, AS-path, and next-hop. If route-map evaluation is constrained, the attributes in bgpRib() may not reflect the full policy effect.

- **(FF-1.3.03 → FF-1.2.01): community-based filtering affects path availability**
  Community matching in import policies can reject or accept paths. If community extraction is degraded, a path that should have been filtered may appear in the RIB (or vice versa).

- **(FF-1.3.04 → FF-1.2.01): AS-path filtering affects path availability**
  Same mechanism as community-based filtering but via AS-path ACLs.

- **(VD-2.1.03 → FF-1.2.01): tiebreaking flags affect path selection**
  `deterministic-med`, `always-compare-med`, and `bestpath-compare-routerid` change the best-path algorithm's behavior. If these flags are constrained, the selected path in bgpRib() may differ from production.

- **(VD-2.1.05 → FF-1.2.01): attribute handling edge cases affect path selection**
  MED cross-AS comparison and other vendor-specific attribute behaviors change path selection in specific scenarios.

#### Cluster 3: EVPN Overlay

EVPN route types carry community attributes (route-targets) that govern VRF import/export. If community or RT extraction is degraded, EVPN route filtering is uncertain.

- **(FF-1.3.03 → FF-1.3.09): extended communities carry route-target values**
  Route-targets are a subtype of extended communities (type 0x0002 for RT). RT import/export configuration (FF-1.3.09) specifies values that are encoded as extended community attributes. If extended community extraction is constrained for a vendor, RT values derived from community attributes may be incomplete.

- **(FF-1.3.03 → FF-1.4.03): extended communities carry route-targets on EVPN routes**
  EVPN routes use extended communities (route-target type) for VRF import/export filtering. If extended community extraction is constrained, RT-based filtering in evpnRib() may be operating on incomplete data.

- **(FF-1.3.09 → FF-1.4.03): RT import/export config governs EVPN route acceptance**
  Route-target configuration determines which EVPN routes are imported into which VRFs. If RT extraction is constrained, EVPN route distribution may be incorrectly modeled.

- **(FF-1.4.04 → FF-1.4.03): VXLAN encap/decap underlies EVPN data plane**
  EVPN routes are meaningless without the VXLAN tunnel that carries the traffic. If VXLAN extraction is constrained, EVPN route validation is incomplete.

#### Cluster 4: Redistribution and Policy Chains

Redistribution uses route-maps and AD comparison. If either is degraded, redistribution behavior is uncertain.

- **(FF-1.3.01 → FF-1.3.06): redistribution route-maps filter/transform redistributed routes**
  Redistribution statements reference route-maps that control which routes are redistributed and with what attributes.

- **(FF-1.2.03 → FF-1.3.06): AD comparison governs route selection after redistribution**
  When a redistributed route competes with a directly-learned route, AD determines the winner. If AD is constrained, the winning route may differ.

- **(FF-1.3.01 → FF-1.3.07): suppress-map and attribute-map in aggregation**
  BGP aggregation references route-maps for suppress and attribute control. If route-map extraction is constrained, aggregation behavior may be affected.

- **(FF-1.3.01 → FF-1.3.08): conditional default origination route-maps**
  `default-originate route-map CHECK` depends on route-map evaluation. If route-map is constrained, the condition evaluation is uncertain.

#### Cluster 4a: VRF Route Leaking

VRF isolation and route leaking depend on RT configuration and optionally on route-maps.

- **(FF-1.3.09 → FF-1.7.03): RT import/export defines VRF membership and route leaking scope**
  VRF route distribution uses RT values to determine which routes are imported into which VRFs. If RT extraction is constrained, VRF route distribution may be incorrectly scoped.

- **(FF-1.3.01 → FF-1.7.03): VRF route-leaking may use route-maps as filters**
  Route-leaking between VRFs can reference route-maps that control which routes are leaked and with what attributes. If route-map extraction is constrained, route-leaking policy is uncertain.

#### Cluster 5: Failover and Timer Relationships

Failover behavior depends on timer values and protocol bindings. If timer extraction is degraded, failover timing predictions are degraded.

- **(FF-1.9.01 → FF-1.5.01): BFD detection time drives failover triggering**
  The failover chain's timing characteristics depend on the BFD detection time formula. If BFD timers are FRR defaults (not production-extracted), the failover timing prediction is approximate.

- **(FF-1.9.02 → FF-1.5.02): OSPF dead interval affects convergence sequencing**
  Convergence sequence depends on which protocol detects failure first. Timer values determine detection order.

- **(FF-1.9.03 → FF-1.5.02): BGP hold time affects convergence sequencing**
  Same as above for BGP.

- **(VD-2.1.01 → FF-1.5.02): vendor default timer divergence affects convergence prediction**
  If timers are vendor-defaulted (not explicitly configured), the convergence prediction uses FRR defaults which may differ from production defaults.

#### Cluster 6: Cross-Validation Integrity

Cross-validation predicates check consistency between multiple extraction sources. If any source is degraded, the cross-validation result is weakened.

- **(FF-1.2.01 → CV-4.5.01): BGP routes provide the next-hops being validated**
  The cross-validation checks that BGP next-hops resolve via IGP. If BGP RIB data is constrained, the set of next-hops being checked is incomplete.

- **(FF-1.2.02 → CV-4.5.01): IGP routes provide the resolution targets**
  Same validation — IGP side. If OSPF route extraction is constrained, resolution may appear to fail when it actually succeeds (or vice versa).

- **(FF-1.4.03, FF-1.4.04 → CV-4.5.02): EVPN/VXLAN data provides VTEP set**
  VTEP reachability validation depends on correct VTEP identification. If EVPN or VXLAN extraction is constrained, the VTEP set may be incomplete.

- **(FF-1.1.04, FF-1.9.01 → CV-4.5.03): BFD data provides detection time for comparison**
  Timer consistency check depends on BFD timer accuracy. If timers are FRR defaults, the comparison is valid but uses approximate values.

#### Cluster 7: Parser Quality Propagation

Parse quality affects every predicate that reads from namedStructures() for the affected vendor.

- **(VD-2.1.02 → ALL predicates sourcing from R_named for affected device/vendor)**
  If `parseWarning()` returns warnings in routing-critical sections for a device, every predicate that extracts data from `namedStructures()` for that device has a weakened foundation. The semantic edges are: VD-2.1.02 → {FF-1.3.01, FF-1.3.02, FF-1.3.03, FF-1.3.04, FF-1.3.05, FF-1.3.06, FF-1.3.07, FF-1.3.08, FF-1.3.09, FF-1.3.10, FF-1.3.11, FF-1.1.04, FF-1.1.09, FF-1.7.03, FF-1.9.01, FF-1.9.02, FF-1.9.03, VD-2.1.01, VD-2.1.03, VD-2.1.04, PM-2.3.01} — scoped to the devices with parse warnings. (21 predicates total.)

### Downgrade Propagation Rules

For each predicate σⱼ classified as C in P_raw, examine its semantic dependency set S(σⱼ) = { σᵢ | (σᵢ, σⱼ) ∈ E_sem }.

**Rule 1 — Rejected dependency forces downgrade.**
If ∃ σᵢ ∈ S(σⱼ) such that σᵢ ∈ R_raw:
- If the semantic dependency is **strong** (σⱼ's meaning requires σᵢ's data — e.g., a route-map's match clause references a community-list), downgrade σⱼ from C to R.
- If the semantic dependency is **weak** (σⱼ's meaning benefits from but does not require σᵢ's data — e.g., convergence sequencing benefits from timer precision), downgrade σⱼ from C to K.

**Rule 2 — Constrained dependency forces downgrade to constrained.**
If ∃ σᵢ ∈ S(σⱼ) such that σᵢ ∈ K_raw:
- Downgrade σⱼ from C to K with a semantic degradation annotation.

**Rule 3 — Annotation chaining.**
The semantic degradation annotation names the full dependency chain: "σⱼ independently confirmed. Downgraded to constrained because semantic dependency σᵢ is [constrained|rejected]: [σᵢ's constraint annotation]. Data path: [the data-flow path from E_sem]."

**Rule 4 — Transitivity.**
Semantic dependencies are transitive. If FF-1.3.03 (communities) is K, then FF-1.3.01 (route-maps) is downgraded to K, then FF-1.2.01 (best-path) is downgraded to K (because FF-1.3.01 is now K and FF-1.2.01 semantically depends on FF-1.3.01). The downgrade propagates through the graph.

**Implementation:** Process G_sem in reverse topological order (leaves first, roots last). At each node, check if any semantic dependency's corrected classification warrants a downgrade. This ensures transitivity is handled in a single pass through the graph.

**Rule 5 — No upgrades.**
Pass 2 can only downgrade classifications. A predicate in K_raw stays in K or moves to R. A predicate in R_raw stays in R. A predicate in C_raw stays in C or moves to K or R. No predicate ever improves.

**Rule 6 — Scope narrowing.**
Semantic downgrades inherit the scope of the triggering constraint. If FF-1.3.03 is constrained only for FortiOS devices (extended communities not parsed), then FF-1.3.01's semantic downgrade applies only to route-maps on FortiOS devices that reference community-lists. Route-maps on Cisco devices whose community-list predicates are confirmed are not downgraded. The downgrade is per-device and per-field, not blanket.

### Strong vs. Weak Semantic Dependencies

Each edge in E_sem is classified as strong or weak:

| Edge | Classification | Rationale |
|------|---------------|-----------|
| FF-1.3.02 → FF-1.3.01 | **Strong** | Route-map match clause directly references prefix-list. Without correct prefix-list, match result is unknown. |
| FF-1.3.03 → FF-1.3.01 | **Strong** | Route-map match/set clause directly references community-list. |
| FF-1.3.04 → FF-1.3.01 | **Strong** | Route-map match clause directly references AS-path ACL. |
| FF-1.3.10 → FF-1.3.01 | **Strong** | Route-map match clause directly references ACL. |
| FF-1.3.01 → FF-1.2.01 | **Strong** | Import/export policies shape the attributes that best-path selection operates on. |
| FF-1.3.03 → FF-1.2.01 | **Strong** | Community-based import filtering determines which paths are candidates. |
| FF-1.3.04 → FF-1.2.01 | **Strong** | AS-path filtering determines which paths are candidates. |
| VD-2.1.03 → FF-1.2.01 | **Weak** | Tiebreaking flags affect selection only in rare equal-through-all-RFC-steps scenarios. |
| VD-2.1.05 → FF-1.2.01 | **Weak** | Attribute handling edge cases are rare. |
| FF-1.3.03 → FF-1.4.03 | **Strong** | Extended communities carry route-targets governing EVPN route acceptance. |
| FF-1.3.03 → FF-1.3.09 | **Strong** | Route-targets are a subtype of extended communities. If extended community extraction is constrained, RT values are also constrained. |
| FF-1.3.09 → FF-1.4.03 | **Strong** | RT config directly governs which EVPN routes populate which VRFs. |
| FF-1.4.04 → FF-1.4.03 | **Weak** | VXLAN is the transport, not the control plane. EVPN route validation doesn't require VXLAN validation. |
| FF-1.3.01 → FF-1.3.06 | **Strong** | Redistribution route-maps control what gets redistributed. |
| FF-1.2.03 → FF-1.3.06 | **Weak** | AD affects route selection after redistribution, not the redistribution itself. |
| FF-1.3.01 → FF-1.3.07 | **Weak** | Suppress-maps are optional refinements to aggregation. |
| FF-1.3.01 → FF-1.3.08 | **Weak** | Conditional default origination route-maps are refinements. |
| FF-1.3.09 → FF-1.7.03 | **Strong** | RT import/export defines VRF membership and route distribution scope. |
| FF-1.3.01 → FF-1.7.03 | **Weak** | VRF route-leaking route-maps are optional policy refinements. |
| FF-1.9.01 → FF-1.5.01 | **Weak** | Timer values affect timing predictions, not causal correctness. |
| FF-1.9.02 → FF-1.5.02 | **Weak** | Same — timing precision, not causal ordering. |
| FF-1.9.03 → FF-1.5.02 | **Weak** | Same. |
| VD-2.1.01 → FF-1.5.02 | **Weak** | Default timer divergence affects timing prediction accuracy. |
| FF-1.2.01 → CV-4.5.01 | **Strong** | BGP routes are one side of the cross-validation. |
| FF-1.2.02 → CV-4.5.01 | **Strong** | IGP routes are the other side. |
| FF-1.4.03 → CV-4.5.02 | **Strong** | EVPN provides the VTEP set. |
| FF-1.4.04 → CV-4.5.02 | **Strong** | VXLAN provides the tunnel endpoints. |
| FF-1.1.04 → CV-4.5.03 | **Weak** | BFD timers may be FRR defaults — comparison still valid. |
| FF-1.9.01 → CV-4.5.03 | **Weak** | Same. |
| VD-2.1.02 → namedStructures consumers | **Strong** (per-device) | Parse warnings in routing-critical sections mean all namedStructures data for that device is suspect. |

### Pass 2 Algorithm

**Input:** P_raw from Pass 1, G_sem (semantic dependency graph with strong/weak annotations)

**Step 1:** Initialize P_corrected = P_raw (copy).

**Step 2:** Compute a reverse topological order of G_sem. (Process predicates that have no outgoing semantic edges first, then predicates whose consumers have already been processed.)

**Step 3:** For each σⱼ in forward topological order of G_sem (sources first, consumers last):

If σⱼ ∈ C in P_corrected:
  - Let S_R = { σᵢ ∈ S(σⱼ) | σᵢ ∈ R in P_corrected, (σᵢ, σⱼ) is strong }
  - Let S_R_weak = { σᵢ ∈ S(σⱼ) | σᵢ ∈ R in P_corrected, (σᵢ, σⱼ) is weak }
  - Let S_K = { σᵢ ∈ S(σⱼ) | σᵢ ∈ K in P_corrected }
  - If |S_R| > 0: downgrade σⱼ to R. Annotation: "Rejected due to strong semantic dependency [list S_R members] being rejected."
  - Else if |S_R_weak| > 0: downgrade σⱼ to K. Annotation: "Constrained due to weak semantic dependency [list S_R_weak members] being rejected: [dependency chain]."
  - Else if |S_K| > 0: downgrade σⱼ to K. Annotation: "Independently confirmed. Downgraded to constrained because semantic dependency [list S_K members] is constrained: [each member's constraint annotation]. Data path: [E_sem edge annotation]."

If σⱼ ∈ K in P_corrected:
  - Let S_R = { σᵢ ∈ S(σⱼ) | σᵢ ∈ R in P_corrected, (σᵢ, σⱼ) is strong }
  - If |S_R| > 0: downgrade σⱼ to R.
  - Else: σⱼ remains K. Append any additional semantic constraint annotations from degraded dependencies to the existing constraint annotation.

If σⱼ ∈ R in P_corrected: no change.

**Step 4:** Apply scope narrowing (Rule 6). For each downgrade, determine which devices are affected by tracing the triggering constraint's device scope through the semantic dependency edge. Restrict the downgrade to the affected device set.

**Output of Pass 2:** P_corrected = {C_corrected, K_corrected, R_corrected} over Σ. Every predicate's classification accounts for semantic compounding. Every K and R entry carries the complete annotation chain.

### Correctness Properties of Pass 2

**Monotonicity:** No predicate's classification improves. Proof: the algorithm only downgrades (C→K, C→R, K→R). The only operations are set membership changes in the downward direction on the {C > K > R} ordering.

**Idempotence:** Running Pass 2 twice on the same P_raw produces the same P_corrected. Proof: after one pass, all semantic downgrades have been applied. A second pass finds no C-classified predicates with degraded semantic dependencies (they were all downgraded in the first pass).

**Soundness:** Every fidelity tag in M_verified is at least as conservative as the true fidelity status. Proof: downgrades are only applied when a data dependency is provably degraded. No downgrade is speculative. The worst case is over-conservatism (a predicate is tagged K when it could have been C), which produces more singletons in the compression engine, not wrong equivalence classes.

---

## M_verified Construction

### Structure

M_verified extends M with a fidelity tag on every element of every relation.

For each tuple t in each relation R_x of M, M_verified attaches:

```
tag(t, field) = {
    classification:  C | K | R,
    source_predicate: σᵢ (the predicate that governs this field),
    annotation:      string (empty for C; constraint description for K; rejection reason for R),
    semantic_chain:  [σ₁ → σ₂ → ... → σᵢ] (empty if no semantic downgrade; 
                     the chain of semantic dependencies that caused the downgrade),
    device_scope:    set of device names this tag applies to,
    field_scope:     set of field names within the relation this tag applies to
}
```

### Construction Rules

**Rule M1 — Direct mapping.** Each predicate σᵢ in Stage 2 specifies which Batfish relations and fields it validates. The predicate's corrected classification (from P_corrected) becomes the fidelity tag on those fields for the devices in scope.

Predicate-to-field mappings (the complete set):

| Predicate | Relations | Fields |
|-----------|-----------|--------|
| FF-1.1.01 | R_bgpPeers, R_bgpStatus, R_bgpCompat, R_bgpEdges | All columns |
| FF-1.1.02 | R_ospfEdges, R_ospfCompat | All columns |
| FF-1.1.03 | R_ospfInterfaces | Network_Type, OSPF_Enabled, Passive |
| FF-1.1.04 | R_named (BFD structures) | BFD enablement, intervals, multiplier |
| FF-1.1.05-06 | R_named (STP structures), R_interfaces | Spanning_Tree_Portfast |
| FF-1.1.07 | R_interfaces | Channel_Group, Channel_Group_Members |
| FF-1.1.08 | R_l1Edges, R_l3Edges | All columns |
| FF-1.1.09 | R_named (GR structures) | GR enablement, timers |
| FF-1.2.01 | R_bgpRib, R_bgpProcess | All path attributes, multipath config |
| FF-1.2.02 | R_routes (protocol=ospf) | OSPF routes, metrics |
| FF-1.2.03 | R_routes | Admin_Distance across protocols |
| FF-1.3.01 | R_named (Route_Map) | All route-map fields |
| FF-1.3.02 | R_named (Route_Filter_List, Prefix_List) | All prefix-list fields |
| FF-1.3.03 | R_named (Community_List), R_bgpRib | Community attributes |
| FF-1.3.04 | R_named (As_Path_Access_List), R_bgpRib | AS_Path |
| FF-1.3.05 | R_routes | Admin_Distance |
| FF-1.3.06 | R_named (redistribute), R_routes | Redistributed routes |
| FF-1.3.07 | R_named (aggregate-address), R_bgpRib | Aggregate routes |
| FF-1.3.08 | R_named (default-originate), R_routes | Default route (0.0.0.0/0) |
| FF-1.3.09 | R_vxlan, R_named (RT config), R_evpnRib | RT values, VNI mappings |
| FF-1.3.10 | R_named (Ip_Access_List), R_filterLines | ACL definitions and analysis |
| FF-1.3.11 | R_bgpPeers, R_named | maximum-prefix config |
| FF-1.4.03 | R_evpnRib | EVPN route types, RD, RT |
| FF-1.4.04 | R_vxlan, R_interfaces (VXLAN) | VNI config, VTEP IPs |
| FF-1.9.01 | R_named (BFD) | BFD intervals, multiplier (timer arithmetic) |
| FF-1.9.02 | R_ospfInterfaces | Hello_Interval, Dead_Interval |
| FF-1.9.03 | R_named (BGP timers) | Keepalive, hold time |
| VD-2.1.01 | R_ospfInterfaces, R_named | Timer explicit/default classification |
| VD-2.1.02 | R_parseWarnings | Parse warnings per device |
| VD-2.1.03 | R_bgpProcess | Tiebreaking flags |
| VD-2.1.04 | R_ospfProcess, R_named | SPF throttle timers |
| VD-2.1.05 | R_bgpRib, R_bgpProcess | Attribute handling flags |
| VD-2.1.06 | R_named (GR) | GR vendor edge cases |
| PM-2.3.01 | R_mlag | MLAG/vPC config |
| TE-3.3.01 | R_routes (protocol=ospf) | IGP metrics per equivalence class |
| TE-3.3.02 | R_ospfInterfaces, R_named | DR priority |
| TE-3.3.03 | R_bgpPeers, R_bgpProcess | RR-client, cluster-ID |
| FF-1.7.01 | R_parseStatus | Parse completeness per device |
| FF-1.7.02 | R_undefinedRefs, R_unusedStructs | Reference integrity analysis |
| FF-1.7.03 | R_node (VRFs), R_routes (per-VRF), R_named (VRF config, route-leaking) | VRF names, per-VRF RIB, VRF isolation |
| FF-1.8.01-06 | R_node | DNS/NTP/SNMP/syslog/AAA server IPs, DHCP relay config |
| CV-4.5.01-05 | (cross-validation — no new fields; validate consistency of existing fields) | |
| LE-4.4.01-08 | (legacy — tag existing fields with legacy degradation annotations) | |
| PI-4.2.01-07 | (protocol interaction — composite; follow constituent tags) | |
| DEF-01-10 | (deferred — no fields tagged; elements are absent from M_verified by definition) | |

**Rule M2 — Conflict resolution.** When multiple predicates tag the same field, the most restrictive tag wins (R > K > C). The annotation concatenates both constraint descriptions.

**Rule M3 — Untagged fields.** Any field in M that is not covered by any predicate is tagged as `unverified` (equivalent to K with annotation "field not covered by any Stage 2 predicate"). In a correctly complete Stage 2, there should be no unverified fields in routing-critical relations. The presence of unverified fields in routing-critical relations is a Stage 2 completeness defect.

**Rule M4 — Device exclusion.** Devices in R_raw for Gate 0 (parse failure) do not appear in M_verified at all. Their absence is logged.

**Rule M5 — Capability predicates.** Not all predicates tag data fields. Some predicates validate Batfish's *computational capabilities* — whether the Batfish instance can perform specific analyses on the snapshot. These predicates produce **capability tags** on M_verified rather than field-level fidelity tags.

Capability predicates:

| Predicate | Capability Validated | Batfish Query |
|-----------|---------------------|---------------|
| FF-1.5.02 | Convergence sequencing analysis | `fork_snapshot()` + `differentialReachability()` |
| FF-1.5.03 | Multi-failure blast radius analysis | Iterated `fork_snapshot()` with multiple deactivations |
| FF-1.6.01 | ECMP path enumeration | `traceroute()` with `maxTraces` |
| FF-1.6.02-06 | Graph property computation | `layer3Edges()` → graph algorithms |
| CV-4.5.02 | VTEP reachability verification | `traceroute()` between VTEP pairs |

Capability tags are attached to M_verified at the snapshot level (not per-device, per-field):

```
capability_tag(capability_name) = {
    classification:  C | K | R,
    source_predicate: σᵢ,
    annotation:      string,
    semantic_chain:  [...]
}
```

Downstream consumers check capability tags before invoking Batfish for dynamic analysis. If FF-1.5.02 is R (differential analysis non-functional), the Cathedral does not attempt to use `differentialReachability()` for convergence prediction — it falls back to its own analytical model. If FF-1.6.01 is K (ECMP width approximate), the compression engine's path-count preservation validation notes the approximation.

---

## Output Specification

Stage 3 produces three artifacts:

### Artifact 1: P_corrected — The Corrected Partition

A vector of 97 entries, each containing:
- Predicate identifier (e.g., FF-1.3.01)
- Raw classification from Pass 1 (C, K, or R)
- Corrected classification from Pass 2 (C, K, or R)
- If downgraded: the semantic dependency chain that caused the downgrade
- Constraint annotation (for K) or rejection reason (for R)
- Device scope (which devices are affected, if not all)

### Artifact 2: M_verified — The Pre-Qualified Topology Database

The finite relational structure M extended with fidelity tags per Rule M1–M4. This is the single source of truth for all downstream components. Every field carries its classification, source predicate, annotation, and semantic chain.

M_verified is consumed by:
- **Stage 4** (reads P_corrected for disposition; reads M_verified for constraint directive generation)
- **Compression Engine** (reads fidelity tags to determine which fields are safe for behavioral signature computation)
- **Cathedral** (reads fidelity tags to determine which parameters are trustworthy for analytical modeling)
- **Mirror Box** (reads fidelity tags to determine which expansion claims carry full confidence)
- **Certification Report** (reads all tags for customer-facing documentation)

### Artifact 3: Evaluation Log

A machine-readable log of every predicate evaluation:
- Predicate identifier
- Evaluation result (which condition was satisfied: pass, partial, fail)
- The specific query calls made and their result summaries
- Elapsed time per predicate
- Any errors encountered during evaluation

The log is an auditability artifact. It allows post-hoc verification that the evaluator executed correctly.

---

## Technical Chain: Customer Configs to M_verified

The complete chain, with each transformation precisely identified:

```
1. Customer provides config directory
   └─► Input: directory of show-running-config files

2. Batfish parses configs
   └─► bf.init_snapshot(config_dir)
   └─► Gate 0: bf.q.fileParseStatus() — exclude failed devices
   └─► Output: M (finite relational structure, all relations populated)

3. Stage 3, Pass 1: Syntactic evaluation
   └─► Input: M, Σ (97 predicates from Stage 2)
   └─► Construct G_eval (evaluation DAG from Stage 2 explicit dependencies)
   └─► Topological sort Σ by G_eval
   └─► For each σᵢ in order:
       ├─► Check evaluation dependencies (short-circuit if dependency failed)
       ├─► Evaluate φᵢ (pass condition) against M
       ├─► If φᵢ fails, evaluate ψᵢ (partial condition) against M
       └─► Classify as C, K, or R
   └─► Output: P_raw = {C_raw, K_raw, R_raw}

4. Stage 3, Pass 2: Semantic correction
   └─► Input: P_raw, G_sem (semantic dependency graph, this document §Pass 2)
   └─► Initialize P_corrected = P_raw
   └─► Process G_sem in topological order (sources first)
   └─► For each σⱼ classified C in P_corrected:
       ├─► Compute S(σⱼ) = semantic dependency set
       ├─► Check for R or K members in S(σⱼ)
       ├─► Apply downgrade rules (strong/weak, scope narrowing)
       └─► Annotate with semantic dependency chain
   └─► Output: P_corrected = {C_corrected, K_corrected, R_corrected}

5. M_verified construction
   └─► Input: M, P_corrected, predicate-to-field mappings (this document §M_verified)
   └─► For each field in each relation of M:
       ├─► Look up governing predicate(s)
       ├─► Apply fidelity tag from P_corrected
       ├─► Resolve conflicts by most restrictive tag
       └─► Attach annotation and semantic chain
   └─► For each capability predicate:
       └─► Attach capability tag at snapshot level from P_corrected
   └─► Output: M_verified (topology database with correct fidelity and capability tags)

6. Stage 4: Qualification gate (defined separately)
   └─► Input: P_corrected (for disposition), M_verified (for constraint directives)
   └─► Output: GREEN / YELLOW / RED + constraint directives
   └─► If GREEN or YELLOW: pass M_verified + directives to Compression Engine
   └─► If RED: halt pipeline with diagnostic
```

---

## Complexity Analysis

**Pass 1:** Each predicate evaluation is a constant number of pybatfish query calls (bounded by the predicate definition, not by the data size). The number of predicates is fixed (97). Data complexity per query is in AC⁰ (Vardi 1982). Total Pass 1 complexity: O(97 × query_cost), where query_cost is dominated by Batfish's internal computation (IBDP fixed-point iteration). This is linear in the number of predicates and polynomial in the size of M.

**Pass 2:** One traversal of G_sem (97 nodes, bounded edges). Per-node work is proportional to the in-degree in G_sem (bounded by the maximum semantic dependency set size, which is at most ~21 for VD-2.1.02's parser quality propagation). Total Pass 2 complexity: O(|Σ| × max_in_degree) = O(97 × 21) = O(2037). Constant.

**M_verified construction:** One pass over all fields in all relations, applying a tag lookup per field. Complexity: O(|M|), linear in the size of the Batfish snapshot.

**Total Stage 3 complexity:** Dominated by Batfish query costs in Pass 1. Pass 2 and M_verified construction are negligible overhead.

---

## Invariants

The following invariants hold for any Stage 3 execution:

1. **Exhaustive evaluation.** Every predicate in Σ receives a classification. |C_corrected| + |K_corrected| + |R_corrected| = 97.

2. **Monotone correction.** ∀ σ ∈ Σ: corrected(σ) ≤ raw(σ) on the ordering C > K > R. No predicate improves in Pass 2.

3. **Tag correctness.** ∀ fields f in M_verified: tag(f).classification ≤ P_corrected(tag(f).source_predicate). ∀ capability tags c in M_verified: c.classification = P_corrected(c.source_predicate). No tag is more optimistic than its governing predicate's corrected classification.

4. **Semantic soundness.** ∀ σⱼ ∈ C_corrected: ∀ σᵢ ∈ S(σⱼ): σᵢ ∈ C_corrected. No confirmed predicate has a degraded semantic dependency.

5. **Single source of truth.** M_verified is the only artifact consumed by downstream components for fidelity determination. No downstream component reads P_raw, only P_corrected (via M_verified tags).

6. **Auditability.** Every tag in M_verified traces to a predicate, every predicate traces to a Stage 2 definition, every Stage 2 definition traces to a Stage 1 element, every Stage 1 element traces to an RFC or invariance proof. The chain is complete.
