#!/usr/bin/env python3
"""NetWatch Topology Import — CLI entry point.

Usage:
    python3 -m importer.import --snapshot <name>
    python3 importer/import.py --snapshot <name>

Expects configs in:  importer/input/<name>/configs/<hostname>.cfg
Optional hints:      importer/input/<name>/hints.yml

Outputs:
    importer/output/<name>/topology.yml
    importer/output/<name>/fragments/<device>.conf
    importer/output/<name>/mapping.yml
    importer/output/<name>/report.txt
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import yaml

# Ensure the project root is on the path
PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

from importer.batfish_client import ensure_batfish_running, init_snapshot
from importer.batfish_extract import extract_topology
from importer.hints_schema import load_hints
from importer.ip_remapper import remap_ips
from importer.model import ImportReport
from importer.policy_extractor import extract_fragments
from importer.role_inference import infer_roles
from importer.scale_mapper import map_to_netwatch
from importer.topology_emitter import emit_topology


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Import production network configs into NetWatch topology.yml",
    )
    parser.add_argument(
        "--snapshot", required=True,
        help="Snapshot name (matches importer/input/<name>/)",
    )
    parser.add_argument(
        "--input-dir", default=None,
        help="Override input directory (default: importer/input/<snapshot>)",
    )
    parser.add_argument(
        "--output-dir", default=None,
        help="Override output directory (default: importer/output/<snapshot>)",
    )
    parser.add_argument(
        "--skip-batfish", action="store_true",
        help="Skip Batfish container management (assume already running)",
    )
    parser.add_argument(
        "--remap-ips", action="store_true",
        help="Remap production IPs to NetWatch scheme (default: use production IPs verbatim)",
    )
    args = parser.parse_args()

    # Resolve paths
    importer_root = Path(__file__).resolve().parent
    input_dir = Path(args.input_dir) if args.input_dir else importer_root / "input" / args.snapshot
    output_dir = Path(args.output_dir) if args.output_dir else importer_root / "output" / args.snapshot
    hints_path = input_dir / "hints.yml"
    fragment_dir = output_dir / "fragments"

    # Validate input
    configs_dir = input_dir / "configs"
    if not configs_dir.is_dir():
        print(f"ERROR: Config directory not found: {configs_dir}", file=sys.stderr)
        print(f"Place device configs in: {configs_dir}/<hostname>.cfg", file=sys.stderr)
        sys.exit(1)

    config_files = list(configs_dir.iterdir())
    if not config_files:
        print(f"ERROR: No config files found in {configs_dir}", file=sys.stderr)
        sys.exit(1)

    print(f"=== NetWatch Topology Import ===")
    print(f"Snapshot:  {args.snapshot}")
    print(f"Input:     {input_dir}")
    print(f"Output:    {output_dir}")
    print(f"Configs:   {len(config_files)} files")
    print()

    # ------------------------------------------------------------------
    # Stage 1: Batfish extraction
    # ------------------------------------------------------------------
    if not args.skip_batfish:
        ensure_batfish_running()

    bf = init_snapshot(input_dir, args.snapshot)
    topo = extract_topology(bf)

    # ------------------------------------------------------------------
    # Stage 2: Role inference
    # ------------------------------------------------------------------
    hints = load_hints(hints_path)
    infer_roles(topo, hints)

    # ------------------------------------------------------------------
    # Stage 3: Scale mapping
    # ------------------------------------------------------------------
    map_to_netwatch(topo)

    # ------------------------------------------------------------------
    # Stage 4: IP remapping (optional — default: use production IPs)
    # ------------------------------------------------------------------
    ip_mappings = None
    if args.remap_ips:
        ip_mappings = remap_ips(topo)
        print(f"[remap] Remapped {len(ip_mappings)} IPs to NetWatch scheme")
    else:
        print("[remap] Using production IPs verbatim (--remap-ips not set)")

    # ------------------------------------------------------------------
    # Stage 5: Policy extraction (verbatim production IPs by default)
    # ------------------------------------------------------------------
    policy_count = extract_fragments(topo, ip_mappings, fragment_dir)

    # ------------------------------------------------------------------
    # Stage 6: Emit topology.yml
    # ------------------------------------------------------------------
    topology_path = output_dir / "topology.yml"
    emit_topology(topo, ip_mappings or [], topology_path, fragment_dir, args.snapshot)

    # ------------------------------------------------------------------
    # Stage 7: Write mapping and report
    # ------------------------------------------------------------------
    report = ImportReport(snapshot_name=args.snapshot)
    report.total_devices = len(topo.devices)
    report.mapped_devices = len(topo.active_devices())
    report.dropped_devices = sum(1 for d in topo.devices.values() if d.dropped)
    report.total_edges = len(topo.edges)
    report.mapped_edges = sum(
        1 for e in topo.edges
        if not topo.devices.get(e.a_hostname, type("", (), {"dropped": True})).dropped
        and not topo.devices.get(e.b_hostname, type("", (), {"dropped": True})).dropped
    )
    report.total_policies = policy_count
    report.ip_mappings = ip_mappings or []

    for device in topo.active_devices():
        report.device_mapping[device.hostname] = device.netwatch_name or device.hostname

    for device in topo.devices.values():
        if device.dropped:
            report.add_warning(f"Dropped {device.hostname}: {device.drop_reason}")

    # Write mapping.yml
    mapping_path = output_dir / "mapping.yml"
    mapping_data = {
        "device_mapping": report.device_mapping,
        "dropped": {
            d.hostname: d.drop_reason
            for d in topo.devices.values() if d.dropped
        },
        "ip_mapping": [
            {"prod": m.prod_ip, "netwatch": m.netwatch_ip, "device": m.device, "purpose": m.purpose}
            for m in ip_mappings[:50]  # Cap at 50 for readability
        ],
    }
    mapping_path.parent.mkdir(parents=True, exist_ok=True)
    with open(mapping_path, "w") as f:
        yaml.dump(mapping_data, f, default_flow_style=False, sort_keys=False)

    # Write report
    report_path = output_dir / "report.txt"
    report_path.write_text(report.render())

    # ------------------------------------------------------------------
    # Summary
    # ------------------------------------------------------------------
    print()
    print(f"=== Import Complete ===")
    print(f"Topology:  {topology_path}")
    print(f"Fragments: {fragment_dir}/ ({policy_count} files)")
    print(f"Mapping:   {mapping_path}")
    print(f"Report:    {report_path}")
    print()
    print(f"Devices: {report.mapped_devices}/{report.total_devices} mapped")
    print(f"Edges:   {report.mapped_edges}/{report.total_edges} mapped")
    print(f"Policies: {report.total_policies} extracted")
    if report.warnings:
        print(f"Warnings: {len(report.warnings)}")
    print()
    print("Next steps:")
    print(f"  1. Review {topology_path}")
    print(f"  2. Review {report_path} for warnings")
    print(f"  3. Copy topology.yml to project root:")
    print(f"     cp {topology_path} topology.yml")
    print(f"  4. Regenerate configs: make generate")
    print(f"  5. Bring up: make vms && make up")


if __name__ == "__main__":
    main()
