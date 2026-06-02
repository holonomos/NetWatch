#!/usr/bin/env bash
# ==========================================================================
# serve.sh — Start/stop the local artifact HTTP server
# ==========================================================================
# Serves artifacts/ over HTTP so VMs can install packages and pull binaries
# without internet access.
#
# Binds to 0.0.0.0 so both bake VMs (vagrant-libvirt NAT, ~192.168.121.x)
# and regular VMs (netwatch-mgmt, 192.168.0.x) can reach the host.
#
# Usage:
#   bash scripts/artifacts/serve.sh start    # start serving
#   bash scripts/artifacts/serve.sh stop     # stop serving
#   bash scripts/artifacts/serve.sh status   # check if running
# ==========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACTS_DIR="$PROJECT_ROOT/artifacts"
PID_FILE="$ARTIFACTS_DIR/.serve.pid"
LOG_FILE="$ARTIFACTS_DIR/.serve.log"

BIND_IP="0.0.0.0"
PORT="8080"

case "${1:-}" in
  start)
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      echo "Artifact server already running (PID $(cat "$PID_FILE"))"
      exit 0
    fi

    if [ ! -d "$ARTIFACTS_DIR/rpms/repodata" ]; then
      echo "ERROR: Artifact depot not built yet. Run: make artifacts-build"
      exit 1
    fi

    echo "Starting artifact server on http://${BIND_IP}:${PORT}/"

    # ThreadingHTTPServer handles concurrent requests from multiple VMs
    python3 -c "
import os, sys
from http.server import SimpleHTTPRequestHandler
from socketserver import ThreadingMixIn
from http.server import HTTPServer

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True

os.chdir('${ARTIFACTS_DIR}')
server = ThreadedHTTPServer(('${BIND_IP}', ${PORT}), SimpleHTTPRequestHandler)
print(f'Serving {os.getcwd()} on http://${BIND_IP}:${PORT}/', flush=True)
server.serve_forever()
" > "$LOG_FILE" 2>&1 &

    echo $! > "$PID_FILE"
    sleep 1

    if kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      echo "  PID: $(cat "$PID_FILE")"
      echo "  Log: $LOG_FILE"
      echo "  RPMs:     http://HOST_IP:${PORT}/rpms/"
      echo "  Binaries: http://HOST_IP:${PORT}/binaries/"
    else
      echo "ERROR: Server failed to start. Check $LOG_FILE"
      cat "$LOG_FILE"
      rm -f "$PID_FILE"
      exit 1
    fi
    ;;

  stop)
    if [ -f "$PID_FILE" ]; then
      PID=$(cat "$PID_FILE")
      if kill -0 "$PID" 2>/dev/null; then
        kill "$PID"
        echo "Artifact server stopped (PID $PID)"
      else
        echo "Artifact server not running (stale PID file)"
      fi
      rm -f "$PID_FILE"
    else
      echo "Artifact server not running (no PID file)"
    fi
    ;;

  status)
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      echo "Artifact server running (PID $(cat "$PID_FILE")) on http://${BIND_IP}:${PORT}/"
    else
      echo "Artifact server not running"
      exit 1
    fi
    ;;

  *)
    echo "Usage: $0 {start|stop|status}"
    exit 1
    ;;
esac
