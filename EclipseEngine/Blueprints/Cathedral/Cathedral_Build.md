Version - 1.0
# Cathedral — Build Document

> **Purpose:** Source-of-truth implementation blueprint for the NetWatch Cathedral — the purely analytical model that predicts full production-scale network behavior from static configuration truth. This document bridges the Cathedral specification (what must be built) and the codebase (what is built).
>
> **Audience:** The engineer(s) implementing the Cathedral. Assumes full familiarity with the Cathedral specification (`Cathedral.md` v4.3), the compression engine outputs it consumes, and the Batfish validation protocol it must satisfy.
>
> **Standard:** DO-178C. Every requirement → implementation → test chain must be auditable.
>
> **Critical architectural property:** The Cathedral operates on the FULL production graph (M_verified), not on the compressed graph (G_c). It consumes the compression engine's outputs (π, |Cᵢ|, bᵢⱼ) for scaling corrections but runs its primary computation — steady-state solving, perturbation propagation, cascade analysis — over the complete topology.
>
> **Critical distinction from Batfish:** Batfish computes converged steady-state via IBDP fixed-point iteration. It answers "what is the converged state?" The Cathedral answers "what is the sequence of state transitions and their timing?" Batfish is ground truth for steady-state. The Cathedral provides dynamics.
>
> **Normative References:**
>
> | Document | Version | Role |
> |----------|---------|------|
> | `Cathedral.md` | 4.3 | Governing specification |
> | `Compression_Engine.md` | 4.3 | Upstream outputs consumed |
> | `Entity_Store.md` | 4.3 | Vertex/edge type definitions, FSM specifications |
> | `State_Space_Stage_4.md` | 4.3 | Analytical degradation directives |
> | `Eclipse_Engine.md` | 4.3 | Unified mathematical framing, entity type definitions |
> | `Convergence_Diagnostic.md` | 4.3 | Downstream consumer of Cathedral predictions |
> | `Fidelity_Boundary.md` | 5.0 | Tier system defining confidence levels |
> | RFC 4271 | — | BGP FSM, best-path selection, timer specifications |
> | RFC 2328 | — | OSPF neighbor/interface FSMs, SPF, LSA flooding |
> | RFC 5880 | — | BFD FSM, detection time computation |

---

## §1 — Architectural Position and Execution Preconditions

### 1.1 Where the Cathedral Sits

The Cathedral executes after the compression engine has produced its six artifacts. It receives M_verified (the full production topology) directly from Stage 4 and the compression artifacts (π, |Cᵢ|, bᵢⱼ, extraction confidence report) from the compression engine. It runs in parallel with VM Instantiation — the Cathedral does not need the VMs to be running.

The Cathedral's outputs feed two consumers: the Convergence Diagnostic (which compares Cathedral predictions against Mirror Box projections) and the Certification Report (which documents what the product claims).

### 1.2 Execution Preconditions

| ID | Precondition | Source | Verification |
|----|-------------|--------|-------------|
| CA-PRE-01 | M_verified is non-empty and fully tagged | Stage 3 | Assert |V_net| > 0. Assert every field has a fidelity tag. |
| CA-PRE-02 | Compression engine artifacts are available | Compression Engine | Assert π, |Cᵢ|, bᵢⱼ, and extraction confidence report are non-null. |
| CA-PRE-03 | π covers all V_net devices | Compression Engine contract | Assert domain(π) = V_net from M_verified. |
| CA-PRE-04 | Σ|Cᵢ| = |V_net| | Compression Engine INV-7.4 | Assert cell sizes sum to total network device count. |
| CA-PRE-05 | Batfish session is initialized and queryable | Stage 3 | Execute a trivial Batfish query and assert success. |
| CA-PRE-06 | Entity Store type definitions are loaded | Entity_Store.md | Assert FSM state transition tables and coupling functions are available for all vertex/edge types in M_verified. |
| CA-PRE-07 | Analytical degradation directives (if any) are present | Stage 4 | If disposition = YELLOW, check for analytical_degradation directives in the extraction confidence report. |

---

## §2 — Input Data Model

### 2.1 From M_verified (Full Production Graph)

The Cathedral reads the complete production topology. It uses the same M_verified structure as the compression engine (see Compression Engine Build Document §2.1) but reads it differently:

- **The compression engine** reads M_verified to compute signatures and build the compressed graph.
- **The Cathedral** reads M_verified to instantiate the dynamical model — one FSM per protocol session, one SPF tree per OSPF area, one RIB per device.

Key M_verified data the Cathedral consumes:

| Data | Use in Cathedral |
|------|-----------------|
| BGP peer configurations (per-device) | Instantiate per-session BGP FSMs. Parameterize UPDATE processing, policy evaluation. |
| BGP process configuration (router-id, multipath, deterministic-med flags) | Parameterize best-path selection algorithm. |
| OSPF interface configurations (area, network type, cost, hello/dead, passive) | Instantiate per-adjacency OSPF FSMs. Build link-state database for SPF. |
| Route-map, prefix-list, community-list, AS-path ACL content | Parameterize policy evaluation in BGP UPDATE processing. |
| VRF configuration (RT import/export) | Scope routing tables. Determine inter-VRF route leaking. |
| BFD enablement and timer values (where extracted) | Instantiate BFD FSMs in default or parameterized mode. |
| Static routes | Populate initial RIBs. |
| Interface IP assignments | Determine connected routes. Resolve next-hops. |
| Edge set (BGP sessions, OSPF adjacencies, L1/L3 links) | Build the full graph adjacency structure for dynamic propagation. |
| Fidelity tags (per-field) | Determine confidence on each parameter. Tag predictions that use defaulted values. |

### 2.2 From Compression Engine

| Artifact | Cathedral Use |
|----------|--------------|
| π (partition mapping) | Map production devices to cells. Used for hot-potato divergence analysis (compare routing decisions across cell members). |
| \|Cᵢ\| (cell sizes) | Scale route churn predictions (Tier 2). |
| bᵢⱼ (inter-cell connectivity) | Compute capacity scaling corrections (Tier 2). |
| Extraction confidence report | Determine which timer values are extracted vs. defaulted. Tag predictions accordingly. Identify analytical_degradation directives for domain-level confidence reduction. |

### 2.3 From Entity Store

| Data | Cathedral Use |
|------|--------------|
| Vertex type FSM definitions | Instantiate the correct FSM for each device type (Router: BGP+OSPF+BFD, Firewall: routing+ACL, etc.). |
| Edge type coupling functions | Model how state changes propagate across edges (BGP UPDATE filtering, OSPF LSA flooding, BFD detection signals). |
| Timer specifications with extraction confidence | Determine which timers to default and which to use extracted values for. |

### 2.4 Batfish Session

The Cathedral issues three categories of Batfish queries:

| Gate | Queries | Purpose |
|------|---------|---------|
| CA-V1 (mandatory) | `bf.q.routes(nodes=...)` for every device | Validate Cathedral steady-state RIBs against Batfish ground truth. |
| CA-V2 (mandatory) | `bf.q.reachability(srcIps=..., dstIps=...)` for sampled pairs | Validate Cathedral reachability against Batfish ground truth. |
| CA-V3 (mandatory for Tier 4) | `bf.q.routes(nodes=...)` for all members of flagged cells | Confirm hot-potato divergence predictions. |

---

## §3 — Internal Data Structures

### 3.1 Full Graph Model

```
FullGraphModel {
    // Device state vectors
    device_states: map<string, DeviceState>

    // Protocol sessions (per-session FSMs)
    bgp_sessions: map<(string, string), BGPSessionState>   // (local, remote) → state
    ospf_adjacencies: map<(string, string), OSPFAdjState>  // (local, remote) → state
    bfd_sessions: map<(string, string), BFDSessionState>   // (local, remote) → state

    // Routing tables
    ribs: map<string, RIB>                                 // device → RIB
    fibs: map<string, FIB>                                 // device → FIB

    // OSPF link-state databases (per-area)
    lsdbs: map<int, LSDB>                                  // area_id → LSDB

    // Policy objects (pre-compiled for evaluation)
    policies: map<string, CompiledPolicies>                // device → compiled route-maps, prefix-lists, etc.
}

DeviceState {
    hostname:       string
    device_type:    string          // from Entity Store
    vrfs:           list<string>    // VRF names
    router_id:      string
    bgp_config:     BGPProcessConfig
    ospf_config:    OSPFProcessConfig
    timer_config:   TimerConfig
    timer_provenance: map<string, TimerProvenance>  // timer_name → extracted|defaulted
}

TimerProvenance {
    timer_name:         string
    value:              float       // actual value used
    extraction_tag:     enum        // ● | ◐ | ○
    is_defaulted:       bool        // true if using RFC/FRR default
    default_source:     string      // "RFC 4271" | "FRR 10.6.0" | etc.
    confidence_impact:  string      // how defaulting affects predictions
}
```

### 3.2 BGP State Machine (Per-Session)

```
BGPSessionState {
    local_device:       string
    remote_device:      string
    fsm_state:          enum        // Idle | Connect | Active | OpenSent | OpenConfirm | Established
    local_as:           int
    remote_as:          int
    peer_type:          enum        // eBGP | iBGP
    address_families:   list<string>
    inbound_policy:     string      // route-map name (resolved to compiled policy)
    outbound_policy:    string
    rr_client:          bool
    adj_rib_in:         RIB         // routes received from this peer (pre-policy)
    adj_rib_out:        RIB         // routes sent to this peer (post-policy)

    // Timer state
    keepalive_timer:    TimerState
    hold_timer:         TimerState
    mrai_timer:         TimerState  // per-peer or per-destination

    // BFD binding
    bfd_bound:          bool
    bfd_session_ref:    Optional<(string, string)>  // reference to BFD session
}
```

### 3.3 Best-Path Selection Trace

```
BestPathTrace {
    prefix:             string
    candidates:         list<BGPRoute>
    winner:             BGPRoute
    deciding_step:      string      // which step in the comparison chain decided
    steps_evaluated:    list<StepResult>
}

StepResult {
    step_name:          string      // "weight" | "local_pref" | "as_path_length" | ...
    candidates_before:  int         // how many candidates entered this step
    candidates_after:   int         // how many survived
    deciding_value:     any         // the value that narrowed the set
}
```

### 3.4 Perturbation Propagation State

```
PerturbationResult {
    perturbation:       Perturbation        // what was perturbed
    convergence_sequence: list<ConvergenceEvent>  // Tier 1: ordered events
    convergence_timing:   list<TimedEvent>         // Tier 2: timed events
    final_state:        FullGraphModel              // post-convergence state
    affected_devices:   set<string>
    scaling_corrections: ScalingCorrections         // Tier 2 correction factors
}

Perturbation {
    perturbation_type:  enum        // LINK_DOWN | NODE_DOWN | CONFIG_CHANGE
    target:             string      // device or link identifier
    details:            map<string, any>
}

ConvergenceEvent {
    sequence_number:    int         // Tier 1: position in causal ordering
    device:             string
    protocol:           string      // "bgp" | "ospf" | "bfd"
    event_type:         string      // "session_down" | "withdraw" | "update" | "lsa_flood" | ...
    detail:             string
    caused_by:          Optional<int>   // sequence_number of the causing event
}

TimedEvent {
    timestamp:          float       // Tier 2: wall-clock time (seconds from perturbation)
    event:              ConvergenceEvent
    timer_provenance:   list<TimerProvenance>  // which timers affected this timestamp
}
```

### 3.5 Scaling Corrections

```
ScalingCorrections {
    diameter_ratio:         float       // D_prod / D_compressed
    cell_size_multipliers:  map<int, int>   // cell_id → |Cᵢ|
    spf_scaling_factor:     float       // (N_prod / N_comp) × log(N_prod / N_comp)
    capacity_ratios:        map<(int, int), float>  // (cell_i, cell_j) → ratio
    diameter_prod:          int
    diameter_compressed:    int
    n_prod:                 int
    n_compressed:           int
}
```

### 3.6 Hot-Potato Divergence Report

```
HotPotatoDivergence {
    cell_id:            int
    divergent_devices:  list<DivergentDevice>
    affected_prefixes:  list<string>
    batfish_confirmed:  bool            // after CA-V3 validation
}

DivergentDevice {
    hostname:           string
    representative:     string          // the cell's representative
    prefix:             string
    rep_best_path:      string          // representative's chosen next-hop
    device_best_path:   string          // this device's chosen next-hop
    rep_igp_cost:       int             // representative's IGP cost to its next-hop
    device_igp_cost:    int             // this device's IGP cost to its next-hop
    deciding_step:      string          // always "lowest_igp_cost" for hot-potato
}
```

### 3.7 Cathedral Output

```
CathedralOutput {
    // Tier 1 — exact
    steady_state_ribs:      map<string, RIB>            // per device
    best_path_traces:       map<(string, string), BestPathTrace>  // (device, prefix) → trace
    reachability_matrix:    map<(string, string), bool>  // (src, dst) → reachable

    // Tier 1 — perturbation ordering
    perturbation_results:   list<PerturbationResult>

    // Tier 2 — scaling corrections
    scaling_corrections:    ScalingCorrections

    // Tier 4 — Cathedral-only
    hot_potato_divergences: list<HotPotatoDivergence>
    cascade_analyses:       list<CascadeResult>

    // Confidence tags
    prediction_confidence:  map<string, PredictionConfidence>  // prediction_id → confidence
    analytical_degradation_domains: list<string>                // domains with reduced confidence
}

PredictionConfidence {
    prediction_id:      string
    tier:               int             // 1, 2, or 4
    defaulted_timers:   list<TimerProvenance>
    extraction_tags:    list<string>    // which ●/◐/○ tags affect this prediction
    confidence_level:   string         // "full" | "default-assumed" | "partial-confidence" | "supplemental-required"
    confidence_detail:  string
}
```

---

## §4 — Module Decomposition

Nine modules, ordered by dependency.

### Module 1: Full Graph Construction

**Spec reference:** Cathedral §Construction, "For each vertex v ∈ V_net, instantiate the dynamical model."

**Purpose:** Build the complete in-memory representation of the production network from M_verified. Instantiate one FSM per protocol session, one SPF database per OSPF area, one RIB per device, one policy evaluation engine per device.

**Inputs:** M_verified, Entity Store type definitions, extraction confidence report.

**Algorithm:**

1. **Device instantiation.** For each device in M_verified, create a DeviceState. Populate device type, VRFs, router-id, BGP config, OSPF config. Determine timer provenance for each timer parameter: if the extraction confidence report shows the field as ● with fidelity C, use the extracted value. If ◐ with fidelity K or missing, use the RFC default and mark as "defaulted."

2. **BGP session instantiation.** For each BGP peering edge in M_verified, create a BGPSessionState. Initialize FSM to Idle. Set peer type (eBGP/iBGP) from ASN comparison. Compile inbound/outbound policies from M_verified named structures.

3. **OSPF adjacency instantiation.** For each OSPF adjacency edge, create an OSPFAdjState. Initialize FSM to Down. Build per-area LSDB from interface configurations.

4. **BFD session instantiation.** For each BFD-enabled protocol session, create a BFDSessionState. Determine mode: if BFD timer values are in the extraction confidence report with included_in_sigma = true (or at least extraction_tag = ● or ◐ with successful extraction), use parameterized mode. Otherwise, use default mode (detection time = 0).

5. **Policy compilation.** For each device, compile all route-maps, prefix-lists, community-lists, and AS-path ACLs into an evaluable form. The compilation must be semantically equivalent to the canonical form used in the compression engine's signature computation — but here it's used for actual evaluation, not hashing.

**Outputs:** FullGraphModel (§3.1)

**Invariants:**
- Every device in M_verified has a DeviceState.
- Every BGP peering in M_verified has a BGPSessionState.
- Every OSPF adjacency in M_verified has an OSPFAdjState.
- Timer provenance is recorded for every timer value used.

---

### Module 2: OSPF SPF Computation

**Spec reference:** Cathedral §Computation, "For OSPF: SPF computation over the link-state database."

**Purpose:** Compute the OSPF shortest-path tree rooted at every device in every OSPF area. These SPF trees provide the IGP cost-to-next-hop values that feed into BGP best-path selection (step 8).

**Algorithm:**

1. For each OSPF area in the LSDB:
   a. For each device participating in that area:
      - Run Dijkstra's algorithm from that device over the area's link-state database.
      - Record shortest-path costs to every other device in the area.
      - For ABRs: merge inter-area routes using summary LSAs (Type 3/4).
      - For ASBRs: incorporate external routes (Type 5/7 LSAs) with appropriate metrics.

2. Build the OSPF RIB for each device: the set of OSPF-learned routes with their costs, next-hops, and route types (intra-area, inter-area, E1, E2).

3. Install OSPF routes into the device's main RIB at the OSPF administrative distance (default 110).

**Outputs:** Per-device OSPF SPF trees. Per-device OSPF routes installed in the RIB.

**Invariants:**
- SPF is deterministic: same LSDB → same tree.
- SPF costs are symmetric on bidirectional links with equal OSPF cost.
- Every device's OSPF RIB is consistent with its SPF tree.

---

### Module 3: BGP Steady-State Solver

**Spec reference:** Cathedral §Computation, "Solve the system of FSM equations to fixed point."

**Purpose:** Compute the converged BGP routing state for every device in the full production graph. This is the Cathedral's Tier 1 foundation — if steady-state is wrong, nothing downstream is trustworthy.

**Algorithm:**

```
FUNCTION bgp_steady_state(model: FullGraphModel):

    // Initialize: populate RIBs with connected routes, static routes, OSPF routes
    FOR EACH device IN model.device_states:
        install_connected_routes(model.ribs[device], device)
        install_static_routes(model.ribs[device], device)
        // OSPF routes already installed by Module 2

    // Iterative BGP convergence
    // Simulate BGP UPDATE propagation until no more changes occur
    changed = true
    iteration = 0
    max_iterations = |V_net| × |prefixes|  // bounded convergence

    WHILE changed AND iteration < max_iterations:
        changed = false
        iteration += 1

        FOR EACH bgp_session IN model.bgp_sessions:
            IF bgp_session.fsm_state != Established:
                CONTINUE

            local = bgp_session.local_device
            remote = bgp_session.remote_device

            // Compute what local would send to remote (adj-RIB-out)
            exportable_routes = compute_adj_rib_out(
                model.ribs[local],
                bgp_session.outbound_policy,
                model.policies[local],
                bgp_session
            )

            // For each route in adj-RIB-out that remote hasn't already received
            FOR EACH route IN exportable_routes:
                // Apply inbound policy on remote
                accepted = evaluate_inbound_policy(
                    route,
                    bgp_session.inbound_policy,
                    model.policies[remote]
                )

                IF accepted:
                    // Resolve next-hop via OSPF (multi-protocol interaction)
                    resolved_route = resolve_next_hop(route, model, remote)

                    // Run best-path selection
                    current_best = model.ribs[remote].get_best(route.prefix)
                    new_candidates = model.ribs[remote].get_candidates(route.prefix)
                    new_candidates.add(resolved_route)

                    new_best, deciding_step = bgp_best_path_select(new_candidates)

                    IF new_best != current_best:
                        model.ribs[remote].install(new_best)
                        changed = true

    IF iteration >= max_iterations:
        RAISE "BGP did not converge in {max_iterations} iterations — oscillation detected"

    RETURN model
```

**Best-Path Selection Implementation:**

The comparison chain must follow RFC 4271 §8 exactly:

| Step | Attribute | Comparison | Winner |
|------|-----------|-----------|--------|
| 1 | Weight | Highest wins | Cisco-specific, pre-RFC |
| 2 | Local Preference | Highest wins | RFC 4271 §5.1.5 |
| 3 | Locally Originated | Local > non-local | |
| 4 | AS-Path Length | Shortest wins | RFC 4271 §9.1.2.2 |
| 5 | Origin | IGP < EGP < Incomplete | RFC 4271 §5.1.4 |
| 6 | MED | Lowest wins | RFC 4271 §5.1.4 (with deterministic-MED flag) |
| 7 | Peer Type | eBGP > iBGP | RFC 4271 §9.1.2.2 |
| 8 | IGP Cost to Next-Hop | Lowest wins | Hot-potato routing |
| 9 | (Multipath check) | Skipped for best-path | |
| 10 | Router ID | Lowest wins | RFC 4271 §9.1.4 |
| 11 | Peer Address | Lowest wins | Final tiebreak |

**Critical implementation details:**
- MED comparison scope: controlled by `always-compare-med` and `deterministic-med` flags from BGP process config. If `deterministic-med` is off, MED is only compared between routes from the same neighbor AS.
- The Cathedral must record a BestPathTrace for every (device, prefix) pair — this is required for audit and for the Convergence Diagnostic to understand why routing decisions were made.
- IGP cost at step 8 comes from Module 2's OSPF SPF computation. This is the multi-protocol interaction point.

**Outputs:** Converged RIBs for all devices. Best-path traces.

**Verification:** CA-VC-01 (RIBs match Batfish), CA-VC-02 (reachability matches Batfish).

---

### Module 4: Batfish Steady-State Validation

**Spec reference:** Cathedral §Batfish Validation Protocol, Gates CA-V1 and CA-V2.

**Purpose:** Validate the Cathedral's steady-state computation against Batfish's ground truth. This is a mandatory gate — not an optional check.

**Algorithm:**

```
FUNCTION validate_steady_state(model: FullGraphModel, bf_session):

    // ── Gate CA-V1: RIB Match ──
    mismatches = []
    FOR EACH device IN model.device_states:
        cathedral_rib = model.ribs[device.hostname]
        batfish_rib = bf_session.q.routes(nodes=device.hostname).answer()

        comparison = compare_ribs_structural(cathedral_rib, batfish_rib)
        IF comparison.has_divergence:
            mismatches.append(RIBMismatch(
                device = device.hostname,
                divergent_prefixes = comparison.divergent_prefixes,
                cathedral_entries = comparison.cathedral_side,
                batfish_entries = comparison.batfish_side,
                diagnosis = diagnose_rib_divergence(comparison)
            ))

    IF len(mismatches) > 0:
        RAISE CathedralValidationError(
            gate = "CA-V1",
            message = f"Cathedral RIBs diverge from Batfish on {len(mismatches)} devices",
            mismatches = mismatches
        )
        // This is fatal. The Cathedral cannot proceed with wrong steady-state.

    // ── Gate CA-V2: Reachability Consistency ──
    sample_pairs = generate_reachability_sample(model)  // representative src-dst pairs
    reachability_mismatches = []

    FOR EACH (src, dst) IN sample_pairs:
        cathedral_reachable = model.reachability_matrix.get((src, dst))
        batfish_result = bf_session.q.reachability(
            srcIps=src_ip, dstIps=dst_ip
        ).answer()
        batfish_reachable = batfish_result.is_reachable

        IF cathedral_reachable != batfish_reachable:
            reachability_mismatches.append(...)

    IF len(reachability_mismatches) > 0:
        RAISE CathedralValidationError(gate="CA-V2", ...)

    RETURN ValidationResult(ca_v1="PASS", ca_v2="PASS")
```

**On failure:** A CA-V1 or CA-V2 failure is a Cathedral modeling error. The response is to diagnose the divergence (which prefix, which protocol, which step in the comparison chain differs), fix the Cathedral's model, and re-run. The Cathedral does NOT proceed past validation with known divergences.

---

### Module 5: Perturbation Propagation Engine

**Spec reference:** Cathedral §Computation, Perturbation Propagation Analysis.

**Purpose:** Given a perturbation (link failure, node failure), propagate the effect through the full production graph. Produce Tier 1 output (convergence ordering) and Tier 2 output (convergence timing with scaling corrections).

**Algorithm:**

```
FUNCTION propagate_perturbation(model: FullGraphModel, perturbation: Perturbation):

    result = new PerturbationResult(perturbation)
    event_queue = PriorityQueue()   // ordered by timestamp
    sequence_number = 0
    t = 0.0

    // ── Phase 1: Apply perturbation ──
    IF perturbation.type == LINK_DOWN:
        (src, dst) = perturbation.target
        event_queue.push(TimedEvent(t, ConvergenceEvent(
            sequence_number++, src, "physical", "link_down", f"link to {dst} failed")))
        event_queue.push(TimedEvent(t, ConvergenceEvent(
            sequence_number++, dst, "physical", "link_down", f"link to {src} failed")))

    // ── Phase 2: Protocol detection cascade ──
    // BFD detects first (sub-second if parameterized, instant if default)
    // BFD → bound protocol notification
    // OSPF dead timer fires if no BFD
    // BGP hold timer fires if no BFD and no OSPF

    WHILE NOT event_queue.empty():
        timed_event = event_queue.pop()
        event = timed_event.event
        t = timed_event.timestamp

        result.convergence_sequence.append(event)
        result.convergence_timing.append(timed_event)

        // Generate consequent events based on protocol FSM transitions
        new_events = process_event(model, event, t)
        FOR EACH ne IN new_events:
            event_queue.push(ne)

    // Record final state
    result.final_state = deepcopy(model)
    result.affected_devices = {e.device for e in result.convergence_sequence}

    RETURN result
```

**Event processing logic (process_event):**

| Input Event | Protocol | Generated Events |
|------------|----------|-----------------|
| link_down | BFD | bfd_session_down (at t + detection_time) |
| bfd_session_down | BGP (if bound) | bgp_session_down (at t + ε) |
| bfd_session_down | OSPF (if bound) | ospf_neighbor_down (at t + ε) |
| bgp_session_down | BGP | bgp_withdraw for all routes learned from this peer (at t + ε) |
| bgp_withdraw | BGP | bgp_best_path_recompute, potentially bgp_update to other peers (at t + MRAI) |
| ospf_neighbor_down | OSPF | ospf_lsa_flood to area neighbors (at t + ε), spf_recompute (at t + SPF_delay) |
| spf_recompute | OSPF+BGP | rib_update, potentially bgp_next_hop_change (at t + ε) |

**Tier 1 vs Tier 2 separation:** The convergence_sequence (ordered by sequence_number) is Tier 1. The convergence_timing (ordered by timestamp) is Tier 2. Tier 1 is scale-invariant — it doesn't change with |Cᵢ|. Tier 2 timestamps depend on timer values (which may be defaulted) and are scaled by the correction factors in Module 6.

**Invariants:**
- CA-VC-03: Running the same perturbation twice produces identical ordering.
- Every event has a causal chain traceable back to the initial perturbation.

---

### Module 6: Scaling Correction Computation

**Spec reference:** Cathedral §Scaling Correction Computation.

**Purpose:** Compute the four Tier 2 correction factors from the compression mapping and full topology.

**Algorithm:**

```
FUNCTION compute_scaling_corrections(model, G_c, pi, cell_sizes, b_ij):

    corrections = new ScalingCorrections()

    // 1. Diameter ratio
    D_prod = compute_graph_diameter(model.ospf_links, model.all_devices)
    D_comp = compute_graph_diameter(G_c.ospf_links, G_c.all_devices)
    corrections.diameter_ratio = D_prod / D_comp if D_comp > 0 else 1.0
    corrections.diameter_prod = D_prod
    corrections.diameter_compressed = D_comp

    // 2. Cell size multipliers (direct from compression engine)
    corrections.cell_size_multipliers = cell_sizes

    // 3. SPF scaling factor
    N_prod = len(model.device_states)
    N_comp = len(G_c.vertices)
    corrections.n_prod = N_prod
    corrections.n_compressed = N_comp
    ratio = N_prod / N_comp if N_comp > 0 else 1.0
    corrections.spf_scaling_factor = ratio * math.log(ratio) if ratio > 1 else 1.0

    // 4. Capacity ratios (from bᵢⱼ)
    FOR EACH (ci, cj), prod_edge_count IN b_ij:
        comp_edge_count = count_edges_between_reps(G_c, ci, cj)
        corrections.capacity_ratios[(ci, cj)] = (
            prod_edge_count / comp_edge_count if comp_edge_count > 0 else prod_edge_count
        )

    RETURN corrections
```

**Key finding from math validation:** For symmetric Clos topologies (the target topology class), the diameter ratio is 1.0 — adding more leaves does not change the diameter. This simplifies Tier 2 timing corrections significantly for the primary use case. The correction only matters for non-Clos topologies (chains, hierarchical designs).

**Verification:** CA-VC-04 (timing scales with diameter ratio), CA-VC-05 (churn scales with |Cᵢ|), CA-VC-06 (SPF scales N·log·N).

---

### Module 7: Hot-Potato Divergence Detection

**Spec reference:** Cathedral §Hot-Potato Routing Divergence Detection.

**Purpose:** For every equivalence class in π, detect cases where members would route differently than their representative due to position-dependent IGP costs.

**Algorithm:**

```
FUNCTION detect_hot_potato_divergences(model, pi, bf_session):

    divergences = []

    FOR EACH cell_id, members IN get_cells(pi):
        IF |members| <= 1:
            CONTINUE

        representative = get_representative(cell_id, pi)

        // Get all BGP next-hops used by the representative
        rep_rib = model.ribs[representative]
        bgp_prefixes = rep_rib.get_bgp_prefixes()

        FOR EACH prefix IN bgp_prefixes:
            rep_best = rep_rib.get_best(prefix)
            rep_igp_cost = rep_best.igp_cost_to_next_hop

            FOR EACH member IN members WHERE member != representative:
                // Compute this member's IGP cost to the same next-hop
                member_igp_cost = ospf_spf(model.ospf_links, member).get(rep_best.next_hop)

                // Check if a different next-hop would win for this member
                member_candidates = resolve_bgp_next_hops(
                    model.ribs[member].get_candidates(prefix), model.ospf_links, member)
                member_best, member_step = bgp_best_path_select(member_candidates)

                IF member_best.next_hop != rep_best.next_hop:
                    divergences.append(HotPotatoDivergence(
                        cell_id = cell_id,
                        divergent_devices = [DivergentDevice(
                            hostname = member,
                            representative = representative,
                            prefix = prefix,
                            rep_best_path = rep_best.next_hop,
                            device_best_path = member_best.next_hop,
                            rep_igp_cost = rep_igp_cost,
                            device_igp_cost = member_best.igp_cost_to_next_hop,
                            deciding_step = member_step
                        )],
                        affected_prefixes = [prefix],
                        batfish_confirmed = false
                    ))

    // ── CA-V3: Confirm with Batfish ──
    FOR EACH divergence IN divergences:
        // Query Batfish for all members of the flagged cell
        FOR EACH device IN divergence.cell_members:
            batfish_rib = bf_session.q.routes(nodes=device.hostname).answer()
            // Compare Cathedral prediction against Batfish
            ...
        divergence.batfish_confirmed = true  // or false if Batfish disagrees

    RETURN divergences
```

**Verification:** CA-VC-08 (zero false negatives against Batfish).

---

### Module 8: Cascade Analysis

**Spec reference:** Cathedral §Cascade Analysis.

**Purpose:** Propagate multi-failure scenarios through the full production graph. This is Tier 4 — Cathedral-only, no emulation validation possible.

**Key constraint:** This module MUST operate on the full graph (|V_net| vertices), NOT the compressed graph (|V_c| vertices). CA-VC-09 verifies this.

**Algorithm:** Iteratively apply Module 5's perturbation propagation for each failure in the scenario, checking after each failure whether secondary failures are triggered (overloaded links, session losses from rerouted traffic). Track the cascade wavefront and convergence boundary.

---

### Module 9: Output Assembly and Confidence Tagging

**Spec reference:** Cathedral §Downstream outputs, verification criteria CA-VC-12, CA-VC-13.

**Purpose:** Assemble all Cathedral outputs. Tag every prediction with its confidence assessment.

**Confidence tagging rules:**

| Condition | Confidence Level | Tag |
|-----------|-----------------|-----|
| All inputs are ● with fidelity C | "full" | No qualification needed |
| Any input timer is defaulted (◐ → RFC default) | "default-assumed" | "This prediction assumes [timer] = [default] because actual value was not extracted." |
| BFD in mixed-extraction mode | "partial-confidence" | "BFD timing mixed-extraction — some devices use extracted values, others use default." |
| Input field is ○ (supplemental-required) | "supplemental-required" | "This prediction requires supplemental data not available from device configs." |
| Analytical degradation directive covers this domain | "degraded" | "Analytical degradation: [source_predicate] → [affected domain]." |

**Verification:** CA-VC-12 (degradation directives reduce confidence), CA-VC-13 (every prediction has confidence tags), CA-VC-14 (deterministic).

---

## §5 — Traceability Matrix

| VC | Spec Requirement | Module | Test Method |
|----|-----------------|--------|-------------|
| CA-VC-01 | Steady-state RIBs match Batfish | 3, 4 | Compare Cathedral RIBs against bf.q.routes() for every device. Zero mismatches. |
| CA-VC-02 | Reachability matches Batfish | 3, 4 | Compare Cathedral reachability against bf.q.reachability(). Zero mismatches on sampled pairs. |
| CA-VC-03 | Convergence ordering is deterministic | 5 | Run perturbation propagation twice on same input; ordering identical. |
| CA-VC-04 | Timing scales with diameter ratio | 5, 6 | Compare timing against known analytical model for standard Clos. |
| CA-VC-05 | Route churn scales linearly with |Cᵢ| | 6 | Verify churn = compressed_churn × (|Cᵢ|/|Rᵢ|). |
| CA-VC-06 | SPF scaling follows N·log·N | 6 | Verify SPF prediction against known complexity bounds. |
| CA-VC-07 | Defaulted timers correctly tagged | 9 | Feed mixed ●/◐ timers; verify "default-assumed" tags. |
| CA-VC-08 | Hot-potato divergences match Batfish | 7 | For flagged cells, compare against bf.q.routes(). Zero false negatives. |
| CA-VC-09 | Cascade runs on full graph | 8 | Verify cascade graph has |V_net| vertices, not |V_c|. |
| CA-VC-10 | BFD default mode: correct sequencing | 5 | BFD detection_time=0 → event sequence correct (ordering). |
| CA-VC-11 | BFD parameterized mode: uses extracted values | 5 | Feed extracted BFD timers → Cathedral uses interval × multiplier. |
| CA-VC-12 | Degradation directives reduce confidence | 9 | Feed analytical_degradation directives; verify reduced-confidence tags. |
| CA-VC-13 | All predictions carry confidence tags | 9 | Every prediction output has extraction provenance and confidence assessment. |
| CA-VC-14 | Cathedral is deterministic | All | Same inputs → identical outputs. No randomness. |

---

## §6 — Known Gap Implementation

### Gap CA-1: Non-Markovian Timer Interactions

**Implementation:** Use RFC default values when actual timer values are not extracted. Tag all Tier 2 predictions that depend on defaulted values as "default-assumed." Record the specific default value and its source (e.g., "BGP Hold = 180s, RFC 4271") in the TimerProvenance. The Convergence Diagnostic receives these tags and uses them for cause categorization when δ exceeds threshold.

**Module affected:** Module 1 (timer provenance recording), Module 5 (timer-dependent event timestamps), Module 9 (confidence tagging).

### Gap CA-2: Cascading Failure Propagation

**Implementation:** Cascade analysis runs on the full graph exclusively (Module 8). Individual failure responses are validated against the compressed emulation (Tier 1 via CA-VC-01/02). Cascade composition is flagged as Tier 4 — Cathedral-only, no emulation validation. The certification report documents cascade predictions with "analytical, Cathedral-only, not emulation-validated."

**Module affected:** Module 8.

### Gap CA-3: Hot-Potato Routing Divergence

**Implementation:** Module 7 detects hot-potato divergences by computing IGP costs from every cell member to every BGP next-hop. Divergences are flagged as Tier 4 and confirmed against Batfish via CA-V3. The certification report includes per-cell divergence reports with affected devices and prefixes.

**Module affected:** Module 7.

### Gap CA-4: Stateful Device Analytical Modeling

**Implementation:** Firewalls participate in the Cathedral's routing model (RIB, FIB, BGP peering) but not in stateful path analysis. Traffic path analysis through firewalls considers ACL permit/deny but not session-table dynamics. The extraction confidence report documents "stateful_session_tracking: unmodeled" for firewall devices.

**Module affected:** Module 3 (treats firewalls as routing-only devices).

---

## §7 — Dependency Graph

```
Module 1: Full Graph Construction
    │
    │ Produces: FullGraphModel
    │ Required by: Module 2, Module 3
    │
    ▼
Module 2: OSPF SPF Computation
    │
    │ Produces: Per-device SPF trees, OSPF routes in RIBs
    │ Required by: Module 3 (IGP cost for BGP step 8)
    │
    ▼
Module 3: BGP Steady-State Solver
    │
    │ Produces: Converged RIBs, best-path traces
    │ Required by: Module 4
    │
    ▼
Module 4: Batfish Steady-State Validation ◄── MANDATORY GATE
    │
    │ Produces: CA-V1 PASS, CA-V2 PASS (or halts)
    │ Required by: Module 5, Module 7, Module 8
    │
    ├──────────────────────────────────┐
    ▼                                  ▼
Module 5: Perturbation              Module 7: Hot-Potato
Propagation Engine                  Divergence Detection
    │                                  │
    │                                  │ (includes CA-V3)
    ▼                                  ▼
Module 6: Scaling                   Module 8: Cascade Analysis
Correction Computation              (full graph, Tier 4)
    │                                  │
    └──────────────┬───────────────────┘
                   ▼
            Module 9: Output Assembly
                   │
                   ▼
            Cathedral Output → Convergence Diagnostic
                             → Certification Report
```

**Critical gate:** Module 4 is a hard gate. If CA-V1 or CA-V2 fails, Modules 5–9 do not execute. The Cathedral refuses to make predictions from a model that cannot reproduce known ground truth.

---

## §8 — Open Implementation Decisions

| Decision | Constraints |
|----------|------------|
| Convergence loop implementation (Module 3) | Must converge for any valid BGP configuration. Must handle route reflectors, confederations, multi-AF. Oscillation detection is required (CA-VC-03 implicitly requires termination). |
| SPF algorithm implementation | Dijkstra with priority queue. Must handle multi-area OSPF, ABR summarization, ASBR external routes. |
| Policy evaluation engine | Must exactly match the canonical semantics of route-maps, prefix-lists, community-lists, AS-path ACLs as used by Batfish and FRR. Any divergence will show up in CA-V1 as a RIB mismatch. |
| Perturbation event queue | Priority queue ordered by timestamp. Must handle simultaneous events deterministically (break ties by device name, then by event type). |
| Cascade scenario specification format | How the user/system specifies multi-failure scenarios for Module 8. |
| Reachability sampling strategy (CA-V2) | Which src-dst pairs to sample. Must cover every VRF, every access control boundary, and every routing domain boundary. |

---

*End of Cathedral Build Document v1.0*
