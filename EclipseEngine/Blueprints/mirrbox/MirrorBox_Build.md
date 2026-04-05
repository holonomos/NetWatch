Version - 1.0
# Mirror Box — Build Document

> **Purpose:** Source-of-truth implementation blueprint for the NetWatch Mirror Box — the deterministic expansion function that projects live telemetry from the compressed emulation onto the full production topology.
>
> **Standard:** DO-178C.
>
> **Scope Decision (v1.0):** Tier 3 stochastic expansion is OUT OF SCOPE. The variance expansion formula, ρ measurement, tail probability computation, Mori-Zwanzig timescale separation argument, and all associated confidence interval machinery are removed from the Mirror Box specification. The mathematical stress-test (`mirrorbox_math_stresstest.py`) demonstrated that Tier 3's core formula is mathematically correct but rests on inputs (ρ from compressed substrate) that cannot be deterministically guaranteed to represent production behavior. Under the project's architectural principle — if a deterministic guarantee cannot be achieved, the claim is removed from scope, not patched with workarounds — Tier 3 is dropped.
>
> **What remains:** Tier 1 (exact replication, lifting theorem) and Tier 2 (deterministic correction factors). Both are fully deterministic, fully testable, and fully provable.
>
> **Spec Amendments Required:**
>
> | Section | Amendment |
> |---------|-----------|
> | Eclipse_Engine.md §Mirror Box | Remove Tier 3 formulas, ρ measurement, Mori-Zwanzig justification, entropy preservation section |
> | Cathedral.md §Tier 3 note | Change "Tier 3 is the Mirror Box's domain" to "Tier 3 is out of scope" |
> | Convergence_Diagnostic.md §Tier 3 | Remove Tier 3 self-consistency checks, ρ diagnostics, distribution analysis |
> | Convergence_Diagnostic.md §Cause categorization | Remove HOST_CONTENTION, NONSTATIONARITY, DISTRIBUTION_MISMATCH causes |
> | Entity_Store.md | No changes needed — Timer exclusions from σ remain valid for compression engine reasons |
>
> **Normative References:**
>
> | Document | Version | Role |
> |----------|---------|------|
> | `Compression_Engine.md` | 4.3 | Upstream: provides π, |Cᵢ|, bᵢⱼ |
> | `Cathedral.md` | 4.3 | Upstream: provides correction factors, steady-state predictions |
> | `Convergence_Diagnostic.md` | 4.3 | Downstream: compares Mirror Box projections against Cathedral predictions |

---

## §1 — Architectural Position

### 1.1 What the Mirror Box Is

A deterministic expansion function:

```
E: Telemetry(G_c) → Telemetry(G)
```

It takes live measurements from the compressed emulation (real FRR VMs running real protocol implementations) and maps them onto the full production topology. The mapping is defined by the compression engine's partition π and the Cathedral's correction factors.

The Mirror Box has no model. It has no analytical engine. It has no stochastic machinery. It reads live telemetry, applies a deterministic transformation, and emits full-scale projections. Its simplicity is its strength — it is trivially auditable because it does exactly one thing per tier.

### 1.2 What the Mirror Box Is NOT (Scope Exclusions)

| Exclusion | Reason |
|-----------|--------|
| Stochastic variance expansion (Tier 3) | Cannot deterministically guarantee ρ_prod from ρ_compressed. Dropped per scope discipline. |
| Tail probability computation | Depends on ρ. Dropped with Tier 3. |
| Confidence interval generation | Stochastic. Dropped with Tier 3. |
| Cross-correlation (ρ) measurement | No longer consumed. Dropped with Tier 3. |
| BFD timing as stochastic metric | BFD timing was Tier 3. Now handled by Cathedral only (BFD default mode for sequencing, parameterized mode for extracted timers). |
| Distribution expansion | Stochastic. Dropped. |
| Mori-Zwanzig coarse-graining | Justified Tier 3. No longer needed. |

### 1.3 Execution Preconditions

| ID | Precondition | Verification |
|----|-------------|-------------|
| MB-PRE-01 | Compressed emulation is running and producing telemetry | Assert telemetry feed is active and non-empty. |
| MB-PRE-02 | π (partition mapping) is available | Assert π maps every V_net device to a cell and representative. |
| MB-PRE-03 | |Cᵢ| (cell sizes) are available | Assert one positive integer per cell, Σ|Cᵢ| = |V_net|. |
| MB-PRE-04 | Cathedral scaling corrections are available | Assert diameter_ratio, cell_size_multipliers, spf_scaling_factor, and capacity_ratios are present and non-null. |
| MB-PRE-05 | Representative mapping is well-defined | For every production device v, rep(v) is a device in the compressed emulation producing telemetry. |

---

## §2 — Input Data Model

### 2.1 Live Telemetry from Compressed Emulation

The Mirror Box reads a continuous telemetry stream from the running FRR VMs. Each telemetry sample is:

```
TelemetrySample {
    timestamp:      float           // wall-clock time
    device:         string          // hostname of the compressed-graph representative
    metric_name:    string          // what's being measured
    metric_value:   any             // the measurement
    metric_tier:    enum            // TIER_1 | TIER_2 (determined by metric classification)
}
```

**Tier 1 metrics (scale-invariant):**

| Metric | Source | Value Type |
|--------|--------|-----------|
| BGP session state | FRR bgpd | enum: Idle/Connect/Active/OpenSent/OpenConfirm/Established |
| OSPF adjacency state | FRR ospfd | enum: Down/Init/2Way/ExStart/Exchange/Loading/Full |
| RIB contents | FRR zebra | set of (prefix, next-hop, protocol, metric, AD) |
| FIB entries | FRR zebra | set of (prefix, next-hop, interface) |
| Route-map evaluation outcomes | FRR bgpd | per-route permit/deny with attribute modifications |
| Convergence event ordering | FRR logs | ordered sequence of protocol state transitions |

**Tier 2 metrics (scale-dependent):**

| Metric | Source | Correction Factor |
|--------|--------|-------------------|
| Convergence wall-clock duration | FRR timestamps | × diameter_ratio |
| Route churn count (withdrawals + updates) | FRR bgpd counters | × (|Cᵢ| / |Rᵢ|) per cell |
| SPF computation count | FRR ospfd counters | × spf_scaling_factor |
| Link utilization / capacity | FRR interface counters | × capacity_ratio per cell pair |

### 2.2 From Compression Engine

| Artifact | Mirror Box Use |
|----------|---------------|
| π | Map each production device to its representative. For Tier 1: replicate representative's state to all cell members. |
| \|Cᵢ\| | Scale Tier 2 metrics (churn, SPF count). |
| bᵢⱼ | (Consumed by Cathedral for capacity ratio computation. Mirror Box receives the computed ratio.) |

### 2.3 From Cathedral

| Artifact | Mirror Box Use |
|----------|---------------|
| Scaling corrections | Apply correction factors to Tier 2 metrics. |
| Steady-state predictions | Not directly consumed — the Convergence Diagnostic compares Cathedral predictions against Mirror Box projections. |

---

## §3 — Internal Data Structures

The Mirror Box is thin. Its internal state is minimal.

```
MirrorBoxState {
    // The projection: production device → current state
    projections: map<string, DeviceProjection>
    
    // Tier 2 scaled metrics
    scaled_metrics: map<string, ScaledMetric>
}

DeviceProjection {
    hostname:           string          // production device hostname
    cell_id:            int             // which cell this device belongs to
    representative:     string          // which compressed device represents it
    
    // Tier 1: direct replication from representative
    bgp_sessions:       map<string, enum>   // peer → session state
    ospf_adjacencies:   map<string, enum>   // neighbor → adjacency state
    rib:                RIB                 // replicated from representative
    fib:                FIB                 // replicated from representative
    convergence_events: list<ConvergenceEvent>  // replicated ordering
    
    // Metadata
    projection_tier:    int             // 1 for all direct replications
    last_updated:       float           // timestamp of last telemetry update
}

ScaledMetric {
    metric_name:        string
    raw_value:          float           // from compressed emulation
    correction_factor:  float           // from Cathedral
    scaled_value:       float           // raw × correction
    cell_id:            int             // which cell this applies to
    projection_tier:    int             // always 2
}
```

---

## §4 — Module Decomposition

Three modules. That's it. The Mirror Box is deliberately thin.

### Module 1: Telemetry Ingestion

**Purpose:** Read live telemetry from the compressed emulation. Classify each measurement as Tier 1 or Tier 2.

**Algorithm:**

```
FUNCTION ingest_telemetry(sample: TelemetrySample, state: MirrorBoxState):

    // Classify the metric
    tier = classify_metric(sample.metric_name)

    IF tier == TIER_1:
        // Store raw measurement, keyed by (device, metric)
        state.raw_tier1[sample.device][sample.metric_name] = sample.metric_value
        state.raw_tier1_timestamps[sample.device] = sample.timestamp

    ELSE IF tier == TIER_2:
        state.raw_tier2[sample.device][sample.metric_name] = sample.metric_value

    RETURN state
```

**Metric classification table:**

| Metric | Tier | Rationale |
|--------|------|-----------|
| BGP session state | 1 | FSM state is scale-invariant (lifting theorem) |
| OSPF adjacency state | 1 | FSM state is scale-invariant |
| RIB contents | 1 | Routing decisions are scale-invariant (same config → same routes) |
| FIB entries | 1 | Derived from RIB — scale-invariant |
| Convergence event ordering | 1 | Causal ordering is scale-invariant (validated in math suite) |
| Convergence duration | 2 | Wall-clock timing scales with diameter |
| Route churn count | 2 | Total churn scales with cell size |
| SPF computation count | 2 | SPF load scales with N·log·N |
| Link utilization | 2 | Aggregate capacity scales with bᵢⱼ |

**Invariants:**
- Every telemetry sample is classified as exactly one tier.
- No unclassified metrics are accepted.

---

### Module 2: Tier 1 Expansion — Direct Replication

**Purpose:** For every production device v, set its Tier 1 metrics to the current values of its representative rep(v).

**Algorithm:**

```
FUNCTION expand_tier1(state: MirrorBoxState, pi: PartitionMapping):

    FOR EACH device IN pi.all_production_devices():
        representative = pi.get_representative(device)
        cell_id = pi.get_cell(device)

        projection = DeviceProjection()
        projection.hostname = device
        projection.cell_id = cell_id
        projection.representative = representative
        projection.projection_tier = 1

        // Direct replication: copy representative's state
        projection.bgp_sessions = state.raw_tier1[representative]["bgp_sessions"]
        projection.ospf_adjacencies = state.raw_tier1[representative]["ospf_adjacencies"]
        projection.rib = state.raw_tier1[representative]["rib"]
        projection.fib = state.raw_tier1[representative]["fib"]
        projection.convergence_events = state.raw_tier1[representative]["convergence_events"]
        projection.last_updated = state.raw_tier1_timestamps[representative]

        state.projections[device] = projection

    RETURN state
```

**The guarantee:** This is exact. `metric_prod(v) = metric_compressed(rep(v))` for all v ∈ Cᵢ. The lifting theorem guarantees that if the partition π is equitable, every state transition in the compressed graph lifts to a corresponding state transition for every member of the cell. We proved this in the compression engine math validation.

**What could invalidate the guarantee:** A defect in the compression engine's partition (devices grouped that shouldn't be). This would show up in the Convergence Diagnostic as δ > 0 on a Tier 1 metric.

**Invariants:**
- Every production device has a projection.
- Every projection's representative is a device that exists in the compressed emulation and has telemetry.
- projection.projection_tier = 1 for all direct replications.

**Verification:** MB-VC-01, MB-VC-02.

---

### Module 3: Tier 2 Expansion — Deterministic Correction

**Purpose:** For Tier 2 metrics, apply the Cathedral's correction factors to the compressed emulation's measurements.

**Algorithm:**

```
FUNCTION expand_tier2(state: MirrorBoxState, corrections: ScalingCorrections):

    FOR EACH device IN state.raw_tier2:
        FOR EACH (metric_name, raw_value) IN state.raw_tier2[device]:

            // Look up the correction factor for this metric
            factor = get_correction_factor(metric_name, device, corrections)

            scaled = ScaledMetric()
            scaled.metric_name = metric_name
            scaled.raw_value = raw_value
            scaled.correction_factor = factor
            scaled.scaled_value = raw_value * factor
            scaled.cell_id = pi.get_cell(device)
            scaled.projection_tier = 2

            state.scaled_metrics[f"{device}:{metric_name}"] = scaled

    RETURN state

FUNCTION get_correction_factor(metric_name, device, corrections):
    SWITCH metric_name:
        CASE "convergence_duration":
            RETURN corrections.diameter_ratio
        CASE "route_churn_count":
            cell_id = pi.get_cell(device)
            cell_size = corrections.cell_size_multipliers[cell_id]
            rep_count = pi.get_representative_count(cell_id)
            RETURN cell_size / rep_count
        CASE "spf_computation_count":
            RETURN corrections.spf_scaling_factor
        CASE "link_utilization":
            cell_id = pi.get_cell(device)
            // Capacity ratio is per cell pair — need the relevant pair
            RETURN corrections.capacity_ratios.get(relevant_pair, 1.0)
        DEFAULT:
            RAISE UnknownMetricError(metric_name)
```

**Invariants:**
- Every Tier 2 metric has a defined correction factor.
- No Tier 2 metric is emitted without its correction factor applied.
- The correction factor source (diameter_ratio, cell_size, etc.) is recorded for traceability.

**Verification:** MB-VC-03, MB-VC-04, MB-VC-05.

---

## §5 — Output Artifacts

The Mirror Box produces exactly two artifact categories:

### Artifact 1: Tier 1 Full-Scale Projections

Per-device, per-metric. Deterministic replication from representative telemetry.

```
{
    device: "leaf-17",
    cell_id: 3,
    representative: "leaf-1",
    tier: 1,
    bgp_sessions: { "spine-1": "Established", "spine-2": "Established" },
    ospf_adjacencies: { "spine-1": "Full", "spine-2": "Full" },
    rib: [ ... ],
    convergence_events: [ ... ],
    timestamp: 1714900000.0
}
```

**Contract with Convergence Diagnostic:** The Convergence Diagnostic compares these projections against the Cathedral's Tier 1 predictions. δ = 0 is the contract. Non-zero δ is a defect.

### Artifact 2: Tier 2 Scaled Metrics

Per-metric, per-cell. Deterministic correction applied to live measurements.

```
{
    metric: "route_churn_count",
    cell_id: 3,
    raw_value: 47,
    correction_factor: 16.0,    // |Cᵢ| / |Rᵢ| = 32 / 2
    scaled_value: 752,
    tier: 2,
    correction_source: "cell_size_multiplier"
}
```

**Contract with Convergence Diagnostic:** The Convergence Diagnostic compares these against the Cathedral's Tier 2 predictions. δ must be within correction factor bounds.

---

## §6 — Verification Criteria

| ID | Criterion | Verification Method |
|----|-----------|-------------------|
| MB-VC-01 | Every production device has a Tier 1 projection | Count projections. Assert = |V_net|. |
| MB-VC-02 | Tier 1 projections exactly replicate representative state | For each projection, assert every metric value equals the representative's current telemetry value. |
| MB-VC-03 | Tier 2 correction factors are correctly applied | For each scaled metric, assert scaled_value = raw_value × correction_factor. |
| MB-VC-04 | Correction factor sources are traceable | Every Tier 2 metric has a correction_source field identifying which Cathedral correction was applied. |
| MB-VC-05 | No metric is emitted without tier classification | Assert every output metric has tier = 1 or tier = 2. No unclassified metrics. |
| MB-VC-06 | Mirror Box is deterministic | Same telemetry + same π + same corrections → identical projections. |
| MB-VC-07 | Telemetry staleness detection | If a representative's telemetry is older than a configurable threshold, flag the projection as stale. Do not emit stale projections as current. |

---

## §7 — Traceability Matrix

| VC | Spec Requirement | Module | Test Method |
|----|-----------------|--------|-------------|
| MB-VC-01 | π completeness | 2 | Assert |projections| = |V_net|. |
| MB-VC-02 | Lifting theorem guarantee | 2 | Compare projection values against representative telemetry. Bit-identical. |
| MB-VC-03 | Tier 2 formula correctness | 3 | Assert scaled = raw × factor for every metric. |
| MB-VC-04 | Traceability | 3 | Assert non-null correction_source on every Tier 2 output. |
| MB-VC-05 | Classification completeness | 1 | Assert every metric has a tier. |
| MB-VC-06 | Determinism | All | Run 5 times, assert identical output. |
| MB-VC-07 | Staleness | 1, 2 | Withhold telemetry for one representative; assert staleness flag. |

---

## §8 — Downstream Contract Verification

### Contract with Convergence Diagnostic

| Contract | Verification |
|----------|-------------|
| Tier 1 projections are per-device, per-metric | Assert structure matches Convergence Diagnostic input schema. |
| Tier 2 projections carry correction factor provenance | Assert correction_source is present on every Tier 2 metric. |
| No Tier 3 outputs are emitted | Assert no output has tier = 3. The Convergence Diagnostic should not expect Tier 3 inputs from the Mirror Box. |
| Every projection has a timestamp | Assert non-null timestamp on every output. |

---

## §9 — What Was Removed and Why

The following were present in earlier specifications (Eclipse_Engine.md v4.3, referenced in Convergence_Diagnostic.md v4.3) and are now formally OUT OF SCOPE for the Mirror Box.

| Removed Item | Original Spec Location | Reason for Removal |
|-------------|----------------------|-------------------|
| Tier 3 stochastic expansion | Eclipse_Engine.md §Mirror Box, "For Tier 3 metrics" | ρ_compressed cannot deterministically represent ρ_prod. Cannot guarantee. Dropped. |
| Variance expansion formula | Eclipse_Engine.md §Mirror Box, Var_prod = \|Cᵢ\| × σ² × (1 + (\|Cᵢ\| - 1) × ρ) | Formula is correct but inputs (ρ) are not deterministically obtainable. Dropped. |
| Tail probability computation | Eclipse_Engine.md §Mirror Box, P(≥1 failure) | Depends on ρ. Dropped. |
| Confidence interval generation | Eclipse_Engine.md §Mirror Box, "CI width scales with 1/√(samples)" | Stochastic. Dropped. |
| Cross-correlation (ρ) measurement | Eclipse_Engine.md §Mirror Box, "ρ_measured between ≥2 representatives" | Host contention dominates measurement. Cannot deterministically interpret. Dropped. |
| BFD timing as stochastic metric | Eclipse_Engine.md §Mirror Box, "BFD behavior is a Tier 3 metric" | BFD timing now handled by Cathedral only (default mode for sequencing, parameterized for extracted timers). |
| Entropy preservation / Mori-Zwanzig | Eclipse_Engine.md §Mirror Box, "Entropy Preservation" | Justified Tier 3. Tier 3 dropped. Justification no longer needed. |

**Impact on Convergence Diagnostic:** The following Convergence Diagnostic features are no longer needed and should be removed from that specification:

| CD Feature | Why Removed |
|-----------|-------------|
| Tier 3 self-consistency checks (T3-SC-1 through T3-SC-4) | No Tier 3 outputs to check. |
| ρ diagnostic (ρ reasonableness, ρ stability, ρ trend) | ρ not measured. |
| HOST_CONTENTION cause category | ρ-dependent. Dropped. |
| NONSTATIONARITY cause category | Distribution-dependent. Dropped. |
| DISTRIBUTION_MISMATCH cause category | Distribution-dependent. Dropped. |
| Tier 3 breach response (severity LOW) | No Tier 3 breaches possible. |

**Impact on Compression Engine:** None. Rule 1 (|Rᵢ| ≥ 2 per cell) was originally motivated partly by ρ measurement (needing ≥2 representatives for cross-correlation). With ρ dropped, Rule 1 still stands independently — its remaining rationale is failover validation (the compressed emulation needs a redundancy pair to test failover behavior).

---

*End of Mirror Box Build Document v1.0*
