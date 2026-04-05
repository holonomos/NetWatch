Version - 1.0
# Mirror Box — Verification Requirements Specification

> **Document Type:** Software Verification Cases and Procedures (SVCP)
>
> **Scope:** Tier 1 (deterministic replication) and Tier 2 (deterministic correction) only. Tier 3 is out of scope.

---

## LEVEL 1 — PRECONDITION VERIFICATION

### MB-PRE-01: Telemetry Feed Guard

**Procedure:** Invoke Mirror Box with no telemetry feed active.

**PASS:** Precondition error raised identifying absent telemetry. No projections emitted.

**FAIL:** Mirror Box emits projections without live telemetry input.

---

### MB-PRE-02: Partition Mapping Guard

**Procedure:** Invoke Mirror Box with null π.

**PASS:** Precondition error identifying missing partition mapping.

**FAIL:** Mirror Box proceeds without π.

---

### MB-PRE-03: Scaling Corrections Guard

**Procedure:** Invoke Mirror Box with null Cathedral scaling corrections.

**PASS:** Precondition error. Tier 2 expansion cannot proceed without correction factors.

**FAIL:** Mirror Box emits Tier 2 metrics without correction factors.

---

## LEVEL 2 — UNIT VERIFICATION

### MB-VC-01: Tier 1 Projection Coverage

**Requirement:** Every production device in V_net has a Tier 1 projection.

**Procedure:**
1. Start the compressed emulation with a known topology (4 spines, 8 leaves).
2. Provide π mapping all 12 devices to their cells and representatives.
3. Execute Module 2 (Tier 1 expansion).
4. Count the Tier 1 projections emitted.

**PASS:** |projections| = |V_net| = 12. Every device has exactly one projection.

**FAIL:** Any device missing, duplicated, or extra.

---

### MB-VC-02: Tier 1 Replication Exactness

**Requirement:** Every Tier 1 projection exactly replicates the representative's current telemetry values.

**Procedure:**
1. Start compressed emulation. Let it reach steady state.
2. For each production device v:
   a. Read the current telemetry of rep(v) from the compressed emulation.
   b. Read the Mirror Box projection for v.
   c. Compare every Tier 1 metric: BGP session states, OSPF adjacency states, RIB contents, FIB entries, convergence event ordering.

**PASS:** Every metric value in the projection is bit-identical to the representative's current telemetry value. Zero differences.

**FAIL:** Any metric value differs between the projection and the representative's telemetry.

---

### MB-VC-03: Tier 2 Correction Factor Application

**Requirement:** Every Tier 2 metric has its correction factor correctly applied: scaled_value = raw_value × correction_factor.

**Procedure:**
1. Execute Module 3 (Tier 2 expansion).
2. For every ScaledMetric in the output:
   a. Independently multiply raw_value × correction_factor.
   b. Compare against scaled_value.

**PASS:** scaled_value = raw_value × correction_factor for every Tier 2 metric. Exact (floating-point tolerance of 10⁻¹² is acceptable).

**FAIL:** Any ScaledMetric has incorrect arithmetic.

---

### MB-VC-04: Correction Factor Traceability

**Requirement:** Every Tier 2 metric carries a non-null correction_source identifying which Cathedral correction was applied.

**Procedure:**
1. Execute Module 3.
2. For every ScaledMetric, check correction_source.

**PASS:** Every ScaledMetric has correction_source ∈ {"diameter_ratio", "cell_size_multiplier", "spf_scaling_factor", "capacity_ratio"}. No null values.

**FAIL:** Any correction_source is null, empty, or not one of the defined sources.

---

### MB-VC-05: Metric Classification Completeness

**Requirement:** Every metric emitted by the Mirror Box has a tier classification (1 or 2). No Tier 3 metrics exist.

**Procedure:**
1. Enumerate all outputs from the Mirror Box.
2. Check the tier field on each.

**PASS:** Every output has tier = 1 or tier = 2. Zero outputs have tier = 3 or tier = null.

**FAIL:** Any output has tier = 3, tier = null, or any other value.

---

### MB-VC-06: Determinism

**Requirement:** Same telemetry + same π + same corrections → identical projections.

**Procedure:**
1. Capture a snapshot of the compressed emulation's telemetry at a fixed time.
2. Execute the Mirror Box 5 times with identical inputs (snapshot, π, corrections).
3. Compare all 5 outputs.

**PASS:** All 5 outputs are bit-identical.

**FAIL:** Any output differs between runs.

---

### MB-VC-07: Telemetry Staleness Detection

**Requirement:** If a representative's telemetry is older than a configurable staleness threshold, the Mirror Box flags the projection as stale.

**Procedure:**
1. Start compressed emulation. Let it produce telemetry.
2. Stop telemetry for one representative (simulate VM freeze or network partition).
3. Wait for the staleness threshold to elapse.
4. Invoke the Mirror Box.

**PASS:** Projections for devices in the affected cell are flagged as stale. They are NOT emitted as current. Projections for all other devices are emitted normally.

**FAIL:** Stale projections are emitted as current without the staleness flag.

---

## LEVEL 3 — INTEGRATION VERIFICATION

### MB-INT-01: Compression Engine → Mirror Box Contract

**Requirement:** Mirror Box correctly consumes π and |Cᵢ| from the compression engine.

**Procedure:**
1. Execute compression engine on a test topology.
2. Feed π and |Cᵢ| to Mirror Box.
3. Verify Mirror Box uses π to map devices to representatives and |Cᵢ| for Tier 2 scaling.

**PASS:** Every device maps to the correct representative per π. Churn scaling uses the correct |Cᵢ| per cell.

**FAIL:** Any device maps to wrong representative, or wrong |Cᵢ| used for scaling.

---

### MB-INT-02: Cathedral → Mirror Box Contract

**Requirement:** Mirror Box correctly consumes scaling corrections from the Cathedral.

**Procedure:**
1. Execute Cathedral to produce scaling corrections.
2. Feed corrections to Mirror Box.
3. Verify Mirror Box applies diameter_ratio, cell_size_multipliers, spf_scaling_factor, and capacity_ratios to the correct metrics.

**PASS:** Each Tier 2 metric uses the correct correction factor. diameter_ratio applied to convergence_duration. cell_size_multiplier applied to route_churn_count. spf_scaling_factor applied to spf_computation_count.

**FAIL:** Any metric uses the wrong correction factor, or any correction factor is not applied.

---

### MB-INT-03: Mirror Box → Convergence Diagnostic Contract

**Requirement:** Mirror Box output is consumable by the Convergence Diagnostic.

**Procedure:**
1. Execute Mirror Box.
2. Feed output to Convergence Diagnostic.
3. Verify the Diagnostic can compute δ for Tier 1 (comparison against Cathedral) and Tier 2 (comparison against Cathedral with correction bounds).

**PASS:** Convergence Diagnostic computes δ without contract violations. δ = 0 for Tier 1 metrics at steady state. δ within bounds for Tier 2 metrics.

**FAIL:** Convergence Diagnostic raises contract violation on Mirror Box output. Or δ computation fails.

---

### MB-INT-04: No Tier 3 Leakage

**Requirement:** The Mirror Box does not emit any Tier 3 outputs, even if the Convergence Diagnostic has legacy Tier 3 input schemas.

**Procedure:**
1. Execute full pipeline.
2. Inspect all Mirror Box outputs.
3. Verify no output has tier = 3, and no output contains ρ, confidence intervals, variance expansion, or distribution parameters.

**PASS:** Zero Tier 3 outputs. Zero stochastic metadata.

**FAIL:** Any Tier 3 output or stochastic metadata present.

---

## LEVEL 4 — OUTPUT CONTRACT VERIFICATION

### MB-OUT-01: Contract with Convergence Diagnostic — Tier 1

**Requirement:** Tier 1 projections are per-device, per-metric, with timestamp and representative identification.

**Procedure:** Verify output schema matches Convergence Diagnostic input requirements for Tier 1.

**PASS:** Every Tier 1 projection has: hostname, cell_id, representative, tier (= 1), metric values, timestamp.

**FAIL:** Any required field missing.

---

### MB-OUT-02: Contract with Convergence Diagnostic — Tier 2

**Requirement:** Tier 2 projections carry raw_value, correction_factor, scaled_value, and correction_source.

**Procedure:** Verify output schema matches Convergence Diagnostic input requirements for Tier 2.

**PASS:** Every Tier 2 metric has all four fields populated.

**FAIL:** Any required field missing.

---

## APPENDIX — VERDICT RULES

1. A case is PASS if and only if every assertion passes.
2. A case is FAIL if any assertion fails.
3. The Mirror Box passes verification if and only if every case at every level is PASS.
4. A single FAIL is sufficient to reject the implementation.
5. A FAIL means fix the code, not fix the test.
6. Test evidence is retained for DO-178C audit.

---

*End of Mirror Box Verification Requirements Specification v1.0*
