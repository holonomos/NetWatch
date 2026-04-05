# EclipseEngine Build Manifest

## Standard

DO-178C. Every requirement traces forward to implementation, forward to test, backward to spec. Every claim has a formal boundary. Every approximation is documented, tagged, and visible. No component is "done" until its SVCP passes completely.

## Pipeline

```
Customer configs
    ↓
Batfish parse → M (relational structure, 26 relations)
    ↓
Stage 3: Evaluator (97 predicates, 2-pass) → M_verified + P_corrected
    ↓
Stage 4: Qualification Gate → GREEN/YELLOW/RED + DirectiveSet
    ↓
Compression Engine (8 modules) → G_c, π, |C_i|, b_ij
    ↓
    ├→ VM Instantiation (compressed FRR emulation)
    │       ↓
    │   Mirror Box (3 modules) → Telemetry(G) projected
    │
    └→ Cathedral (9 modules) → Predictions on full graph
            ↓
    Convergence Diagnostic (4 modules) → δ = |Cathedral - MirrorBox|
            ↓
    Certification Report
```

## External Dependencies

| Dependency | Version | Purpose |
|-----------|---------|---------|
| Batfish | >= 2025.07.07 | Network config parsing, topology inference, RIB computation |
| pybatfish | >= 0.36.0 | Python client for Batfish |
| FRR | 10.6.0 | Routing software on compressed VMs |
| Python | >= 3.12 | Implementation language |
| networkx | >= 3.0 | Graph algorithms (W-L refinement, centrality) |
| hashlib | stdlib | SHA-256 behavioral signatures |

---

## Phase 0: Mathematical Foundations

Validation scripts already exist. Run them, verify all claims pass. These are the mathematical proofs that the compression is sound. Nothing else gets built until these pass.

| # | Task | File | Claims validated | Gate |
|---|------|------|-----------------|------|
| 0.1 | Run compression math validation | `cengmathval.py` | Fibration lifting on typed multigraphs, W-L convergence + coarseness, behavioral signature sufficiency, representative subgraph preservation, typed-edge equitability, compression ratio | All 6 claims PASS |
| 0.2 | Run Cathedral math validation | `cathedral_math_validation.py` | BGP best-path (5 scenarios), OSPF SPF, multi-protocol interaction, hot-potato divergence, perturbation ordering scale-invariance, timer independence, Tier 2 scaling formulas, determinism | All 14 tests PASS |

**Phase gate:** Both validation suites pass with zero failures. If any claim fails, the mathematical foundation is wrong and nothing downstream can be trusted.

---

## Phase 1: Entity Store + Shared Data Model

The type system that every component reads and writes. Defines vertices, edges, fidelity tags, directives, and the extraction confidence scheme. Nothing can be built without this.

| # | Task | Depends on | Output | Verification |
|---|------|-----------|--------|-------------|
| 1.1 | Define vertex type taxonomy | Stage 1 spec | `V_net` (border, spine, leaf, server, aggregation, route-reflector, firewall) + `V_inf` (bastion, mgmt, obs) | Type covers every device role in supported stacks |
| 1.2 | Define edge type taxonomy | Stage 1 spec | `E_fabric`, `E_mgmt`, `E_bgp_session` (overlay), `E_ospf_adjacency` | Type covers every link type in 4 protocol stacks |
| 1.3 | Define FidelityTag enum | Stage 3 spec | `{C, K, R}` with annotation chain (predicate ID, RFC ref, scope) | 3-value enum with provenance |
| 1.4 | Define Directive schema | Stage 4 spec | `field_exclusion`, `force_singleton`, `structural_caveat`, `analytical_degradation` | 4 directive types with target/scope/source fields |
| 1.5 | Define ExtractionConfidence scheme | Entity Store spec | Per-device per-field confidence: `{CONFIRMED, CONSTRAINED, REJECTED, NOT_EXTRACTED}` | Covers all 12 behavioral signature fields |
| 1.6 | Define Device data structure | All specs | Hostname, vendor, ASN, loopback, interfaces, BGP neighbors, OSPF config, static routes, policies, behavioral signature, fidelity tags | Superset of all fields consumed by any module |
| 1.7 | Define Edge data structure | All specs | Endpoints, IPs, subnet, edge type, fidelity tags | Covers fabric + overlay edges |
| 1.8 | Define M_verified schema | Stage 3 spec | Dict of Device + list of Edge + per-field FidelityTag + evaluation log | Schema consumed by Stage 4 and Compression Engine |

**Phase gate:** All data structures instantiable, serializable to/from YAML, and round-trip tested.

---

## Phase 2: State Space Pipeline (Stages 3 + 4)

Stages 1 and 2 are specifications (the predicate catalog), not code. Stage 3 is the first executable code — the evaluator that runs 97 predicates against a Batfish snapshot and produces M_verified.

| # | Task | Depends on | Output | Verification |
|---|------|-----------|--------|-------------|
| 2.1 | Implement predicate registry | Stage 2 spec, Phase 1 | Dict of 97 predicates: ID → (Batfish query, pass/partial/fail conditions, disposition) | All 97 predicates registered with correct IDs |
| 2.2 | Implement evaluation DAG | Stage 3 spec | Topological sort of predicates by evaluation dependency | DAG is acyclic, covers all 97 predicates |
| 2.3 | Implement Pass 1: Syntactic evaluation | 2.1, 2.2, Batfish | For each predicate: execute query, evaluate conditions, classify C/K/R | Pass 1 produces P_raw with 97 classifications |
| 2.4 | Implement semantic dependency graph G_sem | Stage 3 spec | 7 clusters, strong/weak edges, transitive closure | Graph matches spec exactly |
| 2.5 | Implement Pass 2: Semantic correction | 2.3, 2.4 | Propagate downgrades: R-strong→R, K-strong→K, scope narrowing | Monotonicity: no upgrades. Idempotence: f(f(x)) = f(x) |
| 2.6 | Construct M_verified | 2.5, Phase 1 | Tagged topology DB: per-device per-field fidelity | Every field on every device has a FidelityTag |
| 2.7 | Implement Qualification Gate | Stage 4 spec, 2.6 | Q(P_corrected) → disposition + DirectiveSet | Tier assignment correct, directive generation matches spec |
| 2.8 | Implement disposition logic | Stage 4 spec | GREEN/YELLOW/RED based on worst tier classification | Monotonicity: worsening any predicate can only worsen disposition |
| 2.9 | End-to-end Stage 3+4 test | All above | Configs → Batfish → 97 predicates → M_verified → disposition + directives | Known-good config set produces expected classifications |

**Phase gate:** Feed reference NetWatch FRR configs through pipeline. All 97 predicates evaluate. Disposition is GREEN (reference topology is clean eBGP Clos). Directives are empty (no degradation).

---

## Phase 3: Compression Engine

The load-bearing wall. A defect here propagates to everything downstream. 8 modules, strict sequential dependency.

| # | Task | Depends on | Output | Verification |
|---|------|-----------|--------|-------------|
| 3.1 | Module 1: Extraction Confidence Report | Phase 2 (M_verified + directives) | Per-device per-field ledger. 6 phases: force_singleton → field_exclusion → structural_caveat → analytical_degradation → per-device confidence → vendor-class robustness | PRE-01 through PRE-07. Vendor-class rule: if >50% of devices of same vendor+model have a field confirmed, partial extraction on others is upgraded |
| 3.2 | Module 2: Behavioral Signature σ(v) | 3.1 | SHA-256 over 12 canonicalized fields per device. Excludes: IPs, hostnames, interface names, literal ASNs, BFD intervals | VC-01: identical configs → identical σ. VC-02: different route-maps → different σ. VC-03: IP-only difference → same σ |
| 3.3 | Module 3: Equitable Partition (W-L) | 3.2 | Initial grouping by σ, then iterative refinement until equitable. Convergence guaranteed in ≤ |V| iterations | VC-04: partition is equitable (∀ C_i, C_j, e: uniform neighbor count). VC-05: partition is coarsest. INV-3.1: monotone refinement |
| 3.4 | Module 4: Batfish Cross-Validation | 3.3, Batfish | 3 checks per non-singleton cell: RIB structural equivalence, BGP session topology, ACL behavioral equivalence (BDD/Z3) | VC-06: cells with RIB mismatch are split. VC-07: ACL equivalence uses symbolic analysis, not sample packets |
| 3.5 | Module 5: Representative Selection | 3.4 | Rules 1-7: min 2 reps/cell, unique external peerings, tier-to-tier complete bipartite, singletons, V_inf 2-3/rack, type coverage, conservative dual-homing | VC-08: every cell has ≥ 2 reps. VC-09: external peerings preserved. VC-10: G_c is connected |
| 3.6 | Module 6: Path Completeness | 3.5, Batfish | Every policy interaction chain in G has a corresponding path in G_c | VC-11: searchRoutePolicies results all have paths in G_c |
| 3.7 | Module 7: Compressed Graph Construction | 3.6 | G_c (vertices, edges, types), b_ij (branching factors), differentialReachability regression | VC-12: G_c reachability matches G for all (src, dst) pairs. INV-7.3: edge count = Σ b_ij |
| 3.8 | Module 8: Output Assembly | 3.7 | 6 artifacts: G_c, π, |C_i|, b_ij, mapping report, extraction confidence report | OUT-01 through OUT-05: all artifacts present, consistent, complete |
| 3.9 | Full SVCP execution | All above | Run all verification cases from Compression_Engine_SVCP.md | 20 unit VCs + 7 invariants + 5 integration tests + 5 output tests + 6 math tests = ALL PASS |

**Phase gate:** SVCP passes completely. Compression of reference topology produces G_c that is the reference topology itself (identity compression — clean Clos with unique signatures per device). Compression of a synthetic 4-spine/32-leaf Clos with identical leaf configs produces a compressed graph with 2 leaf representatives.

---

## Phase 4: Cathedral

Analytical model on the FULL production graph. Predicts dynamics, not just steady state. Validated against Batfish ground truth with zero tolerance.

| # | Task | Depends on | Output | Verification |
|---|------|-----------|--------|-------------|
| 4.1 | Module 1: Full Graph Construction | Phase 2 (M_verified), Phase 3 (π, |C_i|, b_ij) | One FSM per protocol session, one SPF tree per OSPF area, one RIB per device, one policy engine per device. Timer provenance tracking. | Graph has correct vertex/edge count matching M_verified |
| 4.2 | Module 2: OSPF SPF Computation | 4.1 | Dijkstra per device per area. OSPF RIBs. | SPF output matches Batfish OSPF routes |
| 4.3 | Module 3: BGP Steady-State Solver | 4.2 | Iterative convergence to fixed point. RFC 4271 §8 best-path (11-step chain). BestPathTrace per (device, prefix). | BGP RIBs converge in finite iterations |
| 4.4 | Module 4: Batfish Steady-State Validation | 4.3, Batfish | CA-V1: RIB match (mandatory). CA-V2: reachability match (mandatory). | **FATAL on any mismatch.** If Cathedral RIBs ≠ Batfish RIBs, Cathedral is wrong. Fix Cathedral, never question Batfish. |
| 4.5 | Module 5: Perturbation Propagation | 4.4 | Event-driven simulation: link_down → BFD timeout → protocol notification → withdraw → recompute → reconverge. Priority queue by timer. | Tier 1: ordering matches known-good sequence. Tier 2: timing within scaling bounds. |
| 4.6 | Module 6: Scaling Corrections | 4.5, Phase 3 (π, |C_i|, b_ij) | 4 factors: diameter_ratio, cell_size_multipliers, spf_scaling_factor, capacity_ratios | Formulas match spec. Clos diameter_ratio = 1.0. |
| 4.7 | Module 7: Hot-Potato Divergence | 4.6, Batfish | For each cell: compare IGP costs from each member to BGP next-hops. Confirm with Batfish CA-V3. | Divergences detected match Batfish traceroute asymmetries |
| 4.8 | Module 8: Cascade Analysis | 4.7 | Multi-failure on FULL graph. Tier 4 Cathedral-only. | Runs on |V_net| vertices without crash. Results tagged Tier 4. |
| 4.9 | Module 9: Output Assembly | 4.8 | Every prediction tagged with: tier, extraction provenance, confidence, correction factors applied | All predictions have complete provenance chain |
| 4.10 | Full SVCP execution | All above | Run all verification cases from Cathedral_SVCP.md | 14 unit VCs + 4 math tests + 4 integration tests + 2 output tests = ALL PASS |

**Phase gate:** CA-V1 and CA-V2 pass on reference topology (Cathedral steady-state matches Batfish). Perturbation test: simulate spine-1 failure, verify convergence ordering matches expected BFD→BGP→ECMP sequence.

---

## Phase 5: VM Instantiation + Mirror Box

Requires running compressed FRR VMs. Mirror Box is deliberately thin — 3 modules.

| # | Task | Depends on | Output | Verification |
|---|------|-----------|--------|-------------|
| 5.1 | Generate FRR configs from G_c | Phase 3 (G_c) | frr.conf per compressed VM using production IPs | Configs parseable by FRR, BGP sessions establish |
| 5.2 | Generate Vagrantfile from G_c | Phase 3 (G_c) | Vagrantfile with correct VM count, memory, NICs | VMs boot, fabric wires correctly |
| 5.3 | Generate bridge/wiring scripts from G_c | Phase 3 (G_c) | setup-bridges.sh, setup-frr-links.sh | Bridges created, NICs attached, IPs configured |
| 5.4 | Boot and verify compressed emulation | 5.1-5.3 | All BGP sessions establish, BFD up, routes converge | `make status` equivalent passes |
| 5.5 | Module 1: Telemetry Ingestion | 5.4, Phase 4 (tier classification) | Classify live metrics as Tier 1 or Tier 2 | Classification matches Cathedral tier assignments |
| 5.6 | Module 2: Tier 1 Expansion | 5.5, Phase 3 (π) | For each prod device v: metric(v) = metric(rep(v)). Lifting theorem. | Expanded metrics identical to representative's |
| 5.7 | Module 3: Tier 2 Expansion | 5.6, Phase 4 (scaling corrections) | Apply correction factors: convergence × diameter_ratio, churn × |C_i|/|R_i|, SPF × scaling | Scaled values within expected bounds |
| 5.8 | Full SVCP execution | All above | Run all verification cases from MirrorBox_SVCP.md | 7 unit VCs + 4 integration tests + 2 output tests = ALL PASS |

**Phase gate:** Compressed emulation runs. Mirror Box projects telemetry to full scale. Projected values are plausible (no NaN, no negative, within physical bounds).

---

## Phase 6: Convergence Diagnostic

Pure comparator. No model, no analytical capability. Simplicity is the strength.

| # | Task | Depends on | Output | Verification |
|---|------|-----------|--------|-------------|
| 6.1 | Module 1: Delta Computation | Phase 4 (Cathedral), Phase 5 (Mirror Box) | δ = \|Cathedral - MirrorBox\| per shared metric | Delta computed for every shared metric |
| 6.2 | Module 2: Threshold Engine | 6.1 | Tier 1: threshold = 0 (any nonzero = BREACH). Tier 2: threshold = α × \|correction_factor - 1\| × base_value | Tier 1 breaches are binary. Tier 2 breaches proportional to correction magnitude. |
| 6.3 | Module 3: Cause Categorization | 6.2 | Tier 1 triage: IMPORT_ERROR → SIGNATURE_DEFICIENCY → CATHEDRAL_MODEL_ERROR → EMULATION_DIVERGENCE → UNKNOWN. Tier 2 triage: DEFAULTED_TIMERS → NONLINEAR_SCALING → TIMER_INTERACTION → UNKNOWN | Causes assigned in priority order. Severity matches spec. |
| 6.4 | Module 4: Output Assembly | 6.3 | Delta per metric, threshold verdicts, cause categorization, Tier 4 passthrough (Cathedral-only predictions), breach history, α calibration | Complete diagnostic report |
| 6.5 | Full SVCP execution | All above | Run all verification cases from ConvergenceDiagnostic_SVCP.md | 14 unit VCs + 3 integration tests + 2 operational tests = ALL PASS |

**Phase gate:** On reference topology (identity compression), Tier 1 deltas are exactly 0 (Cathedral and Mirror Box agree perfectly when compression is lossless). Tier 2 deltas are within threshold.

---

## Phase 7: Integration + Certification

| # | Task | Depends on | Output | Verification |
|---|------|-----------|--------|-------------|
| 7.1 | End-to-end pipeline test | All phases | Customer configs → Batfish → Stages 3-4 → Compression → Cathedral + VMs → Mirror Box → Convergence Diagnostic → Certification Report | Pipeline completes without fatal errors |
| 7.2 | Reference topology regression | All phases | NetWatch v1 topology → v2 migration → pipeline → verify identity compression, zero Tier 1 deltas | Proves v2 is superset of v1 |
| 7.3 | Synthetic scale test | All phases | 4-spine/32-leaf Clos with 16 identical leaf configs → compression → verify 2-leaf representatives, correct b_ij | Compression ratio validated |
| 7.4 | OSPF+iBGP stack test | All phases | Cisco-style configs (OSPF area 0 + iBGP EVPN with RR) → pipeline → verify OSPF+iBGP FRR configs emitted | Stack 1 (dominant enterprise pattern) works |
| 7.5 | Boundary test | All phases | Configs with external BGP peers → verify bastion stubbing | External peers collapsed to bastion correctly |
| 7.6 | Certification report generation | All phases | Formal document: what is proven, what is corrected, what is excluded, per-metric confidence | Report is complete, traceable, honest |

**Phase gate:** All 4 protocol stacks produce correct compressed emulations. Certification report accurately reflects fidelity boundaries. A senior network engineer can read the report and trust the claims.

---

## Task Count Summary

| Phase | Tasks | SVCP tests | Cumulative |
|-------|-------|-----------|------------|
| 0: Math foundations | 2 | 20 | 2 |
| 1: Data model | 8 | 8 | 10 |
| 2: State Space (Stages 3+4) | 9 | 97+ | 19 |
| 3: Compression Engine | 9 | 43 | 28 |
| 4: Cathedral | 10 | 28 | 38 |
| 5: VM Instantiation + Mirror Box | 8 | 13 | 46 |
| 6: Convergence Diagnostic | 5 | 19 | 51 |
| 7: Integration | 6 | 6 | 57 |
| **Total** | **57 tasks** | **234+ tests** | |

---

## Rules

1. **No phase starts until the previous phase gate passes.**
2. **Every module has a verification case. No exceptions.**
3. **Batfish is ground truth for steady-state. If Cathedral disagrees, fix Cathedral.**
4. **Production IPs throughout the fabric. Never remap.**
5. **Tier 3 is OUT OF SCOPE. Deterministic guarantees only.**
6. **frr_fragments are verbatim production config. Zero translation.**
7. **The reference topology is the integration test, not the hardcoded target.**
8. **A defect in the Compression Engine is a defect in everything downstream.**
