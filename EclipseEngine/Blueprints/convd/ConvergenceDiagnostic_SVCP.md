Version - 1.0
# Convergence Diagnostic — Verification Requirements Specification

> **Document Type:** Software Verification Cases and Procedures (SVCP)
>
> **Scope:** Tier 1 (δ = 0 contract), Tier 2 (δ within correction bounds), Tier 4 (passthrough). All Tier 3 cases removed.

---

## LEVEL 1 — PRECONDITION VERIFICATION

### CD-PRE-01: Cathedral Output Guard

**Procedure:** Invoke Diagnostic with null Cathedral output.

**PASS:** Precondition error. No δ computed, no verdicts emitted.

**FAIL:** Diagnostic proceeds without Cathedral input.

---

### CD-PRE-02: Mirror Box Output Guard

**Procedure:** Invoke Diagnostic with null Mirror Box output.

**PASS:** Precondition error. No δ computed.

**FAIL:** Diagnostic proceeds without Mirror Box input.

---

### CD-PRE-03: Extraction Confidence Report Guard

**Procedure:** Invoke Diagnostic with null extraction confidence report.

**PASS:** Precondition error identifying missing report. Cause categorization cannot function without it.

**FAIL:** Diagnostic proceeds and attempts triage without the report.

---

## LEVEL 2 — UNIT VERIFICATION

### CD-VC-01: δ Computed for Every Shared Metric

**Requirement:** Every metric where both Cathedral and Mirror Box produce output has a δ.

**Procedure:**
1. Provide Cathedral output with Tier 1 RIBs for 10 devices and Tier 2 timing for 3 cells.
2. Provide Mirror Box output with projections for same 10 devices and scaled metrics for same 3 cells.
3. Execute Module 1.

**PASS:** DeltaRecord exists for every (device, rib), every (device, bgp_session), every (cell, timing), and every (cell, churn). Zero metrics without a δ.

**FAIL:** Any shared metric missing a DeltaRecord.

---

### CD-VC-02: Tier 1 Threshold is Exactly Zero

**Requirement:** Any non-zero δ on a Tier 1 metric is BREACH. No tolerance.

**Procedure:**
1. Provide Cathedral RIB for device A: prefix 10.0.0.0/8 via next-hop X.
2. Provide Mirror Box projection for device A: prefix 10.0.0.0/8 via next-hop Y (different).
3. Execute Module 2.

**PASS:** Verdict for device A RIB is BREACH with threshold = 0.0 and delta = 1.0.

**FAIL:** Verdict is PASS despite non-zero δ. Or threshold is non-zero.

---

### CD-VC-02b: Tier 1 PASS on Exact Match

**Procedure:**
1. Provide identical Cathedral and Mirror Box Tier 1 outputs (same RIBs, same states).
2. Execute Module 2.

**PASS:** Every Tier 1 verdict is PASS with delta = 0.0.

**FAIL:** Any BREACH on an exact match.

---

### CD-VC-03: Tier 2 Threshold Correctly Computed

**Requirement:** threshold = α × |correction_factor − 1| × base_value.

**Procedure:**
1. Set α = 0.1.
2. Provide a Tier 2 metric with correction_factor = 5.0 and base_value = 100.
3. Expected threshold = 0.1 × |5.0 − 1| × 100 = 0.1 × 4.0 × 100 = 40.0.
4. Provide Cathedral prediction = 500, Mirror Box projection = 520 (δ = 20).
5. Execute Module 2.

**PASS:** threshold = 40.0. δ = 20.0 ≤ 40.0. Verdict = PASS.

**FAIL:** Threshold computed incorrectly, or verdict wrong.

---

### CD-VC-03b: Tier 2 BREACH When δ Exceeds Threshold

**Procedure:**
1. Same setup as CD-VC-03 but Mirror Box projection = 560 (δ = 60 > threshold 40).

**PASS:** Verdict = BREACH. δ = 60.0 > threshold 40.0.

**FAIL:** Verdict = PASS despite δ > threshold.

---

### CD-VC-05: Cause Categorization Follows Triage Order

**Requirement:** Tier 1 triage checks IMPORT_ERROR before SIGNATURE_DEFICIENCY before CATHEDRAL_MODEL_ERROR. Tier 2 triage checks DEFAULTED_TIMERS before NONLINEAR_SCALING before TIMER_INTERACTION.

**Procedure (Tier 1):**
1. Create a Tier 1 BREACH where the affected device has parse_status = PARTIALLY_UNRECOGNIZED AND the equivalence class has RIB divergence in Batfish.
2. Execute Module 3.

**PASS:** Cause = IMPORT_ERROR (step 1 in triage). NOT SIGNATURE_DEFICIENCY (step 2). The triage stops at the first matching cause.

**FAIL:** Cause is SIGNATURE_DEFICIENCY or any cause other than IMPORT_ERROR. Triage skipped step 1.

---

### CD-VC-05b: Triage Falls Through When Early Steps Don't Match

**Procedure (Tier 1):**
1. Create a Tier 1 BREACH where all devices have parse_status = PASSED and vendor_confidence = HIGH (step 1 does not match). But Batfish shows RIB divergence within the cell (step 2 matches).
2. Execute Module 3.

**PASS:** Cause = SIGNATURE_DEFICIENCY (step 2). Step 1 was checked and did not match.

**FAIL:** Cause is anything other than SIGNATURE_DEFICIENCY.

---

### CD-VC-06: Extraction Confidence Report Consulted

**Requirement:** During Tier 1 triage, the extraction confidence report is the first thing checked.

**Procedure:**
1. Create a Tier 1 BREACH.
2. Provide an extraction confidence report where the affected device shows PARTIALLY_UNRECOGNIZED.
3. Execute Module 3.

**PASS:** IMPORT_ERROR diagnosed. The triage detail references the extraction confidence report entry for the specific device.

**FAIL:** Triage does not reference the extraction confidence report, or diagnoses a different cause.

---

### CD-VC-07: Tier 4 Passthrough Without δ

**Requirement:** Tier 4 Cathedral predictions are passed through to output with "analytical only" tag and no δ computation.

**Procedure:**
1. Provide Cathedral output with hot-potato divergences and cascade analyses.
2. Execute the full Diagnostic pipeline.

**PASS:** All Tier 4 predictions appear in output with tag = "analytical_only_no_empirical_validation". No DeltaRecord exists for any Tier 4 prediction. No Verdict exists for any Tier 4 prediction.

**FAIL:** δ is computed for a Tier 4 prediction. Or Tier 4 predictions are missing from output. Or tag is wrong.

---

### CD-VC-10: Severity Correctly Assigned

**Requirement:** Each tier × cause combination produces the correct severity.

**Procedure:** For each entry in the severity table, create the matching breach condition and verify.

| Test | Tier | Cause | Expected Severity |
|------|------|-------|------------------|
| 10a | 1 | IMPORT_ERROR | CRITICAL |
| 10b | 1 | SIGNATURE_DEFICIENCY | CRITICAL |
| 10c | 1 | CATHEDRAL_MODEL_ERROR | HIGH |
| 10d | 1 | EMULATION_DIVERGENCE | MEDIUM |
| 10e | 2 | DEFAULTED_TIMERS | MEDIUM |
| 10f | 2 | NONLINEAR_SCALING | LOW |
| 10g | 2 | TIMER_INTERACTION | LOW |

**PASS:** Every test produces the exact expected severity.

**FAIL:** Any severity mismatch.

---

### CD-VC-11: No Automatic Correction

**Requirement:** The Diagnostic never modifies Cathedral, Mirror Box, or Compression Engine state.

**Procedure:**
1. Execute the Diagnostic with a known BREACH.
2. After execution, verify Cathedral predictions are unchanged.
3. Verify Mirror Box projections are unchanged.
4. Verify Compression Engine partition is unchanged.

**PASS:** All upstream state is identical before and after Diagnostic execution. Output is diagnostic + recommendation only.

**FAIL:** Any upstream state is modified.

---

### CD-VC-12: Determinism

**Requirement:** Same inputs → identical outputs.

**Procedure:**
1. Execute the Diagnostic 5 times with identical inputs (Cathedral, Mirror Box, extraction report, π).

**PASS:** All 5 outputs are identical: same δ values, same verdicts, same causes, same severities, same timestamps (except wall-clock timestamp, which may differ but must be deterministic given a fixed clock input).

**FAIL:** Any output differs between runs.

---

### CD-VC-13: α Calibration Documented

**Requirement:** The α value and calibration methodology are included in the Diagnostic output.

**Procedure:**
1. Execute the Diagnostic.
2. Inspect the output for α documentation.

**PASS:** Output contains: α value, number of calibration topologies, compression ratio range tested, and the calibration verdict (whether α produced consistent breach rates across scales).

**FAIL:** α documentation is missing, incomplete, or not present in output.

---

### CD-VC-14: All Outputs Timestamped

**Requirement:** Every δ, verdict, cause categorization, and Tier 4 record has a timestamp.

**Procedure:**
1. Execute the Diagnostic.
2. Enumerate all output records.

**PASS:** Every record has a non-null timestamp field.

**FAIL:** Any record has a null or missing timestamp.

---

## LEVEL 3 — INTEGRATION VERIFICATION

### CD-INT-01: End-to-End Pipeline

**Requirement:** Diagnostic correctly processes outputs from the actual Cathedral and Mirror Box implementations.

**Procedure:**
1. Execute Compression Engine → Cathedral → Mirror Box on a production-representative topology.
2. Feed Cathedral and Mirror Box outputs to the Diagnostic.
3. Verify δ computation, threshold evaluation, and verdict generation.

**PASS:** All Tier 1 metrics show δ = 0 at steady state. All Tier 2 metrics show δ within threshold. All Tier 4 predictions passed through. No unhandled errors.

**FAIL:** Any Tier 1 δ ≠ 0 at steady state (indicates system defect). Or any unhandled error.

---

### CD-INT-02: Breach Detection Under Induced Error

**Requirement:** The Diagnostic correctly detects a deliberately introduced error.

**Procedure:**
1. Run the full pipeline normally (all δ = 0).
2. Modify one device's RIB in the Cathedral output (simulate a Cathedral model error).
3. Re-run the Diagnostic.

**PASS:** The modified device's RIB metric shows BREACH with δ = 1.0. Cause categorization produces CATHEDRAL_MODEL_ERROR (after ruling out IMPORT_ERROR and SIGNATURE_DEFICIENCY). All other metrics remain PASS.

**FAIL:** The induced error is not detected. Or the wrong cause is assigned. Or unaffected metrics are disturbed.

---

### CD-INT-03: No Tier 3 Leakage

**Requirement:** The Diagnostic does not expect, process, or emit any Tier 3 content.

**Procedure:**
1. Execute the full pipeline.
2. Inspect all Diagnostic inputs, internal state, and outputs.

**PASS:** No reference to Tier 3, ρ, confidence intervals, distribution parameters, HOST_CONTENTION, NONSTATIONARITY, or DISTRIBUTION_MISMATCH anywhere in the Diagnostic's processing or output.

**FAIL:** Any Tier 3 artifact present.

---

## LEVEL 4 — OPERATIONAL PROPERTIES

### CD-OP-01: Monotonicity of Concern

**Requirement:** A metric at BREACH does not silently become PASS without the underlying cause being resolved.

**Procedure:**
1. Execute Diagnostic → one metric at BREACH.
2. Re-execute with unchanged inputs.
3. Verify the BREACH persists and is logged in breach_history.
4. Modify the upstream input to fix the cause (correct the Cathedral RIB).
5. Re-execute. Verify the metric returns to PASS.
6. Verify the breach_history still contains the original BREACH record.

**PASS:** BREACH persists when cause persists. BREACH resolves when cause resolves. History is append-only — no records deleted.

**FAIL:** BREACH disappears without cause resolution. Or breach_history loses records.

---

### CD-OP-02: Independence from Upstream Correctness

**Requirement:** The Diagnostic treats Cathedral and Mirror Box outputs as opaque values. It does not verify whether they are individually correct — only whether they agree.

**Procedure:**
1. Provide Cathedral and Mirror Box outputs that are both WRONG (e.g., both predict an incorrect RIB for a device) but agree with each other.
2. Execute the Diagnostic.

**PASS:** δ = 0. Verdict = PASS. The Diagnostic does not detect the error because both sources agree. This is correct behavior — the Diagnostic is a comparator, not a validator.

**FAIL:** The Diagnostic somehow detects the error despite both sources agreeing. (This would mean it has an independent model, which violates its architectural property of having no model.)

---

## APPENDIX — VERDICT RULES

1. A case is PASS if and only if every assertion passes.
2. A case is FAIL if any assertion fails.
3. The Convergence Diagnostic passes verification if and only if every case at every level is PASS.
4. A single FAIL is sufficient to reject the implementation.
5. A FAIL means fix the code, not fix the test.
6. Test evidence is retained for DO-178C audit.

---

*End of Convergence Diagnostic Verification Requirements Specification v1.0*
