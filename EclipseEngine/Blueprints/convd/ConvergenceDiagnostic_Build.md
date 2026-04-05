Version - 1.0
# Convergence Diagnostic — Build Document

> **Purpose:** Source-of-truth implementation blueprint for the NetWatch Convergence Diagnostic — the pure comparator that proves the system's claims are valid by measuring divergence between two independent computations.
>
> **Standard:** DO-178C.
>
> **Architectural identity:** The Convergence Diagnostic has no model. It has no analytical capability. It has no stochastic machinery. It takes two inputs (Cathedral predictions, Mirror Box projections), computes their absolute difference, classifies that difference, and reports. Its simplicity is its strength — it is trivially auditable because it does exactly one thing.
>
> **Scope (post Tier 3 removal):** The Diagnostic compares Tier 1 metrics (δ must be zero), Tier 2 metrics (δ within correction bounds), and passes through Tier 4 predictions (Cathedral-only, no δ computable). All Tier 3 machinery — ρ diagnostics, confidence interval checks, distribution self-consistency, HOST_CONTENTION/NONSTATIONARITY/DISTRIBUTION_MISMATCH cause categories — is out of scope.
>
> **Normative References:**
>
> | Document | Version | Role |
> |----------|---------|------|
> | `Convergence_Diagnostic.md` | 4.3 | Governing specification (with Tier 3 amendments) |
> | `Cathedral.md` | 4.3 | Upstream: analytical predictions |
> | `MirrorBox_Build.md` | 1.0 | Upstream: empirical projections (Tier 1, Tier 2 only) |
> | `Compression_Engine.md` | 4.3 | Upstream: extraction confidence report, π |

---

## §1 — Architectural Position

### 1.1 What the Diagnostic Proves

The product's trustworthiness rests on one property: two independent computations — one from static configuration truth (Cathedral), one from live measurement (Mirror Box) — agree within bounded delta. When they agree, the product's claims are validated. When they disagree, the diagnostic identifies why.

The customer does not trust the vendor. The customer trusts the math: δ = 0 on Tier 1 means the system is correct. δ within bounds on Tier 2 means the scaling corrections are sound. δ outside bounds means something is wrong and the diagnostic explains what.

### 1.2 Execution Preconditions

| ID | Precondition | Verification |
|----|-------------|-------------|
| CD-PRE-01 | Cathedral Tier 1 predictions are available | Assert non-null steady-state RIBs for all V_net devices. |
| CD-PRE-02 | Cathedral Tier 2 predictions are available | Assert non-null timing/churn/SPF predictions with correction factors. |
| CD-PRE-03 | Mirror Box Tier 1 projections are available | Assert non-null projections for all V_net devices. |
| CD-PRE-04 | Mirror Box Tier 2 projections are available | Assert non-null scaled metrics with correction factors. |
| CD-PRE-05 | Extraction confidence report is available | Required for cause categorization during triage. |
| CD-PRE-06 | π is available | Required to identify which equivalence class is affected during triage. |

---

## §2 — Input Data Model

### 2.1 From Cathedral

| Input | Tier | Structure |
|-------|------|-----------|
| Steady-state RIBs | 1 | Per-device: (prefix, next-hop, protocol, metric, AD) |
| Convergence ordering | 1 | Ordered list of ConvergenceEvents per perturbation |
| Convergence timing | 2 | Per-event timestamp with correction_factor and timer_provenance |
| Route churn prediction | 2 | Per-cell count with correction_factor |
| SPF load prediction | 2 | Per-area count with correction_factor |
| Per-prediction confidence tags | All | Tier, defaulted_timers, extraction_tags, confidence_level |
| Tier 4 predictions | 4 | Hot-potato divergences, cascade analyses — passthrough only |

### 2.2 From Mirror Box

| Input | Tier | Structure |
|-------|------|-----------|
| Device projections | 1 | Per-device: replicated BGP/OSPF state, RIB, FIB |
| Scaled metrics | 2 | Per-metric: raw_value, correction_factor, scaled_value, correction_source |

### 2.3 From Compression Engine

| Input | Use |
|-------|-----|
| Extraction confidence report | Cause categorization: check for parse failures, vendor confidence issues, defaulted timers |
| π (partition mapping) | Identify the equivalence class implicated in a breach |

---

## §3 — Internal Data Structures

```
DiagnosticState {
    // δ per metric at current time
    deltas: map<string, DeltaRecord>
    
    // Threshold verdicts
    verdicts: map<string, Verdict>
    
    // Breach log (append-only)
    breach_history: list<BreachRecord>
    
    // Tier 4 passthrough
    tier4_passthrough: list<Tier4Record>
}

DeltaRecord {
    metric_id:          string      // unique metric identifier
    tier:               int         // 1 or 2
    cathedral_value:    any         // analytical prediction
    mirrorbox_value:    any         // empirical projection
    delta:              float       // |cathedral - mirrorbox|
    timestamp:          float
}

Verdict {
    metric_id:          string
    tier:               int
    threshold:          float       // 0 for Tier 1; computed for Tier 2
    delta:              float
    result:             enum        // PASS | BREACH
    cause:              Optional<CauseCategory>     // populated on BREACH
    severity:           Optional<enum>              // CRITICAL | HIGH | MEDIUM | LOW
    triage_detail:      Optional<string>
    timestamp:          float
}

BreachRecord {
    verdict:            Verdict
    resolution:         Optional<string>    // how it was resolved (human-authored)
    resolved_at:        Optional<float>     // when resolved
}

CauseCategory = enum {
    // Tier 1 causes
    IMPORT_ERROR,
    SIGNATURE_DEFICIENCY,
    CATHEDRAL_MODEL_ERROR,
    EMULATION_DIVERGENCE,
    UNKNOWN_TIER1,
    
    // Tier 2 causes
    DEFAULTED_TIMERS,
    NONLINEAR_SCALING,
    TIMER_INTERACTION,
    UNKNOWN_TIER2
}

Tier4Record {
    prediction_type:    string      // "hot_potato_divergence" | "cascade_analysis"
    content:            any
    tag:                string      // always "analytical_only_no_empirical_validation"
    timestamp:          float
}
```

---

## §4 — Module Decomposition

Four modules. The Diagnostic is the thinnest component in the system.

### Module 1: δ Computation Engine

**Purpose:** For every metric where both Cathedral and Mirror Box produce output, compute δ = |Cathedral − MirrorBox|.

**Algorithm:**

```
FUNCTION compute_deltas(cathedral_output, mirrorbox_output):
    
    deltas = {}
    
    // ── Tier 1: discrete metrics (RIBs, FSM states) ──
    FOR EACH device IN V_net:
        // RIB comparison
        cathedral_rib = cathedral_output.ribs[device]
        mirrorbox_rib = mirrorbox_output.projections[device].rib
        
        rib_match = compare_ribs_structural(cathedral_rib, mirrorbox_rib)
        deltas[f"{device}:rib"] = DeltaRecord(
            metric_id = f"{device}:rib",
            tier = 1,
            cathedral_value = cathedral_rib,
            mirrorbox_value = mirrorbox_rib,
            delta = 0.0 if rib_match else 1.0,
            timestamp = now()
        )
        
        // BGP session states
        FOR EACH peer IN cathedral_output.bgp_sessions[device]:
            c_state = cathedral_output.bgp_sessions[device][peer]
            m_state = mirrorbox_output.projections[device].bgp_sessions.get(peer)
            deltas[f"{device}:bgp:{peer}"] = DeltaRecord(
                metric_id = f"{device}:bgp:{peer}",
                tier = 1,
                cathedral_value = c_state,
                mirrorbox_value = m_state,
                delta = 0.0 if c_state == m_state else 1.0,
                timestamp = now()
            )
        
        // OSPF adjacency states (same pattern)
        ...
    
    // ── Tier 1: convergence ordering ──
    FOR EACH perturbation IN cathedral_output.perturbation_results:
        c_ordering = perturbation.convergence_sequence
        m_ordering = mirrorbox_output.convergence_events  // from live observation
        
        ordering_match = compare_orderings(c_ordering, m_ordering)
        deltas[f"perturbation:{perturbation.id}:ordering"] = DeltaRecord(
            metric_id = f"perturbation:{perturbation.id}:ordering",
            tier = 1,
            delta = 0.0 if ordering_match else 1.0,
            timestamp = now()
        )
    
    // ── Tier 2: scaled metrics ──
    FOR EACH metric IN mirrorbox_output.scaled_metrics:
        cathedral_prediction = cathedral_output.get_tier2_prediction(metric.metric_name, metric.cell_id)
        
        deltas[metric.metric_name] = DeltaRecord(
            metric_id = f"{metric.cell_id}:{metric.metric_name}",
            tier = 2,
            cathedral_value = cathedral_prediction,
            mirrorbox_value = metric.scaled_value,
            delta = abs(cathedral_prediction - metric.scaled_value),
            timestamp = now()
        )
    
    RETURN deltas
```

**Invariants:**
- δ is computed for every metric where both sources produce output.
- No δ is computed for Tier 4 metrics (Cathedral-only).
- δ for Tier 1 discrete metrics is binary: 0 (match) or 1 (mismatch).

---

### Module 2: Threshold Engine

**Purpose:** Compare each δ against its tier-specific threshold. Emit PASS or BREACH.

**Algorithm:**

```
FUNCTION evaluate_thresholds(deltas, cathedral_output):
    
    verdicts = {}
    
    FOR EACH (metric_id, delta_record) IN deltas:
        
        v = Verdict()
        v.metric_id = metric_id
        v.tier = delta_record.tier
        v.delta = delta_record.delta
        v.timestamp = delta_record.timestamp
        
        IF delta_record.tier == 1:
            // Tier 1: threshold is exactly zero
            v.threshold = 0.0
            v.result = PASS if delta_record.delta == 0.0 else BREACH
        
        ELSE IF delta_record.tier == 2:
            // Tier 2: threshold = α × |correction_factor − 1| × base_value
            correction_factor = get_correction_factor(metric_id, cathedral_output)
            base_value = get_base_value(metric_id, cathedral_output)
            alpha = get_alpha()  // configurable, initially 0.1
            
            v.threshold = alpha * abs(correction_factor - 1) * base_value
            v.result = PASS if delta_record.delta <= v.threshold else BREACH
        
        verdicts[metric_id] = v
    
    RETURN verdicts
```

**Tier 1 threshold = 0.** This is absolute. Any non-zero δ on a Tier 1 metric is a BREACH. There is no tolerance, no rounding, no "close enough." For discrete metrics (BGP state, RIB contents), δ is binary — either the states match or they don't.

**Tier 2 threshold formula:** `threshold = α × |correction_factor − 1| × base_value`. This is proportional to the correction magnitude. A 10× compression ratio with α = 0.1 means 10% of the correction gap is acceptable. The α coefficient is calibrated at integration testing against golden regression topologies.

---

### Module 3: Cause Categorization (Triage)

**Purpose:** When δ exceeds threshold, diagnose WHY. The cause categories are an ordered decision tree, checked in sequence.

**Tier 1 Triage:**

```
FUNCTION triage_tier1(verdict, extraction_report, pi, bf_session):
    
    affected_cell = pi.get_cell_for_metric(verdict.metric_id)
    
    // Step 1: Check extraction confidence
    FOR EACH device IN pi.get_members(affected_cell):
        entry = extraction_report.get(device)
        IF entry.parse_status IN {PARTIALLY_UNRECOGNIZED, FAILED}:
            RETURN CauseCategory.IMPORT_ERROR, 
                f"Device {device}: parse_status = {entry.parse_status}"
        IF entry.vendor_confidence IN {MEDIUM, LOW}:
            RETURN CauseCategory.IMPORT_ERROR,
                f"Device {device}: vendor_confidence = {entry.vendor_confidence}"
    
    // Step 2: Batfish cross-validation of the equivalence class
    members = pi.get_members(affected_cell)
    FOR EACH (a, b) IN pairs(members):
        rib_a = bf_session.q.routes(nodes=a).answer()
        rib_b = bf_session.q.routes(nodes=b).answer()
        IF NOT structurally_equivalent(rib_a, rib_b):
            RETURN CauseCategory.SIGNATURE_DEFICIENCY,
                f"Devices {a} and {b} in same cell but RIBs differ"
    
    // Step 3: Cathedral model vs RFC check
    // (This is a manual investigation flag, not an automated check)
    RETURN CauseCategory.CATHEDRAL_MODEL_ERROR,
        "Cathedral FSM may not match RFC for affected protocol. Investigate."
    
    // Steps 4-5 escalate further — EMULATION_DIVERGENCE, UNKNOWN_TIER1
```

**Tier 2 Triage:**

```
FUNCTION triage_tier2(verdict, extraction_report):
    
    // Step 1: Check for defaulted timers
    affected_metrics = get_timer_dependencies(verdict.metric_id)
    FOR EACH timer IN affected_metrics:
        provenance = extraction_report.get_timer_provenance(timer)
        IF provenance.is_defaulted:
            RETURN CauseCategory.DEFAULTED_TIMERS,
                f"Timer {timer.name} defaulted to {provenance.value} ({provenance.default_source})"
    
    // Step 2: Check correction factor linearity
    IF correction_factor_is_linear(verdict.metric_id):
        RETURN CauseCategory.NONLINEAR_SCALING,
            f"Linear correction factor insufficient for this topology"
    
    // Step 3: Check timer interaction effects
    IF metric_involves_mrai(verdict.metric_id):
        RETURN CauseCategory.TIMER_INTERACTION,
            "MRAI interaction at production diameter"
    
    // Step 4: Unknown
    RETURN CauseCategory.UNKNOWN_TIER2, "Investigate correction factor assumptions"
```

---

### Module 4: Output Assembly

**Purpose:** Package everything for downstream consumers.

**Outputs:**

| Artifact | Consumers | Content |
|----------|-----------|---------|
| δ_m(t) per metric | Certification Report, Dashboard | Every δ with its tier, threshold, and verdict. |
| Threshold verdicts | Certification Report, Dashboard, Alert System | PASS or BREACH per metric. |
| Cause categorization | Certification Report, Alert System | On BREACH: cause category, supporting evidence, triage recommendation. |
| Tier 4 passthrough | Certification Report | Cathedral-only predictions with "analytical only" tag. |
| Breach history | Certification Report | Append-only log of all breaches and their resolutions. |
| α calibration record | Certification Report | The α value, calibration dataset, and calibration methodology. |

**Tier 4 passthrough handling:**

```
FUNCTION passthrough_tier4(cathedral_output):
    
    records = []
    
    FOR EACH hot_potato IN cathedral_output.hot_potato_divergences:
        records.append(Tier4Record(
            prediction_type = "hot_potato_divergence",
            content = hot_potato,
            tag = "analytical_only_no_empirical_validation",
            timestamp = now()
        ))
    
    FOR EACH cascade IN cathedral_output.cascade_analyses:
        records.append(Tier4Record(
            prediction_type = "cascade_analysis",
            content = cascade,
            tag = "analytical_only_no_empirical_validation",
            timestamp = now()
        ))
    
    RETURN records
```

---

## §5 — Severity and Response

### Tier 1 Breach Response

| Severity | Condition | Response |
|----------|-----------|----------|
| CRITICAL | IMPORT_ERROR or SIGNATURE_DEFICIENCY | Halt SLA claims for the affected equivalence class. Projections for affected devices marked unvalidated. |
| HIGH | CATHEDRAL_MODEL_ERROR | Suspend Cathedral predictions for the affected protocol. Mirror Box projections remain valid (live measurement). |
| MEDIUM | EMULATION_DIVERGENCE | Flag FRR investigation needed. Document as known divergence. |

### Tier 2 Breach Response

| Severity | Condition | Response |
|----------|-----------|----------|
| MEDIUM | DEFAULTED_TIMERS | Flag in cert report. Recommend customer provide actual timer config. |
| LOW | NONLINEAR_SCALING or TIMER_INTERACTION | Flag in cert report. Mark correction factor as approximate. |

### No Automatic Correction

The Diagnostic never modifies Cathedral predictions, Mirror Box projections, or the Compression Engine's partition. It reports and recommends. Corrections are human-authorized changes.

**DO-178C rationale:** Automatic self-correction creates a feedback loop that is difficult to verify and audit. Separating diagnosis from correction keeps guarantees traceable to specification at all times.

---

## §6 — Operational Properties

### Determinism

Same Cathedral + same Mirror Box + same extraction confidence report → identical diagnostic output. No randomness. No external state.

### Monotonicity of Concern

A metric at BREACH does not silently become PASS without the underlying cause being resolved. The breach is logged in breach_history. If the upstream inputs change and δ returns to within threshold, the metric returns to PASS, but the breach history is retained for audit.

### Independence from Upstream Correctness

The Diagnostic does not trust Cathedral or Mirror Box. It treats their outputs as opaque values and compares them. If both are wrong identically (same error in both), δ = 0 and the breach is undetectable — but this requires two independent systems to fail identically, which is the architectural reason for having two independent systems.

---

## §7 — Removed Scope (Tier 3 Amendments)

The following are formally OUT OF SCOPE per the Mirror Box Tier 3 removal:

| Removed | Original Location | Reason |
|---------|------------------|--------|
| Tier 3 δ computation | CD spec §Per-Tier δ Semantics, "Tier 3" | No Tier 3 Mirror Box outputs exist. |
| Tier 3 threshold (CI_width / 2) | CD spec §Threshold Table | No CIs to compare against. |
| Tier 3 cause categorization (HOST_CONTENTION, NONSTATIONARITY, DISTRIBUTION_MISMATCH) | CD spec §Cause Categorization, "For Tier 3 Breaches" | No Tier 3 breaches possible. |
| Tier 3 self-consistency checks (T3-SC-1 through T3-SC-4) | CD spec §Tier 3 Self-Consistency | No Tier 3 metrics to check. |
| ρ diagnostic (pattern classification, host health indicator) | CD spec §The ρ Diagnostic | ρ not measured by Mirror Box. |
| ρ_measured input | CD spec §Upstream: Mirror Box | Mirror Box no longer measures ρ. |
| Tier 3 projections input | CD spec §Upstream: Mirror Box | Mirror Box no longer emits Tier 3. |
| Tier 3 breach response | CD spec §Feedback Mechanism | No Tier 3 breaches. |
| UNKNOWN_TIER3 cause category | CD spec §Cause Categorization | No Tier 3 triage. |

**Verification criteria affected:**

| Original VC | Disposition |
|-------------|-------------|
| CD-VC-04 (Tier 3 threshold uses CI width) | REMOVED — no Tier 3 threshold. |
| CD-VC-08 (Tier 3 self-consistency checks fire) | REMOVED — no Tier 3 checks. |
| CD-VC-09 (ρ diagnostic classifies patterns) | REMOVED — no ρ diagnostic. |

---

## §8 — Dependency Graph

```
Cathedral Output ───────────────┐
                                ▼
                    ┌───────────────────────┐
Mirror Box Output ──►  CONVERGENCE          │
                    │  DIAGNOSTIC           │
Extraction Report ──►  (this component)     │
π ──────────────────►                       │
                    └───────────────────────┘
                                │
                    ┌───────────┼───────────┐
                    ▼           ▼           ▼
              Cert Report   Dashboard   Alert System
```

No upstream dependencies beyond receiving the four inputs. No downstream feedback loops. The Diagnostic is a leaf node in the dependency graph — it reads, computes, and reports. Nothing depends on its output for correctness of any other component.

---

## §9 — Traceability Matrix

| VC | Requirement | Module | Test Method |
|----|------------|--------|-------------|
| CD-VC-01 | δ computed for every shared metric | 1 | Feed known Cathedral + Mirror Box outputs. Assert δ exists for every shared metric. |
| CD-VC-02 | Tier 1 threshold is exactly 0 | 2 | Feed Tier 1 δ = 0.0001. Assert BREACH. |
| CD-VC-03 | Tier 2 threshold correctly computed | 2 | Feed known α, correction_factor, base_value. Assert threshold = α × \|factor − 1\| × base_value. |
| CD-VC-05 | Cause categorization follows triage order | 3 | For each cause, feed inputs that trigger it. Assert correct cause selected. Assert triage steps not skipped. |
| CD-VC-06 | Extraction confidence consulted during triage | 3 | Feed Tier 1 breach with PARTIALLY_UNRECOGNIZED device. Assert IMPORT_ERROR diagnosed first. |
| CD-VC-07 | Tier 4 passed through without δ | 4 | Feed Tier 4 predictions. Assert "analytical only" tag. Assert no δ computed. |
| CD-VC-10 | Severity correctly assigned | 3, 4 | For each tier × cause, verify severity matches the table. |
| CD-VC-11 | No automatic correction | All | Assert no write to Cathedral, Mirror Box, or Compression Engine state. Output is diagnostic only. |
| CD-VC-12 | Deterministic | All | Same inputs → identical outputs. 5 runs. |
| CD-VC-13 | α calibration documented | 4 | Assert α value and calibration dataset present in output. |
| CD-VC-14 | All outputs timestamped | 4 | Assert every δ, verdict, cause, and Tier 4 record has non-null timestamp. |

---

*End of Convergence Diagnostic Build Document v1.0*
