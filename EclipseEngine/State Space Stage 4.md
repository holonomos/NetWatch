Version - 4.3
# Stage 4 — Qualification Gate: Product Disposition and Constraint Directive Emission

> The qualification gate is a monotone decision function. It reads the semantically-corrected partition from Stage 3, applies tier-based disposition rules derived from the pipeline dependency graph, and emits a product disposition plus constraint propagation directives for the compression engine. No semantic analysis occurs here — that was resolved in Stage 3 Pass 2. Stage 4 reads corrected classifications at face value and makes a go/qualified/no-go decision.
>
> **This stage is fully mechanizable.** The tier assignments are derived from the pipeline dependency trace. The disposition rules are deterministic. The constraint directives are generated from M_verified's field-level tags. No human judgment in the loop.

---

## Version Pin

Per Stage 2 and Stage 3 authoritative artifact identifiers. Stage 4 introduces no new external dependencies — it operates entirely on Stage 3's output artifacts.

- **Stage 3 reference:** `State_Space_Stage_3.md`, two-pass evaluator producing P_corrected and M_verified
- **Compression Engine reference:** `Compression_Engine.md`, behavioral signature definition and extraction gate
- **Entity Store reference:** `Entity_Store.md`, vertex and edge type definitions

---

## Position in Pipeline

```
Stage 3 output:
    P_corrected ──► 97 predicates, each classified C/K/R with annotations
    M_verified  ──► topology database with per-field fidelity tags
        │
        ▼
Stage 4: Qualification Gate
    Step 1: Apply tier assignments (derived from pipeline dependency trace)
    Step 2: Apply tier-based disposition rules
    Step 3: Generate constraint propagation directives (for YELLOW)
    Step 4: Emit final disposition
        │
        ├──► GREEN: M_verified + empty directive set → Compression Engine
        ├──► YELLOW: M_verified + directive set → Compression Engine
        └──► RED: halt pipeline, emit diagnostic
```

---

## The Function Q

Stage 4 implements the function:

```
Q: {C, K, R}⁹⁷ → {GREEN, YELLOW, RED} × DirectiveSet
```

where:
- The input is P_corrected from Stage 3 (the semantically-corrected partition over 97 predicates)
- The first output component is the product disposition
- The second output component is the set of constraint propagation directives (empty for GREEN and RED)

The function Q is composed of two sub-functions:
- **T: Σ → {0, 1, 2, 3}** — the tier assignment function, which maps each predicate to its tier based on which downstream component first consumes its output
- **D: {C, K, R}⁹⁷ × T → {GREEN, YELLOW, RED}** — the disposition function, which applies tier-based rules to the corrected partition

Both T and D are deterministic and mechanizable.

---

## Tier Derivation Rule

### Principle

A predicate's tier is determined by tracing its output forward through the pipeline dependency graph to identify which downstream component first consumes it. "First consumer" means the earliest component in the pipeline execution order that reads data validated by the predicate.

The pipeline execution order is: **Compression Engine → Cathedral → Mirror Box → Certification Report**. The compression engine runs first because it determines the compressed graph that the Cathedral and Mirror Box operate on. The Cathedral runs second because the Mirror Box's expansion function references the Cathedral's analytical predictions. The certification report is generated last from all prior outputs.

### Tier Definitions

**Tier 0 — Structural graph predicates.** The predicate's output is consumed by the compression engine's graph construction, equitable partition computation, or partition cross-validation. These predicates validate the structural foundation that the compression algorithm operates on: the device set, the edge set, the adjacency structure, and the routing tables used to verify that equivalence classes are behaviorally consistent.

If a Tier 0 predicate is R (rejected), the compression engine's structural model of the topology is missing a foundational input. The compressed graph may have wrong edges, missing devices, or unverifiable equivalence classes. The pipeline cannot produce a result whose structural correctness is provable. Disposition: **RED**.

If a Tier 0 predicate is K (constrained), the structural model is usable but carries identified uncertainties. The compression engine can still operate — the uncertainty is bounded and documented — but all downstream claims for affected devices are qualified. Disposition contribution: **YELLOW**.

**Tier 1 — Behavioral signature predicates.** The predicate's output is consumed by the compression engine's behavioral signature computation (the function σ(v)) or by the extraction validation gate that determines whether a device enters signature computation.

If a Tier 1 predicate is R (rejected), the compression engine cannot compute a reliable signature for affected devices. The defined fallback is: force affected devices into singleton equivalence classes (|Cᵢ| = 1). The compression engine's output is still structurally sound — singletons are trivially correct equivalence classes — but compression is reduced. Disposition contribution: **YELLOW**.

If a Tier 1 predicate is K (constrained), the compression engine excludes the degraded field from signature computation for affected devices (per the signature robustness rule in the Compression Engine spec). Affected devices may merge into fewer equivalence classes or be forced to singletons depending on how many signature fields remain. Disposition contribution: **YELLOW**.

**Tier 2 — Analytical prediction predicates.** The predicate's output is consumed by the Cathedral (analytical model) or Mirror Box (expansion function) but is NOT consumed by the compression engine's equivalence classification pipeline.

If a Tier 2 predicate is R (rejected), the Cathedral's analytical predictions or the Mirror Box's expansion claims for the affected domain are degraded. The compression engine and emulation are unaffected — the structural model and behavioral signatures are correct. Disposition contribution: **YELLOW** (with analytical degradation warning).

If a Tier 2 predicate is K (constrained), the analytical predictions carry documented approximations (e.g., timer values are FRR defaults rather than production-extracted). The compression engine is entirely unaffected. Disposition contribution: **GREEN** (partials in analytical predictions are immaterial to structural correctness).

**Tier 3 — Documentation predicates.** The predicate's output is consumed only by the certification report. Deferred protocol elements and infrastructure service validations. These predicates document the environment but do not parameterize any computation.

Tier 3 predicates do not affect disposition regardless of classification. They appear in the certification report with their classification and annotation.

### Tier Assignment Derivation

Each assignment below is derived by tracing the predicate's output (the fields and relations it validates in M_verified, per the Stage 3 predicate-to-field mapping table) forward through the pipeline to the first consuming component.

**Tracing methodology:**
1. Identify the M_verified fields that the predicate governs (from Stage 3, §M_verified Construction, Rule M1).
2. Identify which downstream component reads those fields first.
3. For the compression engine: distinguish between graph construction / partition verification inputs (Tier 0) and behavioral signature inputs (Tier 1).
4. For Cathedral / Mirror Box consumers that are not compression engine inputs: Tier 2.
5. For certification-report-only consumers: Tier 3.

---

## Tier Assignment Table

### Tier 0 — Structural Graph Predicates (7 predicates)

| Predicate | M_verified Fields | First Consumer | Derivation |
|-----------|-------------------|----------------|------------|
| FF-1.1.01 | R_bgpPeers, R_bgpStatus, R_bgpCompat, R_bgpEdges | Compression engine: graph construction (bgpEdges defines the BGP edge set); partition cross-validation (bgpSessionStatus comparison across equivalence class members) | BGP edge set is a structural input to the compressed graph. Peer count by direction is a signature dimension derived from bgpEdges. Cross-validation of equivalence classes uses bgpSessionStatus to verify that all class members show the same session topology. |
| FF-1.1.02 | R_ospfEdges, R_ospfCompat | Compression engine: graph construction (ospfEdges defines the OSPF adjacency set); partition cross-validation (OSPF route comparison across class members) | OSPF adjacency set is a structural input to the compressed graph. Peer count by direction includes ospfEdges. |
| FF-1.1.08 | R_l1Edges, R_l3Edges | Compression engine: graph construction (L1/L3 edges define the physical and logical topology) | The topology graph G = (V, E) is constructed from these edge sets. Wrong edges → wrong graph → wrong compressed graph → wrong emulation wiring. |
| FF-1.2.01 | R_bgpRib, R_bgpProcess | Compression engine: partition cross-validation (routes comparison is the primary mechanism for verifying equivalence class correctness) | The Compression Engine spec requires: "For each equivalence class, run routes(nodes=representative) and routes(nodes=other_member) — RIB contents must be structurally equivalent." FF-1.2.01 validates the RIB data this check operates on. |
| FF-1.2.02 | R_routes (protocol=ospf) | Compression engine: partition cross-validation (OSPF route metrics verify IGP cost consistency within equivalence classes) | IGP cost comparison across equivalence class members detects Gap 4 (hot-potato routing divergence). If OSPF route data is rejected, this validation cannot execute. |
| PM-2.3.01 | R_mlag | Compression engine: graph construction (MLAG/vPC configuration determines dual-homing topology inference for V_inf vertex compression) | The Compression Engine spec's Rule 7 (conservative dual-homing assumption) operates on MLAG detection data. MLAG config determines whether leaf pairs are recognized as dual-homed, which affects V_inf compression and the graph's redundancy structure. |
| CV-4.5.01 | Cross-validation of R_bgpRib and R_routes | Compression engine: partition cross-validation (BGP next-hop resolution via IGP validates overlay/underlay consistency, which is a structural property of the graph) | If BGP next-hops don't resolve via IGP, the routing model has structural inconsistencies. Routes with unresolvable next-hops would blackhole traffic. This is a graph-level integrity check, not a field-level check. |

### Tier 1 — Behavioral Signature Predicates (26 predicates)

| Predicate | M_verified Fields | Signature Field | Derivation |
|-----------|-------------------|----------------|------------|
| FF-1.1.03 | R_ospfInterfaces: Network_Type, OSPF_Enabled, Passive | OSPF configuration structure (interface type, passive-interface) | σ(v) includes OSPF interface types. Passive-interface status affects whether a device advertises routes on an interface, which is behavioral. |
| FF-1.1.04 | R_named (BFD structures): enablement, intervals, multiplier | BFD enablement per protocol | σ(v) includes BFD enablement (boolean). Note: BFD interval/multiplier values are EXCLUDED from σ by the Compression Engine spec (unreliable extraction) — they are Tier 2 (Mirror Box measures them empirically). The Tier 1 assignment covers BFD enablement only. |
| FF-1.1.07 | R_interfaces: Channel_Group, Channel_Group_Members | Port-channel structure (for leaf topology, server-facing interfaces) | Port-channel membership affects leaf-facing interface topology, which affects V_inf compression and ACL application points. |
| FF-1.2.03 | R_routes: Admin_Distance across protocols | Static route patterns (AD component) | σ(v) includes "Static route patterns (structural pattern — destination prefix length, AD)." AD values determine route selection when multiple sources offer the same prefix. |
| FF-1.3.01 | R_named (Route_Map): all route-map fields | Route-map content (match/set clauses, sequence numbers, permit/deny) | σ(v) includes route-map content. This is a primary signature dimension. |
| FF-1.3.02 | R_named (Route_Filter_List, Prefix_List): all prefix-list fields | Prefix-list content (prefix entries with ge/le operators) | σ(v) includes prefix-list content. |
| FF-1.3.03 | R_named (Community_List), R_bgpRib: Community attributes | Community-list content (values and regex) | σ(v) includes community-list content. |
| FF-1.3.04 | R_named (As_Path_Access_List), R_bgpRib: AS_Path | AS-path ACL content (regex patterns) | σ(v) includes AS-path ACL content. |
| FF-1.3.05 | R_routes: Admin_Distance | Administrative distance (per-protocol defaults, per-route overrides) | σ(v) includes AD as part of static route patterns and route selection behavior. |
| FF-1.3.06 | R_named (redistribute), R_routes: redistributed routes | Redistribution route-maps (captured as route-map content in σ) | Redistribution configuration references route-maps (Tier 1 via FF-1.3.01) and determines which routes appear in the RIB (Tier 0 via FF-1.2.01). Stage 3 semantic propagation handles the cascade. The redistribution config itself is a signature input because two devices with different redistribution policies are behaviorally different. |
| FF-1.3.07 | R_named (aggregate-address), R_bgpRib: aggregate routes | BGP aggregation config (suppress-map, attribute-map — captured as route-map content) | Aggregation configuration affects which prefixes are advertised, which is behavioral. |
| FF-1.3.08 | R_named (default-originate), R_routes: default route | Default origination config (route-map conditions — captured as route-map content) | Default route origination policy is behavioral. |
| FF-1.3.09 | R_vxlan, R_named (RT config), R_evpnRib: RT values, VNI mappings | VRF configuration structure (route-target import/export sets) | σ(v) includes VRF configuration structure. RT import/export determines VRF membership and EVPN route filtering. |
| FF-1.3.10 | R_named (Ip_Access_List), R_filterLines: ACL definitions | ACL content on server-facing interfaces (for leaf switches) | σ(v) includes ACL content on server-facing interfaces. |
| FF-1.3.11 | R_bgpPeers, R_named: maximum-prefix config | maximum-prefix configuration | maximum-prefix is aggregate-count-dependent (Stage 1 §1.3 exception). Not a per-route signature field but a per-peer config that determines session teardown behavior. Two devices with different maximum-prefix settings on the same peer type are behaviorally different. |
| FF-1.7.01 | R_parseStatus: parse completeness per device | Extraction gate (determines whether device enters signature computation) | The Compression Engine's Gate 1 requires PASSED parse status. PARTIALLY_UNRECOGNIZED devices are flagged as signature-unreliable and forced to singleton. FF-1.7.01's classification determines which devices pass the gate. |
| FF-1.7.02 | R_undefinedRefs, R_unusedStructs: reference integrity | Extraction gate (undefined references indicate model fidelity gaps) | The Compression Engine's Gate 3 checks initialization issues. Undefined references mean a policy is silently not applied, changing the effective behavioral signature. |
| FF-1.7.03 | R_node (VRFs), R_routes (per-VRF), R_named (VRF config) | VRF configuration structure (VRF names, isolation, route leaking) | σ(v) includes VRF configuration structure. |
| FF-1.9.02 | R_ospfInterfaces: Hello_Interval, Dead_Interval | OSPF configuration structure (hello/dead timers) | σ(v) includes OSPF hello/dead timers as part of OSPF configuration structure. |
| FF-1.9.03 | R_named (BGP timers): keepalive, hold time | BGP timer configuration (keepalive, hold) | σ(v) includes BGP keepalive/hold timers. Note: MRAI is excluded from σ per Compression Engine spec. |
| VD-2.1.02 | R_parseWarnings: parse warnings per device | Extraction gate (parse warnings in routing-critical sections trigger signature robustness rule) | The Compression Engine's signature robustness rule excludes fields that can't be extracted for a vendor class. VD-2.1.02's classification determines which vendor/device combinations trigger the robustness rule. |
| VD-2.1.03 | R_bgpProcess: tiebreaking flags | BGP process configuration (deterministic-med, always-compare-med, bestpath-compare-routerid) | These flags affect best-path selection algorithm behavior. Two devices with different tiebreaking flags in the same topology position may select different best paths. Signature-relevant because the flags change which path wins. |
| TE-3.3.01 | R_routes (protocol=ospf): IGP metrics per equivalence class | Compression Engine Gap 4 detection (IGP cost asymmetry within equivalence class) | The Compression Engine's partition verification checks that all members of an equivalence class have the same IGP metrics to the same destinations. TE-3.3.01 validates this data. If degraded, the partition verification is operating on uncertain metrics. |
| TE-3.3.03 | R_bgpPeers, R_bgpProcess: RR-client, cluster-ID | BGP peer-group template structure (route-reflector-client designation) | σ(v) includes BGP peer-group template structure, which includes RR-client status. A device marked as an RR-client has fundamentally different BGP behavior (receives reflected routes, originator-ID loop prevention applies). |
| CV-4.5.04 | R_undefinedRefs (routing context) | Extraction gate (undefined route-maps in routing context silently change behavior) | An undefined route-map referenced in a BGP neighbor statement means the policy is not applied. Vendor behavior diverges: some deny-all, some permit-all. This directly changes the device's effective behavioral signature. |
| CV-4.5.05 | R_named (ACLs on interfaces) | ACL content (undefined ACLs on forwarding interfaces change packet filtering behavior) | An undefined ACL on a forwarding interface has vendor-dependent behavior. This affects the ACL content dimension of σ. |

### Tier 2 — Analytical Prediction Predicates (48 predicates)

| Predicate | First Consumer | Derivation |
|-----------|----------------|------------|
| FF-1.1.05 | Cathedral: STP analysis for legacy topologies | STP is not in the behavioral signature (target topology is EVPN-VXLAN, where STP is not running on fabric underlay). Cathedral models STP for legacy topology analysis. |
| FF-1.1.06 | Cathedral: RSTP follows STP | Follows FF-1.1.05. |
| FF-1.1.09 | Cathedral / Mirror Box: Graceful Restart behavior modeling | GR configuration affects convergence behavior during restart events. Not a signature dimension — GR behavior is a runtime dynamic modeled by the Cathedral and measured by the Mirror Box. |
| FF-1.4.01 | Cathedral: BGP UPDATE/NOTIFICATION signaling model | BGP signaling behavior (UPDATE formatting, NOTIFICATION handling) is exercised by FRR in the emulation. The Cathedral models it analytically. Not a compression engine input. |
| FF-1.4.02 | Cathedral: OSPF LSA processing model | OSPF LSA generation, flooding, and aging are Cathedral model inputs for convergence prediction. |
| FF-1.4.03 | Cathedral: EVPN route-type analysis | EVPN route types (Type-1 through Type-5) parameterize the Cathedral's overlay model. Not in σ directly — VRF RT config (FF-1.3.09) covers the signature-relevant dimension. |
| FF-1.4.04 | Cathedral: VXLAN tunnel analysis | VXLAN encap/decap is a Cathedral model input for overlay path analysis. VNI mappings (FF-1.3.09) cover the signature-relevant dimension. |
| FF-1.4.05 | Cathedral: session management composite | Composite predicate — follows constituents (FF-1.1.01, FF-1.1.02, FF-1.9.01–03). The session management abstraction is a Cathedral model input. |
| FF-1.4.06 | Cathedral: capability negotiation analysis | BGP capability negotiation affects session establishment. Cathedral models this for compatibility prediction. Not in σ — address-family activation (in FF-1.1.01) covers the signature-relevant dimension. |
| FF-1.5.01 | Cathedral: BFD failover chain modeling | Failover chain timing and sequencing is a Cathedral prediction target. Not a compression engine input. |
| FF-1.5.02 | Cathedral: convergence sequencing analysis | Convergence sequence prediction is a primary Cathedral output. Not a compression engine input. |
| FF-1.5.03 | Cathedral: multi-failure blast radius computation | Blast radius analysis runs on the Cathedral's full graph (Tier 4 Cathedral-only per Compression Engine spec). |
| FF-1.5.04 | Cathedral: next-hop tracking model | NHT behavior (recursive resolution, reachability monitoring) is a Cathedral model input for convergence prediction. |
| FF-1.5.05 | Cathedral / Mirror Box: GR restart behavior | GR restart-timer behavior, stale-route marking, and EOR processing are modeled by the Cathedral and measured by the Mirror Box. |
| FF-1.6.01 | Cathedral: ECMP path enumeration | ECMP path count is a Cathedral structural property. The compression engine uses it for path verification (Step 4) but the path-count preservation check has a defined fallback (note approximation, don't claim exact preservation). Cathedral is the primary consumer. |
| FF-1.6.02 | Cathedral: graph property — bisection bandwidth | Structural graph property. Cathedral input. |
| FF-1.6.03 | Cathedral: graph property — hop count | Structural graph property. Cathedral input. |
| FF-1.6.04 | Cathedral: graph property — connectivity under k failures | Structural graph property. Cathedral input. |
| FF-1.6.05 | Cathedral: graph property — path diversity | Structural graph property. Cathedral input. |
| FF-1.6.06 | Cathedral: graph property — topology symmetry | Structural graph property. Cathedral input. |
| FF-1.9.01 | Cathedral / Mirror Box: BFD detection time formula | BFD timer arithmetic feeds the Cathedral's timing model. BFD interval/multiplier values are excluded from σ per Compression Engine spec — they are measured empirically by the Mirror Box as Tier 3 stochastic metrics. The timer formula itself is a Cathedral input. |
| VD-2.1.01 | Cathedral: vendor default timer divergence | Timer divergence affects Cathedral timing predictions (production vs FRR defaults). Not a compression engine input — timers that are in σ (OSPF hello/dead, BGP keepalive/hold) are covered by FF-1.9.02 and FF-1.9.03 at Tier 1. VD-2.1.01 covers the meta-question of whether those timer values are production-extracted or vendor-defaulted, which the Cathedral needs for prediction confidence. |
| VD-2.1.04 | Cathedral: SPF throttle timer modeling | SPF throttle timers affect convergence timing predictions. Cathedral input. |
| VD-2.1.05 | Cathedral: attribute handling edge cases | MED cross-AS comparison, route-ID tiebreaking, and other vendor-specific attribute behaviors. Cathedral models these for path prediction. |
| VD-2.1.06 | Cathedral / Mirror Box: GR vendor edge cases | GR implementation differences across vendors. Cathedral/Mirror Box model inputs. |
| TE-3.3.02 | Cathedral: DR/BDR election modeling | OSPF DR election is topology-dependent (all participants affect outcome). Cathedral models this. Not in σ — DR priority is extracted but is not a primary signature dimension for equivalence classification. |
| TE-3.3.04 | Cathedral: confederation boundary analysis | BGP confederation sub-AS handling. Cathedral model input. |
| TE-3.3.05 | Cathedral: asymmetric policy detection | Asymmetric import/export policies. Cathedral model input for path prediction. |
| TE-3.3.06 | Cathedral: multi-area OSPF analysis | ABR/ASBR behavior at area boundaries. Cathedral model input. |
| TE-3.3.07 | Cathedral: route leaking loop detection | VRF route-leaking loop potential. Cathedral model input. |
| TE-3.3.08 | Cathedral: STP root bridge analysis | STP root election for legacy topologies. Cathedral input. |
| PI-4.2.01 | Cathedral: IGP-BGP next-hop race condition analysis | Convergence race between IGP and BGP. Cathedral prediction target. |
| PI-4.2.02 | Cathedral: BFD-BGP-OSPF detection hierarchy analysis | Detection protocol hierarchy. Cathedral timing model input. |
| PI-4.2.03 | Cathedral: EVPN Type-2/Type-5 route interaction | LPM behavior between host and prefix routes. Cathedral overlay model input. |
| PI-4.2.04 | Cathedral: VRF RT interaction analysis | Route-target import/export interaction effects. Cathedral model input. |
| PI-4.2.05 | Cathedral: redistribution loop detection | Mutual redistribution loops. Cathedral model input. |
| PI-4.2.06 | Cathedral / Mirror Box: GR+BFD conflict analysis | GR helper mode interacting with BFD detection. Cathedral/Mirror Box model input. |
| PI-4.2.07 | Cathedral: ECMP+route-map interaction | ECMP path selection interacting with route-map policy. Cathedral model input. |
| LE-4.4.01 | Cathedral: L2-heavy network analysis | STP forwarding state for L2-heavy topologies. Cathedral input. Compression engine treats these as singletons by default (STP state unmodeled). |
| LE-4.4.02 | Cathedral: mixed L2/L3 boundary analysis | SVI / VLAN trunk interface boundary. Cathedral input. |
| LE-4.4.03 | Cathedral: NAT at enterprise edge | NAT reachability modeling. Cathedral input. Compression engine treats NAT devices as structurally unique. |
| LE-4.4.04 | Cathedral: legacy timer configurations | Follows VD-2.1.01. Cathedral timing model input. |
| LE-4.4.05 | Cathedral: dual-stack IPv4/IPv6 analysis | IPv6 extraction coverage. Cathedral input. IPv4 dimensions are covered by Tier 0/1 predicates. |
| LE-4.4.06 | Cathedral: OOB management network | Management VRF isolation. Cathedral input. Pipeline design property (separate management bridge), not a compression input. |
| LE-4.4.07 | Cathedral: stateful firewall analysis | Stateful session logic modeling. Cathedral input. Compression engine treats firewalls as singletons by default (Gap 5). |
| LE-4.4.08 | Cathedral: load balancer analysis | F5 VIP/pool modeling. Cathedral input. Compression engine treats load balancers as singletons by default (Gap 5). |
| CV-4.5.02 | Cathedral: EVPN VTEP reachability verification | Overlay fabric integrity. Cathedral overlay model input. |
| CV-4.5.03 | Cathedral: BFD/protocol timer consistency | Timer relationship validation. Cathedral timing model input. |

### Tier 3 — Documentation Predicates (16 predicates)

| Predicate | Rationale |
|-----------|-----------|
| FF-1.8.01 | DNS server IPs — informational, does not parameterize any computation |
| FF-1.8.02 | NTP server IPs — informational |
| FF-1.8.03 | SNMP configuration — informational |
| FF-1.8.04 | Syslog configuration — informational |
| FF-1.8.05 | AAA/TACACS+/RADIUS — informational |
| FF-1.8.06 | DHCP relay configuration — informational |
| DEF-01 | IS-IS — deferred, not in v1 pipeline |
| DEF-02 | PIM/Multicast — deferred |
| DEF-03 | MPLS/LDP — deferred |
| DEF-04 | MSDP — deferred |
| DEF-05 | VRRP — deferred |
| DEF-06 | SR-MPLS/SRv6/PCEP — deferred |
| DEF-07 | BGP Flowspec — deferred |
| DEF-08 | RPKI/ROA — deferred |
| DEF-09 | RIP — deferred |
| DEF-10 | BMP — deferred |

### Tier Count Verification

| Tier | Count | Predicates |
|------|-------|------------|
| Tier 0 | 7 | FF-1.1.01, FF-1.1.02, FF-1.1.08, FF-1.2.01, FF-1.2.02, PM-2.3.01, CV-4.5.01 |
| Tier 1 | 26 | FF-1.1.03, FF-1.1.04, FF-1.1.07, FF-1.2.03, FF-1.3.01–11, FF-1.7.01–03, FF-1.9.02–03, VD-2.1.02–03, TE-3.3.01, TE-3.3.03, CV-4.5.04–05 |
| Tier 2 | 48 | FF-1.1.05–06, FF-1.1.09, FF-1.4.01–06, FF-1.5.01–05, FF-1.6.01–06, FF-1.9.01, VD-2.1.01, VD-2.1.04–06, TE-3.3.02, TE-3.3.04–08, PI-4.2.01–07, LE-4.4.01–08, CV-4.5.02–03 |
| Tier 3 | 16 | FF-1.8.01–06, DEF-01–10 |
| **Total** | **97** | |

---

## Disposition Rules

### Rule Table

| Tier | Classification | Disposition Contribution | Rationale |
|------|---------------|-------------------------|-----------|
| 0 | C | — | Structural foundation verified. |
| 0 | K | YELLOW | Structural foundation usable but carries bounded uncertainty. Compression proceeds with structural caveats for affected devices. |
| 0 | R | **RED** | Structural foundation missing. Compressed graph cannot be constructed or verified. Pipeline halts. |
| 1 | C | — | Signature field verified. |
| 1 | K | YELLOW | Signature field degraded. Compression engine excludes field from σ for affected devices (per signature robustness rule). Affected devices may be forced to singleton. |
| 1 | R | YELLOW | Signature field missing. Compression engine forces affected devices to singleton equivalence classes. Sound but uncompressed for those devices. |
| 2 | C | — | Analytical prediction fully confident. |
| 2 | K | — | Analytical prediction carries documented approximation. Immaterial to structural correctness. |
| 2 | R | YELLOW | Analytical prediction domain unavailable. Cathedral/Mirror Box analysis degraded for this domain. |
| 3 | C/K/R | — | No disposition impact. Documentation only. |

### Final Disposition Computation

```
disposition = GREEN

for each σᵢ ∈ Σ:
    tier = T(σᵢ)
    classification = P_corrected(σᵢ)
    
    if tier = 0 and classification = R:
        disposition = RED
    
    if tier = 0 and classification = K:
        disposition = max(disposition, YELLOW)
    
    if tier = 1 and classification ∈ {K, R}:
        disposition = max(disposition, YELLOW)
    
    if tier = 2 and classification = R:
        disposition = max(disposition, YELLOW)

return disposition
```

where the ordering is GREEN < YELLOW < RED and max returns the worst.

### RED Condition Analysis

RED occurs if and only if at least one Tier 0 predicate is R in P_corrected.

Because P_corrected is the semantically-corrected partition from Stage 3, a Tier 0 R can arise from two sources:

1. **Direct evaluation failure.** The predicate's own conditions failed in Pass 1 (e.g., `bgpEdges()` returns ∅ for BGP-configured devices). This indicates a fundamental extraction or Batfish issue.

2. **Semantic cascade.** A Tier 1 predicate is R, and the semantic dependency graph in Stage 3 propagates the rejection to a Tier 0 predicate via a strong semantic edge. For example: FF-1.3.03 (community-lists) R → FF-1.3.01 (route-maps) R → FF-1.2.01 (BGP best-path) R. The original failure is in community-list extraction, but the cascade makes BGP best-path R because the RIB data is untrustworthy.

In both cases, the P_corrected annotation chain (from Stage 3 Pass 2, Rule 3) traces the full causal path. The RED diagnostic includes this chain so the customer knows exactly what to fix.

This cascade mechanism is critical: it means that a Tier 1 R predicate can trigger RED, but only when its rejection semantically propagates to a Tier 0 predicate via a strong dependency chain. A Tier 1 R that does NOT cascade to Tier 0 (because there is no strong semantic path from that Tier 1 predicate to any Tier 0 predicate) produces YELLOW, not RED. The severity is proportional to the structural impact, and the proportionality is derived from the semantic dependency graph — not from intuition.

---

## Constraint Propagation Directives

When disposition is YELLOW, Stage 4 generates a set of constraint propagation directives that instruct the compression engine on how to adjust its behavior. The compression engine does not know about predicates, tiers, or dispositions. It receives M_verified (with field-level fidelity tags) plus the directive set.

### Directive Schema

Each directive is a tuple:

```
directive = {
    directive_type:     "field_exclusion" | "force_singleton" | "structural_caveat" | "analytical_degradation",
    source_predicate:   σᵢ (the predicate that triggered the directive),
    source_tier:        0 | 1 | 2,
    classification:     K | R,
    affected_devices:   set of device names (from P_corrected device scope),
    affected_fields:    set of (relation, field_name) pairs (from Stage 3 predicate-to-field mapping),
    required_behavior:  string (precise instruction to the compression engine),
    annotation:         string (constraint annotation from P_corrected),
    semantic_chain:     [σ₁ → σ₂ → ... → σᵢ] (from P_corrected semantic chain)
}
```

### Directive Generation Rules

**Rule D1 — Tier 0 K generates structural caveats.**

For each Tier 0 predicate σ₀ in K:
```
emit directive {
    directive_type:     "structural_caveat",
    source_predicate:   σ₀,
    source_tier:        0,
    classification:     K,
    affected_devices:   P_corrected(σ₀).device_scope,
    affected_fields:    fields governed by σ₀ (from Stage 3 predicate-to-field mapping),
    required_behavior:  "All equivalence class claims involving affected devices carry structural qualification. 
                         Partition cross-validation results for affected devices are advisory, not definitive. 
                         Compression engine MAY still compress affected devices but the certification report 
                         qualifies all claims with the annotation below.",
    annotation:         P_corrected(σ₀).annotation,
    semantic_chain:     P_corrected(σ₀).semantic_chain
}
```

**Rule D2 — Tier 1 K generates field exclusion directives.**

For each Tier 1 predicate σ₁ in K:
```
emit directive {
    directive_type:     "field_exclusion",
    source_predicate:   σ₁,
    source_tier:        1,
    classification:     K,
    affected_devices:   P_corrected(σ₁).device_scope,
    affected_fields:    fields governed by σ₁ (from Stage 3 predicate-to-field mapping),
    required_behavior:  "Exclude affected_fields from behavioral signature σ(v) for all devices in 
                         affected_devices. Apply signature robustness rule: if a field is excluded 
                         for any device in a vendor class, exclude it for ALL devices in that vendor class. 
                         Devices whose remaining signature fields are insufficient for equivalence 
                         determination are forced to singleton equivalence classes.",
    annotation:         P_corrected(σ₁).annotation,
    semantic_chain:     P_corrected(σ₁).semantic_chain
}
```

**Rule D3 — Tier 1 R generates singleton directives.**

For each Tier 1 predicate σ₁ in R:
```
emit directive {
    directive_type:     "force_singleton",
    source_predicate:   σ₁,
    source_tier:        1,
    classification:     R,
    affected_devices:   P_corrected(σ₁).device_scope,
    affected_fields:    fields governed by σ₁ (from Stage 3 predicate-to-field mapping),
    required_behavior:  "Force all devices in affected_devices to singleton equivalence classes 
                         (|Cᵢ| = 1). Do not compute behavioral signatures for these devices. 
                         Preserve them as structurally unique in the compressed graph.",
    annotation:         P_corrected(σ₁).annotation,
    semantic_chain:     P_corrected(σ₁).semantic_chain
}
```

**Rule D4 — Tier 2 R generates analytical degradation warnings.**

For each Tier 2 predicate σ₂ in R:
```
emit directive {
    directive_type:     "analytical_degradation",
    source_predicate:   σ₂,
    source_tier:        2,
    classification:     R,
    affected_devices:   P_corrected(σ₂).device_scope,
    affected_fields:    [],
    required_behavior:  "Cathedral and Mirror Box analysis for the domain covered by source_predicate 
                         is unavailable. Cathedral falls back to reduced-confidence analytical model 
                         for this domain. Mirror Box does not emit expansion claims for this domain. 
                         Convergence diagnostic notes the gap. Compression engine is NOT affected.",
    annotation:         P_corrected(σ₂).annotation,
    semantic_chain:     P_corrected(σ₂).semantic_chain
}
```

**Rule D5 — Tier 2 K and Tier 3 C/K/R generate no directives.**

These classifications do not affect any computation. Tier 2 K annotations appear in the certification report only. Tier 3 classifications appear in the certification report only.

### Directive Consumption

The compression engine consumes directives as follows:

1. **Process all force_singleton directives first.** For each, mark the affected devices as singleton-forced. These devices will not participate in equivalence classification regardless of their signature.

2. **Process all field_exclusion directives.** For each, remove the affected fields from the signature computation for affected devices. Apply the signature robustness rule (vendor-class-wide exclusion).

3. **Process structural_caveat directives.** Note the affected devices. Partition cross-validation results involving these devices carry the caveat annotation.

4. **Proceed with normal compression algorithm** (signature computation → equitable partition → representative selection → path verification → graph construction) on the modified inputs.

The compression engine's algorithm is unchanged. It operates on M_verified plus directives. The directives are modifications to the inputs, not modifications to the algorithm.

---

## Complete Stage 4 Algorithm

**Input:** P_corrected (from Stage 3), M_verified (from Stage 3), T (tier assignment function, this document)

**Step 1: Initialize.**
```
disposition = GREEN
directive_set = ∅
red_diagnostics = []
```

**Step 2: Evaluate Tier 0 predicates.**
```
for each σ ∈ Σ where T(σ) = 0:
    if P_corrected(σ) = R:
        disposition = RED
        red_diagnostics.append({
            predicate: σ,
            reason: P_corrected(σ).annotation,
            semantic_chain: P_corrected(σ).semantic_chain,
            affected_devices: P_corrected(σ).device_scope
        })
    else if P_corrected(σ) = K:
        disposition = max(disposition, YELLOW)
        directive_set.add(generate_structural_caveat(σ))    // Rule D1
```

**Step 3: Check for RED.**
```
if disposition = RED:
    return (RED, ∅, red_diagnostics)
    // Pipeline halts. No directives emitted. Diagnostic explains why.
```

**Step 4: Evaluate Tier 1 predicates.**
```
for each σ ∈ Σ where T(σ) = 1:
    if P_corrected(σ) = R:
        disposition = max(disposition, YELLOW)
        directive_set.add(generate_singleton_directive(σ))   // Rule D3
    else if P_corrected(σ) = K:
        disposition = max(disposition, YELLOW)
        directive_set.add(generate_field_exclusion(σ))       // Rule D2
```

**Step 5: Evaluate Tier 2 predicates.**
```
for each σ ∈ Σ where T(σ) = 2:
    if P_corrected(σ) = R:
        disposition = max(disposition, YELLOW)
        directive_set.add(generate_analytical_degradation(σ)) // Rule D4
    // K: no directive, no disposition change (GREEN contribution)
```

**Step 6: Tier 3 — no evaluation needed.** Tier 3 predicates are documented in the certification report only.

**Step 7: Return.**
```
return (disposition, directive_set, [])
// Empty diagnostic list for GREEN/YELLOW (diagnostics are in the directives)
```

---

## Monotonicity Proof

**Theorem.** Q is monotone: changing any predicate's classification from C→K, C→R, or K→R in P_corrected can only maintain or worsen the disposition.

**Proof.** The disposition is computed as the maximum over individual contributions, where the ordering is GREEN < YELLOW < RED.

Each predicate's contribution is determined by a function f(tier, classification):

| Tier | C | K | R |
|------|---|---|---|
| 0 | GREEN | YELLOW | RED |
| 1 | GREEN | YELLOW | YELLOW |
| 2 | GREEN | GREEN | YELLOW |
| 3 | GREEN | GREEN | GREEN |

**Claim 1:** f is monotone non-increasing in classification (C ≥ K ≥ R on the truth ordering maps to ≥ on {GREEN, YELLOW, RED}).

Verification by case:
- Tier 0: GREEN ≥ YELLOW ≥ RED. ✓
- Tier 1: GREEN ≥ YELLOW ≥ YELLOW. ✓ (non-strictly, K→R doesn't change contribution)
- Tier 2: GREEN ≥ GREEN ≥ YELLOW. ✓ (non-strictly, C→K doesn't change contribution)
- Tier 3: GREEN ≥ GREEN ≥ GREEN. ✓ (constant)

Each f(tier, ·) is monotone non-increasing. ✓

**Claim 2:** The max operator preserves monotonicity.

If x₁ ≤ x₁' and all other xᵢ are unchanged, then max(x₁, x₂, ..., xₙ) ≤ max(x₁', x₂, ..., xₙ). ✓

**Claim 3:** Tier assignments are fixed. T(σ) does not depend on P_corrected.

T is derived from the pipeline dependency graph, which is a static property of the architecture. Changing a predicate's classification does not change its tier. ✓

**Combining:** Worsening any predicate's classification can only increase (worsen) its contribution f(T(σ), classification), which can only increase (worsen) the max, which can only increase (worsen) the disposition.

**QED.**

**Corollary (the customer guarantee):** Fixing a problem can only help, never hurt. If the customer improves any predicate's classification (from R→K, R→C, or K→C), the disposition stays the same or improves. This property holds for both direct improvements (the customer fixes a config issue that changes a predicate from R to C) and indirect improvements (fixing one predicate's input causes Stage 3 Pass 2 to stop cascading a semantic downgrade, improving downstream predicates' classifications).

---

## Output Specification

Stage 4 produces three artifacts:

### Artifact 1: Product Disposition

A single value from {GREEN, YELLOW, RED} with the following contractual semantics:

| Disposition | Contract | Compression Engine Behavior | Customer Communication |
|-------------|----------|---------------------------|----------------------|
| GREEN | Full SLA. All predicates confirmed or analytically immaterial. | Operates on M_verified with empty directive set. Full compression. All equivalence class claims carry full confidence. | "Your configuration has been fully validated. The emulation will faithfully reproduce your production network's control-plane behavior at the documented fidelity level." |
| YELLOW | Qualified SLA with enumerated caveats. Specific predicates are constrained or rejected, with identified compensations. | Operates on M_verified with non-empty directive set. Compression proceeds with field exclusions, singleton forcing, and structural caveats as specified. | "Your configuration has been validated with the following caveats: [enumerated list from directives]. The emulation is structurally sound but [N] devices are running uncompressed and [M] analytical predictions carry documented approximations." |
| RED | Product refuses to run. Structural foundation is missing. | Does not execute. | "Your configuration cannot be validated for emulation. The following structural issues prevent the pipeline from producing a trustworthy result: [enumerated list from red_diagnostics]. Each issue includes a trace showing exactly which extraction failure caused it and what would need to change to resolve it." |

### Artifact 2: Directive Set

For YELLOW: the set of constraint propagation directives (per the schema in §Constraint Propagation Directives). Each directive includes the source predicate, affected devices, affected fields, required behavior, annotation, and full semantic chain.

For GREEN: empty set.

For RED: empty set (no directives because the pipeline does not proceed).

### Artifact 3: RED Diagnostic (RED only)

For RED: a list of diagnostic entries, each containing:
- The Tier 0 predicate that is R
- The full annotation (from P_corrected)
- The full semantic chain (from P_corrected Pass 2), tracing the failure back to its root cause predicate
- The affected device set
- A remediation hint derived from the root cause: "Root cause: [predicate] is [R|K] because [annotation]. To resolve: [specific action — e.g., 'improve community-list parser coverage for [vendor]' or 'provide supplemental MLAG configuration data']."

The diagnostic is designed so the customer knows exactly what to fix. The semantic chain traces from the Tier 0 R predicate back through the dependency graph to the original failure, naming every predicate in the chain and its classification. The remediation hint is derived from the root cause predicate's Stage 2 disposition documentation.

### Artifact 4: Certification Report Annotations

For all dispositions: a structured report containing:
- The classification and annotation for all 97 predicates (grouped by tier)
- The directive set (for YELLOW)
- The RED diagnostic (for RED)
- Tier 3 documentation entries (deferred elements, infrastructure services)
- A summary: counts by tier and classification, overall disposition, and the formal statement of what the emulation does and does not guarantee

This report is the customer-facing document that the enterprise attaches to their compliance management system. It is the formal statement of the product's claims about fidelity.

---

## Invariants

The following invariants hold for any Stage 4 execution:

1. **Determinism.** The same P_corrected produces the same disposition, the same directive set, and the same diagnostic. Q is a pure function with no randomness, no external state, and no configuration parameters.

2. **Monotonicity.** Worsening any predicate's classification can only worsen the disposition (proved above).

3. **Tier stability.** T(σ) is constant for all σ. Tier assignments are derived from the pipeline architecture, not from evaluation results. A predicate's tier never changes based on what a customer config contains.

4. **Directive soundness.** Every directive in the directive set references a predicate that is K or R in P_corrected. No directive is generated for a C-classified predicate. No directive references a Tier 3 predicate.

5. **RED necessity.** RED occurs if and only if at least one Tier 0 predicate is R in P_corrected. There is no other path to RED. YELLOW cannot escalate to RED without a Tier 0 R.

6. **GREEN sufficiency.** GREEN occurs if and only if: all Tier 0 predicates are C, all Tier 1 predicates are C, and all Tier 2 predicates are C or K. Tier 3 classifications are irrelevant.

7. **Directive completeness.** Every K or R predicate in Tier 0, 1, or 2 that contributes to the YELLOW disposition has a corresponding directive in the directive set. No YELLOW trigger is undirected.

8. **Semantic chain integrity.** Every directive's semantic_chain field is a valid path in Stage 3's semantic dependency graph. The chain terminates at a predicate whose classification was determined by Pass 1 evaluation (not by semantic propagation). This means every directive traces to a concrete Batfish evaluation result, not to a derived classification.

9. **Traceability.** For every directive, the chain: directive → source predicate → Stage 2 predicate definition → Stage 1 element → RFC or invariance proof is complete and auditable.

---

## Interface Contracts

### Upstream: Stage 3 → Stage 4

Stage 4 requires from Stage 3:

| Artifact | Content | Contract |
|----------|---------|----------|
| P_corrected | 97-element vector of (classification, annotation, semantic_chain, device_scope) | Every predicate classified. Semantic propagation complete. No predicate has a C classification with degraded semantic dependencies (Stage 3 Invariant 4). |
| M_verified | Finite relational structure with per-field fidelity tags | Every field tagged. Tags consistent with P_corrected (Stage 3 Invariant 3). Capability tags attached at snapshot level. |

### Downstream: Stage 4 → Compression Engine

Stage 4 provides to the compression engine:

| Artifact | Content | Contract |
|----------|---------|----------|
| M_verified | Topology database (pass-through from Stage 3) | Unchanged. Stage 4 does not modify M_verified. |
| Directive set | Set of constraint propagation directives | Each directive specifies affected devices, affected fields, and required behavior. The compression engine applies directives to its inputs, not to its algorithm. |
| Disposition | GREEN or YELLOW | Only GREEN or YELLOW reach the compression engine. RED halts the pipeline before the compression engine executes. |

### Downstream: Stage 4 → Cathedral

| Artifact | Content | Contract |
|----------|---------|----------|
| M_verified | Topology database (pass-through) | Cathedral reads field-level fidelity tags to determine parameter confidence. |
| Analytical degradation directives | Subset of directive set where directive_type = "analytical_degradation" | Cathedral checks for degradation directives covering its analysis domains before computing predictions. Degraded domains produce reduced-confidence predictions or are omitted. |

### Downstream: Stage 4 → Certification Report

| Artifact | Content | Contract |
|----------|---------|----------|
| Disposition | GREEN, YELLOW, or RED | Top-line status. |
| Directive set | All directives | Enumerated caveats for YELLOW. |
| RED diagnostic | Root cause analysis | Remediation guidance for RED. |
| P_corrected | Full predicate classifications | Detailed per-predicate status for auditor review. |

---

## Interaction with Stage 3's Semantic Propagation

A critical architectural property: Stage 4 does NOT perform semantic analysis. All semantic dependency propagation is completed in Stage 3 Pass 2 before P_corrected reaches Stage 4.

This means:

1. **Stage 4 treats every classification in P_corrected as final.** If P_corrected says FF-1.3.01 is K, Stage 4 applies the Tier 1 K rule and emits a field_exclusion directive. It does not check whether FF-1.3.01's K was direct (from its own partial condition) or semantic (from a degraded community-list dependency). The semantic chain is preserved in the annotation for traceability, but it does not affect the disposition computation.

2. **The escalation rules from earlier architectural notes are no longer needed.** The majority rule ("|S_K(σ₀)| > |S_C(σ₀)| → RED") was designed for a Stage 4 that performed its own semantic analysis. With semantic analysis moved to Stage 3, the cascade is resolved before Stage 4 sees the data. A Tier 0 predicate that would have been escalated under the majority rule is already downgraded to K or R by Stage 3 Pass 2. Stage 4 just reads the corrected classification.

3. **The semantic dependency graph is Stage 3's responsibility.** Stage 4 does not construct, reference, or reason about G_sem. It receives a flat vector of 97 classifications and applies a deterministic tier-based decision function. This separation makes Stage 4 simple, auditable, and independently testable.

---

## Complexity Analysis

**Tier assignment:** O(97) — one lookup per predicate. The tier assignment table is static.

**Disposition computation:** O(97) — one comparison per predicate.

**Directive generation:** O(|YELLOW_triggers|) — one directive per predicate that triggers YELLOW. Bounded by 97.

**Total Stage 4 complexity:** O(97). Constant. Dominated by Stage 3's evaluation cost, which is in turn dominated by Batfish query costs. Stage 4 adds negligible overhead.
