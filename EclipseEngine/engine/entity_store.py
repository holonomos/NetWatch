"""EclipseEngine Entity Store — shared type definitions.

Every component in the pipeline reads and writes these types. Getting
them wrong propagates to everything downstream. Each type traces to
the specification documents:

    Stage 1-4:  State Space Stage {1-4}.md
    CompEng:    Blueprints/COMPENG/Compression_Engine_Build.md
    Cathedral:  Blueprints/Cathedral/Cathedral_Build.md
    MirrorBox:  Blueprints/mirrbox/MirrorBox_Build.md
    ConvDiag:   Blueprints/convd/ConvergenceDiagnostic_Build.md

Types are organized by layer:
    1. Enums and primitives
    2. Fidelity and confidence tags
    3. Directives (Stage 4 → Compression Engine)
    4. M_verified entities (Stage 3 output)
    5. Compression Engine output (shared downstream)
    6. Cathedral output (shared downstream)
    7. Mirror Box output (shared downstream)
    8. Convergence Diagnostic output (shared downstream)
"""

from __future__ import annotations

import enum
from dataclasses import dataclass, field
from typing import Any, Optional


# ═══════════════════════════════════════════════════════════════════════
# 1. ENUMS AND PRIMITIVES
# ═══════════════════════════════════════════════════════════════════════


class Classification(enum.Enum):
    """Fidelity classification for a single field or predicate.

    Ref: Stage 3 §Pass 1 — Syntactic Evaluation
    """
    C = "confirmed"       # Full fidelity — behavior matches production
    K = "constrained"     # Degraded fidelity — documented limitation
    R = "rejected"        # Cannot be faithfully reproduced


class Disposition(enum.Enum):
    """Pipeline-level qualification result.

    Ref: Stage 4 — Qualification Gate
    """
    GREEN = "green"       # Pipeline proceeds with full confidence
    YELLOW = "yellow"     # Pipeline proceeds with documented constraints
    RED = "red"           # Pipeline halts — Tier 0 rejection


class ExtractionConfidence(enum.Enum):
    """Per-field extraction quality from Batfish.

    Ref: Compression Engine Build §Module 1
    """
    BULLET = "full"                 # Direct extraction, verified
    HALF_BULLET = "partial"         # Extracted with caveats
    CIRCLE = "supplemental"         # Supplemental source required


class DirectiveType(enum.Enum):
    """Types of qualification directives from Stage 4.

    Ref: Stage 4 §Directive Generation
    Processing order: force_singleton → field_exclusion →
                      structural_caveat → analytical_degradation
    """
    FORCE_SINGLETON = "force_singleton"
    FIELD_EXCLUSION = "field_exclusion"
    STRUCTURAL_CAVEAT = "structural_caveat"
    ANALYTICAL_DEGRADATION = "analytical_degradation"


class EdgeType(enum.Enum):
    """Types of edges in the topology graph.

    Ref: Entity Store §Edge Type Taxonomy
    """
    BGP_SESSION = "bgp_session"
    OSPF_ADJACENCY = "ospf_adjacency"
    L1_PHYSICAL = "l1_physical"
    L3_LOGICAL = "l3_logical"
    MLAG_PEER = "mlag_peer"


class BGPPeerType(enum.Enum):
    """BGP session type, determined by ASN comparison.

    Ref: Cathedral Build §Module 3
    """
    EBGP = "ebgp"
    IBGP = "ibgp"


class BGPFSMState(enum.Enum):
    """BGP Finite State Machine states per RFC 4271 §8.2.2.

    Ref: Stage 1 §1.1 (FSM Family 1)
    """
    IDLE = "Idle"
    CONNECT = "Connect"
    ACTIVE = "Active"
    OPEN_SENT = "OpenSent"
    OPEN_CONFIRM = "OpenConfirm"
    ESTABLISHED = "Established"


class CauseCategory(enum.Enum):
    """Convergence Diagnostic breach cause classification.

    Ref: Convergence Diagnostic Build §Module 3
    Tier 1 triage order: IMPORT_ERROR → SIGNATURE_DEFICIENCY →
                         CATHEDRAL_MODEL_ERROR → EMULATION_DIVERGENCE
    Tier 2 triage order: DEFAULTED_TIMERS → NONLINEAR_SCALING →
                         TIMER_INTERACTION
    """
    # Tier 1 causes
    IMPORT_ERROR = "import_error"
    SIGNATURE_DEFICIENCY = "signature_deficiency"
    CATHEDRAL_MODEL_ERROR = "cathedral_model_error"
    EMULATION_DIVERGENCE = "emulation_divergence"
    UNKNOWN_TIER1 = "unknown_tier1"

    # Tier 2 causes
    DEFAULTED_TIMERS = "defaulted_timers"
    NONLINEAR_SCALING = "nonlinear_scaling"
    TIMER_INTERACTION = "timer_interaction"
    UNKNOWN_TIER2 = "unknown_tier2"


class Severity(enum.Enum):
    """Breach severity levels.

    Ref: Convergence Diagnostic Build §Module 3 — Severity Table
    """
    CRITICAL = "critical"     # IMPORT_ERROR, SIGNATURE_DEFICIENCY
    HIGH = "high"             # CATHEDRAL_MODEL_ERROR
    MEDIUM = "medium"         # EMULATION_DIVERGENCE, DEFAULTED_TIMERS
    LOW = "low"               # NONLINEAR_SCALING, TIMER_INTERACTION


class PerturbationType(enum.Enum):
    """Types of perturbation events for Cathedral simulation.

    Ref: Cathedral Build §Module 5
    """
    LINK_DOWN = "link_down"
    NODE_DOWN = "node_down"
    CONFIG_CHANGE = "config_change"


# ═══════════════════════════════════════════════════════════════════════
# 2. FIDELITY AND CONFIDENCE TAGS
# ═══════════════════════════════════════════════════════════════════════


@dataclass(frozen=True)
class FidelityTag:
    """Per-field fidelity classification with full provenance.

    Attached to every field in M_verified. No field may have tag=None.

    Ref: Stage 3 §Pass 2 — Semantic Correction
    Invariant: conflict resolution is most-restrictive-wins (R > K > C).
    """
    classification: Classification
    source_predicate: str                          # e.g., "FF-1.3.01"
    annotation: str = ""                           # constraint/rejection reason
    semantic_chain: tuple[str, ...] = ()           # traceable dependency chain
    device_scope: frozenset[str] = frozenset()     # which devices this applies to

    def is_confirmed(self) -> bool:
        return self.classification == Classification.C

    def is_constrained(self) -> bool:
        return self.classification == Classification.K

    def is_rejected(self) -> bool:
        return self.classification == Classification.R


@dataclass(frozen=True)
class CapabilityTag:
    """Snapshot-level capability classification.

    Ref: Stage 3 — checked by Compression Engine before Batfish queries.
    """
    capability_name: str        # e.g., "differential_reachability"
    classification: Classification
    source_predicate: str
    annotation: str = ""


# ═══════════════════════════════════════════════════════════════════════
# 3. DIRECTIVES (Stage 4 → Compression Engine)
# ═══════════════════════════════════════════════════════════════════════


@dataclass(frozen=True)
class Directive:
    """Qualification directive from Stage 4 to Compression Engine.

    Ref: Stage 4 §Directive Generation
    Processing order is mandatory: force_singleton first, field_exclusion
    second, structural_caveat third, analytical_degradation passthrough.
    """
    directive_type: DirectiveType
    source_predicate: str                   # must be in 97-predicate set
    source_tier: int                        # 0 | 1 | 2
    classification: Classification          # K or R
    affected_devices: frozenset[str]        # device hostnames
    affected_fields: frozenset[tuple[str, str]]  # (relation_name, field_name)
    required_behavior: str = ""
    annotation: str = ""
    semantic_chain: tuple[str, ...] = ()


# ═══════════════════════════════════════════════════════════════════════
# 4. M_VERIFIED ENTITIES (Stage 3 output)
# ═══════════════════════════════════════════════════════════════════════


@dataclass
class TaggedValue:
    """A value with its fidelity tag. Every extractable field uses this.

    Ref: Entity Store — per-field tagging scheme.
    """
    value: Any
    tag: FidelityTag


@dataclass
class Interface:
    """A single network interface on a device."""
    name: str
    ip_address: Optional[str] = None       # CIDR notation
    admin_up: bool = True
    ospf_area: Optional[int] = None
    ospf_network_type: Optional[str] = None  # "point-to-point" | "broadcast"
    description: str = ""


@dataclass
class BgpPeer:
    """A single BGP peer configuration."""
    peer_ip: str
    peer_asn: int
    local_asn: int
    peer_type: BGPPeerType = BGPPeerType.EBGP
    update_source: Optional[str] = None      # loopback interface name
    next_hop_self: bool = False
    rr_client: bool = False
    address_families: list[str] = field(default_factory=lambda: ["ipv4_unicast"])
    inbound_policy: Optional[str] = None     # route-map name
    outbound_policy: Optional[str] = None    # route-map name
    bfd_enabled: bool = False
    description: str = ""


@dataclass
class OspfInterface:
    """OSPF configuration on a specific interface."""
    interface_name: str
    area: int = 0
    network_type: str = "point-to-point"
    cost: Optional[int] = None
    passive: bool = False


@dataclass
class VRF:
    """VRF configuration."""
    name: str
    rd: Optional[str] = None                  # Route Distinguisher
    rt_import: list[str] = field(default_factory=list)
    rt_export: list[str] = field(default_factory=list)


@dataclass
class StructureDefinition:
    """A named routing policy structure (route-map, prefix-list, etc.)."""
    structure_type: str    # "route-map" | "prefix-list" | "community-list" | "as-path-acl"
    name: str
    content: Any = None    # Vendor-normalized representation from Batfish


@dataclass
class Device:
    """A single network device in M_verified.

    Every leaf field carries a FidelityTag via TaggedValue.

    Ref: Compression Engine Build §Device
    Owner: Stage 3 (M_verified construction)
    Consumed by: Compression Engine, Cathedral, Mirror Box, Convergence Diagnostic
    """
    hostname: str
    parse_status: str = "PASSED"               # PASSED | PARTIALLY_UNRECOGNIZED | FAILED
    vendor_class: str = ""                      # "cisco_ios" | "cisco_nxos" | "juniper" | "arista" | "frr"
    config_format: str = ""

    interfaces: list[Interface] = field(default_factory=list)
    bgp_asn: Optional[int] = None
    bgp_router_id: Optional[str] = None
    bgp_peers: list[BgpPeer] = field(default_factory=list)
    ospf_process: Optional[dict] = None        # OSPF process config
    ospf_interfaces: list[OspfInterface] = field(default_factory=list)
    vrfs: list[VRF] = field(default_factory=list)
    static_routes: list[dict] = field(default_factory=list)  # [{prefix, nexthop, ad}]
    named_structures: dict[str, StructureDefinition] = field(default_factory=dict)

    # Per-field fidelity tags
    field_tags: dict[str, FidelityTag] = field(default_factory=dict)

    # Parse quality
    init_issues: list[str] = field(default_factory=list)
    undefined_refs: list[str] = field(default_factory=list)
    parse_warnings: list[str] = field(default_factory=list)


@dataclass
class Edge:
    """A single edge in M_verified.

    Ref: Entity Store §Edge
    """
    edge_type: EdgeType
    source_device: str
    source_interface: str
    target_device: str
    target_interface: str
    attributes: dict[str, TaggedValue] = field(default_factory=dict)


@dataclass
class MVerified:
    """The complete verified topology database.

    Output of Stage 3. Input to Stage 4 and Compression Engine.

    Ref: Stage 3 §Output
    Invariant: every field on every device has a FidelityTag.
    """
    devices: dict[str, Device] = field(default_factory=dict)
    edges: list[Edge] = field(default_factory=list)
    capability_tags: list[CapabilityTag] = field(default_factory=list)
    evaluation_log: list[str] = field(default_factory=list)

    # Per-predicate classification
    predicate_results: dict[str, Classification] = field(default_factory=dict)


@dataclass
class QualificationResult:
    """Output of Stage 4 — Qualification Gate.

    Ref: Stage 4 §Disposition Function Q
    """
    disposition: Disposition
    directives: list[Directive] = field(default_factory=list)
    tier_assignments: dict[str, int] = field(default_factory=dict)  # predicate_id → tier
    predicate_classifications: dict[str, Classification] = field(default_factory=dict)


# ═══════════════════════════════════════════════════════════════════════
# 5. COMPRESSION ENGINE OUTPUT (shared downstream)
# ═══════════════════════════════════════════════════════════════════════


@dataclass
class CompressedVertex:
    """A single vertex in the compressed graph G_c.

    Ref: Compression Engine Build §Module 7
    """
    hostname: str
    cell_id: int
    represents: frozenset[str]             # all production devices represented
    configuration: Optional[Device] = None  # full device config
    metadata: dict[str, Any] = field(default_factory=dict)


@dataclass
class CompressedEdge:
    """A single edge in the compressed graph G_c.

    Ref: Compression Engine Build §Module 7
    """
    source: str
    target: str
    edge_type: EdgeType
    attributes: dict[str, Any] = field(default_factory=dict)
    production_edge_ref: Optional[tuple[str, str]] = None  # original (source, target)


@dataclass
class CompressedGraph:
    """The compressed graph G_c — output of the Compression Engine.

    Ref: Compression Engine Build §Module 8
    Consumed by: VM Instantiation, Cathedral (b_ij), Mirror Box (via π)
    """
    vertices: dict[str, CompressedVertex] = field(default_factory=dict)
    edges: list[CompressedEdge] = field(default_factory=list)
    b_ij: dict[tuple[int, int], int] = field(default_factory=dict)  # inter-cell connectivity
    partition: dict[int, frozenset[str]] = field(default_factory=dict)  # cell_id → member hostnames
    cell_sizes: dict[int, int] = field(default_factory=dict)  # cell_id → |C_i|
    device_to_cell: dict[str, int] = field(default_factory=dict)  # hostname → cell_id
    representative_to_cell: dict[str, int] = field(default_factory=dict)  # rep hostname → cell_id


@dataclass
class ExtractionConfidenceLedger:
    """Per-device per-field confidence from Compression Engine Module 1.

    Shared as Artifact 6 — consumed by Cathedral, Mirror Box, Convergence Diagnostic.

    Ref: Compression Engine Build §Module 1
    Invariant INV-1.1: every device has exactly one entry.
    """
    entries: dict[str, DeviceConfidenceEntry] = field(default_factory=dict)
    singleton_forced: frozenset[str] = frozenset()
    vendor_class_exclusions: dict[str, frozenset[str]] = field(default_factory=dict)


@dataclass
class DeviceConfidenceEntry:
    """Per-device extraction confidence.

    Ref: Compression Engine Build §Module 1
    """
    hostname: str
    parse_status: str
    vendor_class: str
    gate_result: str = "PASSED"       # PASSED | FAILED_PARSE | FAILED_INIT | FAILED_SINGLETON_FORCED
    gate_failure_reason: str = ""
    field_confidence: dict[str, FieldConfidence] = field(default_factory=dict)


@dataclass
class FieldConfidence:
    """Per-field extraction confidence.

    Ref: Compression Engine Build §Module 1
    """
    field_name: str
    extraction_tag: ExtractionConfidence = ExtractionConfidence.BULLET
    fidelity_tag: Classification = Classification.C
    included_in_sigma: bool = True
    exclusion_reason: str = ""


# ═══════════════════════════════════════════════════════════════════════
# 6. CATHEDRAL OUTPUT (shared downstream)
# ═══════════════════════════════════════════════════════════════════════


@dataclass
class TimerProvenance:
    """Tracks whether a timer value was extracted or defaulted.

    Ref: Cathedral Build §Module 1, §Module 9
    """
    timer_name: str
    value: float
    extraction_tag: ExtractionConfidence = ExtractionConfidence.BULLET
    is_defaulted: bool = False
    default_source: str = ""          # "RFC 4271" | "FRR 10.6.0" | etc.
    confidence_impact: str = ""


@dataclass
class ConvergenceEvent:
    """A single event in a convergence sequence.

    Tier 1 — ordering is exact (scale-invariant).

    Ref: Cathedral Build §Module 5
    Owner: Cathedral (produces)
    Consumed by: Mirror Box (replicates), Convergence Diagnostic (compares)
    """
    sequence_number: int
    device: str
    protocol: str                     # "bgp" | "ospf" | "bfd"
    event_type: str                   # "session_down" | "withdraw" | "update" | "lsa_flood"
    detail: str = ""
    caused_by: Optional[int] = None   # sequence_number of the causing event


@dataclass
class TimedEvent:
    """A convergence event with timing information.

    Tier 2 — timing is corrected by scaling factors.

    Ref: Cathedral Build §Module 5
    """
    timestamp: float                  # seconds from perturbation
    event: ConvergenceEvent
    timer_provenance: list[TimerProvenance] = field(default_factory=list)


@dataclass
class ScalingCorrections:
    """Deterministic scaling factors from Cathedral.

    Ref: Cathedral Build §Module 6
    Owner: Cathedral
    Consumed by: Mirror Box (applies corrections)
    """
    diameter_ratio: float = 1.0       # D_prod / D_compressed (Clos: always 1.0)
    cell_size_multipliers: dict[int, int] = field(default_factory=dict)  # cell_id → |C_i|
    spf_scaling_factor: float = 1.0   # (N_prod / N_comp) × ln(N_prod / N_comp)
    capacity_ratios: dict[tuple[int, int], float] = field(default_factory=dict)
    diameter_prod: int = 0
    diameter_compressed: int = 0
    n_prod: int = 0
    n_compressed: int = 0


@dataclass
class BestPathTrace:
    """BGP best-path selection trace for a single (device, prefix).

    Ref: Cathedral Build §Module 3 — RFC 4271 §8
    """
    prefix: str
    device: str
    candidates: list[dict] = field(default_factory=list)
    winner: Optional[dict] = None
    deciding_step: str = ""
    steps_evaluated: list[dict] = field(default_factory=list)


@dataclass
class HotPotatoDivergence:
    """Detected hot-potato routing divergence within an equivalence class.

    Tier 4 — Cathedral-only, no emulation validation.

    Ref: Cathedral Build §Module 7
    """
    cell_id: int
    divergent_devices: list[dict] = field(default_factory=list)
    affected_prefixes: list[str] = field(default_factory=list)
    batfish_confirmed: bool = False


@dataclass
class PredictionConfidence:
    """Confidence metadata for a Cathedral prediction.

    Ref: Cathedral Build §Module 9
    """
    prediction_id: str
    tier: int                                  # 1, 2, or 4
    defaulted_timers: list[TimerProvenance] = field(default_factory=list)
    extraction_tags: list[str] = field(default_factory=list)
    confidence_level: str = "full"             # full | default-assumed | partial | supplemental-required
    confidence_detail: str = ""


@dataclass
class PerturbationResult:
    """Complete result of a Cathedral perturbation simulation.

    Ref: Cathedral Build §Module 5
    Owner: Cathedral
    Consumed by: Convergence Diagnostic (comparisons)
    """
    perturbation_type: PerturbationType
    target: str
    convergence_sequence: list[ConvergenceEvent] = field(default_factory=list)  # Tier 1
    convergence_timing: list[TimedEvent] = field(default_factory=list)          # Tier 2
    affected_devices: frozenset[str] = frozenset()
    scaling_corrections: Optional[ScalingCorrections] = None


@dataclass
class CathedralOutput:
    """Complete output of the Cathedral analytical model.

    Ref: Cathedral Build §Module 9
    Owner: Cathedral
    Consumed by: Convergence Diagnostic, Certification Report
    """
    steady_state_ribs: dict[str, dict] = field(default_factory=dict)
    best_path_traces: dict[tuple[str, str], BestPathTrace] = field(default_factory=dict)
    reachability_matrix: dict[tuple[str, str], bool] = field(default_factory=dict)
    perturbation_results: list[PerturbationResult] = field(default_factory=list)
    scaling_corrections: Optional[ScalingCorrections] = None
    hot_potato_divergences: list[HotPotatoDivergence] = field(default_factory=list)
    cascade_analyses: list[dict] = field(default_factory=list)     # Tier 4
    prediction_confidence: dict[str, PredictionConfidence] = field(default_factory=dict)
    analytical_degradation_domains: list[str] = field(default_factory=list)


# ═══════════════════════════════════════════════════════════════════════
# 7. MIRROR BOX OUTPUT (shared downstream)
# ═══════════════════════════════════════════════════════════════════════


@dataclass
class TelemetrySample:
    """A single telemetry measurement from the compressed emulation.

    Ref: Mirror Box Build §Module 1
    """
    timestamp: float
    device: str                    # hostname of compressed-graph representative
    metric_name: str
    metric_value: Any
    metric_tier: int               # 1 or 2


@dataclass
class DeviceProjection:
    """Projected state for a single production device.

    Ref: Mirror Box Build §Module 2
    Constraint: every production device has a projection.
    """
    hostname: str
    cell_id: int
    representative: str
    bgp_sessions: dict[str, str] = field(default_factory=dict)    # peer → state
    ospf_adjacencies: dict[str, str] = field(default_factory=dict)
    convergence_events: list[ConvergenceEvent] = field(default_factory=list)
    projection_tier: int = 1       # always 1 for direct replications
    last_updated: float = 0.0


@dataclass
class ScaledMetric:
    """A Tier 2 metric with deterministic correction applied.

    Ref: Mirror Box Build §Module 3
    Invariant: scaled_value = raw_value × correction_factor
    """
    metric_name: str
    raw_value: float
    correction_factor: float
    scaled_value: float            # raw × correction — enforced at construction
    cell_id: int
    projection_tier: int = 2       # always 2

    def __post_init__(self):
        expected = self.raw_value * self.correction_factor
        if abs(self.scaled_value - expected) > 1e-10:
            raise ValueError(
                f"ScaledMetric invariant violated: "
                f"{self.scaled_value} != {self.raw_value} × {self.correction_factor} "
                f"(expected {expected})"
            )


# ═══════════════════════════════════════════════════════════════════════
# 8. CONVERGENCE DIAGNOSTIC OUTPUT (shared downstream)
# ═══════════════════════════════════════════════════════════════════════


@dataclass
class DeltaRecord:
    """Delta between Cathedral prediction and Mirror Box projection.

    Ref: Convergence Diagnostic Build §Module 1
    Constraint: Tier 1 discrete delta is binary (0 = match, 1 = mismatch).
    """
    metric_id: str
    tier: int                      # 1 or 2
    cathedral_value: Any
    mirrorbox_value: Any
    delta: float                   # |cathedral - mirrorbox|
    timestamp: float = 0.0


@dataclass
class Verdict:
    """Threshold verdict for a single metric comparison.

    Ref: Convergence Diagnostic Build §Module 2
    Constraint: Tier 1 threshold is exactly 0.0.
    Constraint: Tier 2 threshold = α × |correction_factor - 1| × base_value.
    """
    metric_id: str
    tier: int
    threshold: float               # 0.0 for Tier 1
    delta: float
    result: str                    # "PASS" | "BREACH"
    cause: Optional[CauseCategory] = None
    severity: Optional[Severity] = None
    triage_detail: str = ""
    timestamp: float = 0.0

    def __post_init__(self):
        if self.tier == 1 and self.threshold != 0.0:
            raise ValueError(
                f"Tier 1 threshold must be exactly 0.0, got {self.threshold}"
            )


@dataclass
class BreachRecord:
    """A recorded breach with optional resolution.

    Ref: Convergence Diagnostic Build §Module 4
    """
    verdict: Verdict
    resolution: Optional[str] = None
    resolved_at: Optional[float] = None


@dataclass
class Tier4Record:
    """Passthrough for Cathedral-only predictions (no empirical validation).

    Ref: Convergence Diagnostic Build §Module 4
    """
    prediction_type: str           # "hot_potato_divergence" | "cascade_analysis"
    content: Any = None
    tag: str = "analytical_only_no_empirical_validation"
    timestamp: float = 0.0
