Version - 1.0
# Compression Engine — Verification Requirements Specification

> **Document Type:** Software Verification Cases and Procedures (SVCP)
>
> **Purpose:** This document defines the binary pass/fail acceptance criteria for every testable requirement of the compression engine implementation. An independent verification engineer reads this document, executes the specified procedures against the implementation, and stamps each case PASS or FAIL. There is no "partial pass," no "close enough," and no room for interpretation. The code either satisfies the stated condition or it does not.
>
> **Scope:** Covers the compression engine component only — from M_verified intake through six-artifact emission. Does not cover upstream (State Space pipeline), downstream (Cathedral, Mirror Box, VM Instantiation), or lateral (Entity Store definitions) components except at their interface boundaries with the compression engine.
>
> **Governing Documents:**
>
> | Document | Version | Relationship |
> |----------|---------|-------------|
> | `Compression_Engine.md` | 4.3 | Source requirements |
> | `Compression_Engine_Build.md` | 1.0 | Implementation blueprint |
> | `State_Space_Stage_4.md` | 4.3 | Upstream interface contract |
> | `Entity_Store.md` | 4.3 | Lateral interface contract |
> | `Cathedral.md` | 4.3 | Downstream interface contract |
> | `math_validation.py` | 1.0 | Mathematical foundation proofs |
>
> **Standard:** DO-178C. Every case in this document traces backward to a requirement in the specification and forward to a test procedure and expected result. The traceability chain is: Spec Requirement → SVCP Case → Test Procedure → Test Evidence → PASS/FAIL.
>
> **Verification Levels:**
>
> | Level | Prefix | What It Tests |
> |-------|--------|--------------|
> | Precondition | PRE | Input contract assertions — does the code reject invalid upstream data? |
> | Unit | VC | Individual module correctness — does each module produce correct output from correct input? |
> | Invariant | INV | Runtime invariants — do internal data structures maintain their required properties? |
> | Integration | INT | Module-to-module contracts — do modules compose correctly? |
> | Output | OUT | Downstream consumer contracts — do output artifacts satisfy what consumers expect? |
> | Mathematical | MTH | Mathematical foundation — do the core algorithms satisfy their theoretical guarantees? |
>
> **Notation:** "Assert X" means: evaluate condition X. If X is true, the check passes. If X is false, the check fails and the entire case is FAIL. A case with multiple assertions is PASS only if every assertion passes.

---

## LEVEL 1 — PRECONDITION VERIFICATION

These cases verify that the compression engine correctly enforces its input contracts. The compression engine must reject invalid upstream data with a diagnostic — not silently proceed with corrupt inputs.

---

### PRE-01: Disposition Guard

**Requirement:** Compression engine executes only on GREEN or YELLOW disposition. RED must not reach execution.

**Procedure:**
1. Construct a minimal valid M_verified (1 device, 1 edge).
2. Set disposition = RED.
3. Invoke the compression engine entry point.

**PASS:** The compression engine raises a precondition violation error before performing any computation. The error message identifies "disposition = RED" as the violation. No output artifacts are produced. No Batfish queries are issued.

**FAIL:** The compression engine begins computation, produces any output artifact, issues any Batfish query, or raises an error that does not identify the disposition violation.

---

### PRE-02: Empty Topology Guard

**Requirement:** Compression engine rejects an empty M_verified.

**Procedure:**
1. Construct an M_verified with zero devices and zero edges.
2. Set disposition = GREEN, directive set = empty.
3. Invoke the compression engine.

**PASS:** Precondition violation error raised. Error identifies "|V_net ∪ V_inf| = 0" or equivalent. No output artifacts produced.

**FAIL:** Any computation begins, or error does not identify the empty topology.

---

### PRE-03: Untagged Field Guard

**Requirement:** Every field in M_verified must carry a fidelity tag.

**Procedure:**
1. Construct a valid M_verified with 3 devices.
2. Remove the fidelity tag from one field on one device (set tag = null).
3. Set disposition = GREEN.
4. Invoke the compression engine.

**PASS:** Precondition violation error raised. Error identifies the specific device and field with the missing tag.

**FAIL:** Compression engine proceeds past precondition checks with the untagged field.

---

### PRE-04: YELLOW Directive Consistency Guard

**Requirement:** YELLOW disposition must have a non-empty directive set.

**Procedure:**
1. Construct a valid M_verified.
2. Set disposition = YELLOW, directive set = empty.
3. Invoke the compression engine.

**PASS:** Precondition violation error raised. Error identifies "YELLOW disposition with empty directive set."

**FAIL:** Computation proceeds with YELLOW and no directives.

---

### PRE-05: GREEN Directive Consistency Guard

**Requirement:** GREEN disposition must have an empty directive set.

**Procedure:**
1. Construct a valid M_verified.
2. Set disposition = GREEN.
3. Add one field_exclusion directive to the directive set.
4. Invoke the compression engine.

**PASS:** Precondition violation error raised. Error identifies "GREEN disposition with non-empty directive set."

**FAIL:** Computation proceeds with GREEN and a directive set.

---

### PRE-06: Directive Device Reference Guard

**Requirement:** Every directive must reference devices that exist in M_verified.

**Procedure:**
1. Construct a valid M_verified with devices {"A", "B", "C"}.
2. Set disposition = YELLOW.
3. Add a force_singleton directive with affected_devices = {"A", "D"} (where "D" does not exist in M_verified).
4. Invoke the compression engine.

**PASS:** Precondition violation error raised. Error identifies device "D" as not found in M_verified.

**FAIL:** Compression engine ignores the invalid device reference or proceeds without error.

---

### PRE-07: Batfish Session Guard

**Requirement:** Batfish session must be initialized and queryable.

**Procedure:**
1. Construct a valid M_verified and GREEN disposition.
2. Provide a null or uninitialized Batfish session reference.
3. Invoke the compression engine.

**PASS:** Precondition violation error raised before any computation. Error identifies Batfish session as unavailable.

**FAIL:** Compression engine begins signature computation or any other work before verifying Batfish.

---

## LEVEL 2 — UNIT VERIFICATION (VC-01 through VC-20)

These cases correspond directly to the 20 verification criteria defined in the Compression Engine specification. Each case has an exact input specification, procedure, and binary pass/fail condition.

---

### VC-01: Signature Determinism

**Requirement:** σ(v) is a deterministic function. Same M_verified → same hash, every time, regardless of execution environment.

**Procedure:**
1. Construct a valid M_verified with ≥10 devices of ≥3 distinct vendor classes.
2. Set disposition = GREEN, directive set = empty.
3. Execute signature computation (Module 2) 10 times on identical input.
4. Collect the signature registry output from each run.

**PASS:** All of the following hold:
- For every device d, the 10 computed σ(d) values are bit-identical.
- The ordered list of (device, signature) pairs is identical across all 10 runs.
- No device's signature changes between runs.

**FAIL:** Any device's signature differs between any two runs.

---

### VC-02: Extraction Gate — Parse Failure Detection

**Requirement:** Devices with parse failures receive unique signatures and are forced to singleton equivalence classes.

**Procedure:**
1. Construct M_verified with 6 devices:
   - Devices A, B, C: parse_status = PASSED, identical configurations.
   - Device D: parse_status = PARTIALLY_UNRECOGNIZED, identical configuration to A/B/C.
   - Device E: parse_status = FAILED.
   - Device F: has critical init_issues (undefined route-map reference in BGP config).
2. Set disposition = GREEN, directive set = empty.
3. Execute Module 1 (extraction confidence) and Module 2 (signature computation).

**PASS:** All of the following hold:
- σ(A) = σ(B) = σ(C). These three share a signature.
- σ(D) ≠ σ(A). Device D has a unique signature despite identical config.
- σ(E) ≠ σ(A) and σ(E) ≠ σ(D). Device E has a unique signature.
- σ(F) ≠ σ(A) and σ(F) ≠ σ(D) and σ(F) ≠ σ(E). Device F has a unique signature.
- The extraction confidence ledger shows D, E, F with extraction_gate_result ≠ PASSED.
- The extraction confidence ledger shows A, B, C with extraction_gate_result = PASSED.

**FAIL:** Any gate-failed device shares a signature with a gate-passed device. Or any gate-failed device is not flagged in the extraction confidence ledger.

---

### VC-03: Signature Robustness Rule — Vendor-Class-Wide Exclusion

**Requirement:** If a ◐ field is unextractable for any device in a vendor class, that field is excluded from σ for ALL devices in the vendor class.

**Procedure:**
1. Construct M_verified with 4 devices, all vendor_class = "cisco_nxos":
   - Devices A, B, C: BGP keepalive timer (◐ field) is extractable, value = 30s.
   - Device D: BGP keepalive timer (◐ field) is unextractable (fidelity_tag = K, value = missing/default).
   - All 4 devices have identical configuration on all ● fields.
   - Devices A and B have keepalive = 30s. Device C has keepalive = 60s.
2. Set disposition = GREEN.
3. Execute Module 1 and Module 2.

**PASS:** All of the following hold:
- The extraction confidence ledger shows BGP keepalive timer excluded_in_sigma = true, exclusion_reason = "robustness_rule" for ALL 4 devices (A, B, C, D) — not just D.
- The vendor_class_exclusions map contains ("cisco_nxos" → {"bgp_keepalive_timer"}).
- σ(A) = σ(B) = σ(C). Despite C having a different keepalive value, the field is excluded, so all three match.
- σ(D) ≠ σ(A) ONLY if D differs on other non-excluded fields. If D is identical on all included fields, σ(D) = σ(A).

**FAIL:** The keepalive timer contributes to σ for any device in vendor class "cisco_nxos." Or the robustness rule is applied only to device D and not to A, B, C.

---

### VC-04: Field Exclusion Directives

**Requirement:** field_exclusion directives remove specified fields from σ for affected devices before signature computation occurs.

**Procedure:**
1. Construct M_verified with 4 devices (A, B, C, D), identical configuration, vendor_class = "arista".
2. Set disposition = YELLOW.
3. Add a field_exclusion directive: source_predicate = "FF-1.3.01", affected_devices = {A, B}, affected_fields = {("named_structures", "route_map_content")}.
4. Execute Module 1 and Module 2.

**PASS:** All of the following hold:
- The signature_details for devices A and B do NOT include "route_map_content" in fields_included.
- The signature_details for devices C and D DO include "route_map_content" in fields_included.
- The extraction confidence ledger shows A and B with route_map_content.included_in_sigma = false, exclusion_reason = "field_exclusion_directive".
- If A/B and C/D had different route-map content, σ(A) may now equal σ(C) because the distinguishing field was excluded from A's signature. This is correct behavior.

**FAIL:** Route-map content appears in the fields_included for devices A or B. Or the exclusion is not documented in the extraction confidence ledger.

---

### VC-05: Singleton Forcing Directives

**Requirement:** force_singleton directives produce |Cᵢ| = 1 for affected devices, regardless of their configuration.

**Procedure:**
1. Construct M_verified with 4 identical devices (A, B, C, D).
2. Set disposition = YELLOW.
3. Add a force_singleton directive: affected_devices = {B, C}.
4. Execute Modules 1 through 3.

**PASS:** All of the following hold:
- In the final partition, device B is in a cell with |Cᵢ| = 1 (alone).
- In the final partition, device C is in a cell with |Cᵢ| = 1 (alone).
- Devices A and D are in the same cell (their signatures match and they are not singleton-forced).
- The extraction confidence ledger shows B and C with extraction_gate_result = FAILED_SINGLETON_FORCED.
- B and C do not have computed behavioral signatures (they received σ = hash(hostname)).

**FAIL:** B or C shares a cell with any other device. Or B or C has a computed (non-unique) behavioral signature.

---

### VC-06: Partition Equitability

**Requirement:** The final partition π is equitable — for every cell pair (Cᵢ, Cⱼ) and every edge type e, every vertex in Cᵢ has the same number of e-type neighbors in Cⱼ.

**Procedure:**
1. Execute the compression engine on any valid topology (run this case on every test topology in the suite).
2. Extract the final partition state after Module 4 (post-cross-validation).
3. For every pair of cells (Cᵢ, Cⱼ), for every edge type e present in the graph:
   a. Compute count(v, Cⱼ, e) = number of e-type neighbors of v in Cⱼ, for every v ∈ Cᵢ.
   b. Collect all counts into a set S.

**PASS:** |S| ≤ 1 for every (Cᵢ, Cⱼ, e) triple. Every vertex in every cell has uniform neighbor counts to every other cell on every edge type.

**FAIL:** |S| > 1 for any (Cᵢ, Cⱼ, e) triple. Any non-uniformity in neighbor counts.

---

### VC-07: Weisfeiler-Leman Refinement Correctness

**Requirement:** W-L refinement splits cells where signature-identical devices have non-isomorphic neighborhoods.

**Procedure:**
1. Construct a topology where structural asymmetry exists despite identical signatures:
   - 2 spines (identical config), 4 leaves (identical config).
   - Leaves 1–2 connect to BOTH spines. Leaves 3–4 connect only to spine-1.
2. Execute Modules 1 through 3.

**PASS:** All of the following hold:
- The initial partition (before W-L) groups all 4 leaves in one cell.
- The final partition (after W-L) splits leaves into exactly 2 cells: {leaf-1, leaf-2} and {leaf-3, leaf-4}.
- The refinement log contains an entry documenting the split with reason "weisfeiler_leman_structural_asymmetry" or equivalent.
- The final partition is equitable (per VC-06).

**FAIL:** Leaves are not split. Or leaves are split into the wrong groups. Or the refinement log does not document the split.

---

### VC-08: Batfish RIB Cross-Validation

**Requirement:** For every non-singleton cell, the RIB contents of the representative and at least one other member are structurally equivalent.

**Procedure:**
1. Execute the compression engine through Module 4 (cross-validation).
2. For each non-singleton cell in the partition:
   a. Identify the representative and at least one other member.
   b. Retrieve the cross-validation result for the (representative, other_member) pair with validation_type = RIB.

**PASS:** All of the following hold:
- Every non-singleton cell has at least one RIB cross-validation result.
- Every result has result = PASS.
- "Structurally equivalent" means: same prefixes, same protocol sources, same administrative distances, same metrics, same communities, same local preferences, same AS-path lengths. Next-hop IPs may differ.

**FAIL:** Any cell is missing a RIB cross-validation result. Or any result has result = MISMATCH and the mismatch was not resolved by cell splitting.

---

### VC-09: Batfish BGP Session Cross-Validation

**Requirement:** For every non-singleton cell, all members show identical BGP session topology.

**Procedure:**
1. Execute through Module 4.
2. For each non-singleton cell, retrieve BGP_SESSION cross-validation results.

**PASS:** All of the following hold:
- Every non-singleton cell has at least one BGP session cross-validation result.
- Every result has result = PASS.
- "Identical session topology" means: same number of established sessions, same number of non-established sessions, same session states per peer direction (upstream/downstream/same-tier).

**FAIL:** Any cell missing a result, or any unresolved MISMATCH.

---

### VC-10: Batfish ACL Cross-Validation

**Requirement:** For every non-singleton leaf cell, all members produce identical ACL behavior on server-facing interfaces.

**Procedure:**
1. Execute through Module 4.
2. Identify all leaf cells (cells containing devices classified as leaf/ToR by topology position).
3. For each non-singleton leaf cell, retrieve ACL cross-validation results.

**PASS:** All of the following hold:
- Every non-singleton leaf cell has at least one ACL cross-validation result.
- Every result has result = PASS.
- "Identical behavior" means: for every possible packet header combination, the ACL produces the same permit/deny decision on both members. This is verified by Batfish's symbolic analysis (BDD/Z3), not by sampling.

**FAIL:** Any leaf cell missing a result, or any unresolved MISMATCH.

---

### VC-11: Rule 1 — Minimum Representative Count

**Requirement:** Every V_net cell has |Rᵢ| ≥ 2.

**Procedure:**
1. Execute through Module 5 (representative selection).
2. For every cell where is_v_inf = false, count |representatives|.

**PASS:** |representatives| ≥ 2 for every V_net cell, without exception.

**FAIL:** Any V_net cell has |representatives| < 2.

---

### VC-12: Rule 2 — Unique External Peering Preservation

**Requirement:** Every unique external BGP peering relationship in the production topology is represented in G_c.

**Procedure:**
1. Enumerate all external BGP peering relationships in M_verified: each (internal_device, external_peer) pair where the external peer's ASN differs from the internal network's ASN.
2. For each external peering, verify that the internal device OR its representative is in V_c.
3. Verify that the edge to the external peer exists in E_c.

**PASS:** Every external peering relationship has a corresponding representative and edge in G_c. No external peer is unreachable in the compressed graph.

**FAIL:** Any external peering is missing from G_c — either the internal device is not represented, or the edge to the external peer is not preserved.

---

### VC-13: Rule 3 — Tier-to-Tier Connectivity

**Requirement:** Every kept leaf connects to every kept spine in G_c. The inter-tier adjacency is complete bipartite.

**Procedure:**
1. Identify all representative leaves and representative spines in V_c.
2. For every (leaf_rep, spine_rep) pair, verify an edge exists in E_c.

**PASS:** The subgraph of G_c induced by {leaf representatives} × {spine representatives} is complete bipartite. Every leaf rep connects to every spine rep.

**FAIL:** Any (leaf_rep, spine_rep) pair lacks an edge in G_c.

---

### VC-14: Rule 4 — Singleton Inclusion

**Requirement:** Every device that is the sole member of its cell (|Cᵢ| = 1) appears in V_c.

**Procedure:**
1. Identify all cells with |members| = 1.
2. For each, verify the sole member is in V_c (the compressed graph's vertex set).

**PASS:** Every singleton device is in V_c.

**FAIL:** Any singleton device is missing from V_c.

---

### VC-15: Rules 5–7 — V_inf Compression

**Requirement:** V_inf (server/endpoint) compression satisfies three sub-rules.

**Procedure:**
1. Identify all racks in the compressed topology (inferred from leaf-pair connectivity).
2. For each rack:
   a. Count V_inf representatives.
   b. Enumerate represented endpoint types.
   c. Check dual-homing model.

**PASS — Rule 5:** Every rack has 2 or 3 V_inf representatives.
**PASS — Rule 6:** Every distinct inferred endpoint type within a rack has at least one representative.
**PASS — Rule 7:** Where ESI is undetectable (dual_homing_model = "esi_undetectable_conservative"), both leaf-facing connections are preserved for each representative endpoint.

**FAIL:** Any rack violates any of the three sub-rules.

---

### VC-16: Route Propagation Path Completeness

**Requirement:** Every policy interaction chain in the production network has a corresponding path in G_c.

**Procedure:**
1. Execute Module 6 (path completeness).
2. Retrieve the list of detected interaction chains.
3. For each chain (Device A sets attribute X → propagation → Device B matches attribute X):
   a. Verify rep(A) ∈ V_c.
   b. Verify rep(B) ∈ V_c.
   c. Verify a BGP propagation path exists from rep(A) to rep(B) in G_c (possibly through intermediate representatives).

**PASS:** Every interaction chain has a complete path in G_c.

**FAIL:** Any interaction chain has no corresponding path in G_c.

---

### VC-17: Regression Validation — differentialReachability

**Requirement:** The differentialReachability output is computed and included in the mapping report.

**Procedure:**
1. Execute Module 7 (graph construction).
2. Check if the differential_reachability capability tag is C.
   - If C: Verify that `bf.q.differentialReachability()` was called and its output is stored in the CompressedGraph.
   - If K or R: Verify that the mapping report documents "differentialReachability unavailable" with the capability tag classification.

**PASS (capability = C):** The differentialReachability output is non-empty and is present in the mapping report's regression validation section.

**PASS (capability = K or R):** The mapping report documents the gap with the specific capability tag classification.

**FAIL:** Capability is C but no differentialReachability output exists. Or capability is K/R but the gap is not documented.

---

### VC-18: Output Artifact Completeness

**Requirement:** The compression engine produces exactly six artifacts.

**Procedure:**
1. Execute the complete compression engine pipeline.
2. Enumerate the output artifacts.

**PASS:** Exactly six artifacts are emitted, each non-null and non-empty:
1. G_c (compressed graph) — has |V_c| > 0 vertices and |E_c| ≥ 0 edges.
2. π (partition mapping) — maps every V_net device to a cell.
3. |Cᵢ| (cell sizes) — one positive integer per cell. Sum equals |V_net|.
4. bᵢⱼ (inter-cell connectivity) — one non-negative integer per cell pair.
5. Mapping report — non-empty structured document.
6. Extraction confidence report — non-empty structured document.

**FAIL:** Fewer than six artifacts. Or any artifact is null, empty, or structurally invalid. Or more than six artifacts are produced.

---

### VC-19: Mapping Report Device Coverage

**Requirement:** Every production device appears exactly once in the mapping report.

**Procedure:**
1. Execute the full pipeline.
2. Extract the set of devices mentioned in the mapping report.
3. Compare against V_net ∪ V_inf from M_verified.

**PASS:** The two sets are identical. Every device in M_verified appears exactly once in the mapping report. No device appears twice. No device is missing. No device appears in the mapping report that is not in M_verified.

**FAIL:** Any device missing, duplicated, or phantom (present in report but not in M_verified).

---

### VC-20: Extraction Confidence Report Device Coverage

**Requirement:** Every production device has a per-field confidence assessment.

**Procedure:**
1. Execute the full pipeline.
2. For every device in M_verified, check that the extraction confidence report contains an entry.
3. For every device entry, check that every field in the Entity Store's field inventory for that device's type has a FieldConfidence record.

**PASS:** Every device has an entry. Every entry has a FieldConfidence record for every applicable field. No gaps.

**FAIL:** Any device missing from the report. Or any device entry missing a FieldConfidence record for an applicable field.

---

## LEVEL 3 — INVARIANT VERIFICATION

These cases verify that internal data structures maintain their required properties throughout execution. Invariant checks run continuously — they are assertions embedded in the code, not post-hoc tests. A single invariant violation at any point during execution constitutes a FAIL.

---

### INV-1.1: Ledger Device Completeness

**Requirement:** Every device in M_verified has exactly one entry in the extraction confidence ledger.

**Check:** After Module 1 completes, assert: `|ledger.device_entries| = |M_verified.devices|` AND every device hostname in M_verified has a corresponding key in ledger.device_entries.

**PASS:** Counts match and every device is present.

**FAIL:** Any device missing or duplicate.

---

### INV-1.4: Robustness Rule Vendor-Class Completeness

**Requirement:** If a ◐ field is excluded by the robustness rule for a vendor class, it is excluded for ALL devices in that class.

**Check:** After Module 1 Phase 6, for every (vendor_class, excluded_field) in vendor_class_exclusions: iterate all devices with that vendor_class. Assert every device's FieldConfidence for that field has included_in_sigma = false.

**PASS:** No exceptions. Every device in the vendor class has the field excluded.

**FAIL:** Any device in the vendor class retains the field in its signature.

---

### INV-2.1: Signature Determinism (Runtime Assertion)

**Requirement:** σ(v) is a pure function of its inputs.

**Check:** After Module 2, compute σ(v) a second time for a random sample of 20% of devices. Assert bit-equality with the first computation.

**PASS:** All re-computed signatures match.

**FAIL:** Any signature differs on recomputation.

---

### INV-3.1: Partition Exhaustiveness

**Requirement:** Every device in V_net belongs to exactly one cell.

**Check:** After Module 3, assert: the union of all cell.members equals V_net (the set of all network devices). Assert no device appears in two cells.

**PASS:** Partition is exhaustive and non-overlapping.

**FAIL:** Any device missing or in multiple cells.

---

### INV-3.3: Equitability (Runtime Assertion)

**Requirement:** The partition is equitable at all times after Module 3 completes.

**Check:** After Module 3 AND after Module 4 (post-cross-validation), run the full equitability verification: for every (Cᵢ, Cⱼ, edge_type) triple, assert uniform neighbor counts.

**PASS:** Equitability holds at both checkpoints.

**FAIL:** Any non-uniformity at either checkpoint.

---

### INV-5.1: Rule 1 Enforcement

**Requirement:** Every V_net cell has ≥ 2 representatives.

**Check:** After Module 5, iterate all V_net cells. Assert |cell.representatives| ≥ 2 for each.

**PASS:** No V_net cell has fewer than 2 representatives.

**FAIL:** Any V_net cell has 0 or 1 representatives.

---

### INV-7.3: bᵢⱼ Computed from Production Graph

**Requirement:** The inter-cell connectivity matrix counts ALL edges between cells in the production graph, not just edges between representatives.

**Check:** After Module 7, independently recompute bᵢⱼ by iterating ALL edges in M_verified and counting per cell pair. Assert the recomputed matrix matches the stored matrix.

**PASS:** Every entry matches.

**FAIL:** Any entry differs.

---

### INV-7.4: Cell Size Sum

**Requirement:** Sum of all |Cᵢ| equals |V_net|.

**Check:** After Module 7, assert: Σ |Cᵢ| = |V_net|.

**PASS:** Sum matches exactly.

**FAIL:** Sum does not match. This would mean devices were lost or double-counted.

---

## LEVEL 4 — INTEGRATION VERIFICATION

These cases verify that modules compose correctly — the output of one module is a valid input to the next.

---

### INT-01: Module 1 → Module 2 Contract

**Requirement:** The extraction confidence ledger produced by Module 1 is consumable by Module 2.

**Procedure:**
1. Execute Module 1.
2. Feed its output to Module 2.
3. Verify Module 2 does not raise any contract violation or type error.
4. Verify that Module 2 correctly reads the ledger:
   - Devices marked FAILED_SINGLETON_FORCED receive σ = hash(hostname).
   - Fields marked included_in_sigma = false do not appear in any signature_detail.fields_included.

**PASS:** Module 2 runs to completion using Module 1's output. All signature computations respect the ledger's inclusion/exclusion decisions.

**FAIL:** Module 2 raises an error on Module 1's output. Or Module 2 ignores any ledger decision.

---

### INT-02: Module 2 → Module 3 Contract

**Requirement:** The signature registry produced by Module 2 is consumable by Module 3.

**Procedure:**
1. Execute Modules 1 and 2.
2. Feed Module 2's output to Module 3.
3. Verify the initial partition groups devices by their signature hash.
4. Verify devices with identical signatures are in the same initial cell.
5. Verify devices with different signatures are in different initial cells.

**PASS:** Initial partition correctly reflects the signature registry. Module 3 runs to completion.

**FAIL:** Devices with identical signatures are in different cells, or devices with different signatures are in the same cell.

---

### INT-03: Module 3 → Module 4 Contract

**Requirement:** The partition state from Module 3 is suitable for Batfish cross-validation.

**Procedure:**
1. Execute Modules 1–3.
2. Verify the partition state contains valid cell IDs, non-empty member sets, and a complete device_to_cell mapping.
3. Feed to Module 4 and verify cross-validation queries execute successfully.

**PASS:** Module 4 successfully queries Batfish for every non-singleton cell and produces cross-validation results.

**FAIL:** Module 4 cannot query Batfish due to invalid partition state, or produces no results for any non-singleton cell.

---

### INT-04: Directive Processing Order

**Requirement:** force_singleton directives are processed before field_exclusion directives.

**Procedure:**
1. Construct M_verified with 4 identical devices (A, B, C, D).
2. Set disposition = YELLOW.
3. Add directives:
   - force_singleton: affected_devices = {B}
   - field_exclusion: affected_devices = {B, C}, affected_fields = {route_map_content}
4. Execute Module 1.

**PASS:** All of the following hold:
- Device B's extraction_gate_result = FAILED_SINGLETON_FORCED.
- Device B does NOT have a field_exclusion entry for route_map_content (because it was already singleton-forced — the field exclusion is redundant).
- Device C DOES have route_map_content.included_in_sigma = false with exclusion_reason = "field_exclusion_directive".

**FAIL:** Device B receives both a singleton forcing AND a field exclusion entry. Or the field exclusion for B is processed before the singleton forcing.

---

### INT-05: End-to-End Pipeline Execution

**Requirement:** The compression engine runs end-to-end on a valid input and produces all six artifacts.

**Procedure:**
1. Construct a production-representative M_verified:
   - 4 spines, 8 leaves, 2 border leaves with external peers.
   - All spines identical config. All leaves identical config.
   - Border leaves identical config but unique external peerings.
   - Full BGP mesh between leaves and spines.
2. Set disposition = GREEN.
3. Provide an initialized Batfish session loaded with the corresponding snapshot.
4. Execute the complete compression engine pipeline.

**PASS:** All of the following hold:
- Six artifacts produced (VC-18).
- Partition is equitable (VC-06).
- All cross-validation checks pass (VC-08, VC-09, VC-10).
- Every V_net cell has ≥ 2 representatives (VC-11).
- Compression ratio is > 50% (spine cell: 4→2, leaf cell: 8→2, border cells: singletons due to unique peerings).
- Mapping report covers all devices (VC-19).
- Extraction confidence report covers all devices (VC-20).

**FAIL:** Any VC fails, or the pipeline raises an unhandled error.

---

## LEVEL 5 — OUTPUT CONTRACT VERIFICATION

These cases verify that the compression engine's outputs satisfy the contracts expected by downstream consumers. The compression engine's job is not done when it produces artifacts — it is done when those artifacts are proven consumable.

---

### OUT-01: G_c Contract with VM Instantiation

**Requirement:** Every vertex in G_c has a complete configuration sufficient for FRR VM template generation.

**Procedure:**
1. Execute the full pipeline.
2. For every vertex in G_c:
   a. Verify it has a non-null, non-empty configuration object.
   b. Verify every Entity Store field defined for its vertex type is populated.
   c. Verify the configuration is derivable from the original M_verified device config (no invented data).

**PASS:** Every vertex has a complete, real configuration. No field is null, missing, or fabricated.

**FAIL:** Any vertex has an incomplete configuration, or any field contains data not traceable to M_verified.

---

### OUT-02: π Contract with Cathedral

**Requirement:** The partition mapping covers every V_net device and maps it to exactly one cell with exactly one representative.

**Procedure:**
1. Execute the full pipeline.
2. Assert: domain(π) = V_net.
3. Assert: for every device d ∈ V_net, π(d) returns a valid cell_id.
4. Assert: for every device d ∈ V_net, rep(d) returns a valid device hostname that is in V_c.

**PASS:** π is total (covers all V_net), functional (each device maps to one cell), and rep is well-defined (each device has a representative in V_c).

**FAIL:** Any device unmapped, multi-mapped, or mapped to a non-existent cell. Or any device's representative is not in V_c.

---

### OUT-03: |Cᵢ| Contract with Cathedral and Mirror Box

**Requirement:** Cell sizes are exact positive integers whose sum equals |V_net|.

**Procedure:**
1. Execute the full pipeline.
2. Assert: every |Cᵢ| > 0.
3. Assert: Σ |Cᵢ| = |V_net|.
4. Assert: for every cell, |Cᵢ| = |cell.members| (the count matches the actual member set).

**PASS:** All assertions hold.

**FAIL:** Any |Cᵢ| = 0, or sum ≠ |V_net|, or count mismatch.

---

### OUT-04: bᵢⱼ Contract with Cathedral

**Requirement:** Inter-cell connectivity counts are exact non-negative integers computed from the production graph.

**Procedure:**
1. Execute the full pipeline.
2. Independently count edges between each cell pair from M_verified.
3. Compare against the emitted bᵢⱼ matrix.

**PASS:** Every entry matches the independent count.

**FAIL:** Any entry differs from the independent count.

---

### OUT-05: Extraction Confidence Report Contract with Cathedral

**Requirement:** The extraction confidence report is complete, per-device, per-field, and consistent with M_verified fidelity tags.

**Procedure:**
1. Execute the full pipeline.
2. For every device d in M_verified:
   a. Verify the report contains an entry for d.
   b. For every field f in the Entity Store's field inventory for d's type:
      - Verify the report contains a FieldConfidence record for f.
      - Verify the extraction_tag matches the Entity Store's tag for f.
      - Verify the fidelity_tag matches M_verified's tag for f on device d.
3. For every analytical_degradation directive in the input directive set:
   - Verify the report contains a passthrough entry for this directive.

**PASS:** Complete, consistent, no gaps. Analytical degradation directives are present in the report.

**FAIL:** Any device missing, any field missing, any tag inconsistency, or any analytical_degradation directive not passed through.

---

## LEVEL 6 — MATHEMATICAL FOUNDATION VERIFICATION

These cases verify the core mathematical properties that the compression engine relies on. They are topology-independent — they must hold for ANY valid input graph.

---

### MTH-01: Equitable Partition ↔ Fibration Lifting

**Requirement:** If the partition is equitable, the fibration lifting property holds: for every vertex v and every quotient edge (π(v), Cⱼ, e), there exists an edge (v, w, e) where π(w) = Cⱼ.

**Procedure:** Run on every test topology. Verify equitability first, then verify the lifting property.

**PASS:** For every equitable partition produced by the implementation, the lifting property holds without exception.

**FAIL:** Any equitable partition for which the lifting property fails.

---

### MTH-02: W-L Refinement Termination

**Requirement:** Weisfeiler-Leman refinement terminates in at most |V_net| iterations.

**Procedure:** Instrument the W-L loop with an iteration counter. Run on topologies of sizes 6, 8, 16, 42, 100, 500 vertices.

**PASS:** For every topology, W-L terminates. Iteration count ≤ |V_net| for every run.

**FAIL:** W-L exceeds |V_net| iterations on any topology, or does not terminate within a reasonable time bound.

---

### MTH-03: W-L Refinement Monotonicity

**Requirement:** W-L refinement only splits cells — it never merges them. The number of cells is monotonically non-decreasing across iterations.

**Procedure:** Instrument W-L to log the cell count after each iteration.

**PASS:** Cell count is non-decreasing across all iterations on all topologies.

**FAIL:** Cell count decreases at any iteration on any topology.

---

### MTH-04: Partition Stability

**Requirement:** After W-L converges, re-running W-L on the converged partition produces no further splits.

**Procedure:**
1. Run W-L to convergence.
2. Run W-L again on the converged partition.
3. Compare the partition before and after the second run.

**PASS:** The partition is identical before and after the second W-L run (idempotent).

**FAIL:** The second run produces additional splits.

---

### MTH-05: Inter-Cell Dynamics Preservation

**Requirement:** Every inter-cell state transition in the original graph has a corresponding transition in the quotient graph.

**Procedure:** For every edge (u, v, e) in G where π(u) ≠ π(v), verify that an edge (π(u), π(v), e) exists in G/π.

**PASS:** Every inter-cell edge projects to a quotient edge.

**FAIL:** Any inter-cell edge has no quotient counterpart.

---

### MTH-06: Intra-Cell Dynamics Boundary

**Requirement:** Intra-cell state transitions (transitions between members of the same cell) are NOT represented in the quotient graph. They are delegated to the Cathedral via |Cᵢ| and bᵢⱼ.

**Procedure:** For every edge (u, v, e) in G where π(u) = π(v), verify that this edge does NOT create a self-loop in the quotient (quotient self-loops from intra-cell edges are an implementation choice — the key property is that the Cathedral receives |Cᵢ| to model these dynamics).

**PASS:** |Cᵢ| is available for every cell with intra-cell edges. The mapping report documents which cells have intra-cell dynamics.

**FAIL:** |Cᵢ| is missing for any cell that has intra-cell edges.

---

## APPENDIX A — TEST TOPOLOGY CATALOG

Every topology used in verification must be cataloged here with its expected compression outcome. These are the canonical test inputs against which all cases are evaluated.

| ID | Name | Vertices | Edges | Expected Cells | Expected Compression | Purpose |
|----|------|----------|-------|----------------|---------------------|---------|
| T-01 | Symmetric Clos 2s4l | 6 | 8 BGP | 2 | 6→4 (33%) | Baseline equitability and lifting |
| T-02 | Asymmetric Clos 2s4l | 6 | 6 BGP | 3 | W-L must split leaves | W-L refinement correctness |
| T-03 | Multi-edge-type Clos | 6 | 8 BGP + 4 OSPF | 3+ | Spines split by OSPF | Typed-edge equitability |
| T-04 | Border Leaf topology | 10 | 12 BGP | 6+ | Border leaves split by ISP peering | Rule 2 testing |
| T-05 | Production Clos 4s32l2b | 42 | 136 BGP | 6+ | 42→10 (76%) | Compression ratio at scale |
| T-06 | Star 1c8s | 9 | 8 OSPF | 2 | Center singleton + spoke cell | Singleton behavior |
| T-07 | Ring 6r | 6 | 6 OSPF | 1 | 6→2 (67%) | W-L must NOT split |
| T-08 | Dual Ring 8r bridge | 8 | 9 (8 OSPF + 1 BGP) | 3 | 8→6 (25%) | Deep structural reasoning |
| T-09 | Single device | 1 | 0 | 1 | 1→1 (0%) | Degenerate case |
| T-10 | YELLOW with directives | 10 | 16 BGP | varies | Tests directive application | VC-03, VC-04, VC-05 |
| T-11 | Parse failure mix | 6 | 8 BGP | 4+ | Tests extraction gate | VC-02 |
| T-12 | Vendor class mix | 8 | 12 BGP | varies | Tests robustness rule across vendors | VC-03 |

---

## APPENDIX B — VERDICT RULES

1. **A case is PASS** if and only if every assertion in the case passes.
2. **A case is FAIL** if any single assertion fails.
3. **The compression engine implementation passes verification** if and only if every case at every level (PRE, VC, INV, INT, OUT, MTH) is PASS.
4. **A single FAIL at any level** is sufficient to reject the implementation. There is no partial credit.
5. **FAIL does not mean "fix the test."** A failing test indicates either an implementation defect (fix the code) or a specification defect (fix the spec, then fix the code, then re-run the test). The test itself is derived from the specification and does not change to accommodate the implementation.
6. **Test evidence must be retained.** For every case, the evidence (input data, output data, pass/fail determination, timestamp, execution environment) is archived. This is the DO-178C audit trail.

---

*End of Verification Requirements Specification v1.0*
