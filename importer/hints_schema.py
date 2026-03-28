"""Load and validate hints.yml for user-provided role annotations."""

from __future__ import annotations

from pathlib import Path

import yaml


VALID_ROLES = {"border", "spine", "leaf", "server"}


def load_hints(hints_path: Path | None) -> dict:
    """Load hints.yml if it exists, otherwise return empty dict.

    Expected format:
        roles:
          dc1-border-01: border
          dc1-spine-*: spine          # glob patterns supported
        asn_roles:
          65000: border
          65001: spine
          65100-65199: leaf           # range notation
    """
    if not hints_path or not hints_path.exists():
        return {}

    with open(hints_path) as f:
        data = yaml.safe_load(f) or {}

    # Validate roles
    roles = data.get("roles", {})
    for pattern, role in roles.items():
        if role not in VALID_ROLES:
            print(f"[hints] WARNING: Invalid role '{role}' for '{pattern}' "
                  f"(valid: {VALID_ROLES})")

    # Validate asn_roles
    asn_roles = data.get("asn_roles", {})
    for asn_spec, role in asn_roles.items():
        if role not in VALID_ROLES:
            print(f"[hints] WARNING: Invalid role '{role}' for ASN '{asn_spec}' "
                  f"(valid: {VALID_ROLES})")

    print(f"[hints] Loaded {len(roles)} role hints, {len(asn_roles)} ASN hints")
    return data
