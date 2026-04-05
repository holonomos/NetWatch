Version - 1.0
# Cathedral — Verification Requirements Specification

> **Document Type:** Software Verification Cases and Procedures (SVCP)
>
> **Purpose:** Binary pass/fail acceptance criteria for every testable requirement of the Cathedral implementation. The code either satisfies the stated condition or it does not.
>
> **Governing Documents:**
>
> | Document | Version |
> |----------|---------|
> | `Cathedral.md` | 4.3 |
> | `Cathedral_Build.md` | 1.0 |
> | `cathedral_math_validation.py` | 1.0 |

---

## LEVEL 1 — PRECONDITION VERIFICATION

### CA-PRE-01: Empty Topology Guard

**Procedure:** Invoke Cathedral with M_verified containing zero devices.

**PASS:** Precondition error raised identifying empty topology. No computation begins.

**FAIL:** Any computation begins.

---

### CA-PRE-02: Missing Compression Artifacts Guard

**Procedure:** Invoke Cathedral with valid M_verified but null π.

**PASS:** Precondition error identifying missing compression artifacts.

**FAIL:** Cathedral proceeds without compression artifacts.

---

### CA-PRE-03: Cell Size Sum Guard

**Procedure:** Provide |Cᵢ| whose sum ≠ |V_net|.

**PASS:** Precondition error identifying cell size mismatch.

**FAIL:** Cathedral proceeds with inconsistent cell sizes.

---

### CA-PRE-04: Batfish Session Guard

**Procedure:** Invoke Cathedral with null Batfish session.

**PASS:** Precondition error before any computation.

**FAIL:** Cathedral begins computation without Batfish access.

---

## LEVEL 2 — UNIT VERIFICATION

### CA-VC-01: Steady-State RIBs Match Batfish

**Requirement:** Cathedral-computed RIBs match Batfish's `bf.q.routes()` for every device, zero mismatches.

**Procedure:**
1. Execute Modules 1–3 (graph construction, OSPF SPF, BGP steady-state).
2. For every device in V_net:
   a. Retrieve Cathedral-computed RIB.
   b. Retrieve Batfish RIB via `bf.q.routes(nodes=device)`.
   c. Compare structurally: same prefixes, same protocols, same AD, same metrics, same communities, same local preferences, same AS-path lengths.
3. Next-hop IPs may differ in representation but must resolve to the same forwarding behavior.

**PASS:** Zero divergences across all devices for all prefixes.

**FAIL:** Any prefix on any device has a different protocol source, different metric, different best-path selection outcome, or is present in one RIB but not the other.

---

### CA-VC-02: Reachability Matches Batfish

**Requirement:** Cathedral reachability verdicts match Batfish for sampled source-destination pairs.

**Procedure:**
1. Generate a sample of ≥100 source-destination pairs spanning every VRF, every ACL boundary, and every routing domain.
2. For each pair, compare Cathedral reachability against `bf.q.reachability()`.

**PASS:** Zero mismatches. Every pair has the same reachable/unreachable verdict.

**FAIL:** Any pair has a different verdict.

---

### CA-VC-03: Convergence Ordering is Deterministic

**Requirement:** Same perturbation on same input produces identical convergence ordering.

**Procedure:**
1. Execute Module 5 (perturbation propagation) 10 times with identical input and identical perturbation (e.g., specific link failure).
2. Extract the convergence_sequence (ordered list of ConvergenceEvents) from each run.

**PASS:** All 10 orderings are identical — same events, same sequence numbers, same causal chains.

**FAIL:** Any ordering differs between runs.

---

### CA-VC-04: Convergence Timing Scales with Diameter Ratio

**Requirement:** For topologies where diameter changes with scale, the Cathedral's timing prediction scales by D_prod / D_compressed.

**Procedure:**
1. Construct two topologies with different diameters but identical structure at the compressed level (e.g., chain of 5 vs chain of 10 — same compressed representative set, different diameter).
2. Compute scaling corrections (Module 6).
3. Verify the diameter_ratio matches the actual ratio of graph diameters.
4. Verify that timing predictions scale by this ratio.

**PASS:** diameter_ratio = D_prod / D_compressed (computed independently). Timing predictions for the larger topology are diameter_ratio × the smaller topology's timing.

**FAIL:** Diameter ratio is incorrect, or timing does not scale by the ratio.

**Note (from math validation):** For symmetric Clos topologies, diameter_ratio = 1.0 (diameter invariant under leaf scaling). This test must include a non-Clos topology (chain, ring) where diameter actually changes.

---

### CA-VC-05: Route Churn Scales Linearly with Cell Size

**Requirement:** Route churn prediction = compressed_churn × (|Cᵢ| / |Rᵢ|) for each cell.

**Procedure:**
1. Execute perturbation propagation on a topology with known cell sizes.
2. Count route churn events (withdrawals + updates) in the compressed emulation.
3. Compute predicted full-scale churn: compressed_churn × (|Cᵢ| / |Rᵢ|) per cell.
4. Compare against Cathedral's churn prediction.

**PASS:** Cathedral's churn prediction matches the formula for every cell within 0% tolerance (churn is an integer count — scaling is exact for uniform cells).

**FAIL:** Any cell's churn prediction deviates from the formula.

---

### CA-VC-06: SPF Scaling Follows N·log·N

**Requirement:** SPF computation load prediction follows (N_prod / N_comp) × log(N_prod / N_comp).

**Procedure:**
1. Compute SPF scaling factor from Module 6.
2. Verify the formula is applied correctly: ratio = N_prod / N_comp, factor = ratio × ln(ratio).
3. Verify the factor is > 1 (super-linear) for N_prod > N_comp.
4. Verify monotonicity: larger N_prod → larger factor (for fixed N_comp).

**PASS:** Formula correctly applied. Factor > 1 for all non-trivial compressions. Monotonically increasing.

**FAIL:** Formula incorrectly applied, or factor ≤ 1 for N_prod > N_comp.

---

### CA-VC-07: Defaulted Timer Values Correctly Tagged

**Requirement:** Predictions that depend on defaulted timer values carry "default-assumed" confidence tags.

**Procedure:**
1. Construct M_verified where:
   - Devices A, B: BGP keepalive/hold extracted (●, fidelity C).
   - Devices C, D: BGP keepalive/hold not extracted (◐, fidelity K — defaulted to RFC values).
2. Execute Cathedral pipeline.
3. Examine predictions involving devices C, D.

**PASS:** All of the following hold:
- TimerProvenance for devices C, D shows is_defaulted = true for BGP keepalive and hold.
- PredictionConfidence for any timing prediction involving C or D shows confidence_level = "default-assumed".
- PredictionConfidence for timing predictions involving only A, B shows confidence_level = "full".

**FAIL:** Any prediction involving defaulted timers lacks the "default-assumed" tag. Or any prediction involving only extracted timers is tagged as "default-assumed."

---

### CA-VC-08: Hot-Potato Divergences Match Batfish

**Requirement:** Cathedral's hot-potato divergence flags have zero false negatives when validated against Batfish.

**Procedure:**
1. Execute Module 7 (hot-potato detection).
2. For every cell flagged with divergence, run `bf.q.routes(nodes=member)` for ALL members.
3. Compare BGP best-path selections across members.
4. Also check: for cells NOT flagged, verify no divergence exists in Batfish.

**PASS — No false negatives:** Every divergence observed in Batfish was also flagged by the Cathedral.
**PASS — False positives acceptable but documented:** Cathedral may over-flag (flag divergences that Batfish doesn't confirm) — these are conservative. They must be documented.
**Overall PASS:** Zero false negatives.

**FAIL:** Any divergence present in Batfish but not flagged by the Cathedral (false negative).

---

### CA-VC-09: Cascade Analysis Runs on Full Graph

**Requirement:** The cascade analysis graph has |V_net| vertices (full production), not |V_c| (compressed).

**Procedure:**
1. Execute Module 8 (cascade analysis).
2. Count the vertices in the graph used for cascade computation.

**PASS:** Vertex count = |V_net| from M_verified.

**FAIL:** Vertex count = |V_c| or any other value ≠ |V_net|.

---

### CA-VC-10: BFD Default Mode — Correct Sequencing

**Requirement:** When BFD detection time is 0 (default mode), the event sequence is correct even though timing is instantaneous.

**Procedure:**
1. Construct topology with BFD-enabled sessions but no extracted BFD timers.
2. Execute perturbation (link failure).
3. Verify event sequence: link_down → bfd_down (at t=0) → protocol_session_down → withdraw propagation.

**PASS:** BFD detection fires at t=0 (instantaneous). Causal ordering is: link failure → BFD → bound protocol → route withdrawal. No events precede BFD detection.

**FAIL:** BFD detection has non-zero delay despite default mode. Or any event occurs before BFD detection that should occur after.

---

### CA-VC-11: BFD Parameterized Mode — Uses Extracted Values

**Requirement:** When BFD timers are extracted, the Cathedral uses interval × multiplier as detection time.

**Procedure:**
1. Construct topology where BFD timers are extracted: interval = 100ms, multiplier = 3 → detection_time = 300ms.
2. Execute perturbation (link failure).
3. Verify BFD detection fires at t = 0.300s (not t = 0).

**PASS:** BFD detection timestamp = interval × multiplier = 0.300s.

**FAIL:** BFD detection at t = 0 (default mode used despite extracted values), or at any time ≠ 0.300s.

---

### CA-VC-12: Analytical Degradation Directives Reduce Confidence

**Requirement:** Analytical degradation directives from Stage 4 cause affected prediction domains to have reduced confidence.

**Procedure:**
1. Provide extraction confidence report with analytical_degradation directives covering the OSPF convergence domain.
2. Execute Cathedral pipeline.
3. Examine predictions in the OSPF convergence domain.

**PASS:** Predictions in the affected domain carry confidence_level = "degraded" with the directive annotation.

**FAIL:** Affected predictions show confidence_level = "full" or lack the degradation tag.

---

### CA-VC-13: All Predictions Carry Confidence Tags

**Requirement:** Every prediction in the Cathedral output has a PredictionConfidence entry.

**Procedure:**
1. Execute the full Cathedral pipeline.
2. Enumerate all predictions in the output (steady-state RIBs, perturbation results, hot-potato flags, cascade results).
3. For each prediction, verify a PredictionConfidence entry exists.

**PASS:** Every prediction has a PredictionConfidence with non-null tier, confidence_level, and extraction_tags fields.

**FAIL:** Any prediction lacks a confidence entry or has null confidence fields.

---

### CA-VC-14: Cathedral is Deterministic

**Requirement:** Same M_verified + same compression artifacts → identical Cathedral output.

**Procedure:**
1. Execute the full Cathedral pipeline 5 times on identical input.
2. Compare outputs.

**PASS:** All 5 outputs are identical: same RIBs, same orderings, same timing, same divergence flags, same confidence tags.

**FAIL:** Any output differs between runs.

---

## LEVEL 3 — INTEGRATION VERIFICATION

### CA-INT-01: Compression Engine → Cathedral Contract

**Requirement:** Cathedral correctly consumes all four compression engine artifacts.

**Procedure:**
1. Execute compression engine on a production-representative topology.
2. Feed compression artifacts to Cathedral.
3. Verify Cathedral uses π for hot-potato analysis, |Cᵢ| for churn scaling, bᵢⱼ for capacity ratios.

**PASS:** All four artifacts are consumed without error. Scaling corrections reference the correct cell sizes and connectivity counts.

**FAIL:** Any artifact causes a contract violation or is silently ignored.

---

### CA-INT-02: Module 4 Gate Blocks Downstream

**Requirement:** CA-V1 or CA-V2 failure prevents Modules 5–9 from executing.

**Procedure:**
1. Deliberately introduce a modeling error in Module 3 (e.g., skip a best-path comparison step).
2. Execute through Module 4.
3. Verify Module 4 fails (CA-V1 or CA-V2).
4. Verify Modules 5–9 do not execute and no predictions are emitted.

**PASS:** Module 4 raises CathedralValidationError. No downstream modules execute. No predictions are produced.

**FAIL:** Any downstream module executes despite the validation failure. Or any prediction is emitted.

---

### CA-INT-03: OSPF → BGP Multi-Protocol Interaction

**Requirement:** OSPF SPF results correctly feed into BGP best-path step 8 (IGP cost to next-hop).

**Procedure:**
1. Construct topology where BGP best-path is decided by IGP cost (all prior steps tied).
2. Verify OSPF SPF costs are correctly populated in BGP route candidates.
3. Verify best-path selection uses these costs at step 8.

**PASS:** The winning BGP route has the lowest IGP cost as computed by OSPF SPF. The deciding_step in the BestPathTrace is "lowest_igp_cost."

**FAIL:** IGP costs are not populated, or best-path ignores them, or the deciding_step is wrong.

---

### CA-INT-04: End-to-End Pipeline

**Requirement:** Cathedral runs end-to-end on a production-representative topology and produces all outputs.

**Procedure:**
1. Construct M_verified: 4 spines, 8 leaves, 2 border leaves, full BGP mesh, OSPF underlay.
2. Provide compression artifacts from the compression engine.
3. Provide initialized Batfish session.
4. Execute full Cathedral pipeline.

**PASS:** All of the following hold:
- CA-V1 PASS (RIBs match Batfish).
- CA-V2 PASS (reachability matches).
- Perturbation propagation produces results with Tier 1 ordering and Tier 2 timing.
- Scaling corrections are computed.
- Hot-potato analysis runs (may find zero divergences for symmetric topology — that's correct).
- All predictions carry confidence tags.
- Cathedral output is non-null and complete.

**FAIL:** Any gate fails, any module raises an unhandled error, or any output is missing.

---

## LEVEL 4 — MATHEMATICAL FOUNDATION VERIFICATION

### CA-MTH-01: BGP Best-Path Comparison Chain Fidelity

**Requirement:** The Cathedral's best-path selection produces the same winner as the RFC 4271 §8 algorithm for all test cases.

**Procedure:** Run the 5-test BGP best-path suite from `cathedral_math_validation.py` (Tests 1–5) against the Cathedral's implementation.

**PASS:** All 5 tests produce the correct winner at the correct deciding step.

**FAIL:** Any test produces a different winner or deciding step.

---

### CA-MTH-02: OSPF SPF Correctness

**Requirement:** The Cathedral's SPF computation matches Dijkstra on all test topologies.

**Procedure:** Run the OSPF SPF test from `cathedral_math_validation.py` (Test 6) against the Cathedral's implementation.

**PASS:** All shortest-path costs match the hand-computed expected values.

**FAIL:** Any cost differs.

---

### CA-MTH-03: Timer Independence of Ordering

**Requirement:** Changing timer values changes Tier 2 timestamps but not Tier 1 ordering.

**Procedure:** Run the timer independence test from `cathedral_math_validation.py` (Test 10): three timer configurations, same perturbation.

**PASS:** All three configurations produce identical event orderings. Timestamps differ.

**FAIL:** Any ordering differs between configurations.

---

### CA-MTH-04: Clos Diameter Invariance

**Requirement:** For symmetric Clos topologies, adding more leaves does not change the graph diameter.

**Procedure:** Run the diameter test from `cathedral_math_validation.py` (Test 13): compare diameter of 2s2l Clos vs 2s8l Clos.

**PASS:** D_small = D_large. Diameter ratio = 1.0.

**FAIL:** Diameters differ (would mean Tier 2 timing correction is needed for Clos leaf scaling, which would change the scaling correction computation significantly).

---

## LEVEL 5 — OUTPUT CONTRACT VERIFICATION

### CA-OUT-01: Predictions Contract with Convergence Diagnostic

**Requirement:** Cathedral outputs are consumable by the Convergence Diagnostic.

**Procedure:**
1. Execute full Cathedral pipeline.
2. Verify output contains: Tier 1 predictions (steady-state RIBs, convergence ordering), Tier 2 predictions (timing with corrections), Tier 4 predictions (hot-potato flags, cascade results).
3. Verify every prediction has a confidence tag consumable by the Convergence Diagnostic.

**PASS:** All prediction categories present. All confidence tags present and structured.

**FAIL:** Any category missing, or any prediction without a confidence tag.

---

### CA-OUT-02: Predictions Contract with Certification Report

**Requirement:** Cathedral outputs include per-prediction provenance traceable to extraction sources.

**Procedure:**
1. For each prediction, verify the confidence tag includes: which extraction tags (●/◐/○) affect it, which timers were defaulted, and which analytical degradation directives apply.

**PASS:** Every prediction has complete provenance.

**FAIL:** Any prediction has incomplete provenance.

---

## APPENDIX — VERDICT RULES

Same as Compression Engine SVCP Appendix B:
1. A case is PASS if and only if every assertion passes.
2. A case is FAIL if any assertion fails.
3. The Cathedral passes verification if and only if every case at every level is PASS.
4. A single FAIL is sufficient to reject the implementation.
5. A FAIL means fix the code, not fix the test.
6. Test evidence is retained for DO-178C audit.

**Additional Cathedral-specific rule:**
7. **CA-V1/CA-V2 failure is a Cathedral defect, not a Batfish defect.** If the Cathedral's RIBs diverge from Batfish, the Cathedral is wrong. Batfish is ground truth for steady-state. The response is to fix the Cathedral's model, not to question Batfish.

---

*End of Cathedral Verification Requirements Specification v1.0*
