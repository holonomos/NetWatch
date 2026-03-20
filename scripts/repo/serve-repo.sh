#!/usr/bin/env bash
# ==========================================================================
# serve-repo.sh — Start/stop the local package repository HTTP server
# ==========================================================================
# Serves repo/ over HTTP on the management bridge so VMs can install
# packages without internet access.
#
# Usage:
#   bash scripts/repo/serve-repo.sh start    # start serving
#   bash scripts/repo/serve-repo.sh stop     # stop serving
#   bash scripts/repo/serve-repo.sh status   # check if running
# ==========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_DIR="$PROJECT_ROOT/repo"
PID_FILE="$REPO_DIR/.serve.pid"
LOG_FILE="$REPO_DIR/.serve.log"

# Host IP on the management bridge (virbr* for netwatch-mgmt)
BIND_IP="192.168.0.1"
PORT="8080"

get_bind_ip() {
  # Dynamically resolve the host IP on the netwatch-mgmt bridge
  local bridge
  bridge=$(virsh -c qemu:///system net-info netwatch-mgmt 2>/dev/null | awk '/Bridge:/{print $2}')
  if [ -n "$bridge" ]; then
    local ip
    ip=$(ip -4 addr show "$bridge" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
    if [ -n "$ip" ]; then
      echo "$ip"
      return
    fi
  fi
  # Fallback to default
  echo "$BIND_IP"
}

case "${1:-}" in
  start)
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      echo "Repo server already running (PID $(cat "$PID_FILE"))"
      exit 0
    fi

    if [ ! -d "$REPO_DIR/fedora/repodata" ]; then
      echo "ERROR: Repository not built yet. Run: bash scripts/repo/build-repo.sh"
      exit 1
    fi

    BIND_IP=$(get_bind_ip)
    echo "Starting repo server on http://${BIND_IP}:${PORT}/"

    # ThreadingHTTPServer handles concurrent requests from multiple VMs
    python3 -c "
import os, sys
from http.server import SimpleHTTPRequestHandler
from socketserver import ThreadingMixIn
from http.server import HTTPServer

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True

os.chdir('${REPO_DIR}')
server = ThreadedHTTPServer(('${BIND_IP}', ${PORT}), SimpleHTTPRequestHandler)
print(f'Serving {os.getcwd()} on http://${BIND_IP}:${PORT}/', flush=True)
server.serve_forever()
" > "$LOG_FILE" 2>&1 &

    echo $! > "$PID_FILE"
    sleep 1

    if kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      echo "  PID: $(cat "$PID_FILE")"
      echo "  Log: $LOG_FILE"
      echo "  RPMs:     http://${BIND_IP}:${PORT}/fedora/"
      echo "  Binaries: http://${BIND_IP}:${PORT}/binaries/"
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
        echo "Repo server stopped (PID $PID)"
      else
        echo "Repo server not running (stale PID file)"
      fi
      rm -f "$PID_FILE"
    else
      echo "Repo server not running (no PID file)"
    fi
    ;;

  status)
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      BIND_IP=$(get_bind_ip)
      echo "Repo server running (PID $(cat "$PID_FILE")) on http://${BIND_IP}:${PORT}/"
    else
      echo "Repo server not running"
      exit 1
    fi
    ;;

  *)
    echo "Usage: $0 {start|stop|status}"
    exit 1
    ;;
esac
