"""Batfish Docker container lifecycle and pybatfish session wrapper.

Manages the Batfish container (start/stop/reuse) and provides a
thin wrapper around pybatfish for querying network snapshots.
"""

from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

from pybatfish.client.session import Session


CONTAINER_NAME = "netwatch-batfish"
IMAGE = "batfish/batfish:latest"
BATFISH_HOST = "localhost"
BATFISH_PORT = 9997  # coordination port
BATFISH_V2_PORT = 9996


def _run(cmd: list[str], check: bool = True, capture: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        cmd,
        capture_output=capture,
        text=True,
        check=check,
    )


def _container_running() -> bool:
    """Check if the Batfish container is running."""
    result = _run(
        ["docker", "inspect", "-f", "{{.State.Running}}", CONTAINER_NAME],
        check=False,
    )
    return result.returncode == 0 and result.stdout.strip() == "true"


def _container_exists() -> bool:
    """Check if the Batfish container exists (running or stopped)."""
    result = _run(
        ["docker", "inspect", CONTAINER_NAME],
        check=False,
    )
    return result.returncode == 0


def ensure_batfish_running() -> None:
    """Start the Batfish container if not already running."""
    if _container_running():
        print(f"[batfish] Container '{CONTAINER_NAME}' already running")
        return

    if _container_exists():
        print(f"[batfish] Starting existing container '{CONTAINER_NAME}'")
        _run(["docker", "start", CONTAINER_NAME])
    else:
        print(f"[batfish] Creating and starting container '{CONTAINER_NAME}'")
        _run([
            "docker", "run", "-d",
            "--name", CONTAINER_NAME,
            "-p", f"{BATFISH_V2_PORT}:{BATFISH_V2_PORT}",
            "-p", f"{BATFISH_PORT}:{BATFISH_PORT}",
            IMAGE,
        ])

    # Wait for Batfish to be ready (up to 90s)
    print("[batfish] Waiting for Batfish to start...", end="", flush=True)
    import socket
    for i in range(90):
        time.sleep(1)
        print(".", end="", flush=True)
        try:
            sock = socket.create_connection((BATFISH_HOST, BATFISH_V2_PORT), timeout=2)
            sock.close()
            # Also verify pybatfish can connect
            Session(host=BATFISH_HOST)
            print(" ready")
            return
        except Exception:
            continue

    print(" TIMEOUT")
    print("[batfish] ERROR: Batfish did not become ready within 90s", file=sys.stderr)
    sys.exit(1)


def stop_batfish() -> None:
    """Stop the Batfish container."""
    if _container_running():
        print(f"[batfish] Stopping container '{CONTAINER_NAME}'")
        _run(["docker", "stop", CONTAINER_NAME])


def get_session() -> Session:
    """Return a pybatfish Session connected to the local Batfish instance."""
    return Session(host=BATFISH_HOST)


def init_snapshot(snapshot_dir: str | Path, name: str) -> Session:
    """Upload a snapshot to Batfish and return the session.

    Args:
        snapshot_dir: Path to directory containing configs/ subdirectory.
                      Batfish expects: <snapshot_dir>/configs/<device>.cfg
        name: Snapshot name for Batfish.

    Returns:
        pybatfish Session with the snapshot initialized.
    """
    snapshot_dir = Path(snapshot_dir)
    if not (snapshot_dir / "configs").is_dir():
        print(f"[batfish] ERROR: {snapshot_dir}/configs/ not found", file=sys.stderr)
        sys.exit(1)

    config_files = list((snapshot_dir / "configs").iterdir())
    if not config_files:
        print(f"[batfish] ERROR: No config files in {snapshot_dir}/configs/", file=sys.stderr)
        sys.exit(1)

    bf = get_session()
    bf.set_network("netwatch-import")

    print(f"[batfish] Uploading snapshot '{name}' ({len(config_files)} configs)")
    bf.init_snapshot(str(snapshot_dir), name=name, overwrite=True)
    print(f"[batfish] Snapshot '{name}' initialized")

    return bf
