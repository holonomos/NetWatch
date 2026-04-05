"""Stage 4 — Qualification Gate.

Implements the monotone decision function Q: {C,K,R}^97 → {GREEN,YELLOW,RED} × DirectiveSet.

Reads the semantically-corrected partition from Stage 3, applies tier-based
disposition rules, and emits a product disposition plus constraint propagation
directives for the compression engine.

No semantic analysis here — that was resolved in Stage 3 Pass 2. Stage 4
reads corrected classifications at face value.

Ref: State Space Stage 4.md v4.3
"""

from __future__ import annotations

from .entity_store import (
    Classification,
    Directive,
    DirectiveType,
    Disposition,
    FidelityTag,
    MVerified,
    QualificationResult,
)
from .predicates import ALL_PREDICATES, PREDICATE_BY_ID, PredicateSpec


def qualify(
    predicate_results: dict[str, Classification],
    m_verified: MVerified,
) -> QualificationResult:
    """Run the Stage 4 Qualification Gate.

    Args:
        predicate_results: P_corrected from Stage 3 — predicate_id → classification.
        m_verified: Tagged topology DB from Stage 3.

    Returns:
        QualificationResult with disposition and directive set.

    Ref: Stage 4 §Complete Stage 4 Algorithm
    """
    # Step 1: Assign tiers
    tier_assignments = {p.predicate_id: p.tier for p in ALL_PREDICATES}

    # Step 2: Compute disposition
    disposition = _compute_disposition(predicate_results, tier_assignments)

    # Step 3: Generate directives (only for YELLOW)
    directives: list[Directive] = []
    if disposition == Disposition.YELLOW:
        directives = _generate_directives(predicate_results, m_verified)

    return QualificationResult(
        disposition=disposition,
        directives=directives,
        tier_assignments=tier_assignments,
        predicate_classifications=dict(predicate_results),
    )


def _compute_disposition(
    predicate_results: dict[str, Classification],
    tier_assignments: dict[str, int],
) -> Disposition:
    """Apply tier-based disposition rules.

    Ref: Stage 4 §Disposition Rules — Final Disposition Computation

    ```
    disposition = GREEN
    for each σᵢ ∈ Σ:
        tier = T(σᵢ)
        classification = P_corrected(σᵢ)
        if tier = 0 and classification = R: disposition = RED
        if tier = 0 and classification = K: disposition = max(disposition, YELLOW)
        if tier = 1 and classification ∈ {K, R}: disposition = max(disposition, YELLOW)
        if tier = 2 and classification = R: disposition = max(disposition, YELLOW)
    return disposition
    ```

    Ordering: GREEN < YELLOW < RED.
    """
    # Ordering for max()
    _order = {Disposition.GREEN: 0, Disposition.YELLOW: 1, Disposition.RED: 2}

    disposition = Disposition.GREEN

    for predicate_id, classification in predicate_results.items():
        tier = tier_assignments.get(predicate_id)
        if tier is None:
            continue  # Unknown predicate — skip

        if tier == 0 and classification == Classification.R:
            disposition = Disposition.RED
            # RED is terminal — can skip remaining but continue for directive generation

        if tier == 0 and classification == Classification.K:
            if _order[Disposition.YELLOW] > _order[disposition]:
                disposition = Disposition.YELLOW

        if tier == 1 and classification in (Classification.K, Classification.R):
            if _order[Disposition.YELLOW] > _order[disposition]:
                disposition = Disposition.YELLOW

        if tier == 2 and classification == Classification.R:
            if _order[Disposition.YELLOW] > _order[disposition]:
                disposition = Disposition.YELLOW

        # Tier 2 K and Tier 3 anything: no impact

    return disposition


def _generate_directives(
    predicate_results: dict[str, Classification],
    m_verified: MVerified,
) -> list[Directive]:
    """Generate constraint propagation directives for YELLOW disposition.

    Ref: Stage 4 §Constraint Propagation Directives — Rules D1-D5

    Rule D1: Tier 0 K → structural_caveat
    Rule D2: Tier 1 K → field_exclusion
    Rule D3: Tier 1 R → force_singleton
    Rule D4: Tier 2 R → analytical_degradation
    Rule D5: Tier 2 K, Tier 3 anything → no directive
    """
    directives: list[Directive] = []

    for pred in ALL_PREDICATES:
        classification = predicate_results.get(pred.predicate_id)
        if classification is None:
            continue

        # Get annotation and semantic chain from M_verified if available
        annotation, semantic_chain, device_scope = _get_predicate_metadata(
            pred.predicate_id, m_verified
        )

        # Rule D1: Tier 0 K → structural_caveat
        if pred.tier == 0 and classification == Classification.K:
            directives.append(Directive(
                directive_type=DirectiveType.STRUCTURAL_CAVEAT,
                source_predicate=pred.predicate_id,
                source_tier=0,
                classification=Classification.K,
                affected_devices=device_scope,
                affected_fields=frozenset(),  # Populated from predicate-to-field mapping
                required_behavior=(
                    "All equivalence class claims involving affected devices carry "
                    "structural qualification. Partition cross-validation results for "
                    "affected devices are advisory, not definitive."
                ),
                annotation=annotation,
                semantic_chain=semantic_chain,
            ))

        # Rule D2: Tier 1 K → field_exclusion
        elif pred.tier == 1 and classification == Classification.K:
            directives.append(Directive(
                directive_type=DirectiveType.FIELD_EXCLUSION,
                source_predicate=pred.predicate_id,
                source_tier=1,
                classification=Classification.K,
                affected_devices=device_scope,
                affected_fields=frozenset(),
                required_behavior=(
                    "Exclude affected_fields from behavioral signature σ(v) for all "
                    "devices in affected_devices. Apply signature robustness rule: if "
                    "a field is excluded for any device in a vendor class, exclude it "
                    "for ALL devices in that vendor class."
                ),
                annotation=annotation,
                semantic_chain=semantic_chain,
            ))

        # Rule D3: Tier 1 R → force_singleton
        elif pred.tier == 1 and classification == Classification.R:
            directives.append(Directive(
                directive_type=DirectiveType.FORCE_SINGLETON,
                source_predicate=pred.predicate_id,
                source_tier=1,
                classification=Classification.R,
                affected_devices=device_scope,
                affected_fields=frozenset(),
                required_behavior=(
                    "Force all devices in affected_devices to singleton equivalence "
                    "classes (|Cᵢ| = 1). Do not compute behavioral signatures for "
                    "these devices."
                ),
                annotation=annotation,
                semantic_chain=semantic_chain,
            ))

        # Rule D4: Tier 2 R → analytical_degradation
        elif pred.tier == 2 and classification == Classification.R:
            directives.append(Directive(
                directive_type=DirectiveType.ANALYTICAL_DEGRADATION,
                source_predicate=pred.predicate_id,
                source_tier=2,
                classification=Classification.R,
                affected_devices=device_scope,
                affected_fields=frozenset(),
                required_behavior=(
                    "Cathedral and Mirror Box analysis for the domain covered by "
                    "source_predicate is unavailable. Compression engine is NOT affected."
                ),
                annotation=annotation,
                semantic_chain=semantic_chain,
            ))

        # Rule D5: Tier 2 K, Tier 3 anything → no directive

    return directives


def _get_predicate_metadata(
    predicate_id: str,
    m_verified: MVerified,
) -> tuple[str, tuple[str, ...], frozenset[str]]:
    """Extract annotation, semantic chain, and device scope for a predicate.

    Returns:
        (annotation, semantic_chain, device_scope)
    """
    # Default: empty metadata
    annotation = ""
    semantic_chain: tuple[str, ...] = (predicate_id,)
    device_scope: frozenset[str] = frozenset()

    # Try to find metadata from field tags in M_verified
    for hostname, device in m_verified.devices.items():
        for field_name, tag in device.field_tags.items():
            if tag.source_predicate == predicate_id:
                annotation = tag.annotation
                semantic_chain = tag.semantic_chain if tag.semantic_chain else (predicate_id,)
                # Accumulate device scope
                device_scope = device_scope | tag.device_scope | frozenset([hostname])

    return annotation, semantic_chain, device_scope
