Version - 4.3
# Stage 1 — The Bounded Universal Set

> Internal build plan. "State space" = the bounded universal set defining the operational domain.
> Each layer starts wide and tightens. What survives all four layers IS the universe the compression math operates on.
> 
> **FRR version baseline:** 10.6.0 (March 2026). Daemon maturity assessments reflect this version.

---

## Layer 1: Scale and Substrate Invariant

This is the widest, highest-confidence floor of the universal set. Everything here is provably identical between emulation and production — physics-backed guarantees. These behaviors depend only on logic, and the logic is the same logic regardless of what runs it.

> **Filtration notice:** Layer 1 enumerates all theoretically invariant behaviors across all standardized protocols. Not all items survive Layers 2–4. The post-filtration universal set at the end of this document is the authoritative scope — do not cite Layer 1 tables in isolation.

### 1.1 Protocol Finite State Machines (per-session, per-instance)

Every standardized control-plane protocol defines state machines that operate on protocol messages, not physical signals. Each FSM is a pure function of its current state and the next input event.

| Protocol | States | Events/Transitions | Scope | Invariance Proof |
|----------|--------|--------------------|-------|------------------|
| BGP (RFC 4271 §8.1) | 6 (Idle → Connect → Active → OpenSent → OpenConfirm → Established) | 28 events | Per-session | Pure function of state + input event |
| OSPF Neighbor (RFC 2328) | 8 (Down → Attempt → Init → 2-Way → ExStart → Exchange → Loading → Full) | Per-adjacency | Per-adjacency | Message-driven, deterministic |
| OSPF Interface (RFC 2328 §9.1) | 7 (Down / Loopback / Waiting / Point-to-Point / DR Other / Backup / DR) | Per-interface | Per-interface | Timer + hello driven. Loopback state omitted from operational focus but included for completeness. |
| BFD (RFC 5880) | 4 (Down / Init / Up / AdminDown) | Packet reception + timer expiry | Per-session | Detection time formula: see §1.9 for canonical definition — local arithmetic, per-session. **Interval caveat:** FSM invariance holds at intervals ≥1s. At sub-second intervals (≤100ms), substrate determines whether keepalive deadlines are met, producing different reachable states (see Fidelity Boundary §Item 1). Architectural mitigation: emulation uses 10x timer multiplication to prevent false flaps from host CPU contention — day-one design decision. Mirror Box Tier 3 treats BFD timing as empirically measured, not analytically modeled. |
| STP (IEEE 802.1D) | 5 (Disabled / Blocking / Listening / Learning / Forwarding) | Per-port | Per-port | BPDU-driven, deterministic |
| RSTP (IEEE 802.1w) | 3 (Discarding / Learning / Forwarding) | Per-port | Per-port | Proposal/agreement mechanism, deterministic |
| LACP (IEEE 802.1AX, originally 802.3ad) | Partner detection, aggregation logic, active/passive mode | Per-link | Per-link | LACPDU exchange, deterministic |
| LLDP (IEEE 802.1AB) | Neighbor discovery and advertisement | Per-link | Per-link | Per-interface, message-driven |
| IS-IS (ISO 10589) | 3 (Down / Initializing / Up) + DIS election | Per-adjacency | Per-adjacency | Hello-driven, deterministic |
| VRRP (RFC 5798) / HSRP | Master / Backup state transitions | Per-group | Per-group | Priority comparison + timer, deterministic |
| IGMP (RFC 3376) / MLD | Per-group/per-interface membership state | Per-group | Per-group | Query/report driven |
| LDP (RFC 5036) | Session establishment, FEC-label binding | Per-session | Per-session | TCP-based, message-driven |
| RSVP-TE (RFC 3209) | Per-LSP state machines | Per-LSP | Per-LSP | Message-driven |
| Graceful Restart (RFC 4724 BGP, RFC 3623 OSPF) | Restarter/helper roles, stale-path timers, F-bit, EOR markers | Per-session | Per-session | Protocol extension FSM, deterministic |

**Invariance basis:** Each FSM is a pure function of (current_state, input_event) → (next_state, output_actions). The physical substrate does not enter the transition function. Testing one session at any scale validates the FSM at all scales.

### 1.2 Routing Algorithm Correctness (per-invocation)

Algorithms that compute forwarding state from topology and policy input are deterministic mathematical functions.

| Algorithm | Function | Invariance |
|-----------|----------|------------|
| BGP best-path selection | Ordered comparison: weight → local-pref → locally-originated → AS-path length → origin → MED → eBGP-over-iBGP → IGP metric to next-hop → multipath check → oldest route → router-ID → cluster-list length → neighbor IP | Pure total ordering when `deterministic-med` is enabled. **Without `deterministic-med` (the default in FRR and Cisco), MED comparison is arrival-order-dependent — same inputs, different arrival order, different winner** (Griffin & Wilfong, IEEE ICNP 2002). See Layer 2.1 and Fidelity Boundary §Item 12. |
| Dijkstra/SPF | Shortest-path tree from link-state database. O(V log V + E). | Deterministic. Same LSDB = same SPT, regardless of substrate. The *result* is invariant; the *computation time* is scale-dependent (see Layer 3). |
| Bellman-Ford | Distance-vector path computation | Same inputs = same outputs |
| Route redistribution + AD comparison | Lookup operations on route tables | Per-prefix comparison, deterministic |

### 1.3 Route and Policy Processing (per-route)

Each route is evaluated independently against the same policy chain. The evaluation logic is pure pattern matching and attribute manipulation on data structures.

| Operation | Mechanism | Invariance |
|-----------|-----------|------------|
| Route-map evaluation | Match conditions (prefix-list, community-list, AS-path ACL, interface, metric, tag, next-hop) → set actions (local-pref, MED, community, AS-path prepend, next-hop, weight, origin). Continue clauses. Deny/permit. | Per-route pipeline. Same route + same policy = same result at any scale. |
| Prefix-list matching | Exact match, ge/le range operators, implicit deny, sequence ordering | Per-prefix evaluation |
| Community handling | Standard (RFC 1997), extended (RFC 4360), large (RFC 8092). Additive vs replace. Regex matching. Well-known communities (no-export, no-advertise, local-as, no-peer). | Per-route attribute manipulation |
| AS-path manipulation | Prepending, regex filtering, length comparison, private AS removal | Per-route |
| Administrative distance | Per-protocol defaults, per-route overrides, floating static routes | Per-prefix comparison |
| Route redistribution | Between protocols (OSPF↔BGP, static↔BGP, connected↔OSPF), with/without route-maps, metric translation | Per-route evaluation |
| Route summarization | BGP aggregate-address (as-set, suppress-map, attribute-map). OSPF inter-area/external summarization at ABR/ASBR. | Per-aggregate operation |
| Default route origination | BGP default-originate with/without route-map. OSPF default-information originate with/without always. | Per-origination decision |
| Route-target import/export | VRF membership, EVPN route filtering | Per-route, per-VRF |
| ACL/firewall rule evaluation | Ordered rule matching against packet header fields. First-match or best-match. | Per-packet decision. Same packet + same ruleset = same result. Speed is substrate-dependent; result is not. **Note:** match logic is invariant; TCAM capacity (when ACL size exceeds hardware table limits, causing fallback to CPU slow-path) is substrate-dependent — see OUT list and Fidelity Boundary §Item 8. |

**Exception: `maximum-prefix`.** BGP `maximum-prefix` is aggregate-count-dependent, not per-route. It tears down a BGP session when received prefix count exceeds a configured threshold. In compressed emulation with fewer prefixes, this will not trigger at production-scale thresholds. This is a scale-dependent behavior embedded in policy configuration — the Cathedral must model it analytically. See Fidelity Boundary §Item 14.

### 1.4 Control-Plane Signaling and Encoding (per-message)

The on-wire format and processing of protocol messages is substrate-independent.

| Category | Elements |
|----------|----------|
| BGP messages | UPDATE / WITHDRAW / NOTIFICATION encoding and parsing. NLRI processing. |
| OSPF LSAs | Types 1–11. Flooding, aging, database synchronization. |
| EVPN route types | Type-1 (Ethernet Auto-Discovery), Type-2 (MAC/IP), Type-3 (Inclusive Multicast), Type-4 (Ethernet Segment) per RFC 7432; Type-5 (IP Prefix) per RFC 9136. Types 6–11 (informational — RFC 9251 covers IGMP/MLD proxy; additional types defined in subsequent RFCs — verify currency before citing. FRR bgpd production support for Types 6–11 not confirmed.) |
| VXLAN | Encapsulation/decapsulation per RFC 7348. |
| IS-IS | TLV encoding, LSP flooding, CSNP/PSNP exchange. |
| LDP | Label distribution, FEC-label binding. |
| MPLS label operations | Push/pop/swap at the control-plane decision level. |
| Adjacency/session management | Hello/keepalive exchange, hold timer negotiation, capability advertisement, session teardown. TCP establishment (BGP), UDP exchange (BFD), OSPF hello/dead interval negotiation. |
| Protocol capability negotiation | BGP OPEN capabilities, OSPF options bits, BFD parameter negotiation, GR capability exchange. Per-session, same result regardless of session count. |
| Encapsulation/header operations | VXLAN encap, MPLS label push/pop/swap, GRE tunneling, IPsec SA negotiation (control-plane level), IP-in-IP. Per-packet/per-tunnel, scale-independent. |

### 1.5 Failover and Convergence Logic (causal ordering)

The *causal sequence* of failover — which protocol detects failure first, which routes withdraw first, which backup paths activate in which order — is substrate-invariant. The *absolute wall-clock timing* is not (it is substrate-dependent), but the causal ordering is deterministic given the same detection mechanisms and timer configurations.

| Behavior | What is invariant | What is NOT invariant |
|----------|-------------------|----------------------|
| BFD-triggered failover chain | BFD detects → notifies client (BGP/OSPF) → client withdraws/recomputes → Zebra updates FIB. Entire signaling chain with correct ordering. | Absolute detection latency (hardware BFD vs software BFD) |
| Convergence sequencing | Which routes withdraw first, which backup paths activate in which order, which neighbors detect failure first, which protocol reacts first. | Absolute millisecond timing (time dilation compensates in emulation) |
| Multi-failure blast radius | Given N simultaneous failures, which destinations lose reachability, which paths survive, reconverged topology. | Timing-dependent cascade effects at production scale (Layer 3) |
| Next-hop tracking | Recursive resolution, reachability monitoring via IGP, next-hop-self, resolution failure propagation. | Speed of convergence |
| Graceful Restart | Stale route marking, EOR marker processing, restart timer behavior, helper mode, BFD interaction. | Absolute timer wall-clock in virtualized environment |

### 1.6 Structural Graph Properties (topology-intrinsic)

Properties of the topology graph that hold regardless of instantiation.

| Property | Definition | Invariance |
|----------|------------|------------|
| ECMP path count | Number of equal-cost paths between any two nodes | Graph structure, not instantiation |
| Bisection bandwidth ratio | Minimum cut capacity / total edge capacity | Topological invariant |
| Hop count | Shortest path length between any leaf pair | Graph property |
| k-connectivity | Minimum vertex/edge removals to disconnect | Structural resilience metric |
| Diameter | Longest shortest path in the graph | Graph property |
| Symmetry | Topological symmetry (e.g., folded Clos) | Graph structure |

### 1.7 Configuration and Validation (per-transaction)

| Behavior | Invariance |
|----------|------------|
| CLI/API configuration parsing | Software process, identical in emulation within the same implementation (FRR). Cross-vendor CLI parsing semantics differ — empty route-map deny-all (NX-OS) vs empty prefix-list permit-all are vendor-specific. See Fidelity Boundary §Item 9. |
| Commit validation, reference integrity | Per-transaction, substrate-independent |
| Candidate-to-running promotion | Software process |
| Rollback and diff | Software process |
| VRF isolation, route leaking config | Logical operation on data structures |

### 1.8 Infrastructure Service Logic (per-transaction)

| Service | Invariance |
|---------|------------|
| DNS client resolution | Application-layer message exchange |
| DHCP relay forwarding | Per-request forwarding decision |
| NTP client logic | Time synchronization protocol messages (not clock accuracy — that is substrate-dependent) |
| SNMP polling/traps | Application-layer |
| Syslog forwarding | Application-layer |
| AAA (RADIUS/TACACS+) | Authentication flow logic |

### 1.9 Timer and Interval Arithmetic (per-session)

Timer computations are local arithmetic — the formulas do not change with node count.

| Timer | Formula | Scope |
|-------|---------|-------|
| BFD detection time | Remote.DetectMult × max(Local.RequiredMinRxInterval, Remote.DesiredMinTxInterval) (RFC 5880 §6.8.4) | Per-session |
| OSPF dead interval | RouterDeadInterval (convention: 4 × HelloInterval) | Per-adjacency |
| BGP hold time | Negotiated minimum of both peers' advertised hold time | Per-session |
| Route redistribution AD | Per-protocol defaults, per-route overrides | Per-prefix |

### Layer 1 Summary

Everything above is IN the universal set with maximum confidence. These are the hard guarantees — the behaviors where emulation produces identical logical outcomes to production because the behavior depends only on logic.

**The separation that must be maintained:** Many of these behaviors have a substrate-dependent *speed* component alongside the substrate-invariant *correctness* component. ACL evaluation produces the same match result in hardware and software, but at different speeds. SPF produces the same tree in 1ms and 100ms. The correctness enters the universal set; the speed does not. **"Correctness" here means safety properties:** the system computes the right routing decision, the right forwarding entry, the right policy evaluation result. It does not mean liveness properties (the computation completes within a bounded time), which depend on timing.

**FLP caveat:** The Fischer-Lynch-Paterson result establishes that timing and correctness are formally inseparable for liveness properties in distributed systems. Convergence timing, classified here as scale-dependent, is one such case. This means the "correctness enters, speed doesn't" separation is valid for safety properties but not universally. The universal set must acknowledge this boundary — convergence *correctness* (right answer) is in; convergence *liveness* (answer arrives in time) is bounded by timer configurations, not physics guarantees. This caveat qualifies claims in the Compression Engine's Gap 1 (Non-Markovian Timer Interactions) and the Fidelity Boundary's "speed vs correctness" discussion.

---

## Layer 2: Vendor and Proprietary Protocol Edge Cases

This layer identifies where the FRR-based emulation diverges from vendor-specific implementations. Everything in Layer 1 assumed RFC-compliant behavior. Real networks run on vendor NOS implementations that have quirks, proprietary extensions, and implementation-specific defaults.

### 2.1 Vendor Implementation Divergence from RFC (FRR vs Production NOS)

FRR implements the same RFCs as Cisco IOS, Arista EOS, Juniper Junos, NX-OS. A route-map that sets local-preference to 200 on a community match does the same thing in FRR as on a Cisco 9500. A BGP session with the wrong ASN fails identically. An OSPF adjacency stuck in Exstart due to MTU mismatch looks the same.

**What FRR catches (the dominant failure class):** The 45% of outages caused by config/change management errors are overwhelmingly logic errors — wrong ASN, missing prefix filter, bad route-map match clause — not vendor-quirk failures.

**What FRR does NOT reproduce:**

| Divergence Category | Examples | Impact | Disposition |
|---------------------|----------|--------|-------------|
| Default timer values | NX-OS BGP keepalive=60s/hold=180s vs Junos defaults vs IOS defaults. MRAI defaults vary. SPF throttle timers vary. | If customer's config doesn't explicitly set timers, FRR uses FRR defaults, which may differ from their vendor's defaults. | **IN SET, DEGRADED** — extraction must flag defaulted vs explicit timers. Cathedral timing predictions degraded when timers are defaulted. |
| Parser behavior | Cisco CLI parsing quirks, Junos hierarchical commit model, NX-OS regex syntax edge cases in community-lists. | Configs that rely on parser edge cases may produce different behavior in FRR. | **IN SET, FLAGGED** — Batfish parse status catches most of these. `PARTIALLY_UNRECOGNIZED` lines are flagged. |
| Best-path tiebreaking extensions | FRR has weight and locally-originated steps that are implementation-specific (not in RFC 4271 §9.1.2.2). Arista and Cisco have their own tiebreaking extensions. | Rare — only matters when paths are equal through all RFC-defined steps AND vendor-specific steps diverge. | **IN SET** — FRR's tiebreaking is documented; divergence is in the long tail after RFC-standard steps. |
| OSPF implementation quirks | DR election timing, LSA flooding optimizations, SPF scheduling algorithms differ between vendors. | Timing differences, not correctness differences (same SPT, different computation schedule). | **IN SET, TIMING DEGRADED** — correctness preserved, timing is best-effort. |
| BGP attribute handling edge cases | Arista's treatment of MED when paths come from different ASes (always-compare-med). Cisco's deterministic-MED. | Can cause different best-path selection in specific multi-path scenarios. | **IN SET, FLAGGED** — Batfish `testRoutePolicies` can cross-validate per-route. FRR supports `bgp always-compare-med` and `bgp deterministic-med`. |
| GR implementation completeness | Vendor GR edge cases — notification handling during restart, timer interactions, partial GR support. | Edge cases in failover scenarios. | **IN SET, DEGRADED** — GR FSM is invariant; implementation edge cases are documented gaps. |

### 2.2 Proprietary Protocols — No FRR Equivalent

These protocols are vendor-proprietary. FRR cannot implement them. They are filtered OUT of the universal set entirely.

| Protocol | Vendor | Why No FRR Path | Enterprise Impact | Disposition |
|----------|--------|-----------------|-------------------|-------------|
| EIGRP | Cisco | FRR eigrpd exists but is **ALPHA quality** — basic neighbor formation and redistribution only. Not production-grade. | Cisco-dominant legacy networks. | **OUT OF SET** — alpha-quality daemon is not SLA-grade. Batfish has excellent extraction (`eigrpEdges`), so configs are parseable even if not emulatable. |
| MLAG/vPC peer-link protocol | Cisco (vPC), Arista (MLAG) | Proprietary inter-chassis control plane. No standard, no FRR implementation. | Every multi-homed leaf-spine fabric. | **OUT OF SET** — translated to EVPN multihoming (ESI-LAG) or documented as limitation. MLAG data-plane behavior (forwarding, orphan port handling) unmodeled. |
| MLAG/vPC peer keepalive | Cisco, Arista | Proprietary heartbeat mechanism | Same as above | **OUT OF SET** — proprietary |
| CDP | Cisco | Proprietary L2 discovery | Cisco-only environments | **OUT OF SET** — LLDP is the standards equivalent. CDP-specific information not available. |
| VTP | Cisco | Proprietary VLAN propagation | Legacy Cisco L2 networks | **OUT OF SET** — increasingly deprecated, dangerous in production, no equivalent needed. |
| GLBP | Cisco | Proprietary FHRP with load balancing | Rare, Cisco-only | **OUT OF SET** — VRRP is the standards path. |
| HSRP | Cisco | Proprietary FHRP | Very common in Cisco shops | **OUT OF SET** — proprietary protocol. Functional mapping to VRRP is architecturally valid (same master/backup concept) but VRRP itself is DEFERRED from v1 (see §2.6). Therefore HSRP modeling is also deferred. Batfish extracts HSRP config for future use. |
| SD-WAN overlays (OMP, etc.) | Cisco (Viptela/cEdge), VMware, etc. | Proprietary control planes | Growing enterprise adoption | **OUT OF SET** — stubbed at bastion boundary. IOS-XE underlay (BGP, OSPF) may be partially parseable via Batfish. |
| ACI policy model | Cisco | Entirely proprietary intent-based model | Cisco ACI customers | **OUT OF SET** — no FRR equivalent, no Batfish extraction. |
| NSX distributed routing | VMware/Broadcom | Proprietary hypervisor-integrated routing | NSX customers | **OUT OF SET** — not a network device config. |
| Cisco Fabric Path / FabricExtender | Cisco | Proprietary DC fabric protocols | Legacy Nexus environments | **OUT OF SET** |

### 2.3 Proprietary Protocols — Mappable to Standards Equivalents

Some proprietary protocols have standards-based functional equivalents that FRR implements. The mapping introduces fidelity loss on protocol-specific behaviors but preserves the logical function.

| Proprietary Protocol | Standards Equivalent | Mapping Fidelity | What's Lost |
|---------------------|---------------------|-------------------|-------------|
| HSRP → VRRP | VRRP (RFC 5798) | High — same master/backup concept, same virtual IP | HSRP version-specific timers, authentication (VRRPv2 auth not in FRR), HSRP group numbering semantics. **Note: VRRP is DEFERRED from v1. This mapping is architecturally valid but not active until VRRP is implemented.** |
| vPC/MLAG → EVPN MH (ESI-LAG) | EVPN Type-1/Type-4 | Medium — functional dual-homing preserved | Proprietary peer-link failure behavior, orphan port handling, vPC consistency checks, peer-gateway |
| CDP → LLDP | LLDP (IEEE 802.1AB) | High — same neighbor discovery function | CDP-specific TLV information (VTP domain, native VLAN via CDP, power negotiation) |

### 2.4 Alpha-Quality FRR Implementations

These protocols have FRR daemons but the daemons are explicitly flagged as not production-grade by the FRR project itself.

| Daemon | Protocol | FRR Status | Known Issues | Disposition |
|--------|----------|------------|--------------|-------------|
| eigrpd | EIGRP (RFC 7868) | **ALPHA** | Basic neighbor formation and route redistribution only. Not production-grade. FRR website explicitly flags. | **OUT OF SET** — cannot be used for SLA-bound claims. |
| nhrpd | NHRP/DMVPN (RFC 2332) | **ALPHA** | Hub-spoke with strongSwan IPsec integration. Known Cisco interoperability issues. FRR website explicitly flags. | **OUT OF SET** — cannot be used for SLA-bound claims. |

### 2.5 Hard Implementation Gaps (No FRR Path at All)

| Protocol | Why It's a Hard Gap | Enterprise Impact | Disposition |
|----------|--------------------|--------------------|-------------|
| RSVP-TE (RFC 3209) | FRR has no RSVP-TE. GitHub #504, #3101 open. Strategic direction is SR-MPLS via pathd. | SP-influenced MPLS TE deployments. Declining relevance. | **OUT OF SET** — architectural ceiling of FRR-based emulation. |
| LISP (RFC 9300/9301) | No FRR implementation. GitHub #364 open. | Cisco SD-Access campus — dominant campus fabric. **High impact if campus is in scope.** | **OUT OF SET** — hard gap. Strategic decision needed on campus scope. |
| Micro-BFD (RFC 7130) | Not in FRR bfdd. No config syntax, RFC not in supported list. Also no Batfish BFD extraction at all. | DC fabrics using per-LAG-member failure detection. | **OUT OF SET** — hard gap at both FRR and Batfish levels. |
| Ethernet OAM (CFM/Y.1731) | Not FRR. Vendor-specific switch firmware feature. | SP-facing enterprise links. Low enterprise-only impact. | **OUT OF SET** |
| TWAMP/STAMP | Not FRR. Performance measurement protocols. | Network performance SLA verification. Low impact. | **OUT OF SET** |

### 2.6 Protocols Not Supported in v1 (Strategic Scope Decision)

These are implementable (FRR supports them at PROD grade) but excluded from v1 scope.

| Protocol | FRR Status | Batfish Extraction | Why Deferred | Disposition |
|----------|------------|-------------------|--------------|-------------|
| IS-IS | PROD (isisd) — L1/L2/L1L2, SR-MPLS, TI-LFA | ✅ `isisEdges` (stable, Cisco + Juniper) | Low enterprise DC adoption. Common in SP-influenced environments. | **IN SET but DEFERRED** — architecturally supportable, implementation deferred. |
| PIM/multicast | PROD (pimd) — PIM-SM, SSM, static RP, BSR | ❌ Batfish does not model PIM | Ingress replication is modern default in EVPN fabrics. | **IN SET but DEFERRED** — FRR ready, Batfish gap blocks extraction. |
| MPLS/LDP | PROD (ldpd) — targeted LDP supported | ❌ Minimal Batfish MPLS support | Service provider territory. | **IN SET but DEFERRED** |
| MSDP | PROD (partial via pimd) — mesh groups, basic peering | ❌ No Batfish extraction | Inter-domain multicast. Low enterprise DC impact. | **IN SET but DEFERRED** |
| VRRP | PROD (vrrpd) — VRRPv3 + VRRPv2, Linux-only, no VRRPv2 auth | ⚠️ Rich Batfish extraction (`VRRP_Groups`) | Campus and legacy DC. | **IN SET but DEFERRED** — high priority for campus scope. |
| SR-MPLS / SRv6 / PCEP | PROD (pathd) | ❌ Limited Batfish support | Growing but not yet dominant in enterprise DC. | **IN SET but DEFERRED** |
| BGP Flowspec | PROD (bgpd, address-family flowspec) | ❌ No Batfish extraction | DDoS mitigation. Moderate enterprise adoption. | **IN SET but DEFERRED** |
| RPKI/ROA | PROD (frr-rpki-rtrlib) | ❌ No Batfish extraction | Route origin validation. Growing. | **IN SET but DEFERRED** |
| RIP | PROD (ripd/ripngd) — actively maintained | ⚠️ Partial — `Rip_Enabled` and `Rip_Passive` interface properties exist, but no dedicated stable `ripEdges` question | Legacy protocol. Rare in modern DC. | **IN SET but DEFERRED** |
| BMP | PROD (loadable module) | ❌ No Batfish extraction | Monitoring plane. Router-to-BMP-station session. Low priority. | **IN SET but DEFERRED** |

### Layer 2 Summary

**Remains IN the universal set at full fidelity:** Everything from Layer 1 that operates on RFC-standard behavior and is covered by the four supported protocol stacks (OSPF+iBGP EVPN, eBGP everywhere, OSPF only, eBGP+eBGP EVPN).

**Remains IN the universal set at DEGRADED fidelity:** Vendor default timer divergence, parser edge cases (caught by Batfish parse status), GR implementation edge cases, MLAG→EVPN MH mapping.

**IN SET but DEFERRED (architecturally supportable, not in v1):** IS-IS, PIM, MPLS/LDP, MSDP, VRRP (+ HSRP→VRRP mapping), SR-MPLS/SRv6, BGP Flowspec, RPKI, RIP, BMP.

**FILTERED OUT (hard boundary):** EIGRP (alpha), NHRP/DMVPN (alpha), RSVP-TE (no FRR), LISP (no FRR), Micro-BFD (no FRR), Ethernet OAM, TWAMP/STAMP, all proprietary protocols (vPC/MLAG peer-link, CDP, VTP, GLBP, ACI, NSX, FabricPath, SD-WAN overlays).

---

## Layer 3: Topology-Dependent Edge Cases and Topology-Invariant Confidence Check

This layer examines how specific topology patterns interact with the behaviors established in Layer 1 and filtered in Layer 2. Topology is not a separate fidelity axis — a behavior is either substrate-dependent or it is not, regardless of topology. But topology affects *which* scale thresholds are reached and *which* edge cases manifest.

### 3.1 Topology-Invariant Confidence Check

First, verify that everything classified as topology-invariant in Layer 1 actually holds across topology variations.

| Behavior | Topology-Invariant? | Confidence | Notes |
|----------|---------------------|------------|-------|
| Per-session FSMs | ✅ Yes | **HIGH** | FSM transitions are identical on a spine, a leaf, a border router, a standalone switch. Topology position does not change the state machine. |
| Per-route policy evaluation | ✅ Yes | **HIGH** | Route-map match/set is the same logic regardless of where in the topology the route-map is applied. |
| BGP best-path selection | ⚠️ **Mostly** | **HIGH with caveat** | The algorithm is topology-invariant, but the *inputs* to the algorithm are topology-dependent. Specifically: IGP metric to next-hop (step 8) varies by position. Two BGP routers with identical configs at different topological positions may select different best paths because their IGP costs to the same next-hop differ. **This is a known compression engine gap (Gap 4)** — the Cathedral detects it by computing IGP costs from every device to every BGP next-hop on the full graph. |
| SPF result | ✅ Yes | **HIGH** | Same LSDB = same SPT. The LSDB *content* is topology-dependent, but the algorithm is not. |
| ACL evaluation | ✅ Yes | **HIGH** | Same packet + same rules = same result, regardless of position. |
| ECMP path count | ✅ Yes | **HIGH** | Property of the graph, not of instantiation. But which *specific* paths are equal-cost depends on topology and link costs. |
| Convergence causal ordering | ⚠️ **Mostly** | **MEDIUM** | The ordering is deterministic given the same detection mechanisms and timers. But in the compressed fabric, the reduced node count changes which devices are "adjacent" to the failure, which can alter detection order. **Mirror Box Tier 2 corrections address this.** |

### 3.2 Topology-Dependent Behavior Thresholds

These are behaviors where the topology determines *when* a scale-dependent effect kicks in. The behavior itself is not topology-dependent — it's scale-dependent — but the topology parameterizes the threshold.

| Behavior | Topology Dependency | Threshold Parameterization |
|----------|--------------------|-----------------------------|
| Hash polarization across stages | Compounds multiplicatively with forwarding hierarchy depth. 2-stage Clos: negligible. 5-stage: severe. | Number of ECMP stages in the forwarding path |
| ARP/ND broadcast storm | O(N²) in flat L2 domain. EVPN ARP suppression converts to O(N). | L2 domain size. EVPN-VXLAN fabrics suppress this. |
| SPF computation time | O(V log V + E). Matters when single link-state area contains hundreds of nodes. | Number of nodes in a single OSPF/IS-IS area |
| LSA/LSP flooding amplification | One change → O(N) processing events. Under churn: O(N × changes). | Number of nodes in the flooding domain |
| Microloop formation | Probability increases with node count in the convergence domain. | Number of nodes converging simultaneously |
| BGP path exploration (path hunting) | O(d) convergence rounds where d = depth of AS-path-length space. Suppressed in Clos with equal-length paths. | Topology regularity. Irregular topologies with diverse path lengths exhibit more hunting. |
| Cascade failure amplification | More nodes = more trigger points, more propagation paths. | Redundancy structure. Non-uniform redundancy creates asymmetric blast radius. |

**Disposition for the universal set:** These behaviors are **IN SET as scale-dependent phenomena** — the topology parameterization tells us *which customers* will hit them, not whether they're in scope. The compression engine's Mirror Box Tier 2 and Tier 3 corrections are designed to model these effects. They do not need to be filtered out; they need to be *parameterized per customer topology*.

### 3.3 Topology-Specific Edge Cases

These are edge cases that arise from specific topology patterns, not from scale.

| Edge Case | Topology Pattern | Impact | Disposition |
|-----------|-----------------|--------|-------------|
| IGP cost asymmetry within equivalence class | Devices at different topological positions have different IGP costs to the same BGP next-hop, causing different best-path selections despite identical configs. | Compression Gap 4. Can cause incorrect equivalence class formation if not detected. | **IN SET, FLAGGED** — Cathedral detects via full-graph IGP cost computation. Batfish validates via `bf.q.routes()` comparison across equivalence class members. |
| DR/BDR election on broadcast segments | OSPF DR election depends on which routers share a broadcast segment. Different segments with different participants produce different DR results. | Position-dependent behavior within OSPF. | **IN SET** — DR election is a well-defined algorithm. The *inputs* are topology-dependent but the *logic* is invariant. Compression preserves broadcast segment membership. |
| Route reflector topology sensitivity | iBGP with RR: the RR's position determines which routes it reflects and to whom. RR cluster topology affects convergence and can create suboptimal routing if poorly designed. | RR positioning is a topology design decision, not an edge case per se. | **IN SET** — RR behavior is fully modeled. The topology is preserved in compression (RR nodes cannot be merged with non-RR nodes). |
| Anycast gateway behavior under failure | In EVPN fabrics, anycast gateway IP is present on all leaves. Failure of a leaf shifts traffic to surviving leaves. The blast radius depends on which leaf fails and which servers are dual-homed to it. | Position-dependent failure impact. | **IN SET** — the server dual-homing topology is preserved in compression (V_inf vertices retain rack position). |
| Asymmetric ECMP paths | Some source-destination pairs have more equal-cost paths than others due to topology irregularity. | Non-uniform resilience. | **IN SET** — structural graph property. Compression preserves path count per equivalence class representative. |
| Stub/NSSA area boundary effects | OSPF stub/NSSA areas filter certain LSA types at the ABR. Behavior is topology-dependent (which area is the device in). | Area membership determines which routes are visible. | **IN SET** — area boundaries are explicit in config and preserved in extraction. |
| VRF route leaking topology | Route leaking between VRFs depends on which device hosts the leak configuration. If multiple devices leak the same route, the import path depends on topology. | Position-dependent for multi-device VRF topologies. | **IN SET** — VRF config is fully extracted. Leaking is per-device config. |
| STP root bridge placement | In L2 networks with STP, the root bridge's position determines the active forwarding topology. Different root placement = different blocked ports = different data paths. | **Critical topology dependency for L2 networks.** | **IN SET, SEVERELY DEGRADED** — Batfish does not simulate STP. For target topology (EVPN-VXLAN), STP is not on the fabric underlay. For legacy L2: STP state must be supplemental data or all trunks assumed forwarding. Convergence diagnostic reports "STP state unmodeled." |

### 3.4 Topology-Invariant Properties — Reconfirmed

The following properties are confirmed topology-invariant after this layer's analysis:

- Every per-session FSM (Layer 1.1) — **confirmed for point-to-point protocols.** OSPF DR election on broadcast segments and STP root bridge election are topology-dependent shared elections whose inputs vary by position — see Layer 3.3. The FSM logic itself remains invariant; the election *inputs* (participant set, priority values) are topology-derived. (Fidelity Boundary v5.0 Items 11, 13.)
- Every per-route policy evaluation (Layer 1.3) — **confirmed**
- Every per-message encoding (Layer 1.4) — **confirmed**
- Timer arithmetic (Layer 1.9) — **confirmed**
- Configuration validation (Layer 1.7) — **confirmed**
- Infrastructure service logic (Layer 1.8) — **confirmed**

The sole topology-sensitive caveat within Layer 1 is BGP best-path's IGP metric step, which is an *input* sensitivity, not an algorithm sensitivity. The algorithm remains invariant; the inputs are topology-derived.

### Layer 3 Summary

**No behaviors were filtered OUT in this layer.** Topology does not create new exclusions — it parameterizes scale-dependent thresholds and creates position-dependent input variations that the compression engine's existing gap detection (Gap 4, Cathedral IGP cost computation, Mirror Box Tier 2/3 corrections) already accounts for.

**Key topology-dependent concern for the universal set:** STP on legacy L2 networks. This is already documented as Compression Engine Gap 6 and is handled by scope restriction (target topology is EVPN-VXLAN where STP is irrelevant on fabric underlay) and supplemental data path for legacy environments.

---

## Layer 4: Protocol Stack Combination Edge Cases, Legacy Environments

This layer examines edge cases that arise from specific *combinations* of protocols running simultaneously, from legacy technology stacks, and from interaction effects that don't exist when protocols are considered individually.

### 4.1 Supported Protocol Stack Combinations

The four supported stacks and their interaction characteristics:

| Stack | Underlay | Overlay | Interaction Complexity | Known Interaction Edge Cases |
|-------|----------|---------|------------------------|------------------------------|
| OSPF + iBGP EVPN | OSPF area 0, P2P links | iBGP with RR on spines, MP-BGP L2VPN EVPN | **High** — OSPF provides IGP reachability for iBGP next-hops. BGP next-hop resolution depends on OSPF convergence. | OSPF convergence timing affects BGP next-hop tracking. If OSPF reconverges before BGP hold timer expires, BGP sessions survive. If not, BGP sessions drop, triggering a second wave of reconvergence. Timer interaction is scale-dependent (Layer 3). FRR handles this interaction natively — same process (Zebra) manages both. |
| eBGP everywhere | eBGP per link, ASN-per-tier | Same sessions or separate AF | **Low** — single protocol, no IGP/EGP interaction. | Simpler failure model: link failure = BGP session failure. No OSPF/BGP interaction timing. BFD integration straightforward. |
| OSPF only | OSPF or IS-IS, no overlay | None | **Low** — single protocol. | SPF computation is the sole convergence mechanism. No overlay/underlay interaction. |
| eBGP + eBGP EVPN | eBGP per-link | eBGP L2VPN EVPN | **Medium** — same protocol, different address families. | AF interaction: if underlay eBGP session drops, EVPN AF on same session also drops. Coupled failure mode but simpler than OSPF+BGP. |

### 4.2 Protocol Interaction Edge Cases Within Supported Stacks

| Interaction | Protocols Involved | Edge Case | Impact | Disposition |
|-------------|-------------------|-----------|--------|-------------|
| IGP-BGP next-hop resolution race | OSPF + BGP | After a link failure, OSPF must reconverge and install new routes before BGP can resolve its next-hops via the new IGP paths. If OSPF is slow (SPF throttle timers, flooding delay), BGP next-hop resolution temporarily fails, causing BGP to withdraw routes that are actually still reachable via alternate IGP paths. | Transient routing black holes during convergence window. | **IN SET** — FRR's Zebra handles this natively. The race condition is real in production and real in emulation. Timer values matter (Layer 2.1 vendor timer divergence applies). |
| BFD-BGP-OSPF detection hierarchy | BFD + BGP + OSPF | BFD detects failure fastest (sub-second). BGP hold timer is slower (default 180s). OSPF dead interval is intermediate (default 40s). When BFD is enabled for BGP but not OSPF (or vice versa), the two protocols detect the same failure at different times, creating a window where one protocol has reconverged and the other hasn't. | Inconsistent forwarding state during detection gap. | **IN SET** — FRR's bfdd correctly notifies only the bound protocol. The detection hierarchy is real. |
| EVPN Type-2/Type-5 route interaction | BGP EVPN + VXLAN + VRF | Type-2 (MAC/IP) and Type-5 (IP Prefix) routes can both advertise reachability to the same destination. When both exist, the more specific (Type-2 /32 host route) takes precedence. If the Type-2 route is withdrawn (host moves), the Type-5 aggregate route provides fallback. | Route type interaction during host mobility events. | **IN SET** — FRR bgpd handles Type-2/Type-5 coexistence natively. Batfish models both route types (`evpnRoutes`). |
| VRF route leaking + BGP RT interaction | BGP EVPN + VRF + route-targets | Routes leaked between VRFs via RT import/export can interact with EVPN-advertised routes. If a leaked route and an EVPN-received route compete for the same prefix, AD comparison + RT matching determines the winner. | Unexpected route selection in multi-tenant/multi-VRF environments. | **IN SET** — FRR handles VRF leaking + EVPN RT interaction. Batfish extracts VRF config and RT policies. |
| Redistribution loops | OSPF ↔ BGP mutual redistribution | Without proper filtering, routes redistributed from OSPF→BGP can be redistributed back from BGP→OSPF with different metrics, creating routing loops or suboptimal paths. | Classic misconfiguration. This is exactly the kind of error the product exists to catch. | **IN SET** — this is a Layer 1 per-route policy evaluation behavior. FRR reproduces it faithfully. |
| GR + BFD conflict | Graceful Restart + BFD | During a graceful restart, BFD may detect the restarting peer as down (because BFD packets stop), triggering fast failover — defeating the purpose of GR. FRR's `neighbor bfd check-control-plane-failure` addresses this. | Timer interaction between GR restart timer and BFD detection time. | **IN SET** — FRR implements the interaction. Configuration-dependent behavior. |
| ECMP + route-map next-hop manipulation | ECMP paths + route-map set next-hop | A route-map that sets a specific next-hop overrides ECMP, collapsing multiple equal-cost paths to a single forced path. This is a config error in ECMP fabrics but a valid design in some topologies. | ECMP behavior silently overridden by policy. | **IN SET** — per-route policy evaluation (Layer 1.3). |

### 4.3 Unsupported Protocol Interaction Edge Cases

These arise when the customer's environment includes protocols from outside the four supported stacks.

| Interaction | What Happens | Disposition |
|-------------|-------------|-------------|
| EIGRP↔BGP redistribution | EIGRP routes redistributed into BGP — EIGRP side is unmodeled (alpha daemon, out of set). | **OUT OF SET** — EIGRP is out. If customer redistributes EIGRP→BGP at a boundary, the EIGRP-sourced routes must be provided as supplemental static data (injected at bastion). |
| IS-IS underlay + BGP overlay | IS-IS provides IGP reachability for BGP next-hops. IS-IS is deferred from v1. | **IN SET but DEFERRED** — IS-IS is production-grade in FRR. When implemented, interaction is equivalent to OSPF+BGP. |
| PIM + IGMP + OSPF multicast | Multicast routing requires PIM neighbor adjacencies, RP election, IGMP membership, and reverse-path forwarding via IGP. | **IN SET but DEFERRED** — FRR pimd is production-grade. Batfish cannot extract PIM config. |
| MPLS LDP + BGP VPNv4 | LDP provides label distribution for MPLS core; BGP VPNv4 provides VPN routing. | **IN SET but DEFERRED** — FRR ldpd is production-grade. Batfish MPLS support is minimal. |
| SD-WAN OMP + BGP underlay | SD-WAN overlay control plane (OMP) interacts with BGP underlay on cEdge devices. | **OUT OF SET** — OMP is proprietary. BGP underlay may be partially parseable. |

### 4.4 Legacy Environment Edge Cases

| Legacy Technology | Interaction Issues | FRR/Batfish Status | Disposition |
|-------------------|-------------------|-------------------|-------------|
| L2-heavy networks with STP | STP determines active forwarding topology. Interaction with OSPF (passive interfaces on L2 segments), VLAN pruning, trunk negotiation. Batfish does not simulate STP. | FRR: Linux bridge handles STP (kernel) and RSTP (mstpd). Batfish: **no STP simulation.** | **IN SET, SEVERELY DEGRADED** — STP forwarding state unknown. Must be supplemental data or optimistic model (all trunks forwarding). Target topology (EVPN-VXLAN) avoids this. |
| Mixed L2/L3 boundary | Devices that are both L2 switches and L3 routers (SVI interfaces). Interaction between L2 forwarding (VLANs, STP) and L3 routing (OSPF/BGP on SVIs). | FRR: Fedora+FRR box handles both. Batfish: parses SVIs, doesn't model STP. | **IN SET, DEGRADED** on the L2 component. L3 behavior (routing on SVIs) fully modeled. |
| NAT at enterprise edge | NAT interacts with routing (NAT before or after routing decision), ACLs (match on pre-NAT or post-NAT address), and VPN (NAT traversal). | FRR: kernel nftables. Batfish: partial (Cisco IOS). Entity store: not tracked. | **IN SET, DEGRADED** — NAT reachability effects partially modeled by Batfish. Runtime NAT table state not emulated. |
| Legacy timer configurations | Older networks may have non-default timers configured decades ago and never changed. Hello intervals, dead intervals, hold timers may be set to values that interact poorly with modern BFD deployments. | All timer-dependent. | **IN SET** — timers are config-extractable. If explicitly set, FRR uses them. If defaulted, vendor default divergence applies (Layer 2.1). |
| Dual-stack IPv4/IPv6 | IPv4 and IPv6 routing may take different paths through the same topology. Protocol interactions between OSPFv2 (IPv4) and OSPFv3 (IPv6), or IPv4 BGP and IPv6 BGP address families. | FRR: full dual-stack. Batfish: separate IPv4/IPv6 analysis. | **IN SET** — dual-stack is fully supported. |
| Out-of-band management networks | Management VRF, console servers, OOB switches. Interaction with production routing if management traffic leaks into production VRF. | NetWatch uses management bridge (192.168.0.0/24) completely separated from fabric. | **IN SET** — management is isolated by design. Production IPs never touch host network. |
| Stateful firewalls in the routing path | Firewalls with connection tracking interact with routing changes. Asymmetric routing after failover can cause established connections to be dropped by the firewall (traffic hits backup firewall without matching session table entry). | FRR: ACL-only model. Batfish: symbolic stateful session analysis (config-based). | **IN SET, DEGRADED** — Compression Engine Gap 5. ACL behavior modeled; connection-table dynamics not. Convergence diagnostic reports when traffic paths traverse stateful devices. |
| Load balancers | Health-check FSMs, pool state, connection persistence. Interact with routing changes (backend server unreachable after failover, health check fails, pool member removed). | No runtime state extraction. | **IN SET, DEGRADED** — Gap 5. Runtime pool state not emulated. Config-level behavior only. |

### 4.5 Protocol Stack Combination — Cross-Validation Requirements

For the four supported stacks, the following cross-stack validations must hold to maintain universal set integrity:

| Validation | Method | Failure Implication |
|------------|--------|---------------------|
| BGP next-hop resolves via IGP in the emulated fabric | `bf.q.routes()` — verify BGP next-hops appear in IGP RIB | If next-hop doesn't resolve, BGP routes will be inactive. Indicates extraction or topology error. |
| EVPN VTEP reachability via underlay | Underlay routing must provide paths between all VTEPs | If VTEP-to-VTEP path is missing, overlay is broken. |
| BFD session parameters consistent with bound protocol | BFD detection time < protocol hold timer for fast failover to be meaningful | If BFD detection ≥ hold timer, BFD adds no value — may indicate config error or extraction gap. |
| Route-map references resolve | Every route-map referenced in BGP/OSPF config must exist as a named structure | Missing route-map = implicit permit-all or deny-all depending on context. Batfish `undefinedReferences` catches this. |
| ACLs applied to interfaces exist | Every ACL referenced on an interface must be defined | Vendor-dependent behavior for undefined ACLs (some drop all, some permit all). Batfish catches this. |

### Layer 4 Summary

**No new behaviors filtered OUT in this layer** beyond what was already excluded in Layer 2 (EIGRP, proprietary protocols, hard gaps).

**Key findings:**
- Protocol interaction edge cases within the four supported stacks are all **IN SET** — FRR handles them natively because it runs all protocols in a single process (Zebra coordinates BGP, OSPF, BFD).
- Legacy environment edge cases are **IN SET at DEGRADED fidelity** — STP, NAT, stateful firewalls, and load balancers all have documented degradation paths with convergence diagnostic reporting.
- Unsupported protocol interactions are **OUT OF SET** (EIGRP, SD-WAN OMP) or **DEFERRED** (IS-IS, PIM, LDP).
- Cross-validation requirements define the integrity checks that the implementation must pass.

---

## The Universal Set — Post-Filtration

After all four layers, the bounded universal set is:

### IN — Full Fidelity

Everything in Layer 1 (1.1 through 1.9) for the four supported protocol stacks (OSPF+iBGP EVPN, eBGP everywhere, OSPF only, eBGP+eBGP EVPN), with RFC-standard behavior, on the target topology class (EVPN-VXLAN leaf-spine with BGP/OSPF underlay). This is the hard floor. This is the quadrant where emulation is physics-equivalent.

> **Standing caveat:** All Layer 1 claims are safety-property guarantees (the system computes the correct answer). Liveness guarantees (the correct answer arrives within bounded time) are timing-dependent and addressed by Mirror Box Tier 2 corrections, not by the invariance claims below. See FLP caveat in Layer 1 Summary.

Specifically:
- 9 protocol FSM families exercised by v1 supported stacks: BGP, OSPF Neighbor, OSPF Interface, BFD, STP, RSTP, LACP, LLDP, Graceful Restart (BGP/OSPF extension). (Layer 1.1 enumerates 14 theoretically invariant FSM families; 5 are filtered by Layer 2 — IS-IS: deferred, VRRP/HSRP: deferred/out, IGMP/MLD: deferred, LDP: deferred, RSVP-TE: out.)
- 3 routing algorithm families exercised by v1 supported stacks: BGP best-path selection, Dijkstra/SPF, Route redistribution + AD comparison. (Layer 1.2 lists Bellman-Ford as theoretically invariant but it is used by RIP and EIGRP, both filtered in Layer 2.)
- 10 route/policy processing operations, all per-route invariant
- Control-plane signaling and encoding for BGP, OSPF, BFD, EVPN (Type-2/3/5 full; Type-1/4 ESI-LAG partial — FRR does not support ESI multi-homing routes, see Entity Store), VXLAN, LACP, LLDP
- Failover causal ordering (not absolute timing — see standing caveat above)
- Structural graph properties
- Configuration validation
- Infrastructure service logic (DNS, DHCP relay, NTP, SNMP, syslog, AAA)
- Timer arithmetic

### IN — Degraded Fidelity (documented, reported)

| Area | Degradation | Reporting Mechanism |
|------|-------------|---------------------|
| Vendor default timer divergence | FRR defaults may differ from vendor NOS defaults when configs don't explicitly set timers | Extraction confidence report flags defaulted vs explicit timers |
| MLAG/vPC → EVPN MH mapping | Proprietary peer-link behavior, orphan ports, consistency checks lost | Documented limitation in deployment report |
| STP state on legacy L2 networks | Active forwarding topology unknown without supplemental data | Convergence diagnostic: "STP state unmodeled" |
| NAT state | Config-level NAT modeled; runtime translation table not emulated | Convergence diagnostic coverage report |
| Stateful firewall session tables | ACL behavior modeled; connection tracking dynamics not | Convergence diagnostic: percentage of paths through stateful devices |
| Load balancer pool state | Config parsed; runtime health check state not available | Gap 5 report |
| IGP cost asymmetry in equivalence classes | Cathedral detects; does not affect compressed fabric correctness | Gap 4 flag per equivalence class |
| Convergence absolute timing | Causal ordering correct; wall-clock milliseconds approximate | Time dilation compensation documented |
| GR implementation edge cases | GR FSM invariant; vendor-specific edge cases may diverge | Known limitation |

### IN — Deferred (architecturally supportable, not in v1)

IS-IS, PIM/multicast, MPLS/LDP, MSDP, VRRP (+ HSRP→VRRP functional mapping), SR-MPLS/SRv6/PCEP, BGP Flowspec, RPKI/ROA, RIP, BMP.

All of these have production-grade FRR daemons. Most are blocked by Batfish extraction gaps, not FRR gaps. When Batfish support arrives (or supplemental data paths are built), these are additive to the universal set with no architectural changes.

### OUT — Filtered (hard boundary, will never be in set)

| Exclusion | Reason | Permanent? |
|-----------|--------|------------|
| All substrate-dependent behaviors | Physics. Hardware timing, buffer architecture, TCAM capacity, optical layer, PFC/ECN at line rate, hardware hash functions, NIC offloads, thermal throttling, interrupt/DMA behavior. | **Permanent.** Laws of physics. |
| All scale-emergent statistical behaviors | ECMP collision probability at production flow counts, BFD false-flap accumulation, CPU saturation under aggregate churn, cascade failure amplification beyond compressed scale, incast congestion, multicast state explosion, gray failure differential observability. | **Permanent at compressed scale.** Mirror Box Tier 2/3 provides bounded projections, not reproduction. |
| EIGRP (runtime) | FRR eigrpd is alpha-quality. Not SLA-grade. | Until FRR promotes to PROD. |
| NHRP/DMVPN (runtime) | FRR nhrpd is alpha-quality. Cisco interop issues. | Until FRR promotes to PROD. |
| RSVP-TE | No FRR implementation. Strategic direction is SR-MPLS. | **Likely permanent.** |
| LISP | No FRR implementation. | Until FRR implements (unlikely near-term). |
| Micro-BFD (RFC 7130) | Not in FRR bfdd. | Until FRR implements. |
| Ethernet OAM / TWAMP / STAMP | Not FRR. SP-facing niche. | **Likely permanent** for enterprise scope. |
| All vendor-proprietary control planes | vPC/MLAG peer-link, CDP, VTP, GLBP, ACI policy, NSX, FabricPath, SD-WAN (OMP). | **Permanent** — no standards path, no FRR path. |
| Data-plane performance | Throughput, packet rate, latency, jitter, queuing delay, microburst, TCP congestion dynamics. | **Permanent.** Substrate-dependent. |
| Physical-layer | Transceiver degradation, DOM/DDM, fiber effects, BER, signal integrity, auto-negotiation timing. | **Permanent.** Physics. |
| Timing-precise | PTP/NTP hardware timestamping, absolute convergence ms, ASIC BFD detection, line-rate policing. | **Permanent.** Physics. |

---

## Next Step

This document defines the theoretical universal set. Stage 2 subjects this to the Batfish implementation validation cycle — testing each element against what Batfish can actually extract, what FRR can actually execute, and what the pipeline can actually deliver. What survives that validation becomes the implementation-verified universal set, which is what the Entity Store gets validated against and what the compression math operates on.
