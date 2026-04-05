Version - 4.3
## Version Pin

- **Batfish:** ≥ 2025.07.07 (Docker: `batfish/batfish:latest` at or after this tag)
- **pybatfish:** ≥ 0.36.0
- **FRR:** 10.6.0 (March 2026), per Stage 1 baseline
- **Stage 1 reference:** `State_Space_Stage_1.md`, post-filtration universal set

Batfish Docker image         │ 2025.07.07.2423 (commit 7a0efda)
pybatfish 2025.7.7.2423     │ pybatfish-2025.7.7.2423-py3-none-any.whl
FRR 10.6.0 source               │ frr-10.6.0.tar.gz

All predicates are evaluated against these versions. A version change to either Batfish or FRR invalidates all predicates and requires re-evaluation.

---

## Element Catalog Structure

Each element carries a unique identifier of the form `{SECTION}-{SUBSECTION}.{SEQUENCE}`:

- `FF` = Full Fidelity
- `DF` = Degraded Fidelity
- `VD` = Vendor Divergence
- `PM` = Proprietary Mapping
- `TE` = Topology Edge Case
- `PI` = Protocol Interaction
- `LE` = Legacy Environment
- `CV` = Cross-Validation Requirement
- `DEF` = Deferred

Each entry specifies: element identity (traced to Stage 1), extraction method, pass condition, partial condition, fail condition, and pre-decided disposition for each outcome.

Predicate notation:
- `∅` = empty result set (query returns zero rows)
- `⊂` = strict subset
- `|X|` = cardinality of set X
- `∀` = for all devices in the snapshot
- `∃` = there exists at least one device in the snapshot
- A predicate written as `P(x)` means "P evaluates to true for input x"

---

## Section A: Full Fidelity — Protocol Finite State Machines (Stage 1 §1.1)

### FF-1.1.01: BGP Finite State Machine

**Stage 1 trace:** §1.1, table row 1. 6 states (Idle → Connect → Active → OpenSent → OpenConfirm → Established), 28 events, per-session.

**Extraction method:** `bf.q.bgpPeerConfiguration()` returns per-peer configuration (local/remote AS, local/remote IP, address families, route-reflector-client, peer-group, import/export policies). `bf.q.bgpSessionStatus()` returns computed session state (ESTABLISHED, NOT_ESTABLISHED with diagnostic). `bf.q.bgpSessionCompatibility()` returns compatibility assessment. `bf.q.bgpEdges()` returns the edge set.

**Pass condition:** For every BGP peering relationship in the production config: (a) `bgpPeerConfiguration()` returns a row with non-null `Remote_AS`, non-null `Local_IP` or `Local_Interface`, and non-null `Remote_IP` or `Remote_Prefix` (dynamic neighbors); (b) `bgpSessionCompatibility()` returns a row for the peer with `Configured_Status` ≠ `INVALID`; (c) the peer appears in `bgpEdges()`. All three conditions hold for ≥ 99% of configured BGP peers across the snapshot.

**Partial condition:** `bgpPeerConfiguration()` returns rows for the peer but one or more of: (a) `bgpSessionCompatibility()` shows `UNKNOWN_REMOTE` or `HALF_OPEN` (indicating Batfish could not resolve the remote peer — common with dynamic neighbors or incomplete snapshots); (b) address-family columns are incomplete (e.g., L2VPN EVPN AF configured but not reflected in extraction). The peer is extractable but session-state validation is incomplete.

**Fail condition:** `bgpPeerConfiguration()` returns `∅` for a device whose raw config contains `router bgp` stanzas, OR `fileParseStatus()` shows `FAILED` for the device config file.

**Disposition:**
- Confirmed: BGP FSM enters verified set at full fidelity. FRR bgpd exercises the identical 6-state machine.
- Constrained: Peer enters verified set with constraint "session compatibility unverifiable — dynamic neighbor or incomplete snapshot." Convergence diagnostic flags the peer. Compression engine treats the device as structurally unique (singleton equivalence class) if peer extraction is incomplete.
- Rejected: Device is excluded from extraction. Reclassified as "config parse failure — manual review required." Compression engine refuses to process.

---

### FF-1.1.02: OSPF Neighbor Finite State Machine

**Stage 1 trace:** §1.1, table row 2. 8 states (Down → Attempt → Init → 2-Way → ExStart → Exchange → Loading → Full), per-adjacency.

**Extraction method:** `bf.q.ospfEdges()` returns computed OSPF adjacencies. `bf.q.ospfSessionCompatibility()` returns compatibility assessment (MTU mismatch, area mismatch, hello/dead timer mismatch, authentication mismatch, network type mismatch). `bf.q.ospfProcessConfiguration()` returns OSPF process config per node. `bf.q.ospfInterfaceConfiguration()` returns per-interface OSPF config (area, network type, hello interval, dead interval, cost, passive-interface).

**Pass condition:** For every OSPF-enabled interface pair that should form an adjacency: (a) `ospfInterfaceConfiguration()` returns rows for both interfaces with matching `Area`, compatible `Network_Type`, matching `Hello_Interval` and `Dead_Interval`; (b) `ospfSessionCompatibility()` returns `ESTABLISHED` or shows no incompatibility for the pair; (c) the pair appears in `ospfEdges()`.

**Partial condition:** `ospfInterfaceConfiguration()` returns rows but `ospfSessionCompatibility()` reports a diagnostic that is informational rather than fatal (e.g., passive-interface on one side preventing adjacency formation — this is correct config behavior, not an extraction failure).

**Fail condition:** `ospfInterfaceConfiguration()` returns `∅` for a device whose raw config contains `router ospf` stanzas, OR OSPF interfaces appear in config but are absent from `ospfInterfaceConfiguration()` output.

**Disposition:**
- Confirmed: OSPF neighbor FSM enters verified set at full fidelity. FRR ospfd exercises the identical 8-state machine.
- Constrained: Adjacency enters verified set with constraint documenting the specific compatibility diagnostic. No impact on compression — the diagnostic is config-correct behavior.
- Rejected: Device excluded from OSPF extraction. If device participates in an OSPF+BGP stack, the entire stack for this device is flagged. Reclassified as parse failure.

---

### FF-1.1.03: OSPF Interface Finite State Machine

**Stage 1 trace:** §1.1, table row 3. 7 states (Down / Loopback / Waiting / Point-to-Point / DR Other / Backup / DR), per-interface.

**Extraction method:** `bf.q.ospfInterfaceConfiguration()` returns `Network_Type` (POINT_TO_POINT, BROADCAST, NON_BROADCAST, POINT_TO_MULTIPOINT), `OSPF_Enabled`, `Passive`. The interface FSM state (DR/BDR election outcome) is computed by Batfish's dataplane engine and reflected in `ospfEdges()` topology.

**Pass condition:** Every OSPF-enabled non-passive interface in the snapshot has a row in `ospfInterfaceConfiguration()` with non-null `Network_Type`, non-null `Area`, and numeric `Hello_Interval` and `Dead_Interval`. For broadcast segments, Batfish computes DR/BDR election (visible in the adjacency model).

**Partial condition:** Interface appears in `ospfInterfaceConfiguration()` but `Network_Type` is null or unrecognized (some vendor-specific network types may not map cleanly). Interface is extractable but DR election behavior cannot be validated.

**Fail condition:** OSPF interface configured in raw config but absent from `ospfInterfaceConfiguration()`.

**Disposition:**
- Confirmed: OSPF interface FSM enters verified set. FRR exercises the same per-interface state machine.
- Constrained: Interface enters verified set with constraint "network type unresolved — DR election unvalidated." Compression engine uses P2P as conservative default.
- Rejected: Interface excluded. Device flagged for manual review.

---

### FF-1.1.04: BFD Finite State Machine

**Stage 1 trace:** §1.1, table row 4. 4 states (Down / Init / Up / AdminDown), per-session. Interval caveat: FSM invariance at ≥1s intervals; emulation uses 10x timer multiplication.

**Extraction method:** Batfish does **not** have a dedicated BFD question. BFD configuration is partially parsed from `namedStructures()` on a per-vendor basis. BFD enablement per BGP/OSPF peer is detectable via `bgpPeerConfiguration()` (if `BFD` column exists — version-dependent) or via `namedStructures(structType="BFD")` parsing. BFD interval/multiplier values require custom extraction from `namedStructures()` or raw config text.

**Pass condition:** For every device in the snapshot: (a) BFD enablement per protocol peer is extractable — either via a `BFD` column in `bgpPeerConfiguration()` or via `namedStructures()` cross-reference showing `neighbor X bfd` or equivalent vendor syntax parsed; (b) the binding between BFD session and protocol peer is determinable (which BGP/OSPF peer has BFD enabled).

**Partial condition:** BFD enablement (boolean: BFD is on or off per peer) is extractable, but interval and multiplier values are not extractable for the vendor platform. **Emulation impact: none.** All timers are uniformly dilated 10x — BFD intervals, BGP hold timers, OSPF dead intervals — preserving the causal ordering and ratio relationships between detection mechanisms. If explicit timer values are present in config, they are extracted and used (dilated in emulation, reverse-mapped in telemetry). If not, FRR defaults are used; the dashboard labels these as "FRR default" vs "production-extracted" — the engineer sees exactly which timers are approximated. This is a customer data-quality issue bounded by SLA documentation on config format requirements, not a product fidelity risk.

**Fail condition:** `namedStructures()` returns no BFD-related structures for any vendor, AND no BFD column or indicator exists in any protocol-specific question output. BFD configuration is invisible to Batfish — the product cannot determine which peers have BFD enabled.

**Disposition:**
- Confirmed: BFD FSM enters verified set at full fidelity. FRR bfdd exercises the identical 4-state machine. Uniform dilation preserves all timer ratios. Telemetry reverse-maps to production-equivalent times on the dashboard, showing both actual (dilated) and adjusted (production-equivalent) values.
- Constrained: BFD enablement is extractable but timer values are not. Enters verified set with constraint "BFD intervals use FRR defaults — dashboard labels these as approximated. Emulation correctness unaffected (dilation preserves ordering). Customer SLA documentation specifies config format for explicit timer extraction."
- Rejected: BFD is undetectable (enablement invisible, not just timers). Reclassified as supplemental data requirement. Customer must provide BFD config separately, or BFD is disabled in emulation with convergence diagnostic noting "BFD not modeled — failover timing degrades to protocol hold timers."

---

### FF-1.1.05: STP Finite State Machine

**Stage 1 trace:** §1.1, table row 5. 5 states (Disabled / Blocking / Listening / Learning / Forwarding), per-port.

**Extraction method:** Batfish does **not** simulate STP. Batfish extracts limited STP configuration: `namedStructures(structType="Spanning_Tree")` may return STP mode (RSTP, PVST, MST) and `interfaceProperties()` exposes `Spanning_Tree_Portfast` as a boolean. No STP forwarding state computation exists.

**Pass condition:** This predicate **cannot be fully satisfied**. Batfish does not compute STP topology. The pass condition would require Batfish to compute per-port STP states from configuration, which it does not do.

**Partial condition:** (a) `namedStructures()` returns STP-related structures (mode, priority, port cost) for devices with STP configured; (b) `interfaceProperties()` returns `Spanning_Tree_Portfast` for relevant interfaces; (c) the target topology is EVPN-VXLAN where STP does not run on the fabric underlay (STP is only on server-facing access ports with portfast, where the forwarding state is trivially Forwarding).

**Fail condition:** Target topology contains L2 trunks without EVPN underlay AND no supplemental STP state data is provided.

**Disposition:**
- Confirmed: N/A — pass condition cannot be satisfied for STP forwarding state computation.
- Constrained: STP FSM enters verified set with constraint "STP forwarding state unmodeled; all trunk ports assumed Forwarding." For EVPN-VXLAN target topology, this constraint has zero operational impact (STP is access-port-only with portfast). Convergence diagnostic reports "STP state: assumed forwarding on N trunk interfaces." Degradation severity: NONE for EVPN-VXLAN, SEVERE for legacy L2.
- Rejected: For legacy L2 topologies without supplemental STP data, STP forwarding state is rejected. Reclassified as supplemental data requirement. Customer must provide `show spanning-tree` output or equivalent.

---

### FF-1.1.06: RSTP Finite State Machine

**Stage 1 trace:** §1.1, table row 6. 3 states (Discarding / Learning / Forwarding), per-port.

**Extraction method:** Same as FF-1.1.05 — Batfish does not simulate RSTP. Configuration extraction identical to STP.

**Pass condition:** Same as FF-1.1.05 — cannot be fully satisfied.

**Partial condition:** Same as FF-1.1.05.

**Fail condition:** Same as FF-1.1.05.

**Disposition:** Identical to FF-1.1.05. RSTP and STP share the same extraction limitation and the same constraint.

---

### FF-1.1.07: LACP Finite State Machine

**Stage 1 trace:** §1.1, table row 7. Partner detection, aggregation logic, active/passive mode, per-link.

**Extraction method:** `bf.q.interfaceProperties()` returns `Channel_Group` and `Channel_Group_Members` columns for port-channel/LAG interfaces. LACP mode (active/passive) is extractable from `namedStructures()` on supported platforms. `layer1Edges()` (if supplemental L1 topology provided) shows physical link membership.

**Pass condition:** For every port-channel interface in the snapshot: (a) `interfaceProperties()` returns a row with non-empty `Channel_Group_Members` listing member interfaces; (b) each member interface also appears in `interfaceProperties()` with matching `Channel_Group` reference; (c) `interfaceProperties()` shows consistent admin status across members.

**Partial condition:** Port-channel interfaces appear in `interfaceProperties()` with member list, but LACP mode (active/passive) is not extractable from the vendor config format.

**Fail condition:** Port-channel interfaces appear in raw config but `interfaceProperties()` returns null `Channel_Group_Members`, OR member interfaces do not cross-reference back to the port-channel.

**Disposition:**
- Confirmed: LACP enters verified set. FRR + Linux bonding driver exercise LACP negotiation. Channel-group membership is topologically correct.
- Constrained: LACP enters verified set with constraint "LACP mode (active/passive) not extracted — FRR defaults to active mode." Convergence diagnostic notes LACP mode assumption.
- Rejected: Port-channel topology is unextractable. Reclassified as supplemental data requirement (customer provides LAG membership). Without LAG topology, compression engine cannot correctly model dual-homing.

---

### FF-1.1.08: LLDP Discovery

**Stage 1 trace:** §1.1, table row 8. Neighbor discovery and advertisement, per-link.

**Extraction method:** LLDP is not a routing protocol — Batfish does not extract LLDP configuration or state. LLDP neighbor data, if available, would be supplemental (e.g., from `show lldp neighbors` output provided as `layer1_topology.json`). `bf.q.layer1Edges()` uses supplemental L1 topology data that may be derived from LLDP.

**Pass condition:** Supplemental `layer1_topology.json` is provided and `layer1Edges()` returns a non-empty edge set that covers all physical links in the topology. This supplemental data may originate from LLDP neighbor tables.

**Partial condition:** No supplemental L1 topology is provided, but Batfish infers L3 topology from IP addressing and protocol peering (`layer3Edges()`). LLDP-equivalent neighbor discovery is implicit in the inferred topology.

**Fail condition:** Neither supplemental L1 topology nor inferable L3 topology exists for a set of devices. Topology is disconnected in Batfish's model.

**Disposition:**
- Confirmed: LLDP-equivalent topology enters verified set. FRR runs lldpd for neighbor discovery in emulation.
- Constrained: Topology is inferred from L3, not from physical discovery. Enters verified set with constraint "physical topology inferred from L3 addressing — cabling errors between L2 and L3 not detectable."
- Rejected: Disconnected topology. Reclassified as supplemental data requirement.

---

### FF-1.1.09: Graceful Restart (BGP and OSPF)

**Stage 1 trace:** §1.1, table row 12. Restarter/helper roles, stale-path timers, F-bit, EOR markers, per-session.

**Extraction method:** `bf.q.bgpPeerConfiguration()` — no dedicated GR columns exist in pybatfish output. GR configuration must be extracted from `namedStructures()` parsing: `bgp graceful-restart`, `bgp graceful-restart restart-time`, `bgp graceful-restart stalepath-time`, `bgp graceful-restart-disable`. For OSPF: `namedStructures()` for `graceful-restart` under `router ospf`.

**Pass condition:** For every BGP peer with GR configured: `namedStructures()` returns parseable GR configuration entries (restart-time, stalepath-time, helper-only, preserve-fw-state). The GR parameters are structurally complete — all three core timer values (restart-time, stalepath-time, select-defer-time) are present or defaultable.

**Partial condition:** `namedStructures()` returns GR enablement (on/off) but timer values are not parsed for the vendor platform. **Emulation impact: none.** GR timers are uniformly dilated with all other timers. If explicit values are present, they are extracted and used. If not, FRR defaults are used; the dashboard labels them as FRR-defaulted. GR's correctness properties (stale-path preservation, EOR processing, helper mode) are timer-ratio-dependent, not absolute-value-dependent, and uniform dilation preserves all ratios. This is a customer data-quality issue per SLA documentation.

**Fail condition:** GR configuration lines appear in raw config but are in the `PARTIALLY_UNRECOGNIZED` set from `fileParseStatus()` / `parseWarning()`. GR *enablement* is undetectable — not just timers.

**Disposition:**
- Confirmed: GR enters verified set. FRR exercises BGP GR (including LLGR since FRR 8.4+) and OSPF GR natively. GR timers are dilated uniformly; telemetry reverse-maps to production-equivalent values on the dashboard.
- Constrained: GR enablement extracted but timer values defaulted to FRR. Enters verified set with constraint "GR timer values are FRR defaults — dashboard labels as approximated. Emulation correctness unaffected (dilation preserves timer relationships). Customer SLA documentation specifies config format for explicit timer extraction."
- Rejected: GR config unparseable — *enablement* invisible (not just timers). Reclassified as vendor parse gap. GR is disabled in emulation; convergence diagnostic notes "GR not modeled — restart events will cause full session teardown."

---

## Section B: Full Fidelity — Routing Algorithms (Stage 1 §1.2)

### FF-1.2.01: BGP Best-Path Selection Algorithm

**Stage 1 trace:** §1.2, table row 1. Ordered comparison: weight → local-pref → locally-originated → AS-path length → origin → MED → eBGP-over-iBGP → IGP metric → multipath → oldest → router-ID → cluster-list → neighbor IP. MED caveat: without `deterministic-med`, arrival-order-dependent.

**Extraction method:** `bf.q.bgpProcessConfiguration()` returns `Multipath_EBGP`, `Multipath_IBGP`, `Tie_Breaker` (if exposed). `bf.q.bgpPeerConfiguration()` returns per-peer policy (import/export route-maps). `bf.q.bgpRib()` returns the computed BGP RIB with all path attributes (AS_Path, Local_Preference, MED, Origin, Communities, Weight). `bf.q.routes()` returns the final selected routes. `bf.q.testRoutePolicies()` tests individual route-map evaluations.

**Pass condition:** (a) `bgpRib()` returns a non-empty RIB for every BGP-speaking device; (b) for a sample of ≥ 10 prefixes per device, `bgpRib()` shows path attributes (AS_Path, Local_Preference, MED, Origin, Communities) that are structurally complete (non-null for fields that should be populated); (c) `routes(protocols="bgp")` returns the winning routes; (d) `bgpProcessConfiguration()` returns `Multipath_EBGP` and `Multipath_IBGP` values consistent with the raw config.

**Partial condition:** `bgpRib()` returns paths but one or more attribute fields are null when they should be populated (e.g., Weight column missing on some vendors, MED not populated for iBGP-learned routes). Best-path selection is exercisable but attribute completeness is degraded.

**Fail condition:** `bgpRib()` returns `∅` for a device with active BGP peering, OR `routes(protocols="bgp")` returns routes whose attributes are inconsistent with `bgpRib()` path data (indicating a Batfish data-plane computation error).

**Disposition:**
- Confirmed: BGP best-path enters verified set at full fidelity. FRR bgpd implements the identical algorithm including `deterministic-med` and `always-compare-med` options.
- Constrained: Enters verified set with constraint "best-path attribute [X] not extractable for [vendor] — FRR uses default." Compression engine excludes the missing attribute from behavioral signature for that vendor class (per signature robustness rule in Compression Engine).
- Rejected: BGP RIB computation failure. Architectural issue in Batfish. Escalate to Batfish team.

---

### FF-1.2.02: Dijkstra / SPF Algorithm

**Stage 1 trace:** §1.2, table row 2. Shortest-path tree from LSDB. Deterministic: same LSDB = same SPT.

**Extraction method:** `bf.q.routes(protocols="ospf")` returns OSPF-computed routes. `bf.q.ospfEdges()` confirms the adjacency graph. The SPF result is the routing table — Batfish computes SPF internally and exposes the result as routes, not the intermediate SPT.

**Pass condition:** (a) `routes(protocols="ospf")` returns non-empty OSPF routes on every OSPF-speaking device; (b) for every OSPF adjacency in `ospfEdges()`, routes exist in the RIB that are reachable via that adjacency; (c) OSPF route metrics are consistent with the sum of interface costs along the shortest path (verifiable by cross-referencing `ospfInterfaceConfiguration()` cost values with route metrics).

**Partial condition:** OSPF routes are present but metric values cannot be independently verified (e.g., reference bandwidth configuration not extracted, making cost derivation ambiguous).

**Fail condition:** `routes(protocols="ospf")` returns `∅` for a device with `router ospf` configured and active adjacencies in `ospfEdges()`.

**Disposition:**
- Confirmed: Dijkstra/SPF enters verified set. FRR ospfd computes the identical SPT.
- Constrained: Enters with constraint "OSPF metric verification incomplete — reference bandwidth unextracted." Route correctness (right next-hop) is confirmed; metric accuracy is degraded.
- Rejected: Batfish OSPF data-plane computation failure. Escalate.

---

### FF-1.2.03: Route Redistribution and Administrative Distance Comparison

**Stage 1 trace:** §1.2, table row 4. Per-prefix comparison, deterministic.

**Extraction method:** `bf.q.routes()` returns all routes with `Protocol` column (BGP, OSPF, STATIC, CONNECTED, etc.) and `Admin_Distance` column. Redistribution configuration is in `namedStructures()` (route-maps applied to `redistribute` statements). `bf.q.testRoutePolicies()` validates redistribution route-maps.

**Pass condition:** (a) `routes()` returns routes from multiple protocols on devices configured for redistribution; (b) the winning route per prefix has the lowest `Admin_Distance` among competing protocols; (c) redistribution route-maps are extractable via `namedStructures()` and testable via `testRoutePolicies()`.

**Partial condition:** Routes from multiple protocols appear but AD values for some protocols show as default when the config specifies a non-default AD (e.g., `distance bgp 20 200 200` parsed but AD override not reflected in `routes()` output).

**Fail condition:** Redistribution is configured but routes from the source protocol do not appear in the destination protocol's RIB on the redistributing device.

**Disposition:**
- Confirmed: Redistribution + AD enters verified set. FRR Zebra performs the identical AD comparison.
- Constrained: Enters with constraint "non-default AD values unverifiable — FRR uses config-specified values." Convergence diagnostic notes AD assumption.
- Rejected: Redistribution logic failure in Batfish. Escalate.

---

## Section C: Full Fidelity — Route and Policy Processing (Stage 1 §1.3)

### FF-1.3.01: Route-Map Evaluation

**Stage 1 trace:** §1.3, table row 1. Match conditions → set actions. Per-route pipeline.

**Extraction method:** `bf.q.namedStructures(structType="Route_Map")` returns full route-map definitions (sequence numbers, match clauses, set clauses, permit/deny). `bf.q.testRoutePolicies()` tests a specific route against a specific policy, returning the action (permit/deny) and the transformed route attributes. `bf.q.searchRoutePolicies()` symbolically searches for routes that satisfy or violate a policy.

**Pass condition:** (a) `namedStructures(structType="Route_Map")` returns entries for every route-map defined in the snapshot; (b) each entry contains sequence numbers, match conditions, set actions, and permit/deny action; (c) `testRoutePolicies()` correctly evaluates a test route against a sample route-map (match clause matches, set clause transforms attributes, deny clause denies) — verified against at least 3 route-maps per device sampled.

**Partial condition:** Route-maps are returned but one or more match/set clause types are not parsed for the vendor (e.g., `match extcommunity` not parsed on FortiOS, or `set tag` not reflected in output). The route-map is structurally present but specific clauses are opaque.

**Fail condition:** `namedStructures(structType="Route_Map")` returns `∅` for a device with route-maps in its raw config, OR `testRoutePolicies()` produces results inconsistent with manual evaluation of the route-map logic.

**Disposition:**
- Confirmed: Route-map evaluation enters verified set at full fidelity. This is a Tier 1 capability of both Batfish and FRR.
- Constrained: Enters with constraint "match/set clause [X] not parsed for [vendor] — route-map evaluation incomplete for policies using this clause." Convergence diagnostic flags affected policies. Compression engine excludes the unparseable clause from behavioral signature.
- Rejected: Route-map extraction failure. Device enters singleton equivalence class. Manual review required.

---

### FF-1.3.02: Prefix-List Matching

**Stage 1 trace:** §1.3, table row 2. Exact match, ge/le range operators, implicit deny, sequence ordering.

**Extraction method:** `bf.q.namedStructures(structType="Route_Filter_List")` or `namedStructures(structType="Prefix_List")` returns prefix-list entries with prefix, ge, le, action (permit/deny), sequence number.

**Pass condition:** `namedStructures()` returns entries for every prefix-list in the snapshot, each with non-null prefix values, ge/le operators (where configured), and permit/deny actions per entry. Entry count matches the raw config.

**Partial condition:** Prefix-list entries are returned but ge/le operators are missing or default to 0/32 when the raw config specifies different values.

**Fail condition:** Prefix-lists defined in raw config are absent from `namedStructures()`.

**Disposition:**
- Confirmed: Prefix-list matching enters verified set. Batfish and FRR both evaluate prefix-lists identically.
- Constrained: Enters with constraint "ge/le operator accuracy unverified for [vendor]." `searchFilters()` can be used for cross-validation.
- Rejected: Prefix-list extraction failure. Policies referencing these prefix-lists are unverifiable.

---

### FF-1.3.03: Community Handling

**Stage 1 trace:** §1.3, table row 3. Standard (RFC 1997), extended (RFC 4360), large (RFC 8092). Additive vs replace. Regex. Well-known communities.

**Extraction method:** `bf.q.namedStructures(structType="Community_List")` returns community-list definitions with values/regex patterns and permit/deny. `bf.q.bgpRib()` returns per-route communities. `bf.q.testRoutePolicies()` validates community match/set operations.

**Pass condition:** (a) `namedStructures(structType="Community_List")` returns entries for all community-lists; (b) `bgpRib()` shows community attributes on BGP routes; (c) `testRoutePolicies()` correctly evaluates a route-map with `match community` and `set community` clauses — community addition, replacement, and deletion produce expected results.

**Partial condition:** Standard communities are extractable but extended communities (route-target, route-origin) or large communities are not reflected in `bgpRib()` or `namedStructures()` for the vendor platform.

**Fail condition:** Community-lists are absent from `namedStructures()` despite being present in raw config.

**Disposition:**
- Confirmed: Community handling enters verified set. FRR supports all three community types.
- Constrained: Enters with constraint "[extended|large] community extraction incomplete for [vendor]." EVPN route-target operations specifically validated via `vxlanVniProperties()` as a cross-check.
- Rejected: Community extraction failure. Route-maps using community matching are unverifiable. Compression engine excludes community-list content from behavioral signature for affected vendor class.

---

### FF-1.3.04: AS-Path Manipulation

**Stage 1 trace:** §1.3, table row 4. Prepending, regex filtering, length comparison, private AS removal.

**Extraction method:** `bf.q.namedStructures(structType="As_Path_Access_List")` returns AS-path ACL definitions with regex patterns. `bf.q.bgpRib()` returns `AS_Path` per route. `bf.q.testRoutePolicies()` validates AS-path match/set.

**Pass condition:** (a) `namedStructures(structType="As_Path_Access_List")` returns entries for all AS-path ACLs; (b) `bgpRib()` shows non-empty `AS_Path` for eBGP-learned routes; (c) `testRoutePolicies()` correctly evaluates `match as-path` and `set as-path prepend`.

**Partial condition:** AS-path ACLs are extractable but regex syntax interpretation differs between vendor and Batfish (e.g., Cisco-style `_65000_` vs standard regex). `parseWarning()` flags regex syntax issues.

**Fail condition:** AS-path ACLs absent from `namedStructures()`, or `bgpRib()` shows empty `AS_Path` for all routes.

**Disposition:**
- Confirmed: AS-path manipulation enters verified set.
- Constrained: Enters with constraint "AS-path regex [pattern] may interpret differently in Batfish vs [vendor] — flagged by parse warnings."
- Rejected: AS-path extraction failure.

---

### FF-1.3.05: Administrative Distance

**Stage 1 trace:** §1.3, table row 5. Per-protocol defaults, per-route overrides, floating static routes.

**Extraction method:** `bf.q.routes()` returns `Admin_Distance` per route. Cross-reference with protocol-specific defaults and any `distance` configuration in `namedStructures()`.

**Pass condition:** `routes()` returns `Admin_Distance` values for all routes, and these values match expected defaults (OSPF=110, eBGP=20, iBGP=200, Static=1, Connected=0) or config-specified overrides.

**Partial condition:** AD values are present but non-default overrides (e.g., `distance bgp 20 200 200`) are not reflected in `routes()` output.

**Fail condition:** `Admin_Distance` column is null or absent in `routes()` output.

**Disposition:**
- Confirmed: AD enters verified set. FRR Zebra uses the identical AD comparison.
- Constrained: Enters with constraint "non-default AD overrides unverifiable." FRR uses config-specified values when present in frr.conf.
- Rejected: Route extraction incomplete. Escalate.

---

### FF-1.3.06: Route Redistribution Between Protocols

**Stage 1 trace:** §1.3, table row 6. OSPF↔BGP, static↔BGP, connected↔OSPF, with/without route-maps.

**Extraction method:** Redistribution configuration extracted from `namedStructures()` under protocol-specific structures. `routes()` shows redistributed routes appearing in destination protocol RIB. `testRoutePolicies()` validates redistribution route-maps.

**Pass condition:** (a) `namedStructures()` contains `redistribute` statements within BGP/OSPF process configuration; (b) `routes()` shows routes from source protocol appearing in destination protocol's RIB on the redistributing device; (c) if a redistribution route-map is configured, `testRoutePolicies()` confirms it is parseable and evaluable.

**Partial condition:** Redistribution configuration is extractable but the redistributed routes do not appear in `routes()` (possible Batfish data-plane computation gap for complex redistribution chains).

**Fail condition:** `redistribute` statements are in raw config but not parseable by Batfish.

**Disposition:**
- Confirmed: Route redistribution enters verified set. FRR handles all supported redistribution combinations.
- Constrained: Enters with constraint "redistribution route presence unverifiable in Batfish RIB — FRR emulation is ground truth for this path."
- Rejected: Redistribution configuration unparseable. Manual verification required.

---

### FF-1.3.07: Route Summarization

**Stage 1 trace:** §1.3, table row 7. BGP aggregate-address (as-set, suppress-map, attribute-map). OSPF inter-area/external summarization.

**Extraction method:** BGP aggregation: `namedStructures()` for `aggregate-address` statements. `bgpRib()` shows aggregate routes. OSPF summarization: `namedStructures()` for `area range` or `summary-address` statements. `routes()` shows summarized routes.

**Pass condition:** (a) `namedStructures()` returns aggregate-address/area-range config entries; (b) `bgpRib()` or `routes()` shows aggregate routes with expected attributes (as-set, suppressed more-specifics).

**Partial condition:** Aggregation config is extractable but suppress-map/attribute-map details are not fully parsed.

**Fail condition:** Aggregation config absent from extraction despite being in raw config.

**Disposition:**
- Confirmed: Route summarization enters verified set.
- Constrained: Enters with constraint "suppress-map/attribute-map details partially extracted." FRR exercises aggregation with available config.
- Rejected: Aggregation configuration unparseable.

---

### FF-1.3.08: Default Route Origination

**Stage 1 trace:** §1.3, table row 8. BGP default-originate with/without route-map. OSPF default-information originate.

**Extraction method:** `namedStructures()` for `default-originate` / `default-information originate` config. `routes()` for presence of 0.0.0.0/0 in the RIB. `bgpRib()` for BGP-originated default route.

**Pass condition:** (a) Default route origination config is extractable; (b) `routes()` or `bgpRib()` shows 0.0.0.0/0 on the originating device.

**Partial condition:** Config is extractable but the conditional route-map gating default origination is not fully evaluated by Batfish (e.g., `default-originate route-map CHECK` where CHECK depends on the existence of a specific prefix).

**Fail condition:** Default origination config unparseable.

**Disposition:**
- Confirmed: Default route origination enters verified set.
- Constrained: Enters with constraint "conditional default origination route-map evaluation may differ." FRR evaluates the route-map at runtime.
- Rejected: Config unparseable.

---

### FF-1.3.09: Route-Target Import/Export

**Stage 1 trace:** §1.3, table row 9. VRF membership, EVPN route filtering, per-route per-VRF.

**Extraction method:** `bf.q.vxlanVniProperties()` returns VNI-to-VRF mappings. `bf.q.nodeProperties()` returns VRF names. Route-target configuration extracted from `namedStructures()` under VRF or BGP address-family config. `evpnRib()` shows EVPN routes with RT attributes.

**Pass condition:** (a) `vxlanVniProperties()` returns VNI mappings for all EVPN-configured devices; (b) `namedStructures()` returns RT import/export configuration per VRF; (c) `evpnRib()` shows EVPN routes with community attributes containing the expected RT values.

**Partial condition:** VNI mappings are extractable but RT values are not in a queryable format (must be manually cross-referenced from `namedStructures()` output).

**Fail condition:** `vxlanVniProperties()` returns `∅` on EVPN-configured devices.

**Disposition:**
- Confirmed: RT import/export enters verified set. FRR EVPN exercises RT-based route filtering.
- Constrained: Enters with constraint "RT values require manual cross-reference from namedStructures." Compression engine uses composite VRF query for RT extraction.
- Rejected: EVPN VNI extraction failure. EVPN overlay topology is unverifiable. Critical gap.

---

### FF-1.3.10: ACL / Firewall Rule Evaluation

**Stage 1 trace:** §1.3, table row 10. Ordered rule matching. Per-packet. Match logic invariant; TCAM capacity is substrate-dependent (OUT).

**Extraction method:** `bf.q.searchFilters()` symbolically searches for packets matching ACL criteria. `bf.q.testFilters()` tests a concrete packet against an ACL. `bf.q.filterLineReachability()` identifies unreachable ACL lines. `bf.q.findMatchingFilterLines()` shows which line matches a specific packet. `bf.q.namedStructures(structType="Ip_Access_List")` returns ACL definitions.

**Pass condition:** (a) `namedStructures(structType="Ip_Access_List")` returns entries for all ACLs in the snapshot; (b) `searchFilters()` and `testFilters()` produce results for ACLs on multiple devices; (c) `filterLineReachability()` runs without error and produces results indicating ACL analysis is functional.

**Partial condition:** ACLs are extractable for major vendors (Cisco, Juniper, Arista) but not for secondary vendors (Fortinet, Check Point) or for specific ACL types (e.g., time-based ACLs, reflexive ACLs).

**Fail condition:** `namedStructures()` returns no ACL structures for devices with ACLs in raw config.

**Disposition:**
- Confirmed: ACL evaluation enters verified set. Batfish's BDD-based symbolic analysis is ground truth for match logic.
- Constrained: Enters with constraint "ACL extraction incomplete for [vendor/type]. Unextractable ACLs treated as permit-all in reachability analysis." Convergence diagnostic reports ACL coverage percentage.
- Rejected: ACL extraction failure on primary vendor (Cisco/Juniper/Arista). Indicates Batfish parser regression. Escalate.

---

### FF-1.3.11: maximum-prefix (Scale-Dependent Policy)

**Stage 1 trace:** §1.3, exception paragraph. Aggregate-count-dependent, not per-route. Tears down BGP session when threshold exceeded.

**Extraction method:** `bf.q.bgpPeerConfiguration()` — check for maximum-prefix column (version-dependent). `namedStructures()` for `maximum-prefix` under BGP neighbor configuration.

**Pass condition:** `bgpPeerConfiguration()` or `namedStructures()` returns the configured maximum-prefix threshold value for BGP peers where it is set.

**Partial condition:** maximum-prefix enablement is detectable but the threshold value is not extractable.

**Fail condition:** maximum-prefix configuration is invisible to Batfish.

**Disposition:**
- Confirmed: maximum-prefix config enters verified set as data for Cathedral analytical modeling (not runtime enforcement in compressed emulation).
- Constrained: Enters with constraint "maximum-prefix threshold value unknown — Cathedral cannot model session teardown trigger." Convergence diagnostic flags.
- Rejected: maximum-prefix configuration unextractable. Cathedral models all BGP sessions as unlimited prefix capacity. Known gap.

---

## Section D: Full Fidelity — Control-Plane Signaling (Stage 1 §1.4)

### FF-1.4.01: BGP Message Encoding and Parsing

**Stage 1 trace:** §1.4, table row 1. UPDATE/WITHDRAW/NOTIFICATION encoding and parsing. NLRI processing.

**Extraction method:** Not directly extracted — BGP message format is exercised by FRR bgpd at runtime. Batfish's role is to validate the *configuration* that governs message generation (route-maps, prefix-lists, communities that are attached to UPDATEs). Validation: if Batfish can compute the BGP RIB correctly (FF-1.2.01), the implied message processing is correct.

**Pass condition:** FF-1.2.01 (BGP best-path) passes, AND `bgpSessionStatus()` shows sessions reaching ESTABLISHED state in Batfish's model. These together confirm that Batfish models the BGP message exchange correctly at the configuration level.

**Partial condition:** FF-1.2.01 passes partially (some attribute gaps).

**Fail condition:** FF-1.2.01 fails.

**Disposition:**
- Confirmed: BGP signaling enters verified set. FRR bgpd produces RFC-compliant BGP messages.
- Constrained: Follows FF-1.2.01 constraint.
- Rejected: Follows FF-1.2.01 rejection.

---

### FF-1.4.02: OSPF LSA Types

**Stage 1 trace:** §1.4, table row 2. Types 1-11. Flooding, aging, database synchronization.

**Extraction method:** `bf.q.routes(protocols="ospf")` reflects the result of LSA processing. `bf.q.ospfProcessConfiguration()` and `ospfAreaConfiguration()` show area types (stub, NSSA, backbone) that govern LSA filtering. Batfish internally models LSA generation and flooding; the result is the converged OSPF RIB.

**Pass condition:** FF-1.2.02 (Dijkstra/SPF) passes, AND `ospfProcessConfiguration()` correctly identifies area types (stub, NSSA, totally-stubby), AND routes in stub/NSSA areas show appropriate LSA filtering (no Type-5 LSAs in stub, Type-7 NSSA translation at ABR).

**Partial condition:** Area types are correct but Type-7 to Type-5 translation behavior is not independently verifiable from Batfish output.

**Fail condition:** FF-1.2.02 fails.

**Disposition:**
- Confirmed: OSPF LSA processing enters verified set. FRR ospfd generates all standard LSA types.
- Constrained: Enters with constraint "Type-7 NSSA translation not independently verified — FRR emulation is ground truth."
- Rejected: Follows FF-1.2.02 rejection.

---

### FF-1.4.03: EVPN Route Types

**Stage 1 trace:** §1.4, table row 3. Type-2 (MAC/IP), Type-3 (Inclusive Multicast), Type-5 (IP Prefix) at full fidelity. Type-1 (EAD) and Type-4 (ES) partial — ESI-LAG not fully modeled.

**Extraction method:** `bf.q.evpnRib()` returns EVPN routes with route type, RD, RT, and route-specific fields. `bf.q.vxlanVniProperties()` returns VNI-to-VLAN-to-VRF mappings.

**Pass condition:** (a) `evpnRib()` returns Type-2 and Type-5 routes on EVPN-configured devices; (b) Type-3 routes (inclusive multicast) appear for every VNI on every VTEP; (c) route attributes (RD, RT, VNI) are consistent with `vxlanVniProperties()`.

**Partial condition:** Type-2 and Type-5 routes are present but Type-1 (EAD) and Type-4 (ES) routes are absent. This is expected — Batfish does not model EVPN multihoming (GitHub issue #7904).

**Fail condition:** `evpnRib()` returns `∅` on EVPN-configured devices, OR `vxlanVniProperties()` returns `∅`.

**Disposition:**
- Confirmed: EVPN Type-2/3/5 enter verified set at full fidelity. FRR bgpd generates all five route types.
- Constrained: EVPN Type-1/4 enter verified set with constraint "ESI-LAG multihoming routes not modeled by Batfish. FRR generates Type-1/4 in emulation but Batfish cannot validate them against production config. Multihoming correctness relies on FRR runtime behavior, not Batfish pre-validation." Convergence diagnostic: "EVPN multihoming: FRR-only validation."
- Rejected: EVPN extraction failure. Critical gap for any EVPN-VXLAN topology. Blocks pipeline.

---

### FF-1.4.04: VXLAN Encapsulation/Decapsulation

**Stage 1 trace:** §1.4, table row 4. Per RFC 7348.

**Extraction method:** `bf.q.vxlanVniProperties()` returns VNI configurations. `bf.q.interfaceProperties()` shows VXLAN tunnel interfaces. Batfish's `traceroute()` output includes VXLAN encap/decap steps.

**Pass condition:** `vxlanVniProperties()` returns VNI-to-VLAN mappings, AND `interfaceProperties()` shows VXLAN interfaces with configured source (VTEP) IPs, AND `traceroute()` for a cross-VTEP flow shows encapsulation/decapsulation steps.

**Partial condition:** VNI properties are extractable but `traceroute()` does not show encap/decap steps (older Batfish versions may not render these).

**Fail condition:** `vxlanVniProperties()` returns `∅` on devices with VXLAN config.

**Disposition:**
- Confirmed: VXLAN enters verified set. FRR + Linux kernel VXLAN exercises encap/decap.
- Constrained: Enters with constraint "VXLAN encap/decap not visible in traceroute output — VNI mapping verified, path verification incomplete."
- Rejected: VXLAN extraction failure. Critical for EVPN-VXLAN topology.

---

### FF-1.4.05: Adjacency and Session Management

**Stage 1 trace:** §1.4, table row 6. Hello/keepalive exchange, hold timer negotiation, capability advertisement, session teardown.

**Extraction method:** Session management is the aggregate of protocol-specific extractions: `bgpSessionStatus()` for BGP, `ospfSessionCompatibility()` for OSPF, plus timer extraction from `ospfInterfaceConfiguration()` (hello/dead) and `namedStructures()` (BGP keepalive/hold).

**Pass condition:** FF-1.1.01 (BGP FSM), FF-1.1.02 (OSPF Neighbor FSM), and FF-1.9.01–FF-1.9.03 (timer arithmetic) all pass. Session management is the composite of these.

**Partial condition:** Any constituent element is Constrained.

**Fail condition:** Any constituent element is Rejected.

**Disposition:** Follows the most restrictive disposition among its constituents.

---

### FF-1.4.06: Protocol Capability Negotiation

**Stage 1 trace:** §1.4, table row 7. BGP OPEN capabilities, OSPF options bits, BFD parameter negotiation.

**Extraction method:** `bf.q.bgpPeerConfiguration()` returns address families, which implies capability advertisement. `bf.q.bgpSessionCompatibility()` reports capability mismatches as diagnostic reasons. OSPF options bits are implicit in area type configuration.

**Pass condition:** `bgpSessionCompatibility()` correctly identifies capability mismatches (e.g., MP-BGP AFI/SAFI mismatch, 4-byte ASN mismatch) as NOT_COMPATIBLE with diagnostic reason.

**Partial condition:** Basic capability detection works (address families, ASN size) but extended capabilities (ADD-PATH, LLGR, enhanced route refresh) are not reported in compatibility diagnostics.

**Fail condition:** `bgpSessionCompatibility()` does not detect known capability mismatches.

**Disposition:**
- Confirmed: Capability negotiation enters verified set. FRR exercises full BGP capability negotiation.
- Constrained: Enters with constraint "extended capability validation limited to core AFs."
- Rejected: Capability detection failure. Session compatibility is unreliable.

---

## Section E: Full Fidelity — Failover and Convergence Logic (Stage 1 §1.5)

### FF-1.5.01: BFD-Triggered Failover Chain

**Stage 1 trace:** §1.5, table row 1. BFD detects → notifies client → client withdraws/recomputes → Zebra updates FIB. Correct causal ordering.

**Extraction method:** BFD configuration extraction per FF-1.1.04. The causal chain itself is exercised by FRR at runtime, not by Batfish. Batfish's contribution is validating that BFD is correctly bound to the right protocol peers.

**Pass condition:** FF-1.1.04 (BFD FSM) passes at Confirmed or Constrained level, AND the BFD-to-protocol binding is extractable (which protocol peer has BFD enabled).

**Partial condition:** BFD enablement is extractable but binding details (which specific BGP/OSPF peer) are ambiguous.

**Fail condition:** FF-1.1.04 is Rejected.

**Disposition:**
- Confirmed: BFD failover chain enters verified set. FRR bfdd + Zebra + bgpd/ospfd exercise the full chain.
- Constrained: Enters with constraint "BFD binding ambiguous — failover chain exercised but binding accuracy unverified."
- Rejected: BFD unextractable. Failover timing degrades to protocol hold timers.

---

### FF-1.5.02: Convergence Sequencing (Causal Ordering)

**Stage 1 trace:** §1.5, table row 2. Which routes withdraw first, which backup paths activate in which order. Causal ordering invariant; absolute timing is not.

**Extraction method:** Batfish's `bf.q.differentialReachability()` on forked snapshots (with nodes/interfaces deactivated) shows which flows are affected by a failure. `bf.q.traceroute()` on baseline and forked snapshots shows path changes. The *sequencing* is exercised by FRR at runtime.

**Pass condition:** (a) `bf.fork_snapshot()` with a deactivated interface produces a modified topology; (b) `differentialReachability()` returns non-empty results identifying affected flows; (c) `traceroute()` on the forked snapshot shows alternate paths. These confirm that Batfish can model failure impact, enabling pre-computation of expected convergence outcomes.

**Partial condition:** `fork_snapshot()` works but `differentialReachability()` returns overly broad results (haystack problem) or misses subtle path changes.

**Fail condition:** `fork_snapshot()` fails to produce a modified topology, OR differential analysis produces no results.

**Disposition:**
- Confirmed: Convergence sequencing enters verified set for causal ordering. Absolute timing is explicitly excluded (addressed by Mirror Box Tier 2).
- Constrained: Enters with constraint "differential analysis produces approximate failure impact — FRR runtime is ground truth for precise convergence sequence."
- Rejected: Failure analysis is non-functional in Batfish. Pipeline cannot predict failure impact.

---

### FF-1.5.03: Multi-Failure Blast Radius

**Stage 1 trace:** §1.5, table row 3. Given N simultaneous failures, which destinations lose reachability. Reconverged topology.

**Extraction method:** Iterated `bf.fork_snapshot()` with multiple deactivated nodes/interfaces. `differentialReachability()` on each combination. `traceroute()` for path verification post-failure.

**Pass condition:** For a set of ≥ 3 failure scenarios (single link, single node, dual link): `fork_snapshot()` + `differentialReachability()` produces results that identify the correct set of affected source-destination pairs.

**Partial condition:** Single-failure analysis works but multi-failure (2+ simultaneous) analysis produces incomplete or incorrect results.

**Fail condition:** `fork_snapshot()` does not support multiple simultaneous deactivations.

**Disposition:**
- Confirmed: Multi-failure blast radius enters verified set for the reconverged topology (not timing).
- Constrained: Enters with constraint "multi-failure analysis limited to N≤[X] simultaneous failures." N is determined empirically during execution.
- Rejected: Multi-failure analysis non-functional. Single-failure analysis only. Significant capability limitation.

---

### FF-1.5.04: Next-Hop Tracking

**Stage 1 trace:** §1.5, table row 4. Recursive resolution, reachability monitoring via IGP, next-hop-self, resolution failure propagation.

**Extraction method:** `bf.q.routes()` shows BGP routes with resolved next-hops. If a BGP next-hop is not resolvable via IGP, the BGP route will not appear in the FIB — Batfish models this. `bgpRib()` shows next-hop per path. Cross-reference with `routes(protocols="ospf")` for IGP reachability of BGP next-hops.

**Pass condition:** For every BGP route in `bgpRib()`, the next-hop IP appears as a reachable prefix in `routes()` via an IGP or connected route. BGP routes with unresolvable next-hops are correctly absent from the FIB.

**Partial condition:** BGP routes appear in `bgpRib()` but next-hop resolution status is not explicitly reported (must be inferred from presence/absence in FIB).

**Fail condition:** BGP routes with resolvable next-hops are absent from the FIB, OR routes with unresolvable next-hops appear in the FIB.

**Disposition:**
- Confirmed: NHT enters verified set. FRR Zebra NHT operates identically.
- Constrained: Enters with constraint "NHT inferred from RIB/FIB comparison, not explicitly reported."
- Rejected: NHT logic error in Batfish data-plane computation. Escalate.

---

### FF-1.5.05: Graceful Restart Behavior

**Stage 1 trace:** §1.5, table row 5. Stale route marking, EOR processing, restart timer behavior, helper mode.

**Extraction method:** Same as FF-1.1.09 for configuration extraction. Runtime GR behavior is exercised by FRR, not Batfish.

**Pass condition:** FF-1.1.09 passes.

**Partial condition:** FF-1.1.09 is Constrained.

**Fail condition:** FF-1.1.09 is Rejected.

**Disposition:** Follows FF-1.1.09.

---

## Section F: Full Fidelity — Structural Graph Properties (Stage 1 §1.6)

### FF-1.6.01: ECMP Path Count

**Stage 1 trace:** §1.6, table row 1. Number of equal-cost paths between any two nodes.

**Extraction method:** `bf.q.traceroute()` with `maxTraces` parameter shows all ECMP paths. `bf.q.routes()` shows multipath entries. `bf.q.bgpProcessConfiguration()` shows `Multipath_EBGP` and `Multipath_IBGP` (max-paths config).

**Pass condition:** `traceroute()` returns multiple traces for a source-destination pair where ECMP exists, AND the trace count matches the expected ECMP width based on topology and max-paths configuration.

**Partial condition:** `traceroute()` returns multiple traces but the count does not exactly match expected (Batfish may not enumerate all ECMP paths for very wide ECMP).

**Fail condition:** `traceroute()` returns only a single trace where ECMP should exist.

**Disposition:**
- Confirmed: ECMP path count enters verified set. Compression engine uses this for path-count preservation validation.
- Constrained: Enters with constraint "ECMP width approximate for >N paths." N determined empirically.
- Rejected: ECMP analysis failure. Path preservation validation is unreliable.

---

### FF-1.6.02 through FF-1.6.06: Bisection Bandwidth Ratio, Hop Count, k-Connectivity, Diameter, Symmetry

**Stage 1 trace:** §1.6, table rows 2-6. Graph-theoretic properties.

**Extraction method:** `bf.q.layer3Edges()` returns the full L3 adjacency graph. These properties are computed from the graph, not extracted from device config. The computation is performed by the compression engine using the extracted topology, not by Batfish directly.

**Pass condition:** `layer3Edges()` returns a connected graph with edge count consistent with the number of interfaces and subnets. For each property: the value is computable from the graph using standard graph algorithms.

**Partial condition:** `layer3Edges()` returns a graph but with disconnected components (missing edges due to incomplete extraction or L2-only segments not visible at L3).

**Fail condition:** `layer3Edges()` returns `∅` or a trivially small graph (|V| < 3).

**Disposition (all five properties):**
- Confirmed: Graph property enters verified set. Computed from extracted topology.
- Constrained: Enters with constraint "graph has [N] disconnected components — properties computed per component."
- Rejected: Topology extraction failure. Compression engine cannot operate.

---

## Section G: Full Fidelity — Configuration Validation (Stage 1 §1.7)

### FF-1.7.01: CLI/API Configuration Parsing

**Stage 1 trace:** §1.7, table row 1. FRR exercises the same parsing within the same implementation.

**Extraction method:** `bf.q.fileParseStatus()` returns per-file parse status (PASSED, PARTIALLY_UNRECOGNIZED, FAILED). `bf.q.parseWarning()` returns specific parse warnings.

**Pass condition:** ≥ 95% of device config files show `PASSED` status in `fileParseStatus()`. Remaining files show `PARTIALLY_UNRECOGNIZED` with identified unrecognized lines that do not affect routing/forwarding (e.g., banner, logging, AAA details).

**Partial condition:** 80-95% of files show `PASSED`. `PARTIALLY_UNRECOGNIZED` files have unrecognized lines that *may* affect routing (e.g., route-map clauses, ACL entries in unrecognized syntax).

**Fail condition:** < 80% of files show `PASSED`, OR any file shows `FAILED`.

**Disposition:**
- Confirmed: Config parsing enters verified set. FRR parses its own config format natively.
- Constrained: Enters with constraint "N devices have partially-unrecognized config — these devices enter singleton equivalence classes." Per-device extraction completeness report generated.
- Rejected: Parse failure rate exceeds threshold. Snapshot is unsuitable for automated processing. Manual remediation required.

---

### FF-1.7.02: Reference Integrity

**Stage 1 trace:** §1.7, table row 2. Commit validation, reference integrity.

**Extraction method:** `bf.q.undefinedReferences()` returns all undefined references (route-maps, prefix-lists, ACLs, community-lists referenced in config but not defined). `bf.q.unusedStructures()` returns defined-but-never-referenced structures.

**Pass condition:** `undefinedReferences()` is run and produces a DataFrame. Results are categorized by severity: references in routing-critical contexts (BGP neighbor route-map, OSPF distribute-list) are flagged vs references in non-critical contexts (logging, SNMP).

**Partial condition:** `undefinedReferences()` produces results but includes false positives (structures that appear undefined due to vendor-specific naming conventions that Batfish doesn't resolve).

**Fail condition:** `undefinedReferences()` throws an error or returns structurally invalid output.

**Disposition:**
- Confirmed: Reference integrity enters verified set. Undefined references are detected and reported.
- Constrained: Enters with constraint "false positive rate: ~N%. Critical undefined references (routing-context) are manually verified."
- Rejected: Reference integrity checking non-functional. Escalate.

---

### FF-1.7.03: VRF Isolation and Route Leaking Configuration

**Stage 1 trace:** §1.7, table row 5. Logical operation on data structures.

**Extraction method:** `bf.q.nodeProperties()` returns VRF names. `bf.q.routes()` accepts `vrfs` parameter to query per-VRF RIBs. `namedStructures()` for VRF definitions and route-leaking config (`import vrf`, `rd`, `rt`).

**Pass condition:** (a) `nodeProperties()` returns all VRF names for multi-VRF devices; (b) `routes(vrfs="X")` returns VRF-specific routes; (c) route leaking between VRFs (if configured) is reflected in routes appearing in destination VRF.

**Partial condition:** VRFs are enumerated but per-VRF route separation is not verifiable (all VRF routes merge in output).

**Fail condition:** VRF names are absent from `nodeProperties()` on multi-VRF devices.

**Disposition:**
- Confirmed: VRF isolation enters verified set. FRR supports Linux VRF natively.
- Constrained: Enters with constraint "per-VRF route isolation unverifiable in Batfish — FRR enforces VRF separation at runtime."
- Rejected: VRF extraction failure. Multi-tenant topologies cannot be correctly modeled.

---

## Section H: Full Fidelity — Infrastructure Service Logic (Stage 1 §1.8)

### FF-1.8.01 through FF-1.8.06: DNS, DHCP Relay, NTP, SNMP, Syslog, AAA

**Stage 1 trace:** §1.8, table rows 1-6. Application-layer logic, per-transaction.

**Extraction method:** `bf.q.nodeProperties()` returns DNS servers, NTP servers, TACACS servers, SNMP trap hosts, logging servers configured per device. DHCP relay: `namedStructures()` for `ip helper-address` or equivalent.

**Pass condition (per service):** `nodeProperties()` returns non-empty server IP lists for the configured service on devices where the service is configured in raw config.

**Partial condition:** Server IPs are extracted but the service configuration details (e.g., RADIUS shared secret, SNMP community strings, syslog severity level) are not fully parsed.

**Fail condition:** `nodeProperties()` returns empty/null for a service that is clearly configured in the raw config.

**Disposition (all six services):**
- Confirmed: Infrastructure service logic enters verified set for reachability validation (is the DNS server reachable from the device?). FRR VM runs equivalent Linux services.
- Constrained: Enters with constraint "service configuration details beyond server IP are unextracted." Reachability-only validation.
- Rejected: Service configuration invisible. Service reachability validation not possible for this service.

---

## Section I: Full Fidelity — Timer Arithmetic (Stage 1 §1.9)

### FF-1.9.01: BFD Detection Time Formula

**Stage 1 trace:** §1.9, table row 1. `Remote.DetectMult × max(Local.RequiredMinRxInterval, Remote.DesiredMinTxInterval)` per RFC 5880 §6.8.4.

**Extraction method:** BFD interval and multiplier extraction per FF-1.1.04. The arithmetic is local computation, not Batfish extraction.

**Pass condition:** FF-1.1.04 passes at Confirmed level (BFD enablement and timers extractable). Detection time formula is a deterministic calculation from extracted values. Under uniform 10x dilation, the detection time scales linearly — the formula's *result* is dilated but the *relationship* to other timers is preserved.

**Partial condition:** FF-1.1.04 is Constrained (BFD enablement extractable, timers defaulted). Detection time computed with FRR default values. Dashboard shows both the dilated emulation value and the reverse-mapped production-equivalent value, labeled as "FRR default — not production-extracted."

**Fail condition:** FF-1.1.04 is Rejected.

**Disposition:** Follows FF-1.1.04. Dilation is transparent to this predicate — scalar multiplication preserves the formula's arithmetic.

---

### FF-1.9.02: OSPF Dead Interval

**Stage 1 trace:** §1.9, table row 2. RouterDeadInterval (convention: 4 × HelloInterval).

**Extraction method:** `bf.q.ospfInterfaceConfiguration()` returns `Hello_Interval` and `Dead_Interval` as fixed output columns.

**Pass condition:** `ospfInterfaceConfiguration()` returns numeric `Hello_Interval` and `Dead_Interval` for all OSPF-enabled interfaces. Values are consistent (Dead_Interval ≥ Hello_Interval).

**Partial condition:** Values are present but some interfaces show default values where the raw config does not explicitly set them. **Emulation impact: none.** Both hello and dead intervals are uniformly dilated. The 4:1 dead-to-hello ratio (or whatever ratio is configured) is preserved under scalar multiplication. Dashboard shows both dilated and production-equivalent values; defaulted timers are labeled as such.

**Fail condition:** `Hello_Interval` or `Dead_Interval` is null for OSPF-enabled interfaces.

**Disposition:**
- Confirmed: OSPF dead interval enters verified set. These are Batfish-native (●) fields with high confidence. Dilation preserves the dead/hello ratio.
- Constrained: Enters with constraint "timer values are Batfish-extracted defaults, not vendor defaults, for interfaces without explicit timer config. Dashboard labels as approximated. Emulation correctness unaffected — dilation preserves ratio. Customer SLA documentation specifies config format for explicit timer extraction."
- Rejected: OSPF timer extraction failure. Adjacency formation logic is unaffected (timers default in FRR), but production-equivalent dashboard values are unavailable.

---

### FF-1.9.03: BGP Hold Time Negotiation

**Stage 1 trace:** §1.9, table row 3. Negotiated minimum of both peers' advertised hold time.

**Extraction method:** `bgpPeerConfiguration()` does **not** expose timer fields (per Compression Engine documentation). BGP keepalive and hold timers extracted from `namedStructures()` or raw config parsing.

**Pass condition:** `namedStructures()` returns BGP timer configuration (keepalive, hold) for BGP-speaking devices. For explicitly-configured timers, the values are numeric and consistent (hold ≥ 3 × keepalive or hold = 0 for negotiation-disable).

**Partial condition:** Timer values are extractable for some vendors but not others. Vendors without extractable timers use FRR's defaults (60/180 traditional, 3/9 datacenter). **Emulation impact: none.** Both keepalive and hold timers are uniformly dilated. The hold/keepalive ratio and the hold-timer-to-BFD-detection-time ratio are preserved. Dashboard shows both dilated and reverse-mapped production-equivalent values; defaulted timers are labeled as "FRR default." Customer SLA documentation specifies config format for explicit extraction.

**Fail condition:** BGP timer configuration is invisible to Batfish across all vendor platforms. FRR defaults are used universally. Dashboard labels all BGP timer values as "FRR default — not production-extracted."

**Disposition:**
- Confirmed: BGP hold time enters verified set. Extracted values are used in FRR config, dilated for emulation, reverse-mapped for dashboard.
- Constrained: Enters with constraint "BGP timers not extractable for [vendor] — FRR uses [traditional|datacenter] defaults. Dashboard labels as approximated. Emulation correctness unaffected — dilation preserves all timer relationships." This is a customer data-quality issue per SLA documentation, not a product fidelity risk.
- Rejected: N/A under the revised model. Even with universal FRR defaults, the emulation runs correctly (dilation preserves ordering). The only impact is dashboard labeling — all BGP timers show as approximated. This is a severity-low reporting issue, not an emulation failure.

---

## Section J: Vendor Divergence (Stage 1 Layer 2.1)

### VD-2.1.01: Default Timer Values

**Stage 1 trace:** Layer 2.1, table row 1. IN SET, DEGRADED.

**Extraction method:** Cross-reference `ospfInterfaceConfiguration()` timer values and `namedStructures()` BGP timer values against raw config to determine if each timer is explicitly configured or defaulted. A timer is "defaulted" if the raw config contains no explicit `timers` command for that protocol peer/interface.

**Architectural context:** All timers — BGP keepalive/hold, OSPF hello/dead, BFD interval/multiplier, GR restart/stalepath, SPF throttle — are uniformly dilated 10x in emulation. Dilation preserves all ratios and causal ordering (scalar multiplication on an ordered set preserves order). The telemetry layer reverse-maps dilated timers to production-equivalent values for the dashboard, showing both the actual (dilated) and adjusted (production-equivalent) metrics. The dashboard labels every timer as either "production-extracted" (explicit in config) or "FRR default" (not in config). The SLA and product documentation specify config format requirements for explicit timer extraction and enumerate what is acceptable.

**Pass condition:** For every timer-bearing protocol configuration (BGP peers, OSPF interfaces, BFD sessions, GR config): the extraction can determine whether the timer is explicitly configured or vendor-defaulted. This is a binary classification question, not a value-extraction question.

**Partial condition:** The explicit/default classification is determinable for major vendors (Cisco, Juniper, Arista) but ambiguous for secondary vendors (Fortinet, Check Point) where Batfish parsing depth is lower.

**Fail condition:** The extraction cannot distinguish explicit from defaulted timers on any vendor platform.

**Disposition:**
- Confirmed: Every timer is classifiable as explicit or defaulted. Explicit timers enter verified set at full fidelity (extracted, dilated, reverse-mapped, labeled "production-extracted"). Defaulted timers enter verified set with FRR default values (dilated, reverse-mapped, labeled "FRR default"). **Emulation correctness is unaffected in both cases** — dilation preserves all timer relationships. The only impact of defaulted timers is dashboard labeling accuracy, which is a customer data-quality issue bounded by SLA documentation.
- Constrained: Classification is ambiguous for secondary vendors. Enters with constraint "timer explicit/default classification unavailable for [vendor] — all timers labeled as 'unverified source' on dashboard."
- Rejected: N/A under the revised model. Timer extraction cannot cause a Rejected outcome because FRR defaults are always available as a fallback, emulation correctness is dilation-protected, and the dashboard makes the approximation visible. The worst case is every timer labeled "FRR default" — a reporting issue, not a behavioral one.

---

### VD-2.1.02: Parser Behavior Edge Cases

**Stage 1 trace:** Layer 2.1, table row 2. IN SET, FLAGGED.

**Extraction method:** `bf.q.fileParseStatus()` and `bf.q.parseWarning()` identify lines that Batfish could not fully parse.

**Pass condition:** `parseWarning()` returns zero warnings for routing-critical configuration sections (route-maps, BGP neighbor config, OSPF interface config, ACLs).

**Partial condition:** `parseWarning()` returns warnings but they are limited to non-routing-critical sections (banners, logging, NTP, SNMP, AAA).

**Fail condition:** `parseWarning()` returns warnings in routing-critical sections.

**Disposition:**
- Confirmed: Parser behavior for this device/vendor has no edge cases.
- Constrained: Enters with constraint "parse warnings in non-critical sections — routing behavior unaffected." Device remains in normal equivalence class processing.
- Rejected: Parse warnings in routing-critical sections. Device enters singleton equivalence class. Manual review required.

---

### VD-2.1.03: Best-Path Tiebreaking Extensions

**Stage 1 trace:** Layer 2.1, table row 3. IN SET.

**Extraction method:** `bf.q.bgpProcessConfiguration()` for `deterministic-med`, `always-compare-med`, `bestpath-compare-routerid` flags. `namedStructures()` for additional best-path tuning options.

**Pass condition:** `bgpProcessConfiguration()` returns the best-path modification flags, AND these flags are consistent with the raw config.

**Partial condition:** Some flags are extractable but vendor-specific extensions (e.g., Arista's `bgp bestpath ecmp-fast`) are not in Batfish's vocabulary.

**Fail condition:** Best-path flags are not extractable.

**Disposition:**
- Confirmed: Tiebreaking configuration enters verified set. FRR supports `deterministic-med`, `always-compare-med`, and `compare-routerid`.
- Constrained: Enters with constraint "vendor-specific tiebreaking extension [X] not extracted — FRR uses RFC-standard tiebreaking beyond this point."
- Rejected: Best-path configuration extraction failure.

---

### VD-2.1.04: OSPF Implementation Quirks

**Stage 1 trace:** Layer 2.1, table row 4. IN SET, TIMING DEGRADED. DR election timing, SPF scheduling differ.

**Extraction method:** OSPF configuration extracted per FF-1.1.02 and FF-1.1.03. SPF throttle timers from `namedStructures()` (`timers throttle spf`).

**Pass condition:** OSPF topology and routing correctness verified per FF-1.2.02. SPF throttle timer values are extractable from `namedStructures()`.

**Partial condition:** SPF correctness is verified but SPF timing (throttle parameters) is not extractable.

**Fail condition:** OSPF extraction fails per FF-1.1.02.

**Disposition:**
- Confirmed: OSPF routing correctness enters verified set. SPF throttle timers, if extracted, are dilated uniformly with all other timers — the throttle-to-hello ratio and throttle-to-dead ratio are preserved.
- Constrained: Enters with constraint "SPF throttle timing not extracted — FRR uses default SPF timers, dilated uniformly. Dashboard labels SPF timing as 'FRR default.' Emulation correctness unaffected — dilation preserves ordering."
- Rejected: Follows FF-1.1.02.

---

### VD-2.1.05: BGP Attribute Handling Edge Cases

**Stage 1 trace:** Layer 2.1, table row 5. IN SET, FLAGGED.

**Extraction method:** `bf.q.bgpProcessConfiguration()` for `always-compare-med`, `deterministic-med`. `bf.q.testRoutePolicies()` for per-route attribute verification. `bf.q.bgpRib()` for actual attribute values.

**Pass condition:** `bgpRib()` shows consistent attribute handling with `testRoutePolicies()` cross-validation on a sample of routes.

**Partial condition:** Attributes are present but vendor-specific edge cases (e.g., MED comparison for routes from different ASes) cannot be validated without production traffic.

**Fail condition:** Attribute inconsistencies between `bgpRib()` and `testRoutePolicies()`.

**Disposition:**
- Confirmed: BGP attribute handling enters verified set.
- Constrained: Enters with constraint "MED cross-AS comparison behavior follows FRR's implementation (configurable via `bgp always-compare-med`)."
- Rejected: Attribute handling inconsistency. Batfish data-plane bug. Escalate.

---

### VD-2.1.06: Graceful Restart Implementation Completeness

**Stage 1 trace:** Layer 2.1, table row 6. IN SET, DEGRADED.

**Extraction method:** Same as FF-1.1.09.

**Pass condition:** Same as FF-1.1.09.

**Partial condition:** Same as FF-1.1.09.

**Fail condition:** Same as FF-1.1.09.

**Disposition:** Same as FF-1.1.09, with additional note: "vendor-specific GR edge cases (notification handling during restart, partial GR) follow FRR's implementation, which may differ from the production vendor in corner cases."

---

## Section K: Proprietary Mappings (Stage 1 Layer 2.3)

### PM-2.3.01: vPC/MLAG → EVPN Multihoming Mapping

**Stage 1 trace:** Layer 2.3, table row 2. Medium fidelity — functional dual-homing preserved. Proprietary peer-link, orphan ports, consistency checks lost.

**Extraction method:** `bf.q.mlagProperties()` returns MLAG configuration (peer-link, peer-IP, system-MAC). vPC configuration extracted from `namedStructures()`. The mapping to EVPN MH (ESI-LAG) is a pipeline translation, not a Batfish extraction.

**Pass condition:** `mlagProperties()` returns non-empty results for devices configured with MLAG/vPC, AND the MLAG peer relationship is identifiable (peer-link interface, peer IP).

**Partial condition:** MLAG/vPC is detectable from config parsing but `mlagProperties()` returns incomplete data (e.g., system-MAC missing).

**Fail condition:** MLAG/vPC configuration is not detected by Batfish.

**Disposition:**
- Confirmed: MLAG/vPC configuration is extractable and mappable to EVPN MH in the pipeline.
- Constrained: Enters with constraint "MLAG/vPC detected but mapping to EVPN MH is functional only — proprietary peer-link behavior, orphan port handling, and vPC consistency checks are not modeled. Convergence diagnostic: 'MLAG→EVPN MH: functional mapping, proprietary behaviors excluded.'"
- Rejected: MLAG/vPC configuration invisible. Dual-homing topology cannot be determined from extraction. Reclassified as supplemental data requirement.

---

## Section L: Topology Edge Cases (Stage 1 Layer 3.3)

### TE-3.3.01: IGP Cost Asymmetry Within Equivalence Class

**Stage 1 trace:** Layer 3.3, table row 1. IN SET, FLAGGED. Compression Engine Gap 4.

**Extraction method:** `bf.q.routes()` returns OSPF routes with metrics. Compare metric to the same destination across all devices in a proposed equivalence class. `bf.q.ospfInterfaceConfiguration()` returns per-interface costs.

**Pass condition:** For every proposed equivalence class, `routes(protocols="ospf")` returns the same metric to the same BGP next-hop from every member of the class. No IGP cost asymmetry exists.

**Partial condition:** IGP cost asymmetry is detected (different metrics from different class members). The Cathedral can compute the delta and flag it.

**Fail condition:** IGP cost computation is non-functional (FF-1.2.02 Rejected).

**Disposition:**
- Confirmed: No IGP cost asymmetry — equivalence class is valid.
- Constrained: Enters with constraint "IGP cost asymmetry detected in equivalence class [X]: member [A] has metric [M1], member [B] has metric [M2] to next-hop [NH]. Gap 4 flag raised. Cathedral applies IGP cost correction."
- Rejected: Follows FF-1.2.02.

---

### TE-3.3.02: DR/BDR Election on Broadcast Segments

**Stage 1 trace:** Layer 3.3, table row 2. IN SET. DR election is well-defined; inputs are topology-derived.

**Extraction method:** `bf.q.ospfInterfaceConfiguration()` returns `Network_Type` (BROADCAST indicates DR election applies). DR priority extractable from `namedStructures()`. Batfish computes DR/BDR election in its OSPF model.

**Pass condition:** For every broadcast OSPF segment: interfaces show `Network_Type=BROADCAST` and DR priority is extractable. `ospfEdges()` reflects the DR-based adjacency model.

**Partial condition:** Network type is extractable but DR priority values are not (Batfish default DR priority applies).

**Fail condition:** N/A — follows FF-1.1.03.

**Disposition:**
- Confirmed: DR election enters verified set. FRR exercises the identical election algorithm.
- Constrained: Enters with constraint "DR priority values not extracted — FRR uses default priority (1). Production DR election may differ if non-default priorities are configured."

---

### TE-3.3.03: Route Reflector Topology Sensitivity

**Stage 1 trace:** Layer 3.3, table row 3. IN SET. RR behavior is fully modeled.

**Extraction method:** `bf.q.bgpPeerConfiguration()` returns `Route_Reflector_Client` boolean. `bf.q.bgpProcessConfiguration()` returns cluster-ID.

**Pass condition:** `bgpPeerConfiguration()` correctly identifies RR-client relationships, AND `bgpProcessConfiguration()` returns cluster-ID on RR nodes. RR nodes are identifiable in the topology.

**Partial condition:** RR-client status is identified but cluster-ID is not extractable.

**Fail condition:** RR-client relationships are not detected.

**Disposition:**
- Confirmed: RR topology enters verified set. Compression engine preserves RR nodes (cannot merge RR with non-RR).
- Constrained: Enters with constraint "cluster-ID not extracted — FRR auto-generates." Minimal impact for single-RR topologies; may affect multi-RR-cluster environments.
- Rejected: RR topology is invisible. iBGP topology cannot be correctly modeled. Critical for OSPF+iBGP EVPN stack.

---

### TE-3.3.04 through TE-3.3.07: Anycast Gateway, Asymmetric ECMP, Stub/NSSA, VRF Leaking

**Stage 1 trace:** Layer 3.3, table rows 4-7. All IN SET at full fidelity.

**Extraction method:** These are composite properties derived from previously-defined extractions: anycast gateway from `interfaceProperties()` (same IP on multiple leaves), ECMP from `traceroute()`, stub/NSSA from `ospfAreaConfiguration()`, VRF leaking from `namedStructures()` + `routes()`.

**Pass condition:** The constituent extractions (FF-1.3.09, FF-1.6.01, FF-1.1.03, FF-1.7.03) all pass.

**Partial condition:** Any constituent is Constrained.

**Fail condition:** Any constituent is Rejected.

**Disposition:** Follows the most restrictive constituent disposition.

---

### TE-3.3.08: STP Root Bridge Placement

**Stage 1 trace:** Layer 3.3, table row 8. IN SET, SEVERELY DEGRADED.

**Extraction method:** Same as FF-1.1.05. STP root bridge priority is extractable from `namedStructures(structType="Spanning_Tree")`.

**Pass condition:** Same impossibility as FF-1.1.05 — Batfish does not compute STP topology.

**Partial condition:** STP priority is extractable. For EVPN-VXLAN target topology, STP is access-port-only (no fabric trunk STP).

**Fail condition:** Legacy L2 topology without supplemental STP state data.

**Disposition:** Same as FF-1.1.05.

---

## Section M: Protocol Interaction Edge Cases (Stage 1 Layer 4.2)

### PI-4.2.01: IGP-BGP Next-Hop Resolution Race

**Stage 1 trace:** Layer 4.2, table row 1. IN SET. FRR Zebra handles natively.

**Extraction method:** Validated by FF-1.5.04 (NHT) and CV-4.5.01 (BGP next-hop resolves via IGP). No additional extraction needed — this is a runtime interaction exercised by FRR.

**Pass condition:** FF-1.5.04 and CV-4.5.01 both pass.

**Partial condition:** Either is Constrained.

**Fail condition:** Either is Rejected.

**Disposition:** Follows the most restrictive constituent.

---

### PI-4.2.02: BFD-BGP-OSPF Detection Hierarchy

**Stage 1 trace:** Layer 4.2, table row 2. IN SET. FRR bfdd correctly notifies only the bound protocol.

**Extraction method:** BFD binding extraction per FF-1.1.04. Protocol-specific timer extraction per FF-1.9.01-03.

**Pass condition:** BFD bindings are extractable per-protocol (which peers have BFD enabled), AND protocol timers are extractable for comparison (BFD detection time < protocol hold timer). Under uniform dilation, the detection hierarchy ordering (BFD fastest → OSPF intermediate → BGP slowest) is preserved regardless of whether timer values are production-extracted or FRR-defaulted.

**Partial condition:** BFD bindings are extractable but timer values are FRR defaults. The hierarchy ordering is still valid because FRR's default timer ratios (BFD 300ms×3=900ms detection < OSPF 40s dead < BGP 180s hold) preserve the same ordering as production defaults. Dashboard labels timer source.

**Fail condition:** BFD bindings not extractable — the product cannot determine which peers participate in BFD-accelerated failover.

**Disposition:**
- Confirmed: Detection hierarchy enters verified set. FRR exercises the full hierarchy. Dilation preserves ordering.
- Constrained: Enters with constraint "detection hierarchy validated using FRR default timer ratios. Production timer values not extracted. Emulation hierarchy ordering is correct; dashboard labels timer source."
- Rejected: BFD enablement extraction failure. Hierarchy is unknown — failover behavior cannot be predicted.

---

### PI-4.2.03: EVPN Type-2/Type-5 Route Interaction

**Stage 1 trace:** Layer 4.2, table row 3. IN SET.

**Extraction method:** `bf.q.evpnRib()` shows both Type-2 and Type-5 routes. Longest-prefix-match behavior visible in `bf.q.lpmRoutes()`.

**Pass condition:** `evpnRib()` shows both Type-2 (/32 host) and Type-5 (prefix) routes for the same destination. `lpmRoutes()` correctly selects the more-specific Type-2 route.

**Partial condition:** Both route types appear in `evpnRib()` but LPM selection is not independently verifiable.

**Fail condition:** FF-1.4.03 is Rejected.

**Disposition:** Follows FF-1.4.03.

---

### PI-4.2.04 through PI-4.2.07: VRF RT Interaction, Redistribution Loops, GR+BFD Conflict, ECMP+Route-Map

**Stage 1 trace:** Layer 4.2, table rows 4-7. All IN SET.

**Extraction method:** These are runtime interaction behaviors exercised by FRR. Batfish contribution is pre-validating the configuration that enables the interaction (VRF RT config, redistribution config, GR+BFD config, ECMP+route-map config).

**Pass condition:** The constituent configuration extractions pass (FF-1.3.09 for RT, FF-1.3.06 for redistribution, FF-1.1.09+FF-1.1.04 for GR+BFD, FF-1.6.01+FF-1.3.01 for ECMP+route-map).

**Partial condition:** Constituent configs are Constrained.

**Fail condition:** Constituent configs are Rejected.

**Disposition:** Follows the most restrictive constituent.

---

## Section N: Legacy Environment Edge Cases (Stage 1 Layer 4.4)

### LE-4.4.01: L2-Heavy Networks with STP

**Stage 1 trace:** Layer 4.4, table row 1. IN SET, SEVERELY DEGRADED.

**Extraction method:** Same as FF-1.1.05 / TE-3.3.08.

**Pass/Partial/Fail conditions:** Same as FF-1.1.05.

**Disposition:** Same as FF-1.1.05. Convergence diagnostic: "L2-heavy topology detected. STP forwarding state unmodeled. Active topology unknown without supplemental data."

---

### LE-4.4.02: Mixed L2/L3 Boundary

**Stage 1 trace:** Layer 4.4, table row 2. L3 behavior fully modeled; L2 component DEGRADED.

**Extraction method:** `bf.q.interfaceProperties()` returns SVI interfaces (VLAN interfaces with IP addresses). L3 routing on SVIs is fully modeled. L2 forwarding on the VLAN trunk beneath the SVI follows STP constraints (FF-1.1.05).

**Pass condition:** `interfaceProperties()` correctly identifies SVI interfaces with IP addresses, VLANs, and L3 routing participation.

**Partial condition:** SVIs are detected but underlying VLAN trunk topology (which physical interfaces carry which VLANs) is partially extracted.

**Fail condition:** SVIs are not detected as L3 interfaces.

**Disposition:**
- Confirmed: L3 routing on SVIs enters verified set at full fidelity.
- Constrained: Enters with constraint "L2 component (VLAN trunking, STP below the SVI) is degraded per FF-1.1.05." Combined constraint documented.
- Rejected: SVI detection failure.

---

### LE-4.4.03: NAT at Enterprise Edge

**Stage 1 trace:** Layer 4.4, table row 3. IN SET, DEGRADED.

**Extraction method:** Batfish partially models NAT for Cisco IOS (per SIGCOMM 2023 paper — bidirectional reachability includes NAT transformations). `bf.q.reachability()` and `bf.q.traceroute()` output includes NAT steps on supported platforms. NAT configuration in `namedStructures()`.

**Pass condition:** For Cisco IOS devices with NAT: `traceroute()` shows NAT transformation steps, AND `reachability()` correctly accounts for NAT (pre-NAT and post-NAT addresses handled).

**Partial condition:** NAT config is parseable but `traceroute()`/`reachability()` do not show NAT steps (platform not fully supported for NAT modeling in Batfish).

**Fail condition:** NAT configuration is not parsed by Batfish.

**Disposition:**
- Confirmed: NAT reachability modeling enters verified set for Cisco IOS. Runtime NAT translation tables are NOT modeled (permanent gap).
- Constrained: Enters with constraint "NAT modeling limited to [Cisco IOS]. Other vendor NAT configurations parsed for config awareness but not modeled in reachability analysis. Runtime translation table state not emulated."
- Rejected: NAT configuration unparseable. NAT devices treated as opaque L3 hops.

---

### LE-4.4.04: Legacy Timer Configurations

**Stage 1 trace:** Layer 4.4, table row 4. IN SET — timers are config-extractable.

**Extraction method:** Per VD-2.1.01 and FF-1.9.01-03.

**Pass condition:** Explicitly-configured timers are extracted at their configured values.

**Partial condition:** VD-2.1.01 Constrained.

**Fail condition:** VD-2.1.01 Rejected.

**Disposition:** Follows VD-2.1.01.

---

### LE-4.4.05: Dual-Stack IPv4/IPv6

**Stage 1 trace:** Layer 4.4, table row 5. IN SET — full dual-stack support.

**Extraction method:** `bf.q.routes()` returns both IPv4 and IPv6 routes. `bf.q.interfaceProperties()` returns both IPv4 and IPv6 addresses. Batfish performs separate IPv4/IPv6 analysis.

**Pass condition:** `routes()` returns IPv6 routes on devices with IPv6 configured. `interfaceProperties()` shows IPv6 addresses. `traceroute()` supports IPv6 flows.

**Partial condition:** IPv4 extraction is complete but IPv6 extraction is partial (some IPv6-specific features like OSPFv3 not fully modeled).

**Fail condition:** IPv6 routes/addresses absent from extraction despite IPv6 configuration.

**Disposition:**
- Confirmed: Dual-stack enters verified set. FRR has full dual-stack support.
- Constrained: Enters with constraint "IPv6 extraction partial — [specific gap]."
- Rejected: IPv6 extraction failure.

---

### LE-4.4.06: Out-of-Band Management Networks

**Stage 1 trace:** Layer 4.4, table row 6. IN SET — management is isolated by design.

**Extraction method:** Management VRF detection via `nodeProperties()` VRF list. Management interfaces identified in `interfaceProperties()`.

**Pass condition:** Management VRF is identified and isolated from production VRFs. No route leaking between management and production.

**Partial condition:** Management VRF is identified but isolation cannot be verified (production routes appear in management VRF or vice versa — this is a customer config issue, not an extraction failure).

**Fail condition:** Management VRF not detected.

**Disposition:**
- Confirmed: OOB management enters verified set. Pipeline uses separate management bridge.
- Constrained: Enters with constraint "management/production VRF isolation not verified."
- Rejected: N/A — management isolation is a pipeline design property, not an extraction dependency.

---

### LE-4.4.07: Stateful Firewalls in Routing Path

**Stage 1 trace:** Layer 4.4, table row 7. IN SET, DEGRADED. Compression Engine Gap 5.

**Extraction method:** Firewall devices detected by Batfish role inference. ACL configuration extracted per FF-1.3.10. `bf.q.reachability()` and `traceroute()` model stateful session logic symbolically (SETUP_SESSION, MATCH_SESSION steps visible in output) for supported platforms.

**Pass condition:** (a) Firewall devices are identified in the topology; (b) ACLs/security policies are extracted; (c) `traceroute()` shows session setup/match steps for flows through the firewall.

**Partial condition:** ACLs extracted but stateful session modeling not functional for the firewall vendor (e.g., Fortinet, Check Point).

**Fail condition:** Firewall device config is unparseable.

**Disposition:**
- Confirmed: Stateful firewall ACL match logic enters verified set. Symbolic session analysis enters verified set for supported platforms (Cisco IOS, partial Arista, partial PAN-OS).
- Constrained: Enters with constraint "connection tracking dynamics not modeled. Runtime session table state not emulated. Asymmetric routing after failover may cause session drops in production that emulation cannot reproduce. Convergence diagnostic: N% of traffic paths traverse stateful devices."
- Rejected: Firewall config unparseable. Firewall treated as opaque L3 hop. Critical gap for security-policy-dependent topologies.

---

### LE-4.4.08: Load Balancers

**Stage 1 trace:** Layer 4.4, table row 8. IN SET, DEGRADED. Gap 5.

**Extraction method:** F5 BIG-IP configs are partially parsed by Batfish. `bf.q.f5BigipVipConfiguration()` returns VIP-to-pool-to-member mappings.

**Pass condition:** `f5BigipVipConfiguration()` returns VIP configurations with pool members and their IPs.

**Partial condition:** VIP config is extractable but pool member health check state, persistence profiles, and iRules are not modeled.

**Fail condition:** `f5BigipVipConfiguration()` returns `∅` for F5 devices, OR load balancer is non-F5 (Citrix, HAProxy, AWS ALB) and Batfish has no parser.

**Disposition:**
- Confirmed: F5 VIP/pool configuration enters verified set at config level.
- Constrained: Enters with constraint "runtime health check state, pool member up/down status, iRules, persistence profiles not modeled. All configured pool members treated as available. Convergence diagnostic: load balancer at [device] operates in config-only mode."
- Rejected: Load balancer config unparseable (non-F5 vendor). Load balancer modeled as structurally unique with opaque forwarding. Compression engine: singleton equivalence class.

---

## Section O: Cross-Validation Requirements (Stage 1 Layer 4.5)

### CV-4.5.01: BGP Next-Hop Resolves via IGP

**Stage 1 trace:** Layer 4.5, table row 1. Method: `bf.q.routes()`.

**Pass condition:** For every BGP route in `bgpRib()`: the route's next-hop IP is present as a destination in `routes()` via an IGP or connected protocol. Zero BGP routes have unresolvable next-hops (unless intentionally configured as unreachable for traffic engineering).

**Partial condition:** ≤ 5% of BGP routes have next-hops not found in the IGP RIB. These may be legitimate (routes to external peers with directly-connected next-hops) or may indicate extraction/topology gaps.

**Fail condition:** > 5% of BGP routes have unresolvable next-hops. Indicates topology extraction error or missing IGP configuration.

**Disposition:**
- Confirmed: BGP/IGP integration is correct. Overlay/underlay consistency validated.
- Constrained: Small number of unresolvable next-hops documented. Convergence diagnostic lists them.
- Rejected: Systematic next-hop resolution failure. Topology extraction is fundamentally incomplete. Pipeline halts.

---

### CV-4.5.02: EVPN VTEP Reachability via Underlay

**Stage 1 trace:** Layer 4.5, table row 2.

**Pass condition:** For every pair of VTEPs (identified by loopback IPs used as VXLAN source): `bf.q.traceroute()` from VTEP-A to VTEP-B succeeds with `ACCEPTED` disposition. All VTEP pairs are mutually reachable.

**Partial condition:** ≥ 95% of VTEP pairs are mutually reachable. Unreachable pairs are documented.

**Fail condition:** < 95% of VTEP pairs are reachable. Overlay fabric is broken.

**Disposition:**
- Confirmed: EVPN underlay connectivity validated.
- Constrained: Unreachable VTEP pairs documented. Convergence diagnostic: "VTEP [X] unreachable from [Y] — overlay traffic between these VTEPs will fail."
- Rejected: Systematic VTEP unreachability. Topology extraction is fundamentally broken for EVPN. Pipeline halts.

---

### CV-4.5.03: BFD Session Parameters Consistent with Bound Protocol

**Stage 1 trace:** Layer 4.5, table row 3.

**Architectural context:** Uniform 10x dilation preserves all timer inequalities. If BFD detection < protocol hold in production, then (BFD detection × 10) < (protocol hold × 10) in emulation. The cross-validation is order-preserving under scalar multiplication — it can be evaluated on either the production values or the dilated values with identical results.

**Pass condition:** For every BFD-enabled protocol peer: BFD detection time (computed per FF-1.9.01) < protocol hold timer (BGP hold or OSPF dead interval). This inequality holds on extracted values (production-equivalent) or on dilated values identically. If both timers are explicitly extracted, the comparison is exact. If one or both are FRR defaults, the comparison uses FRR defaults — which is valid because FRR defaults are what the emulation actually runs.

**Partial condition:** BFD enablement is extractable but one or both timer values are FRR defaults. The comparison is performed on FRR default values. Dashboard notes "BFD/protocol timer consistency validated using FRR defaults, not production values."

**Fail condition:** BFD detection time ≥ protocol hold timer (BFD adds no value — possible config error). This is a **production config finding worth reporting** regardless of timer source, because if the inequality fails on FRR defaults, it likely fails on production defaults too (FRR defaults are conservative).

**Disposition:**
- Confirmed: BFD/protocol timer consistency validated. Dilation preserves the inequality.
- Constrained: Consistency validated using FRR defaults — documented. Emulation behavior is correct regardless (FRR enforces whatever timers it runs).
- Rejected: Timer inconsistency detected. Convergence diagnostic: "BFD on [peer] has detection time [X]ms ≥ protocol hold timer [Y]ms — BFD provides no benefit. Possible misconfiguration. [Timer source: production-extracted | FRR default]."

---

### CV-4.5.04: Route-Map References Resolve

**Stage 1 trace:** Layer 4.5, table row 4.

**Pass condition:** `bf.q.undefinedReferences()` returns zero results for route-map references in BGP/OSPF contexts.

**Partial condition:** `undefinedReferences()` returns results, but they are limited to non-routing contexts (e.g., PBR, unused interfaces).

**Fail condition:** `undefinedReferences()` returns results in routing-critical contexts (BGP neighbor import/export, OSPF distribute-list).

**Disposition:**
- Confirmed: All route-map references resolve. Policy chain integrity validated.
- Constrained: Non-routing undefined references documented. Routing policies unaffected.
- Rejected: Undefined route-map in routing context. This is a *production config error* that the product exists to detect. Convergence diagnostic: "CRITICAL: route-map [name] referenced by BGP neighbor [peer] on [device] is undefined. Effective behavior: [vendor-specific — deny-all on some, permit-all on others]."

---

### CV-4.5.05: ACLs Applied to Interfaces Exist

**Stage 1 trace:** Layer 4.5, table row 5.

**Pass condition:** `bf.q.undefinedReferences()` returns zero results for ACL references on interfaces.

**Partial condition:** Undefined ACL references exist but only on non-forwarding interfaces (management, loopback).

**Fail condition:** Undefined ACL references on forwarding interfaces.

**Disposition:**
- Confirmed: All interface-applied ACLs are defined.
- Constrained: Non-forwarding undefined ACLs documented.
- Rejected: Undefined ACL on forwarding interface. Production config error. Convergence diagnostic: "CRITICAL: ACL [name] on interface [intf] of [device] is undefined. Vendor behavior: [drop-all|permit-all]."

---

## Section P: Deferred Elements (Stage 1 Layer 2.6)

For each deferred element, Stage 2 defines the *blocking predicate* — the specific extraction or execution gap that prevents inclusion in v1 — and the *unblocking condition* that would enable future inclusion.

### DEF-01: IS-IS

**Stage 1 trace:** Layer 2.6, table row 1. FRR: PROD (isisd). Batfish: ✅ `isisEdges`.

**Blocking predicate:** Strategic scope decision — IS-IS is excluded from v1 supported protocol stacks. NOT blocked by extraction or execution gaps.

**Unblocking condition:** v2 scope decision to include IS-IS. Both Batfish extraction (`isisEdges` is stable) and FRR execution (isisd is production-grade) are ready. No architectural changes needed.

---

### DEF-02: PIM/Multicast

**Stage 1 trace:** Layer 2.6, table row 2. FRR: PROD (pimd). Batfish: ❌ no PIM extraction.

**Blocking predicate:** Batfish does not model or extract PIM configuration. No `pimEdges` or equivalent question exists.

**Unblocking condition:** Batfish adds PIM extraction support, OR supplemental data path built to provide PIM config outside Batfish.

---

### DEF-03: MPLS/LDP

**Stage 1 trace:** Layer 2.6, table row 3. FRR: PROD (ldpd). Batfish: ❌ minimal MPLS support.

**Blocking predicate:** Batfish has minimal MPLS support — parse-and-warn grammar only, no LDP sessions, no label tables, no LFIB.

**Unblocking condition:** Batfish adds MPLS/LDP data-plane modeling, OR supplemental data path.

---

### DEF-04: MSDP

**Stage 1 trace:** Layer 2.6, table row 4. FRR: PROD (partial via pimd). Batfish: ❌.

**Blocking predicate:** No Batfish extraction for MSDP.

**Unblocking condition:** Batfish adds MSDP extraction, OR supplemental data path.

---

### DEF-05: VRRP (+ HSRP→VRRP Mapping)

**Stage 1 trace:** Layer 2.6, table row 5. FRR: PROD (vrrpd). Batfish: ⚠️ rich extraction (`VRRP_Groups`).

**Blocking predicate:** Strategic scope decision. Extraction is available; FRR daemon is production-grade.

**Unblocking condition:** v2 scope decision. Pipeline must add VRRP group extraction from `hsrpProperties()` (for HSRP→VRRP mapping) and `namedStructures()` for VRRP, and add `vrrpd` configuration generation to the template pipeline.

---

### DEF-06: SR-MPLS / SRv6 / PCEP

**Stage 1 trace:** Layer 2.6, table row 6. FRR: PROD (pathd). Batfish: ❌ limited.

**Blocking predicate:** Batfish has limited SR support. No segment routing data-plane modeling.

**Unblocking condition:** Batfish adds SR support, OR supplemental data path for SID/policy configuration.

---

### DEF-07: BGP Flowspec

**Stage 1 trace:** Layer 2.6, table row 7. FRR: PROD. Batfish: ❌.

**Blocking predicate:** No Batfish extraction for BGP Flowspec address-family.

**Unblocking condition:** Batfish adds Flowspec extraction.

---

### DEF-08: RPKI/ROA

**Stage 1 trace:** Layer 2.6, table row 8. FRR: PROD (frr-rpki-rtrlib). Batfish: ❌.

**Blocking predicate:** No Batfish extraction for RPKI configuration or ROA state.

**Unblocking condition:** Batfish adds RPKI extraction, OR supplemental data path for ROA tables.

---

### DEF-09: RIP

**Stage 1 trace:** Layer 2.6, table row 9. FRR: PROD (ripd/ripngd). Batfish: ⚠️ partial.

**Blocking predicate:** Strategic scope decision. Batfish has partial support (`Rip_Enabled`, `Rip_Passive` interface properties). No stable `ripEdges` question.

**Unblocking condition:** v2 scope decision + Batfish adds `ripEdges` or equivalent stable question.

---

### DEF-10: BMP

**Stage 1 trace:** Layer 2.6, table row 10. FRR: PROD. Batfish: ❌.

**Blocking predicate:** No Batfish extraction for BMP. BMP is a monitoring-plane protocol, not a routing-plane protocol.

**Unblocking condition:** Batfish adds BMP extraction. Low priority — BMP does not affect routing decisions.

---

## Completeness Verification

**Element count by category:**

| Category | Count | Coverage |
|----------|-------|----------|
| Full Fidelity — Protocol FSMs (§1.1) | 9 | FF-1.1.01 through FF-1.1.09 |
| Full Fidelity — Routing Algorithms (§1.2) | 3 | FF-1.2.01 through FF-1.2.03 |
| Full Fidelity — Route/Policy Processing (§1.3) | 11 | FF-1.3.01 through FF-1.3.11 |
| Full Fidelity — Control-Plane Signaling (§1.4) | 6 | FF-1.4.01 through FF-1.4.06 |
| Full Fidelity — Failover/Convergence (§1.5) | 5 | FF-1.5.01 through FF-1.5.05 |
| Full Fidelity — Structural Graph Properties (§1.6) | 6 | FF-1.6.01 through FF-1.6.06 |
| Full Fidelity — Config Validation (§1.7) | 3 | FF-1.7.01 through FF-1.7.03 |
| Full Fidelity — Infrastructure Services (§1.8) | 6 | FF-1.8.01 through FF-1.8.06 |
| Full Fidelity — Timer Arithmetic (§1.9) | 3 | FF-1.9.01 through FF-1.9.03 |
| Vendor Divergence (Layer 2.1) | 6 | VD-2.1.01 through VD-2.1.06 |
| Proprietary Mappings (Layer 2.3) | 1 | PM-2.3.01 |
| Topology Edge Cases (Layer 3.3) | 8 | TE-3.3.01 through TE-3.3.08 |
| Protocol Interactions (Layer 4.2) | 7 | PI-4.2.01 through PI-4.2.07 |
| Legacy Environment (Layer 4.4) | 8 | LE-4.4.01 through LE-4.4.08 |
| Cross-Validation Requirements (Layer 4.5) | 5 | CV-4.5.01 through CV-4.5.05 |
| Deferred Elements (Layer 2.6) | 10 | DEF-01 through DEF-10 |
| **Total** | **97** | |

**Trace verification:** Every element in the Stage 1 post-filtration universal set has a corresponding entry. The 9 "IN — Degraded Fidelity" items from the post-filtration summary map to: VD-2.1.01 (vendor timer divergence), PM-2.3.01 (MLAG mapping), TE-3.3.08/LE-4.4.01 (STP), LE-4.4.03 (NAT), LE-4.4.07 (stateful firewalls), LE-4.4.08 (load balancers), TE-3.3.01 (IGP cost asymmetry), FF-1.5.02 (convergence timing), VD-2.1.06 (GR edge cases). The 11 "IN — Deferred" items map to DEF-01 through DEF-10 (BMP and MSDP are both counted; Stage 1 lists 11 items with IS-IS, PIM, MPLS/LDP, MSDP, VRRP, SR-MPLS/SRv6/PCEP, BGP Flowspec, RPKI/ROA, RIP, BMP — SR-MPLS/SRv6/PCEP counted as one). No element remains unevaluated.

---
>Now feeds into Stage 3.
