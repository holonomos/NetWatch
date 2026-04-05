Version - 1.0
# Compression Engine — Build Document

> **Purpose:** This is the source-of-truth implementation blueprint for the NetWatch Compression Engine. It bridges the gap between the Compression Engine specification (what must be built) and the codebase (what is built). Every data structure, every algorithm, every decision boundary, every error path documented here must trace backward to a requirement in the specification and forward to an implementation artifact and a test.
>
> **Audience:** The engineer(s) implementing the compression engine. This document assumes full familiarity with the specification (`Compression_Engine.md` v4.3) and the upstream pipeline (`State_Space_Stage_{1,2,3,4}.md`). It does not repeat the specification's rationale — it translates it into implementable form.
>
> **Standard:** DO-178C. Every requirement → implementation → test chain must be auditable. This document is the master traceability index for the compression engine component.
>
> **Normative References:**
>
> | Document | Version | Role |
> |----------|---------|------|
> | `Compression_Engine.md` | 4.3 | Governing specification |
> | `Entity_Store.md` | 4.3 | Vertex/edge type definitions, extraction confidence tags |
> | `State_Space_Stage_3.md` | 4.3 | M_verified construction rules, fidelity tag schema |
> | `State_Space_Stage_4.md` | 4.3 | Directive schema, tier assignments, disposition rules |
> | `Cathedral.md` | 4.3 | Downstream consumer — defines what it reads from compression engine outputs |
> | `Eclipse_Engine.md` | 4.3 | Unified mathematical framing — extraction gates, vendor confidence tiers |
> | `Fidelity_Boundary.md` | 5.0 | Tier system governing what compression preserves |
> | `Convergence_Diagnostic.md` | 4.3 | Indirect downstream consumer (via Cathedral and Mirror Box) |

---

## §1 — Architectural Position and Execution Preconditions

### 1.1 Where the Compression Engine Sits

The compression engine is the first component in the post-qualification pipeline. It executes after Stage 4 emits a GREEN or YELLOW disposition. It never executes on RED. The execution order downstream of the compression engine is: VM Instantiation → Cathedral → Mirror Box → Convergence Diagnostic → Certification Report.

This ordering matters because the compression engine's outputs are consumed by every downstream component. A defect in the compression engine propagates to every subsequent computation. There is no downstream recovery mechanism — if the partition π is wrong, the Cathedral's scaling corrections are wrong, the Mirror Box's expansion function is wrong, and the Convergence Diagnostic compares wrong predictions against wrong projections. The compression engine is the load-bearing wall.

### 1.2 Execution Preconditions

The compression engine must verify the following invariants before beginning its computation. These are not defensive checks — they are contractual obligations from upstream that, if violated, mean the pipeline has a bug.

| ID | Precondition | Source Contract | Verification Method |
|----|-------------|-----------------|---------------------|
| PRE-01 | Disposition is GREEN or YELLOW | Stage 4, Artifact 1 | Assert disposition ∈ {GREEN, YELLOW}. A RED disposition reaching the compression engine is a pipeline integrity failure. |
| PRE-02 | M_verified is non-empty | Stage 3, Artifact 2 | Assert |V_net ∪ V_inf| > 0 in M_verified. An empty topology is not compressible. |
| PRE-03 | Every field in M_verified carries a fidelity tag | Stage 3, Invariant 3 | Iterate all relations, all fields. Assert no field has tag = null. An untagged field violates Stage 3's exhaustive tagging guarantee. |
| PRE-04 | No field tagged C has a degraded semantic dependency | Stage 3, Invariant 4 | This was enforced by Stage 3 Pass 2. The compression engine does not re-verify semantic propagation — it trusts the upstream contract. However, the extraction confidence report generator (Module 1) logs the tag distribution as a sanity check. |
| PRE-05 | If disposition is YELLOW, directive set is non-empty | Stage 4, Invariant 7 | Assert |directive_set| > 0 when disposition = YELLOW. A YELLOW disposition with no directives means Stage 4 triggered YELLOW but failed to explain why. |
| PRE-06 | If disposition is GREEN, directive set is empty | Stage 4, §Output Specification | Assert |directive_set| = 0 when disposition = GREEN. |
| PRE-07 | Every directive in the directive set references a valid predicate | Stage 4, Invariant 4 | Assert every directive.source_predicate ∈ Σ (the 97-predicate set). |
| PRE-08 | Every directive's affected_devices references devices that exist in M_verified | Stage 4, Directive Schema | Assert ∀ d ∈ directive_set: d.affected_devices ⊂ devices(M_verified). |
| PRE-09 | Batfish snapshot is initialized and queryable | Stage 3, initialized during parse | Execute a trivial Batfish query (e.g., `bf.q.nodeProperties().answer()`) and assert it returns without error. The compression engine needs live Batfish access for cross-validation. |
| PRE-10 | Entity Store type definitions are loaded and accessible | Entity_Store.md | Assert vertex type definitions and edge type definitions are available for the types present in M_verified. |

**Failure behavior on precondition violation:** Halt with a diagnostic that identifies which precondition failed, the expected contract, and the actual state observed. Do not attempt partial execution. A precondition failure is a pipeline bug, not a customer data issue.

---

## §2 — Input Data Model

This section specifies the exact data structures the compression engine receives. These are not implementation choices — they are contract-derived shapes that must match the upstream output formats.

### 2.1 M_verified — The Pre-Qualified Topology Database

M_verified is a finite relational structure. It is the Batfish snapshot viewed as a database, extended with fidelity tags on every field. The compression engine reads M_verified but never writes to it — M_verified is immutable within the compression engine's scope.

#### 2.1.1 Device Records

Each device in M_verified carries:

```
Device {
    hostname:           string          // unique identifier
    parse_status:       enum            // PASSED | PARTIALLY_UNRECOGNIZED | FAILED | ...
    vendor_class:       string          // "cisco_ios" | "cisco_nxos" | "juniper" | "arista" | ...
    config_format:      string          // vendor-specific config format identifier
    role_inferred:      enum            // "router" | "switch" | "host" (Batfish-inferred)
    vrfs:               list<VRF>       // VRF definitions with RT import/export
    interfaces:         list<Interface> // all interfaces with IP, MTU, VLAN, channel-group
    bgp_process:        BgpProcess      // router-id, local-AS, confederation, multipath settings
    bgp_peers:          list<BgpPeer>   // all BGP peer configurations
    ospf_process:       OspfProcess     // router-id, areas, reference bandwidth
    ospf_interfaces:    list<OspfIface> // area, network type, hello/dead, cost, passive
    named_structures:   map<string, StructureDefinition>  // route-maps, prefix-lists, community-lists, ACLs, etc.
    init_issues:        list<InitIssue> // initialization warnings from Batfish
    undefined_refs:     list<UndefRef>  // references to undefined structures
    parse_warnings:     list<Warning>   // parse warnings per routing-critical section
}
```

Every leaf field in the above hierarchy carries a fidelity tag:

```
FidelityTag {
    classification:     enum            // C | K | R
    source_predicate:   string          // e.g., "FF-1.3.01"
    annotation:         string          // empty for C; constraint description for K; rejection reason for R
    semantic_chain:     list<string>    // e.g., ["FF-1.3.06", "FF-1.3.01"] — the chain of semantic dependencies
    device_scope:       set<string>     // which devices this tag applies to
    extraction_confidence: enum         // ● | ◐ | ○ (from Entity Store)
}
```

#### 2.1.2 Edge Records

Edges in M_verified represent protocol adjacencies and physical links:

```
Edge {
    edge_type:          enum            // BGP_SESSION | OSPF_ADJACENCY | L1_PHYSICAL | L3_LOGICAL | MLAG_PEER | ...
    source_device:      string          // hostname
    source_interface:   string          // interface name
    target_device:      string          // hostname
    target_interface:   string          // interface name
    attributes:         map<string, TaggedValue>  // edge-type-specific attributes, each carrying a FidelityTag
}
```

Edge types relevant to compression engine graph construction (Tier 0):

| Edge Type | Source Relation | Governing Predicate | Compression Engine Use |
|-----------|----------------|--------------------|-----------------------|
| BGP_SESSION | R_bgpEdges | FF-1.1.01 | Graph construction, peer count in σ, cross-validation |
| OSPF_ADJACENCY | R_ospfEdges | FF-1.1.02 | Graph construction, peer count in σ, cross-validation |
| L1_PHYSICAL | R_l1Edges | FF-1.1.08 | Graph construction — physical topology |
| L3_LOGICAL | R_l3Edges | FF-1.1.08 | Graph construction — logical topology |
| MLAG_PEER | R_mlag | PM-2.3.01 | V_inf compression — dual-homing detection (Rule 7) |

#### 2.1.3 Capability Tags

Snapshot-level capability tags (not per-device, not per-field):

```
CapabilityTag {
    capability_name:    string          // e.g., "differential_reachability"
    classification:     enum            // C | K | R
    source_predicate:   string
    annotation:         string
}
```

The compression engine checks the following capability tags before invoking the corresponding Batfish queries:

| Capability | Query | Fallback if K/R |
|------------|-------|-----------------|
| differential_reachability | `bf.q.differentialReachability()` | Regression validation is omitted; mapping report notes the gap. Compression still proceeds — differentialReachability is a validation tool, not a computation input. |
| ecmp_path_enumeration | `bf.q.traceroute()` with `maxTraces` | Step 4 path-count preservation check notes approximation. |

### 2.2 Directive Set

The directive set is a list of directive objects, each conforming to the schema defined in Stage 4:

```
Directive {
    directive_type:     enum            // field_exclusion | force_singleton | structural_caveat | analytical_degradation
    source_predicate:   string          // the predicate that triggered the directive
    source_tier:        int             // 0 | 1 | 2
    classification:     enum            // K | R
    affected_devices:   set<string>     // device hostnames
    affected_fields:    set<(string, string)>  // (relation_name, field_name) pairs
    required_behavior:  string          // precise instruction
    annotation:         string          // constraint annotation from P_corrected
    semantic_chain:     list<string>    // from P_corrected
}
```

#### 2.2.1 Directive Processing Order

The specification mandates a processing order (Stage 4, §Directive Consumption):

1. **force_singleton directives first.** Mark affected devices as singleton-forced. These devices exit the equivalence classification pipeline entirely.
2. **field_exclusion directives second.** Remove affected fields from signature computation for affected devices. Apply the vendor-class-wide robustness rule.
3. **structural_caveat directives third.** Note affected devices for annotation in cross-validation results and the mapping report.
4. **analytical_degradation directives — passthrough only.** The compression engine does not act on these. They are preserved in the extraction confidence report for downstream consumption by the Cathedral and Mirror Box.

This ordering is not optional. force_singleton must be processed before field_exclusion because a device that is already singleton-forced does not need field exclusions — its signature is not computed at all. Processing field_exclusion first and then force_singleton would waste work and could produce misleading extraction confidence report entries.

### 2.3 Batfish Snapshot (Live Session)

The compression engine holds a reference to the initialized pybatfish session. It does not initialize the session — that was Stage 3's responsibility. The compression engine issues queries against this session during cross-validation (Step 2 in the spec, Module 4 in this document) and regression validation (Step 5 in the spec, Module 7 in this document).

Queries the compression engine issues:

| Query | Module | Purpose |
|-------|--------|---------|
| `bf.q.routes(nodes=...)` | 4 (Cross-Validation) | RIB structural equivalence across cell members |
| `bf.q.bgpSessionStatus()` | 4 (Cross-Validation) | BGP session topology across cell members |
| `bf.q.searchFilters()` | 4 (Cross-Validation) | ACL behavioral equivalence on leaf server-facing interfaces |
| `bf.q.searchRoutePolicies()` | 6 (Path Completeness) | Policy interaction chain detection |
| `bf.q.testRoutePolicies()` | 4 (Cross-Validation, supplemental) | Behavioral equivalence verification for specific routes |
| `bf.q.differentialReachability()` | 7 (Graph Construction) | Regression validation of compressed graph |

### 2.4 Entity Store Type Definitions (Read-Only Reference)

The compression engine reads but does not write type definitions. The relevant definitions for compression:

**From Entity Store — what the compression engine needs:**

1. **Per-vertex-type field inventory.** For each vertex type (Router, L3 Switch, Firewall, Load Balancer, Route Reflector, etc.), the Entity Store defines which fields exist, their extraction confidence tags (●/◐/○), and their behavioral significance. The compression engine uses this to determine which fields are candidates for σ(v).

2. **Per-edge-type coupling definitions.** For each edge type (BGP_SESSION, OSPF_ADJACENCY, etc.), the Entity Store defines the coupling function, propagation characteristics, and policy bindings. The compression engine uses edge type definitions to verify equitability — every vertex in a cell must have the same number of neighbors of each edge type in every other cell.

3. **V_inf classification rules.** Rules for classifying topology-inferred endpoints (servers, hypervisors, storage, appliances). The compression engine applies these when performing rack-based V_inf compression (Rules 5–7).

4. **Extraction confidence scheme.** The ●/◐/○ tagging definitions and their per-vendor confidence tiers. The compression engine's behavioral signature computation uses these tags to determine which fields are safe to include in σ(v).

---

## §3 — Internal Data Structures

These are the data structures the compression engine creates and maintains during its computation. They are internal — not received from upstream and not emitted downstream (though they inform the output artifacts).

### 3.1 Extraction Confidence Ledger

The ledger is the internal data structure produced by Module 1 and consumed by every subsequent module. It is the compression engine's processed view of "what can I trust?"

```
ExtractionConfidenceLedger {
    // Per-device entries
    device_entries: map<string, DeviceConfidenceEntry>
    
    // Per-vendor-class aggregations (for robustness rule)
    vendor_class_exclusions: map<string, set<string>>  // vendor_class → set of field names excluded for that class
    
    // Singleton-forced devices (from force_singleton directives)
    singleton_forced: set<string>
    
    // Structural caveat devices (from structural_caveat directives)
    structural_caveat_devices: map<string, list<string>>  // device → list of caveat annotations
    
    // Analytical degradation passthrough (for downstream)
    analytical_degradation_directives: list<Directive>
}

DeviceConfidenceEntry {
    hostname:               string
    parse_status:           enum
    vendor_class:           string
    extraction_gate_result: enum            // PASSED | FAILED_PARSE | FAILED_INIT | FAILED_SINGLETON_FORCED
    gate_failure_reason:    string          // empty if PASSED
    field_confidence:       map<string, FieldConfidence>  // field_name → confidence assessment
    directive_modifications: list<DirectiveEffect>         // which directives affected this device and how
}

FieldConfidence {
    field_name:             string
    extraction_tag:         enum            // ● | ◐ | ○
    fidelity_tag:           enum            // C | K | R (from M_verified)
    included_in_sigma:      bool            // after applying robustness rule and directives
    exclusion_reason:       string          // if not included: "supplemental_required" | "robustness_rule" | "field_exclusion_directive" | "extraction_gate_failed"
}

DirectiveEffect {
    directive:              Directive       // the original directive
    effect:                 string          // "forced_to_singleton" | "field_excluded" | "caveat_attached" | "passthrough"
}
```

### 3.2 Behavioral Signature Registry

```
SignatureRegistry {
    // The computed signatures
    signatures: map<string, bytes>          // device hostname → σ(v) hash
    
    // Signature computation details (for mapping report)
    signature_details: map<string, SignatureDetail>
    
    // Devices that bypassed signature computation
    gate_failures: map<string, string>      // device → reason (these get unique signatures = device_id)
}

SignatureDetail {
    hostname:               string
    fields_included:        list<string>    // ordered list of field names that contributed to this signature
    field_values_hash:      bytes           // the final hash
    canonical_input:        string          // the canonical serialized form that was hashed (for auditability)
}
```

### 3.3 Partition State

```
PartitionState {
    // The partition π
    cells: map<int, Cell>                   // cell_id → Cell
    device_to_cell: map<string, int>        // hostname → cell_id
    
    // Refinement log (for mapping report)
    refinement_log: list<RefinementEvent>
    
    // Cross-validation results (for mapping report)
    cross_validation_results: list<CrossValidationResult>
}

Cell {
    cell_id:                int
    members:                set<string>     // device hostnames
    signature:              bytes           // the common signature (or null for refined cells)
    is_v_inf:               bool            // true if this is a V_inf cell (compressed by position, not signature)
    
    // Post-selection fields (populated by Module 5)
    representatives:        set<string>     // selected representative devices
    cell_size:              int             // |Cᵢ| = |members|
}

RefinementEvent {
    original_cell_id:       int
    split_into:             list<int>       // new cell IDs
    reason:                 string          // "weisfeiler_leman_structural_asymmetry" | "batfish_cross_validation_mismatch"
    structural_detail:      string          // which neighbor counts or which Batfish check triggered the split
}

CrossValidationResult {
    cell_id:                int
    validation_type:        enum            // RIB | BGP_SESSION | ACL
    representative:         string          // device used as reference
    compared_member:        string          // device compared against representative
    result:                 enum            // PASS | MISMATCH
    mismatch_detail:        string          // if MISMATCH: what differed
    caveat:                 string          // if device is under structural_caveat: the caveat text
}
```

### 3.4 Representative Selection State

```
RepresentativeSelection {
    // Per-cell selections
    cell_representatives: map<int, set<string>>
    
    // Rule application log (for mapping report)
    rule_log: list<RuleApplication>
    
    // V_inf compression decisions
    v_inf_decisions: list<VInfDecision>
}

RuleApplication {
    cell_id:                int
    rule_number:            int             // 1–7
    effect:                 string          // what the rule caused
    devices_affected:       set<string>
}

VInfDecision {
    rack_id:                string          // rack identifier (inferred from topology position)
    endpoints_in_rack:      int             // total V_inf endpoints in this rack
    representatives_selected: int           // how many were selected (2–3 per Rule 5)
    types_represented:      list<string>    // inferred endpoint types per Rule 6
    dual_homing_model:      string          // "mlag_detected" | "esi_undetectable_conservative" | "single_homed"
}
```

### 3.5 Compressed Graph

```
CompressedGraph {
    // Vertex set
    vertices: map<string, CompressedVertex>     // hostname → vertex (all representatives)
    
    // Edge set
    edges: list<CompressedEdge>
    
    // Inter-cell connectivity matrix
    b_ij: map<(int, int), int>                  // (cell_i, cell_j) → edge count in production graph
    
    // Regression validation output
    differential_reachability_output: string     // raw output from bf.q.differentialReachability()
}

CompressedVertex {
    hostname:               string              // real production device hostname
    cell_id:                int                 // which cell this representative belongs to
    represents:             set<string>         // all production devices this representative stands for
    configuration:          DeviceConfig        // complete configuration from M_verified
    metadata:               map<string, any>    // additional per-vertex metadata for VM instantiation
}

CompressedEdge {
    source:                 string              // hostname
    target:                 string              // hostname
    edge_type:              enum
    attributes:             map<string, any>    // coupling function parameterization, policy bindings
    production_edge_ref:    (string, string)    // (original source, original target) in the production graph
}
```

---

## §4 — Module Decomposition

Eight modules, ordered by dependency. Each module specifies its inputs, algorithm, outputs, invariants, error conditions, and verification criteria.

### Module 1: Extraction Confidence Report Generator

**Spec reference:** Implementation Sequence §1, "Build the module that reads M_verified and the directive set..."

**Purpose:** Produce the per-device, per-field extraction confidence assessment that every subsequent module consults. This is the foundation — it answers "what can I trust?" for every field on every device.

#### 1.1 Inputs

| Input | Source | Structure |
|-------|--------|-----------|
| M_verified | Stage 3 (via Stage 4 passthrough) | §2.1 |
| Directive set | Stage 4 | §2.2 |
| Entity Store extraction confidence scheme | Entity_Store.md | ●/◐/○ per field per vertex type per vendor |

#### 1.2 Algorithm

```
FUNCTION build_extraction_confidence_ledger(M_verified, directive_set, entity_store):

    ledger = new ExtractionConfidenceLedger()
    
    // ──────────────────────────────────────────────
    // PHASE 1: Process force_singleton directives
    // ──────────────────────────────────────────────
    // Rationale: These must be first. A singleton-forced device does not 
    // participate in signature computation at all. Processing these first 
    // prevents wasted field_exclusion analysis on devices that won't use it.
    
    FOR EACH directive IN directive_set WHERE directive.directive_type = "force_singleton":
        FOR EACH device_hostname IN directive.affected_devices:
            ledger.singleton_forced.add(device_hostname)
            ledger.device_entries[device_hostname].extraction_gate_result = FAILED_SINGLETON_FORCED
            ledger.device_entries[device_hostname].gate_failure_reason = 
                "Singleton forced by directive from predicate " + directive.source_predicate +
                ": " + directive.annotation
            ledger.device_entries[device_hostname].directive_modifications.append(
                DirectiveEffect(directive, "forced_to_singleton"))
    
    // ──────────────────────────────────────────────
    // PHASE 2: Process field_exclusion directives
    // ──────────────────────────────────────────────
    // Build a map: (device, field) → excluded
    // Then apply the vendor-class-wide robustness rule
    
    directive_excluded_fields = new map<(string, string), Directive>  // (device, field) → directive
    
    FOR EACH directive IN directive_set WHERE directive.directive_type = "field_exclusion":
        FOR EACH device_hostname IN directive.affected_devices:
            IF device_hostname NOT IN ledger.singleton_forced:  // skip already-singleton devices
                FOR EACH (relation, field_name) IN directive.affected_fields:
                    directive_excluded_fields[(device_hostname, field_name)] = directive
                    ledger.device_entries[device_hostname].directive_modifications.append(
                        DirectiveEffect(directive, "field_excluded"))
    
    // ──────────────────────────────────────────────
    // PHASE 3: Process structural_caveat directives
    // ──────────────────────────────────────────────
    
    FOR EACH directive IN directive_set WHERE directive.directive_type = "structural_caveat":
        FOR EACH device_hostname IN directive.affected_devices:
            ledger.structural_caveat_devices[device_hostname].append(directive.annotation)
    
    // ──────────────────────────────────────────────
    // PHASE 4: Passthrough analytical_degradation directives
    // ──────────────────────────────────────────────
    
    FOR EACH directive IN directive_set WHERE directive.directive_type = "analytical_degradation":
        ledger.analytical_degradation_directives.append(directive)
    
    // ──────────────────────────────────────────────
    // PHASE 5: Build per-device, per-field confidence entries
    // ──────────────────────────────────────────────
    
    FOR EACH device IN M_verified.devices:
        IF device.hostname NOT IN ledger.device_entries:
            ledger.device_entries[device.hostname] = new DeviceConfidenceEntry()
        
        entry = ledger.device_entries[device.hostname]
        entry.hostname = device.hostname
        entry.parse_status = device.parse_status
        entry.vendor_class = device.vendor_class
        
        // Extraction gate evaluation (if not already singleton-forced)
        IF entry.extraction_gate_result != FAILED_SINGLETON_FORCED:
            IF device.parse_status IN {PARTIALLY_UNRECOGNIZED, FAILED, EMPTY, UNKNOWN}:
                entry.extraction_gate_result = FAILED_PARSE
                entry.gate_failure_reason = "Parse status: " + device.parse_status
            ELSE IF device.init_issues contains critical issues:
                entry.extraction_gate_result = FAILED_INIT
                entry.gate_failure_reason = "Critical init issues: " + summarize(device.init_issues)
            ELSE:
                entry.extraction_gate_result = PASSED
        
        // Per-field confidence
        FOR EACH field IN entity_store.fields_for_type(device.role_inferred):
            fc = new FieldConfidence()
            fc.field_name = field.name
            fc.extraction_tag = field.extraction_confidence  // ● | ◐ | ○
            fc.fidelity_tag = M_verified.get_tag(device.hostname, field.name).classification
            
            // Determine inclusion in σ
            IF entry.extraction_gate_result != PASSED:
                fc.included_in_sigma = false
                fc.exclusion_reason = "extraction_gate_failed"
            ELSE IF fc.extraction_tag = ○:
                fc.included_in_sigma = false
                fc.exclusion_reason = "supplemental_required"
            ELSE IF (device.hostname, field.name) IN directive_excluded_fields:
                fc.included_in_sigma = false
                fc.exclusion_reason = "field_exclusion_directive"
            ELSE:
                fc.included_in_sigma = true  // provisional — robustness rule may override in Phase 6
            
            entry.field_confidence[field.name] = fc
    
    // ──────────────────────────────────────────────
    // PHASE 6: Apply vendor-class-wide robustness rule
    // ──────────────────────────────────────────────
    // Spec: "If a ◐ field cannot be extracted for a specific device (vendor parse gap),
    // that field is excluded from σ for ALL devices in the same vendor class."
    //
    // Implementation: For each vendor class, scan all devices in that class.
    // If ANY device has a ◐ field that is unextractable (fidelity_tag = R or K, 
    // or extraction_tag = ◐ and the field value is missing/default), then
    // exclude that field from σ for ALL devices in the vendor class.
    
    // Group devices by vendor class
    vendor_groups = group_by(ledger.device_entries.values(), entry -> entry.vendor_class)
    
    FOR EACH (vendor_class, devices) IN vendor_groups:
        // For each ◐ field defined for this vendor class
        FOR EACH field IN entity_store.partial_fields_for_vendor(vendor_class):
            // Check if any device in this vendor class has this field unextractable
            any_unextractable = false
            FOR EACH device_entry IN devices:
                IF device_entry.extraction_gate_result = PASSED:
                    fc = device_entry.field_confidence.get(field.name)
                    IF fc != null AND fc.extraction_tag = ◐:
                        IF fc.fidelity_tag IN {K, R} OR field_value_is_missing_or_default(device_entry, field):
                            any_unextractable = true
                            BREAK
            
            IF any_unextractable:
                ledger.vendor_class_exclusions[vendor_class].add(field.name)
                // Apply exclusion to ALL devices in this vendor class
                FOR EACH device_entry IN devices:
                    IF device_entry.extraction_gate_result = PASSED:
                        fc = device_entry.field_confidence.get(field.name)
                        IF fc != null AND fc.included_in_sigma = true:
                            fc.included_in_sigma = false
                            fc.exclusion_reason = "robustness_rule"
    
    RETURN ledger
```

#### 1.3 Outputs

| Output | Structure | Consumers |
|--------|-----------|-----------|
| ExtractionConfidenceLedger | §3.1 | Module 2 (signature computation), Module 4 (cross-validation caveats), Module 8 (output assembly — Artifact 6) |

#### 1.4 Invariants

| ID | Invariant |
|----|-----------|
| INV-1.1 | Every device in M_verified has exactly one entry in the ledger. |
| INV-1.2 | Every field in the Entity Store's field inventory for a device's type has a FieldConfidence entry. |
| INV-1.3 | No device is both singleton_forced and PASSED on the extraction gate. |
| INV-1.4 | If a ◐ field is excluded by the robustness rule for a vendor class, it is excluded for ALL devices in that vendor class — not just the device that triggered the exclusion. |
| INV-1.5 | All force_singleton directives are processed before any field_exclusion directives. |

#### 1.5 Error Conditions

| Condition | Response |
|-----------|----------|
| Directive references a device not in M_verified | Precondition PRE-08 violation. Halt with diagnostic. |
| Directive references a field not in the Entity Store | Log warning. Skip the field exclusion for this field. The directive may reference a field that was removed in an Entity Store version update. |
| Vendor class for a device cannot be determined | Assign vendor_class = "unknown". The robustness rule still applies — an "unknown" vendor class is treated as its own class. |

#### 1.6 Verification Criteria Mapping

| VC | Criterion | How This Module Contributes |
|----|-----------|---------------------------|
| VC-02 | Extraction gate correctly identifies devices with parse failures | This module evaluates the extraction gate. VC-02 tests are directly against this module's gate logic. |
| VC-03 | Signature robustness rule excludes ◐ fields correctly | Phase 6 of this module implements the robustness rule. VC-03 tests are directly against Phase 6. |
| VC-04 | Field exclusion directives applied before signature computation | Phases 2 and 5 implement directive application. VC-04 tests verify that field_exclusion directives produce included_in_sigma = false for affected fields. |
| VC-05 | Singleton forcing directives produce singleton cells | Phase 1 marks devices as singleton_forced. VC-05 verifies downstream (in Module 3) that these devices have |Cᵢ| = 1. |

---

### Module 2: Behavioral Signature Computation — σ(v)

**Spec reference:** Compression Engine §Step 1: Behavioral Signature Computation

**Purpose:** For each network device that passed the extraction gate, compute a deterministic hash over its dynamically relevant configuration, excluding instance-specific data.

#### 2.1 Inputs

| Input | Source |
|-------|--------|
| M_verified | §2.1 |
| ExtractionConfidenceLedger | Module 1 output |

#### 2.2 The Signature Inclusion Table

The following fields are included in σ(v), subject to the extraction confidence ledger's per-device, per-field `included_in_sigma` determination.

**Critical implementation requirement:** Each field's contribution to σ(v) must be canonicalized — normalized to a form where semantically equivalent configurations produce identical hash inputs regardless of syntactic differences.

| # | Field | Canonicalization Rule | Notes |
|---|-------|----------------------|-------|
| 1 | Route-map content | Sort by sequence number. For each entry: (seq, permit/deny, sorted match clauses, sorted set clauses). Strip names — hash only content. | Two route-maps named differently but structurally identical → identical contribution. |
| 2 | Prefix-list content | Sort by sequence number. For each entry: (seq, permit/deny, prefix, ge, le). Strip names. | |
| 3 | Community-list content | Sort entries. For each: (permit/deny, community value or regex). Strip names. | |
| 4 | AS-path ACL content | Sort entries. For each: (permit/deny, regex pattern). Strip names. | |
| 5 | BGP peer-group template structure | For each peer group: (remote-AS relationship [same/different, not literal ASN], sorted address families activated, inbound policy structure hash, outbound policy structure hash). | "Policy structure hash" means the structural hash of the referenced route-map's content — not the route-map name. This creates a recursive reference into field #1. |
| 6 | BGP timer configuration (keepalive, hold) | (keepalive_seconds, hold_seconds). | ◐ field. Subject to robustness rule. |
| 7 | OSPF configuration structure | Per-area: (area_id, stub/nssa/normal, sorted interface entries). Per-interface: (network_type, hello_interval, dead_interval, cost, passive_flag). | hello/dead are ● fields. DR priority and authentication are ◐ — subject to robustness rule. |
| 8 | VRF configuration structure | Per-VRF: (sorted RT import set, sorted RT export set, route leaking config). | |
| 9 | BFD enablement per protocol | Per-protocol: (protocol_name, bfd_enabled: bool). | BFD existence only — not interval/multiplier values (those are excluded per spec). |
| 10 | Static route patterns | Per-route: (destination_prefix_length, administrative_distance). NOT specific next-hop IPs. | ◐ field. |
| 11 | Peer count by direction | (upstream_bgp_peers, downstream_bgp_peers, same_tier_bgp_peers, ospf_neighbors_by_area). | "Direction" is determined from the ASN relationship and topology position. |
| 12 | ACL content on server-facing interfaces | Per-interface classified as server-facing: sorted ACL entries (seq, permit/deny, protocol, src, dst, ports). For leaf switches only. | |

**Fields explicitly excluded from σ(v):**

IP addresses, interface names, hostnames, loopback addresses, absolute ASN values, uniform-across-tier metric values, BFD interval/multiplier values, MRAI (unless explicitly configured — ◐, excluded by default).

#### 2.3 Algorithm

```
FUNCTION compute_signatures(M_verified, ledger):
    
    registry = new SignatureRegistry()
    
    FOR EACH device IN M_verified.devices WHERE device.hostname IN V_net:
        entry = ledger.device_entries[device.hostname]
        
        // ── Extraction gate check ──
        IF entry.extraction_gate_result != PASSED:
            // Assign unique signature = device identity
            registry.signatures[device.hostname] = hash(device.hostname)
            registry.gate_failures[device.hostname] = entry.gate_failure_reason
            CONTINUE
        
        // ── Build canonical signature input ──
        canonical_parts = []
        fields_included = []
        
        FOR EACH (field_number, field_name, canonicalize_fn) IN SIGNATURE_INCLUSION_TABLE:
            fc = entry.field_confidence.get(field_name)
            IF fc = null OR NOT fc.included_in_sigma:
                CONTINUE
            
            // Extract field value from M_verified
            raw_value = extract_field(M_verified, device.hostname, field_name)
            
            // Canonicalize
            canonical_value = canonicalize_fn(raw_value)
            
            canonical_parts.append((field_number, canonical_value))
            fields_included.append(field_name)
        
        // ── Deterministic serialization ──
        // Sort by field number (already ordered, but enforce)
        canonical_parts.sort(key = p -> p[0])
        
        // Serialize to a deterministic byte string
        serialized = deterministic_serialize(canonical_parts)
        
        // ── Hash ──
        sigma_v = cryptographic_hash(serialized)  // e.g., SHA-256
        
        registry.signatures[device.hostname] = sigma_v
        registry.signature_details[device.hostname] = SignatureDetail(
            hostname = device.hostname,
            fields_included = fields_included,
            field_values_hash = sigma_v,
            canonical_input = serialized  // retained for auditability
        )
    
    RETURN registry
```

#### 2.4 Canonicalization Requirements

The specification mandates determinism (same M_verified → same hash). This requires:

1. **Sorted keys.** All maps, sets, and unordered collections must be sorted by a canonical key before serialization. Route-map entries by sequence number. Prefix-list entries by sequence number. Community values lexicographically. AS-path regex patterns lexicographically.

2. **Deterministic serialization.** Use a serialization format with canonical form (e.g., canonical JSON with sorted keys, no whitespace variation). The specific format is an implementation choice, but it must be documented and frozen — changing the serialization format invalidates all previously computed signatures.

3. **No evaluation-order dependency.** The hash must not depend on the order in which devices are processed. Each device's σ(v) is computed independently.

4. **Name stripping.** Policy object names (route-map names, prefix-list names, community-list names, ACL names) are stripped before hashing. Only content (match/set clauses, prefix entries, community values, regex patterns) contributes to the signature. Two devices with semantically identical policies under different names must produce identical signature contributions.

5. **ASN relationship, not literal ASN.** The BGP peer-group template contribution uses "same AS as peer" or "different AS from peer" — not the actual ASN values. Two devices in different AS numbers but with identical peer-group structures (same number of eBGP peers with the same policy structure, same number of iBGP peers, etc.) produce identical contributions.

#### 2.5 Outputs

| Output | Structure | Consumers |
|--------|-----------|-----------|
| SignatureRegistry | §3.2 | Module 3 (partition computation) |

#### 2.6 Invariants

| ID | Invariant |
|----|-----------|
| INV-2.1 | σ(v) is deterministic: same M_verified + same ledger → same hash. This is the most critical invariant. |
| INV-2.2 | Every device in V_net has exactly one entry in the registry — either a computed signature or a gate_failure entry. |
| INV-2.3 | No device that failed the extraction gate has a computed signature. Gate failures get σ = hash(hostname). |
| INV-2.4 | No ○-tagged field contributes to any device's signature. |
| INV-2.5 | No field excluded by the robustness rule contributes to any device's signature in the affected vendor class. |

#### 2.7 Verification Criteria Mapping

| VC | Criterion | Test Specification |
|----|-----------|-------------------|
| VC-01 | σ(v) deterministic | Compute σ twice on identical input. Assert bit-identical output. Run on multiple topologies. |
| VC-02 | Extraction gate identifies parse failures | Feed devices with PARTIALLY_UNRECOGNIZED status. Assert they receive unique signatures (σ = hash(hostname)). |
| VC-03 | Robustness rule excludes ◐ fields correctly | Feed a vendor class where one device has an unextractable ◐ field. Assert the field is excluded from σ for ALL devices in that vendor class. |
| VC-04 | Field exclusion directives applied before σ | Feed a YELLOW directive set with field_exclusion. Assert excluded fields do not appear in the signature_details.fields_included for affected devices. |
| VC-05 | Singleton forcing produces singletons | Feed singleton_forcing directives. Assert affected devices have σ = hash(hostname) and are gate failures in the registry. |

---

### Module 3: Equitable Partition Computation — π

**Spec reference:** Compression Engine §Step 2: Equitable Partition

**Purpose:** Group V_net into equivalence classes by signature, then refine until the partition is equitable.

#### 3.1 Inputs

| Input | Source |
|-------|--------|
| SignatureRegistry | Module 2 output |
| M_verified edge set | §2.1.2 |
| Entity Store edge type definitions | §2.4 |

#### 3.2 Algorithm

```
FUNCTION compute_equitable_partition(registry, M_verified, entity_store):
    
    state = new PartitionState()
    
    // ──────────────────────────────────────────────
    // PHASE 1: Initial grouping by signature
    // ──────────────────────────────────────────────
    
    // Group V_net devices by σ(v)
    signature_groups = group_by(
        registry.signatures.entries(),
        entry -> entry.value  // group by signature hash
    )
    
    cell_id = 0
    FOR EACH (sigma, devices) IN signature_groups:
        cell = new Cell()
        cell.cell_id = cell_id
        cell.members = set(d.key for d in devices)
        cell.signature = sigma
        cell.is_v_inf = false
        cell.cell_size = |cell.members|
        
        state.cells[cell_id] = cell
        FOR EACH hostname IN cell.members:
            state.device_to_cell[hostname] = cell_id
        
        cell_id += 1
    
    // ──────────────────────────────────────────────
    // PHASE 2: Weisfeiler-Leman color refinement
    // ──────────────────────────────────────────────
    // Refine until the partition is equitable:
    // For every pair of cells (Cᵢ, Cⱼ), every vertex in Cᵢ has 
    // the same number of neighbors in Cⱼ, for EACH edge type.
    
    // Build adjacency structure from M_verified edges
    // Key: (device, edge_type) → list of neighbor devices
    adjacency = build_typed_adjacency(M_verified.edges)
    
    changed = true
    WHILE changed:
        changed = false
        
        FOR EACH cell IN state.cells.values():
            IF |cell.members| <= 1:
                CONTINUE  // singleton cells are trivially equitable
            
            // For this cell, compute each member's neighbor-count profile
            // Profile: for each (other_cell, edge_type) → neighbor count
            profiles = {}
            FOR EACH device IN cell.members:
                profile = {}
                FOR EACH edge_type IN entity_store.edge_types:
                    FOR EACH other_cell IN state.cells.values():
                        count = count_neighbors_in_cell(device, other_cell, edge_type, adjacency)
                        profile[(other_cell.cell_id, edge_type)] = count
                profiles[device] = profile
            
            // Check if all profiles in this cell are identical
            reference_profile = profiles[cell.members.first()]
            subgroups = group_by(cell.members, d -> profiles[d])
            
            IF |subgroups| > 1:
                // Cell must be split
                changed = true
                
                // Remove original cell
                original_id = cell.cell_id
                state.cells.remove(original_id)
                
                // Create new cells from subgroups
                new_cell_ids = []
                FOR EACH (profile, members) IN subgroups:
                    new_cell = new Cell()
                    new_cell.cell_id = cell_id
                    new_cell.members = members
                    new_cell.signature = null  // no longer pure-signature cell
                    new_cell.is_v_inf = false
                    new_cell.cell_size = |members|
                    
                    state.cells[cell_id] = new_cell
                    FOR EACH hostname IN members:
                        state.device_to_cell[hostname] = cell_id
                    
                    new_cell_ids.append(cell_id)
                    cell_id += 1
                
                // Log the refinement
                state.refinement_log.append(RefinementEvent(
                    original_cell_id = original_id,
                    split_into = new_cell_ids,
                    reason = "weisfeiler_leman_structural_asymmetry",
                    structural_detail = describe_profile_difference(subgroups)
                ))
    
    RETURN state
```

#### 3.3 Equitability Verification

After refinement terminates, verify the equitability property explicitly:

```
FUNCTION verify_equitability(state, adjacency, entity_store):
    
    FOR EACH cell_i IN state.cells.values():
        FOR EACH cell_j IN state.cells.values():
            FOR EACH edge_type IN entity_store.edge_types:
                
                // All members of cell_i must have the same neighbor count in cell_j for this edge type
                counts = set()
                FOR EACH device IN cell_i.members:
                    count = count_neighbors_in_cell(device, cell_j, edge_type, adjacency)
                    counts.add(count)
                
                ASSERT |counts| <= 1, 
                    "Equitability violation: cell " + cell_i.cell_id + 
                    " members have different neighbor counts (" + counts + 
                    ") in cell " + cell_j.cell_id + " for edge type " + edge_type
    
    RETURN true  // no assertion failures
```

#### 3.4 Invariants

| ID | Invariant |
|----|-----------|
| INV-3.1 | Every device in V_net belongs to exactly one cell. |
| INV-3.2 | Every cell is non-empty. |
| INV-3.3 | The partition is equitable: for every cell pair (Cᵢ, Cⱼ) and edge type e, every vertex in Cᵢ has the same number of e-type neighbors in Cⱼ. |
| INV-3.4 | Weisfeiler-Leman refinement terminates. (Guaranteed: each iteration either splits a cell or converges. The number of possible cells is bounded by |V_net|, so at most |V_net| iterations.) |
| INV-3.5 | Devices with identical signatures that were NOT split by W-L refinement are in the same cell. (Signatures are a necessary condition for co-cellularity; structural regularity is the sufficient condition.) |

#### 3.5 Verification Criteria Mapping

| VC | Criterion | Test Specification |
|----|-----------|-------------------|
| VC-06 | Partition π is equitable | Run verify_equitability() on the final partition. Must pass for every cell pair and edge type. |
| VC-07 | W-L refinement produces correct splits | Feed a topology where signature-identical devices have non-isomorphic neighborhoods (e.g., two spines with identical configs but different connectivity patterns to leaves). Assert the refinement splits them into separate cells. |

---

### Module 4: Batfish Cross-Validation

**Spec reference:** Compression Engine §Step 2, "Batfish Cross-Validation of π"

**Purpose:** Use Batfish's formal verification engine as ground truth to validate the partition. Three checks: RIB structural equivalence, BGP session topology, ACL behavioral equivalence.

#### 4.1 Inputs

| Input | Source |
|-------|--------|
| PartitionState | Module 3 output |
| Batfish session | §2.3 |
| ExtractionConfidenceLedger | Module 1 output (for caveat annotations) |

#### 4.2 Algorithm

```
FUNCTION cross_validate_partition(state, bf_session, ledger):
    
    FOR EACH cell IN state.cells.values():
        IF |cell.members| <= 1:
            CONTINUE  // singleton cells are trivially correct
        
        representative = select_reference_member(cell)
        
        FOR EACH other_member IN cell.members WHERE other_member != representative:
            
            // ── Check 1: RIB structural equivalence ──
            rep_routes = bf_session.q.routes(nodes=representative).answer()
            other_routes = bf_session.q.routes(nodes=other_member).answer()
            
            rib_result = compare_rib_structural(rep_routes, other_routes)
            // "Structurally equivalent" means: same prefixes via same protocols 
            // with equivalent policy outcomes, differing only in next-hop IPs.
            
            state.cross_validation_results.append(CrossValidationResult(
                cell_id = cell.cell_id,
                validation_type = RIB,
                representative = representative,
                compared_member = other_member,
                result = rib_result.verdict,
                mismatch_detail = rib_result.detail,
                caveat = get_caveat(ledger, other_member)
            ))
            
            // ── Check 2: BGP session topology ──
            rep_sessions = bf_session.q.bgpSessionStatus(nodes=representative).answer()
            other_sessions = bf_session.q.bgpSessionStatus(nodes=other_member).answer()
            
            bgp_result = compare_bgp_topology(rep_sessions, other_sessions)
            // "Identical session topology" means: same number of established/not-established 
            // sessions per peer direction.
            
            state.cross_validation_results.append(CrossValidationResult(
                cell_id = cell.cell_id,
                validation_type = BGP_SESSION,
                representative = representative,
                compared_member = other_member,
                result = bgp_result.verdict,
                mismatch_detail = bgp_result.detail,
                caveat = get_caveat(ledger, other_member)
            ))
            
            // ── Check 3: ACL behavioral equivalence (leaf cells only) ──
            IF is_leaf_cell(cell):
                rep_acls = bf_session.q.searchFilters(
                    nodes=representative, 
                    filters=server_facing_acl_filter(representative)
                ).answer()
                other_acls = bf_session.q.searchFilters(
                    nodes=other_member,
                    filters=server_facing_acl_filter(other_member)
                ).answer()
                
                acl_result = compare_acl_behavior(rep_acls, other_acls)
                // "Identical permit/deny behavior across the header space"
                // searchFilters uses BDD/Z3 symbolic analysis — this is a formal proof,
                // not a sample-based test.
                
                state.cross_validation_results.append(CrossValidationResult(
                    cell_id = cell.cell_id,
                    validation_type = ACL,
                    representative = representative,
                    compared_member = other_member,
                    result = acl_result.verdict,
                    mismatch_detail = acl_result.detail,
                    caveat = get_caveat(ledger, other_member)
                ))
    
    // ── Mismatch resolution ──
    mismatches = [r for r in state.cross_validation_results if r.result = MISMATCH]
    
    FOR EACH mismatch IN mismatches:
        // Diagnose: which field(s) differ?
        diagnosis = diagnose_mismatch(mismatch)
        
        // Split the cell
        cell = state.cells[mismatch.cell_id]
        split_cell(state, cell, mismatch.compared_member, diagnosis)
        
        state.refinement_log.append(RefinementEvent(
            original_cell_id = mismatch.cell_id,
            split_into = [cell.cell_id, new_cell_id],
            reason = "batfish_cross_validation_mismatch",
            structural_detail = diagnosis.summary
        ))
    
    RETURN state
```

#### 4.3 RIB Structural Equivalence Definition

Two RIBs are "structurally equivalent" when:

1. Same set of destination prefixes (identical prefix/length pairs).
2. For each prefix, same protocol source (BGP, OSPF, static, connected, etc.).
3. For each prefix, same administrative distance and same metric (where applicable).
4. For each prefix, equivalent policy outcome — same communities attached, same local preference, same AS-path length (not same AS-path content — AS paths differ by construction in different positions).
5. Next-hop IPs may differ — these are instance-specific.
6. For OSPF routes: same OSPF area of origin, same OSPF route type (intra-area, inter-area, E1, E2), same metric/metric2.

The comparison must normalize next-hop references and ignore instance-specific interface names.

#### 4.4 Supplemental Cross-Validation

The spec mentions `bf.q.testRoutePolicies()` for supplemental verification. This is used when a RIB comparison shows structural equivalence but the equivalence depends on policy behavior that should be verified explicitly:

```
// For each cell with route-map-heavy policy, optionally verify with testRoutePolicies
FOR EACH cell IN state.cells.values() WHERE cell has complex policy objects:
    FOR EACH (representative, other_member) IN cell pairings:
        FOR EACH test_route IN generate_representative_routes(cell):
            rep_result = bf_session.q.testRoutePolicies(
                nodes=representative, 
                inputRoute=test_route
            ).answer()
            other_result = bf_session.q.testRoutePolicies(
                nodes=other_member,
                inputRoute=test_route
            ).answer()
            
            ASSERT rep_result.action = other_result.action,
                "Policy behavioral divergence in cell " + cell.cell_id
```

This supplemental check is not mandatory for every cell — it is triggered when the primary checks pass but the cell contains complex policy configurations that warrant additional confidence.

#### 4.5 Invariants

| ID | Invariant |
|----|-----------|
| INV-4.1 | Every non-singleton cell has at least one cross-validation result per validation type. |
| INV-4.2 | Every mismatch results in a cell split. No mismatches are ignored. |
| INV-4.3 | After mismatch resolution, re-running cross-validation on the split cells produces no further mismatches. (If it does, iterate until stable.) |
| INV-4.4 | Cross-validation results for devices under structural_caveat carry the caveat annotation. |

#### 4.6 Verification Criteria Mapping

| VC | Criterion | Test Specification |
|----|-----------|-------------------|
| VC-08 | RIB cross-validation passes for all cells | For each cell, compare routes() between representative and at least one other member. Assert structural equivalence. |
| VC-09 | BGP session cross-validation passes | For each cell, compare bgpSessionStatus() across members. Assert identical session topology. |
| VC-10 | ACL cross-validation passes for leaf cells | For each leaf cell, run searchFilters() on server-facing ACLs. Assert identical permit/deny behavior. |

---

### Module 5: Representative Selection

**Spec reference:** Compression Engine §Step 3: Minimum Representative Selection

**Purpose:** From each cell, select a representative set subject to Rules 1–7. Minimize total representative count subject to constraints.

#### 5.1 Inputs

| Input | Source |
|-------|--------|
| PartitionState (post-cross-validation) | Module 4 output |
| M_verified | §2.1 (for topology position, external peering, tier classification) |
| Entity Store V_inf classification rules | §2.4 |

#### 5.2 Algorithm — V_net Cells (Rules 1–4)

```
FUNCTION select_vnet_representatives(state, M_verified):
    
    selection = new RepresentativeSelection()
    
    FOR EACH cell IN state.cells.values() WHERE NOT cell.is_v_inf:
        representatives = set()
        
        // ── Rule 4: Singletons are always included ──
        IF |cell.members| = 1:
            representatives = cell.members
            selection.rule_log.append(RuleApplication(cell.cell_id, 4, "singleton_included", cell.members))
            cell.representatives = representatives
            CONTINUE
        
        // ── Rule 2: Unique neighbor relationships preserved ──
        // If any member has a unique external peering (e.g., border-1 peers with ISP-A, 
        // border-2 peers with ISP-B), both must be kept even if σ(border-1) = σ(border-2).
        unique_peering_devices = find_unique_external_peerings(cell, M_verified)
        representatives = representatives ∪ unique_peering_devices
        IF |unique_peering_devices| > 0:
            selection.rule_log.append(RuleApplication(
                cell.cell_id, 2, "unique_external_peering_preserved", unique_peering_devices))
        
        // ── Rule 1: |Rᵢ| ≥ 2 for every V_net cell ──
        WHILE |representatives| < 2:
            // Add the member with the most diverse connectivity (heuristic for optimization)
            candidate = select_most_connected_non_representative(cell, representatives, M_verified)
            representatives.add(candidate)
        selection.rule_log.append(RuleApplication(
            cell.cell_id, 1, "minimum_pair_enforced", representatives))
        
        // ── Rule 3: Tier-to-tier connectivity pattern preserved ──
        // Every kept leaf must connect to every kept spine in G_c.
        // This may force additional representatives to maintain the complete 
        // bipartite property between tiers.
        additional = enforce_tier_connectivity(cell, representatives, state, M_verified)
        representatives = representatives ∪ additional
        IF |additional| > 0:
            selection.rule_log.append(RuleApplication(
                cell.cell_id, 3, "tier_connectivity_preserved", additional))
        
        cell.representatives = representatives
        selection.cell_representatives[cell.cell_id] = representatives
    
    RETURN selection
```

#### 5.3 Algorithm — V_inf Cells (Rules 5–7)

```
FUNCTION select_vinf_representatives(state, M_verified, entity_store):
    
    // V_inf vertices are not partitioned by σ. They are grouped by rack position.
    // The compression engine infers rack membership from topology position 
    // (which leaf pair a server connects to).
    
    racks = infer_racks(M_verified, entity_store)
    
    FOR EACH rack IN racks:
        endpoints = rack.endpoints  // all V_inf vertices in this rack
        representatives = set()
        
        // ── Rule 6: At least one per inferred endpoint type ──
        endpoint_types = classify_endpoint_types(endpoints, entity_store)
        FOR EACH type IN endpoint_types:
            representatives.add(select_one_of_type(endpoints, type))
        selection.rule_log.append(RuleApplication(
            rack.cell_id, 6, "type_coverage", representatives))
        
        // ── Rule 5: 2–3 endpoints per rack ──
        WHILE |representatives| < 2:
            representatives.add(select_additional(endpoints, representatives))
        IF |representatives| < 3 AND |endpoints| >= 3:
            representatives.add(select_additional(endpoints, representatives))
        selection.rule_log.append(RuleApplication(
            rack.cell_id, 5, "rack_count_enforced", representatives))
        
        // ── Rule 7: Conservative dual-homing ──
        IF rack.dual_homing_type = "esi_undetectable":
            // Preserve both leaf-facing connections per endpoint
            ensure_both_leaf_connections(representatives, rack, M_verified)
            selection.rule_log.append(RuleApplication(
                rack.cell_id, 7, "conservative_dual_homing", representatives))
        
        // Create V_inf cell in partition state
        v_inf_cell = new Cell()
        v_inf_cell.members = set(endpoints)
        v_inf_cell.representatives = representatives
        v_inf_cell.is_v_inf = true
        v_inf_cell.cell_size = |endpoints|
        state.cells[next_cell_id()] = v_inf_cell
        
        selection.v_inf_decisions.append(VInfDecision(
            rack_id = rack.id,
            endpoints_in_rack = |endpoints|,
            representatives_selected = |representatives|,
            types_represented = endpoint_types.keys(),
            dual_homing_model = rack.dual_homing_type
        ))
    
    RETURN selection
```

#### 5.4 Invariants

| ID | Invariant |
|----|-----------|
| INV-5.1 | Every V_net cell has |Rᵢ| ≥ 2. |
| INV-5.2 | Every unique external peering relationship is preserved in the representative set. |
| INV-5.3 | Every kept leaf connects to every kept spine (complete bipartite between tier representatives). |
| INV-5.4 | Every singleton (|Cᵢ| = 1) device is included. |
| INV-5.5 | Every rack has 2–3 V_inf representatives. |
| INV-5.6 | Every inferred endpoint type in a rack is represented. |
| INV-5.7 | Where ESI is undetectable, both leaf-facing connections are preserved per representative endpoint. |

#### 5.5 Verification Criteria Mapping

| VC | Test |
|----|------|
| VC-11 | Count |Rᵢ| for every V_net cell. Assert ≥ 2. |
| VC-12 | Identify all unique external peerings. Assert each is represented in V_c. |
| VC-13 | For every kept leaf, verify it connects to every kept spine in G_c. |
| VC-14 | Assert all |Cᵢ| = 1 devices appear in V_c. |
| VC-15 | Assert 2–3 V_inf endpoints per rack. Assert type coverage. Assert conservative dual-homing. |

---

### Module 6: Route Propagation Path Completeness

**Spec reference:** Compression Engine §Step 4

**Purpose:** Detect all policy interaction chains in the production network. Verify corresponding paths exist in the compressed graph. Add missing representatives if needed.

#### 6.1 Algorithm

```
FUNCTION verify_path_completeness(state, bf_session, M_verified):
    
    // ── Detect policy interaction chains ──
    // Use searchRoutePolicies to find all policies that set or match 
    // communities, AS-path prepends, or local-preference.
    
    setting_policies = bf_session.q.searchRoutePolicies(
        action="set", 
        attributes=["community", "as-path-prepend", "local-preference"]
    ).answer()
    
    matching_policies = bf_session.q.searchRoutePolicies(
        action="match",
        attributes=["community", "as-path", "local-preference"]
    ).answer()
    
    // Build interaction chains:
    // Device A sets attribute X → propagation via BGP → Device B matches attribute X
    chains = trace_interaction_chains(setting_policies, matching_policies, M_verified.edges)
    
    // ── Verify paths in G_c ──
    FOR EACH chain IN chains:
        device_a = chain.setter_device
        device_b = chain.matcher_device
        
        rep_a = state.get_representative(device_a)
        rep_b = state.get_representative(device_b)
        
        // Verify both representatives are in V_c
        IF rep_a NOT IN V_c OR rep_b NOT IN V_c:
            // Add the missing representative
            add_representative_for_chain(state, chain)
            state.refinement_log.append(...)
        
        // Verify a BGP propagation path exists between rep_a and rep_b in G_c
        IF NOT bgp_path_exists(rep_a, rep_b, state):
            // Add intermediate representatives to complete the path
            add_intermediate_representatives(state, chain)
    
    RETURN chains
```

#### 6.2 Verification Criteria Mapping

| VC | Test |
|----|------|
| VC-16 | For each detected interaction chain, verify path existence in G_c between representatives. |

---

### Module 7: Compressed Graph Construction

**Spec reference:** Compression Engine §Step 5

**Purpose:** Assemble G_c from the representative set and preserved edges. Run regression validation.

#### 7.1 Algorithm

```
FUNCTION construct_compressed_graph(state, M_verified, bf_session):
    
    G_c = new CompressedGraph()
    
    // ── Build vertex set ──
    // V_c = ∪ Rᵢ (all selected representatives from V_net and V_inf cells)
    FOR EACH cell IN state.cells.values():
        FOR EACH rep IN cell.representatives:
            G_c.vertices[rep] = CompressedVertex(
                hostname = rep,
                cell_id = cell.cell_id,
                represents = cell.members,
                configuration = M_verified.get_device_config(rep),
                metadata = {}
            )
    
    // ── Build edge set ──
    // Preserve all edges between representatives that correspond to 
    // edges in the original graph between their respective cells
    FOR EACH edge IN M_verified.edges:
        IF edge.source_device IN G_c.vertices AND edge.target_device IN G_c.vertices:
            G_c.edges.append(CompressedEdge(
                source = edge.source_device,
                target = edge.target_device,
                edge_type = edge.edge_type,
                attributes = edge.attributes,
                production_edge_ref = (edge.source_device, edge.target_device)
            ))
    
    // ── Build inter-cell connectivity matrix bᵢⱼ ──
    FOR EACH edge IN M_verified.edges:
        cell_i = state.device_to_cell.get(edge.source_device)
        cell_j = state.device_to_cell.get(edge.target_device)
        IF cell_i != null AND cell_j != null:
            G_c.b_ij[(cell_i, cell_j)] = G_c.b_ij.get((cell_i, cell_j), 0) + 1
    
    // ── Regression validation ──
    // Run differentialReachability between full snapshot and compressed device set
    capability = M_verified.get_capability_tag("differential_reachability")
    IF capability.classification = C:
        compressed_devices = set(G_c.vertices.keys())
        diff_result = bf_session.q.differentialReachability(
            snapshot = "original",
            reference_snapshot = create_compressed_snapshot(compressed_devices)
        ).answer()
        G_c.differential_reachability_output = diff_result.to_string()
    ELSE:
        G_c.differential_reachability_output = 
            "differentialReachability unavailable (capability tag: " + capability.classification + 
            "). Regression validation omitted."
    
    RETURN G_c
```

#### 7.2 Invariants

| ID | Invariant |
|----|-----------|
| INV-7.1 | Every vertex in G_c is a real production device with a complete, valid configuration from M_verified. |
| INV-7.2 | Every edge in G_c corresponds to a real adjacency in the production graph. |
| INV-7.3 | bᵢⱼ is computed from the production graph (not the compressed graph). It counts ALL edges between cells, not just edges between representatives. |
| INV-7.4 | Sum of all |Cᵢ| = |V_net|. Every network device is accounted for. |

#### 7.3 Verification Criteria Mapping

| VC | Test |
|----|------|
| VC-17 | differentialReachability characterization is complete and included in mapping report. |

---

### Module 8: Output Assembly

**Spec reference:** Compression Engine §Output Artifacts

**Purpose:** Produce exactly six artifacts. No more, no fewer.

#### 8.1 Artifact Checklist

| # | Artifact | Source Data | Contract |
|---|----------|------------|----------|
| 1 | G_c — Compressed Graph | Module 7 output | Every vertex is a real device. Every edge is a real adjacency. Ready for VM instantiation. |
| 2 | π — Partition Mapping | PartitionState | π: V_net → {C₁, ..., Cₖ}. Equitable. Batfish cross-validated. Every device in exactly one cell. |
| 3 | |Cᵢ| — Cell Sizes | PartitionState | One integer per cell. Sum = |V_net|. |
| 4 | bᵢⱼ — Inter-Cell Connectivity | CompressedGraph.b_ij | One integer per cell pair. Computed from production graph. |
| 5 | Mapping Report | All modules | Human-readable. Every device appears exactly once. Every decision justified. |
| 6 | Extraction Confidence Report | Module 1 (ledger) + all modules | Per-device, per-field. Consistent with M_verified tags. |

#### 8.2 Mapping Report Structure

The mapping report is a structured document containing:

1. **Summary.** Total devices, total cells, compression ratio, disposition, number of directives applied.
2. **Per-cell section.** For each cell: member devices, common signature fields, selected representatives, selection rules applied.
3. **Per-singleton section.** For each |Cᵢ| = 1 device: reason (extraction gate failure, singleton_forcing, load balancer, structural uniqueness).
4. **Refinement log.** Every W-L split and every Batfish cross-validation split, with structural reasons.
5. **Cross-validation results.** Per-cell RIB/BGP/ACL comparison results. Caveats noted.
6. **Step 4 additions.** Representatives added for route propagation path completeness, with the interaction chain that required them.
7. **differentialReachability output.** Formal statement of preserved vs. abstracted flows.
8. **Rule application log.** Where Rules 1–7 applied and their effects.

#### 8.3 Extraction Confidence Report Structure

Per-device entry containing:

1. Parse status (from M_verified).
2. Extraction gate result and reason (from ledger).
3. Per-field extraction source classification (●/◐/○) from Entity Store.
4. Per-field fidelity tag (C/K/R) from M_verified.
5. Fields excluded from σ with reason (robustness_rule, field_exclusion_directive, supplemental_required, extraction_gate_failed).
6. Vendor class and vendor-class-wide exclusions.
7. Directives that affected this device and their effects.
8. analytical_degradation directives passed through for downstream.

#### 8.4 Verification Criteria Mapping

| VC | Test |
|----|------|
| VC-18 | Assert all six artifacts are produced. |
| VC-19 | Assert every device in V_net ∪ V_inf appears exactly once in the mapping report. |
| VC-20 | Assert every device has a per-field confidence assessment in the extraction confidence report. |

---

## §5 — Traceability Matrix

The complete forward and backward traceability chain for every verification criterion.

| VC | Spec Requirement | Module | Invariant(s) | Test Method |
|----|-----------------|--------|-------------|-------------|
| VC-01 | σ(v) deterministic (§Step 1) | 2 | INV-2.1 | Dual computation on identical input; bit-compare. |
| VC-02 | Extraction gate identifies parse failures (§Step 1) | 1, 2 | INV-1.3 | Feed PARTIALLY_UNRECOGNIZED devices; assert unique σ. |
| VC-03 | Robustness rule excludes ◐ fields (§Step 1) | 1 | INV-1.4 | Feed mixed vendor class with one unextractable ◐; assert class-wide exclusion. |
| VC-04 | Field exclusion directives applied (§Step 1) | 1, 2 | INV-1.5 | Feed YELLOW directives; assert excluded fields absent from σ. |
| VC-05 | Singleton forcing produces singletons (§Step 1) | 1, 3 | INV-1.3 | Feed singleton_forcing directives; assert |Cᵢ| = 1 in partition. |
| VC-06 | Partition equitable (§Step 2) | 3 | INV-3.3 | Run verify_equitability() on final partition. |
| VC-07 | W-L refinement correct (§Step 2) | 3 | INV-3.4, INV-3.5 | Feed non-isomorphic neighborhoods with identical σ; assert split. |
| VC-08 | RIB cross-validation passes (§Step 2) | 4 | INV-4.1 | Run routes() comparison per cell. |
| VC-09 | BGP cross-validation passes (§Step 2) | 4 | INV-4.1 | Run bgpSessionStatus() comparison per cell. |
| VC-10 | ACL cross-validation passes (§Step 2) | 4 | INV-4.1 | Run searchFilters() comparison for leaf cells. |
| VC-11 | Rule 1: |Rᵢ| ≥ 2 (§Step 3) | 5 | INV-5.1 | Count representatives per V_net cell. |
| VC-12 | Rule 2: unique peerings preserved (§Step 3) | 5 | INV-5.2 | Enumerate external peerings; assert all in V_c. |
| VC-13 | Rule 3: tier connectivity preserved (§Step 3) | 5 | INV-5.3 | Assert kept-leaf-to-kept-spine complete bipartite. |
| VC-14 | Rule 4: singletons included (§Step 3) | 5 | INV-5.4 | Assert all |Cᵢ| = 1 devices in V_c. |
| VC-15 | Rules 5–7: V_inf correct (§Step 3) | 5 | INV-5.5, INV-5.6, INV-5.7 | Assert rack counts, type coverage, dual-homing. |
| VC-16 | Policy interaction paths exist (§Step 4) | 6 | — | Per chain, assert path in G_c. |
| VC-17 | differentialReachability complete (§Step 5) | 7 | INV-7.1 | Assert output present in mapping report. |
| VC-18 | All six artifacts produced (§Output) | 8 | — | Assert artifact count = 6 and all non-null. |
| VC-19 | Mapping report covers all devices (§Output) | 8 | — | Assert every device in V_net ∪ V_inf appears exactly once. |
| VC-20 | Confidence report covers all devices (§Output) | 8 | — | Assert every device has per-field assessment. |

---

## §6 — Known Gap Implementation

The specification documents four known gaps. This section specifies how each gap is implemented — not the downstream impact (which is the Cathedral's and Mirror Box's problem), but the compression engine's concrete behavior.

### Gap CE-1: Stateful Device Modeling

**Implementation:**
- Firewalls: Compress using ACL-only behavioral signature. Stateful session-tracking behavior is assumed identical for devices with identical ACL configurations. The extraction confidence report documents "stateful_session_tracking: unmodeled" for every firewall device.
- Load balancers: Model as structurally unique (|Cᵢ| = 1). Never compress. The extraction confidence report documents "load_balancer: structurally_unique_default" for every load balancer.

**Module affected:** Module 1 (extraction confidence ledger sets load balancers to singleton), Module 2 (ACL-only signature for firewalls).

### Gap CE-2: STP / L2 Forwarding Topology

**Implementation:**
- For EVPN-VXLAN fabrics (target topology): No action needed. STP is not running on the fabric underlay.
- For legacy L2 networks: All trunk ports are assumed forwarding (optimistic model). The extraction confidence report documents "stp_state: unmodeled, trunk_ports_assumed_forwarding" for networks with L2 trunks without EVPN underlay.
- Detection logic: If M_verified contains L2 trunk edges without corresponding EVPN/VXLAN underlay configuration on the participating devices, flag the network as potentially STP-dependent.

**Module affected:** Module 7 (compressed graph construction includes potentially-blocked edges), Module 8 (extraction confidence report documents the gap).

### Gap CE-3: Timer Value Uncertainty in Signatures

**Implementation:**
- The robustness rule (Module 1, Phase 6) handles this automatically. If BGP keepalive/hold (◐) or MRAI (◐) cannot be extracted for any device in a vendor class, the field is excluded from σ for the entire vendor class.
- BFD interval/multiplier values are unconditionally excluded from σ (per spec). They are not ◐ candidates — they are hard-excluded.
- The extraction confidence report documents which timer fields were excluded and the vendor class that triggered each exclusion.

**Module affected:** Module 1 (robustness rule), Module 2 (signature inclusion table explicitly excludes BFD interval/multiplier).

### Gap CE-4: ESI-Based Dual-Homing Detection

**Implementation:**
- Rule 7 applies unconditionally when ESI is undetectable. The compression engine cannot distinguish MLAG-based from ESI-based dual-homing without ESI data.
- Detection logic: Check if M_verified contains MLAG peer-link edges for the leaf pair. If yes, dual-homing type = "mlag_detected". If no MLAG and the topology suggests dual-homing (server connects to two different leaves), dual-homing type = "esi_undetectable_conservative".
- Conservative behavior: Preserve both leaf-facing connections per endpoint representative.

**Module affected:** Module 5 (V_inf representative selection, Rule 7).

---

## §7 — Dependency Graph and Implementation Order

The modules have strict dependencies. The order below is the only valid implementation and execution sequence.

```
Module 1: Extraction Confidence Report Generator
    │
    │ Produces: ExtractionConfidenceLedger
    │ Required by: Module 2, Module 4, Module 8
    │
    ▼
Module 2: Behavioral Signature Computation
    │
    │ Produces: SignatureRegistry
    │ Required by: Module 3
    │
    ▼
Module 3: Equitable Partition Computation
    │
    │ Produces: PartitionState (initial)
    │ Required by: Module 4
    │
    ▼
Module 4: Batfish Cross-Validation
    │
    │ Produces: PartitionState (refined)
    │ Required by: Module 5
    │
    ▼
Module 5: Representative Selection
    │
    │ Produces: RepresentativeSelection, PartitionState (with representatives)
    │ Required by: Module 6, Module 7
    │
    ▼
Module 6: Route Propagation Path Completeness
    │
    │ Produces: PartitionState (with additional representatives if needed)
    │ Required by: Module 7
    │
    ▼
Module 7: Compressed Graph Construction
    │
    │ Produces: CompressedGraph
    │ Required by: Module 8
    │
    ▼
Module 8: Output Assembly
    │
    │ Produces: 6 artifacts (G_c, π, |Cᵢ|, bᵢⱼ, Mapping Report, Extraction Confidence Report)
    │ Consumed by: VM Instantiation, Cathedral, Mirror Box, Certification Report
```

No module may begin execution before all of its upstream dependencies have completed successfully. A failure in any module halts the pipeline — there is no skip-and-continue.

---

## §8 — Downstream Contract Verification

Before emitting output artifacts, the compression engine must verify that its outputs satisfy the contracts expected by downstream consumers.

### 8.1 Contracts with VM Instantiation Layer

| Contract | Verification |
|----------|-------------|
| Every vertex in G_c has a complete, valid configuration | Assert all entity store fields are populated for each vertex. Assert no field has fidelity_tag = R without a documented exception. |
| Every edge in G_c corresponds to a real adjacency | Assert every edge in E_c has a corresponding edge in M_verified.edges. |

### 8.2 Contracts with Cathedral

| Contract | Verification |
|----------|-------------|
| π is equitable and Batfish cross-validated | INV-3.3 + INV-4.3 hold. |
| |Cᵢ| is exact per cell | Assert sum = |V_net|. |
| bᵢⱼ is exact per cell pair | Assert bᵢⱼ computed from production graph edges. |
| Extraction confidence report is complete | VC-20. |

### 8.3 Contracts with Mirror Box

| Contract | Verification |
|----------|-------------|
| π maps every production device to a cell and representative | Assert |domain(π)| = |V_net|. |
| |Cᵢ| is exact | Same as Cathedral. |
| Extraction confidence report is complete | VC-20. |

### 8.4 Contracts with Certification Report

| Contract | Verification |
|----------|-------------|
| Mapping report covers every production device | VC-19. |
| Every compression decision has traceable justification | Assert every cell has a rule_log entry. Assert every singleton has a documented reason. |
| differentialReachability output is included | VC-17. |

---

## §9 — Glossary

| Term | Definition |
|------|-----------|
| σ(v) | Behavioral signature of vertex v — deterministic hash of dynamically relevant configuration. |
| π | Equitable partition of V_net into equivalence classes. |
| Cᵢ | A cell (equivalence class) in the partition π. |
| Rᵢ | Representative set for cell Cᵢ — the subset of Cᵢ selected for the compressed graph. |
| V_net | Network device vertex set — devices whose configs Batfish parsed. |
| V_inf | Infrastructure/endpoint vertex set — topology-inferred endpoints (servers, hypervisors, etc.). |
| G_c | The compressed graph — minimum-node subgraph preserving scale-invariant behaviors. |
| bᵢⱼ | Inter-cell connectivity count — number of edges between cells Cᵢ and Cⱼ in the production graph. |
| M_verified | The pre-qualified topology database with per-field fidelity tags from Stage 3. |
| W-L | Weisfeiler-Leman color refinement — iterative partition refinement algorithm. |
| ● | Batfish-native extraction confidence — reliable, structured, queryable. |
| ◐ | Batfish-derived extraction confidence — extractable with custom code, not via clean API. |
| ○ | Supplemental-required extraction confidence — needs input beyond device configs. |

---

## §10 — Open Implementation Decisions

The following decisions are explicitly deferred to the implementation phase. They do not affect the specification's correctness guarantees — they affect performance, ergonomics, and maintainability.

| Decision | Options | Constraints |
|----------|---------|------------|
| Implementation language | Python (pybatfish native), Go, Rust, etc. | Must interface with pybatfish (Python). If not Python, needs Python FFI or subprocess bridge for Batfish queries. |
| Hash algorithm for σ(v) | SHA-256, BLAKE3, etc. | Must be deterministic and collision-resistant. Cryptographic strength is not required for correctness — collision resistance is the property that matters. |
| Serialization format for σ(v) canonical input | Canonical JSON, msgpack with sorted keys, custom binary | Must be deterministic. Must be frozen once chosen — changing format invalidates all signatures. |
| Graph data structure | Adjacency list, adjacency matrix, NetworkX, custom | Must support efficient neighbor-count queries (used heavily by W-L refinement). |
| Partition data structure | Union-find, explicit cell maps, etc. | Must support efficient cell splitting (W-L refinement) and cell membership queries. |
| Parallelism model | Sequential, cell-parallel cross-validation, etc. | Cross-validation queries to Batfish are the bottleneck. Parallelizing per-cell cross-validation is the obvious optimization target. |
| Mapping report format | Markdown, JSON, HTML, PDF | Must be human-readable (spec requirement). Must be machine-parseable (for certification report consumption). |
| Extraction confidence report format | JSON, structured YAML, etc. | Must be machine-parseable (consumed by Cathedral, Mirror Box, Certification Report). |

---

*End of Compression Engine Build Document v1.0*
