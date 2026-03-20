#!/bin/bash
# NetWatch — FRR Container Setup
# Generated from topology.yml — DO NOT HAND-EDIT
#
# Starts 12 FRR containers with --network=none, then:
#   1. Creates veth pairs for each fabric link
#   2. Moves one end into the container network namespace
#   3. Attaches the other end to the corresponding bridge
#   4. Assigns IP addresses inside the namespace
#   5. Connects each container to the management bridge
#   6. Applies sysctls (ip_forward=1, rp_filter=2)
#   7. Starts frr_exporter sidecar for Prometheus metrics
#
# Prerequisites: setup-bridges.sh has already run.
# Run as root: sudo ./setup-frr-containers.sh

set -euo pipefail

FRR_IMAGE="quay.io/frrouting/frr:9.1.0"
FRR_EXPORTER_VERSION="1.10.1"
FRR_EXPORTER_BIN="/usr/local/bin/frr_exporter"
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# --- Resolve management bridge dynamically ---
MGMT_BRIDGE=$(virsh net-info netwatch-mgmt 2>/dev/null | awk '/Bridge:/{print $2}')
if [ -z "$MGMT_BRIDGE" ]; then
    echo "ERROR: Could not resolve bridge for libvirt network 'netwatch-mgmt'"
    echo "  Is the network created? Check: virsh net-list --all"
    exit 1
fi
echo "  Management bridge: $MGMT_BRIDGE"

# --- Ensure frr_exporter is available on the host ---
if [ ! -x "$FRR_EXPORTER_BIN" ]; then
    TARBALL="${PROJECT_ROOT}/repo/binaries/frr_exporter-${FRR_EXPORTER_VERSION}.linux-amd64.tar.gz"
    if [ -f "$TARBALL" ]; then
        echo "  Installing frr_exporter v${FRR_EXPORTER_VERSION} from repo/binaries/..."
        TMPDIR=$(mktemp -d)
        tar xz -C "$TMPDIR" -f "$TARBALL"
        find "$TMPDIR" -name "frr_exporter" -type f -exec mv {} "$FRR_EXPORTER_BIN" \;
        chmod +x "$FRR_EXPORTER_BIN"
        rm -rf "$TMPDIR"
    else
        echo "ERROR: frr_exporter not found at $FRR_EXPORTER_BIN or $TARBALL"
        echo "  Run: bash scripts/bake-golden-image.sh (or manually place the tarball)"
        exit 1
    fi
fi

# --- Docker Loki logging driver ---
LOKI_DRIVER_ARGS=""
if docker plugin inspect loki >/dev/null 2>&1; then
    LOKI_DRIVER_ARGS="--log-driver=loki --log-opt loki-url=http://192.168.0.3:3100/loki/api/v1/push --log-opt loki-retries=5 --log-opt loki-batch-size=102400"
else
    echo "  Installing Docker Loki logging driver..."
    if docker plugin install grafana/loki-docker-driver:latest --alias loki --grant-all-permissions 2>/dev/null; then
        LOKI_DRIVER_ARGS="--log-driver=loki --log-opt loki-url=http://192.168.0.3:3100/loki/api/v1/push --log-opt loki-retries=5 --log-opt loki-batch-size=102400"
    else
        echo "  WARNING: Loki Docker driver not available — FRR logs will use default driver"
    fi
fi

echo "NetWatch: Starting FRR containers..."

# --- Start containers ---
echo "  Starting border-1..."
docker rm -f border-1 2>/dev/null || true
docker run -d \
    --name border-1 \
    --network=none \
    --privileged \
    --hostname border-1 \
    --label netwatch=frr \
    $LOKI_DRIVER_ARGS \
    ${LOKI_DRIVER_ARGS:+--log-opt loki-external-labels=container=border-1} \
    -v "$PROJECT_ROOT/generated/frr/border-1:/etc/frr" \
    -v "$FRR_EXPORTER_BIN:/usr/local/bin/frr_exporter:ro" \
    "$FRR_IMAGE"
echo "  Starting border-2..."
docker rm -f border-2 2>/dev/null || true
docker run -d \
    --name border-2 \
    --network=none \
    --privileged \
    --hostname border-2 \
    --label netwatch=frr \
    $LOKI_DRIVER_ARGS \
    ${LOKI_DRIVER_ARGS:+--log-opt loki-external-labels=container=border-2} \
    -v "$PROJECT_ROOT/generated/frr/border-2:/etc/frr" \
    -v "$FRR_EXPORTER_BIN:/usr/local/bin/frr_exporter:ro" \
    "$FRR_IMAGE"
echo "  Starting leaf-1a..."
docker rm -f leaf-1a 2>/dev/null || true
docker run -d \
    --name leaf-1a \
    --network=none \
    --privileged \
    --hostname leaf-1a \
    --label netwatch=frr \
    $LOKI_DRIVER_ARGS \
    ${LOKI_DRIVER_ARGS:+--log-opt loki-external-labels=container=leaf-1a} \
    -v "$PROJECT_ROOT/generated/frr/leaf-1a:/etc/frr" \
    -v "$FRR_EXPORTER_BIN:/usr/local/bin/frr_exporter:ro" \
    "$FRR_IMAGE"
echo "  Starting leaf-1b..."
docker rm -f leaf-1b 2>/dev/null || true
docker run -d \
    --name leaf-1b \
    --network=none \
    --privileged \
    --hostname leaf-1b \
    --label netwatch=frr \
    $LOKI_DRIVER_ARGS \
    ${LOKI_DRIVER_ARGS:+--log-opt loki-external-labels=container=leaf-1b} \
    -v "$PROJECT_ROOT/generated/frr/leaf-1b:/etc/frr" \
    -v "$FRR_EXPORTER_BIN:/usr/local/bin/frr_exporter:ro" \
    "$FRR_IMAGE"
echo "  Starting leaf-2a..."
docker rm -f leaf-2a 2>/dev/null || true
docker run -d \
    --name leaf-2a \
    --network=none \
    --privileged \
    --hostname leaf-2a \
    --label netwatch=frr \
    $LOKI_DRIVER_ARGS \
    ${LOKI_DRIVER_ARGS:+--log-opt loki-external-labels=container=leaf-2a} \
    -v "$PROJECT_ROOT/generated/frr/leaf-2a:/etc/frr" \
    -v "$FRR_EXPORTER_BIN:/usr/local/bin/frr_exporter:ro" \
    "$FRR_IMAGE"
echo "  Starting leaf-2b..."
docker rm -f leaf-2b 2>/dev/null || true
docker run -d \
    --name leaf-2b \
    --network=none \
    --privileged \
    --hostname leaf-2b \
    --label netwatch=frr \
    $LOKI_DRIVER_ARGS \
    ${LOKI_DRIVER_ARGS:+--log-opt loki-external-labels=container=leaf-2b} \
    -v "$PROJECT_ROOT/generated/frr/leaf-2b:/etc/frr" \
    -v "$FRR_EXPORTER_BIN:/usr/local/bin/frr_exporter:ro" \
    "$FRR_IMAGE"
echo "  Starting leaf-3a..."
docker rm -f leaf-3a 2>/dev/null || true
docker run -d \
    --name leaf-3a \
    --network=none \
    --privileged \
    --hostname leaf-3a \
    --label netwatch=frr \
    $LOKI_DRIVER_ARGS \
    ${LOKI_DRIVER_ARGS:+--log-opt loki-external-labels=container=leaf-3a} \
    -v "$PROJECT_ROOT/generated/frr/leaf-3a:/etc/frr" \
    -v "$FRR_EXPORTER_BIN:/usr/local/bin/frr_exporter:ro" \
    "$FRR_IMAGE"
echo "  Starting leaf-3b..."
docker rm -f leaf-3b 2>/dev/null || true
docker run -d \
    --name leaf-3b \
    --network=none \
    --privileged \
    --hostname leaf-3b \
    --label netwatch=frr \
    $LOKI_DRIVER_ARGS \
    ${LOKI_DRIVER_ARGS:+--log-opt loki-external-labels=container=leaf-3b} \
    -v "$PROJECT_ROOT/generated/frr/leaf-3b:/etc/frr" \
    -v "$FRR_EXPORTER_BIN:/usr/local/bin/frr_exporter:ro" \
    "$FRR_IMAGE"
echo "  Starting leaf-4a..."
docker rm -f leaf-4a 2>/dev/null || true
docker run -d \
    --name leaf-4a \
    --network=none \
    --privileged \
    --hostname leaf-4a \
    --label netwatch=frr \
    $LOKI_DRIVER_ARGS \
    ${LOKI_DRIVER_ARGS:+--log-opt loki-external-labels=container=leaf-4a} \
    -v "$PROJECT_ROOT/generated/frr/leaf-4a:/etc/frr" \
    -v "$FRR_EXPORTER_BIN:/usr/local/bin/frr_exporter:ro" \
    "$FRR_IMAGE"
echo "  Starting leaf-4b..."
docker rm -f leaf-4b 2>/dev/null || true
docker run -d \
    --name leaf-4b \
    --network=none \
    --privileged \
    --hostname leaf-4b \
    --label netwatch=frr \
    $LOKI_DRIVER_ARGS \
    ${LOKI_DRIVER_ARGS:+--log-opt loki-external-labels=container=leaf-4b} \
    -v "$PROJECT_ROOT/generated/frr/leaf-4b:/etc/frr" \
    -v "$FRR_EXPORTER_BIN:/usr/local/bin/frr_exporter:ro" \
    "$FRR_IMAGE"
echo "  Starting spine-1..."
docker rm -f spine-1 2>/dev/null || true
docker run -d \
    --name spine-1 \
    --network=none \
    --privileged \
    --hostname spine-1 \
    --label netwatch=frr \
    $LOKI_DRIVER_ARGS \
    ${LOKI_DRIVER_ARGS:+--log-opt loki-external-labels=container=spine-1} \
    -v "$PROJECT_ROOT/generated/frr/spine-1:/etc/frr" \
    -v "$FRR_EXPORTER_BIN:/usr/local/bin/frr_exporter:ro" \
    "$FRR_IMAGE"
echo "  Starting spine-2..."
docker rm -f spine-2 2>/dev/null || true
docker run -d \
    --name spine-2 \
    --network=none \
    --privileged \
    --hostname spine-2 \
    --label netwatch=frr \
    $LOKI_DRIVER_ARGS \
    ${LOKI_DRIVER_ARGS:+--log-opt loki-external-labels=container=spine-2} \
    -v "$PROJECT_ROOT/generated/frr/spine-2:/etc/frr" \
    -v "$FRR_EXPORTER_BIN:/usr/local/bin/frr_exporter:ro" \
    "$FRR_IMAGE"

echo ""
echo "NetWatch: Wiring fabric interfaces..."

# Helper: get container PID for namespace operations
get_pid() {
    docker inspect -f '{{.State.Pid}}' "$1"
}

# Helper: create veth pair, move one end into container, attach other to bridge
wire_link() {
    local container="$1"
    local ifname="$2"
    local bridge="$3"

    local pid
    pid=$(get_pid "$container")

    # Veth names on host side: h-<bridge>-<short_container>
    local host_veth="h-${bridge}-${container:0:6}"

    # Create veth pair
    ip link add "$host_veth" type veth peer name "$ifname" 2>/dev/null || true

    # Move container-side end into namespace
    ip link set "$ifname" netns "$pid"

    # Attach host-side end to bridge
    ip link set "$host_veth" master "$bridge"
    ip link set "$host_veth" up

    # Bring up the interface — FRR assigns IPs from frr.conf
    nsenter -t "$pid" -n ip link set "$ifname" up
}

# Helper: connect container to management bridge
wire_mgmt() {
    local container="$1"
    local mgmt_ip="$2"
    local mac="$3"

    local pid
    pid=$(get_pid "$container")

    local host_veth="h-mgmt-${container:0:8}"

    ip link add "$host_veth" type veth peer name "eth-mgmt" 2>/dev/null || true
    ip link set "eth-mgmt" netns "$pid"
    ip link set "$host_veth" master "$MGMT_BRIDGE"
    ip link set "$host_veth" up

    nsenter -t "$pid" -n ip link set "eth-mgmt" address "$mac"
    nsenter -t "$pid" -n ip addr add "${mgmt_ip}/24" dev "eth-mgmt"
    nsenter -t "$pid" -n ip link set "eth-mgmt" up
}

# --- Wire fabric links ---
echo "  br000: border-1(eth-spine-1) <-> bridge"
wire_link "border-1" "eth-spine-1" "br000"
echo "  br000: spine-1(eth-border-1) <-> bridge"
wire_link "spine-1" "eth-border-1" "br000"
echo "  br001: border-1(eth-spine-2) <-> bridge"
wire_link "border-1" "eth-spine-2" "br001"
echo "  br001: spine-2(eth-border-1) <-> bridge"
wire_link "spine-2" "eth-border-1" "br001"
echo "  br002: border-2(eth-spine-1) <-> bridge"
wire_link "border-2" "eth-spine-1" "br002"
echo "  br002: spine-1(eth-border-2) <-> bridge"
wire_link "spine-1" "eth-border-2" "br002"
echo "  br003: border-2(eth-spine-2) <-> bridge"
wire_link "border-2" "eth-spine-2" "br003"
echo "  br003: spine-2(eth-border-2) <-> bridge"
wire_link "spine-2" "eth-border-2" "br003"
echo "  br004: spine-1(eth-leaf-1a) <-> bridge"
wire_link "spine-1" "eth-leaf-1a" "br004"
echo "  br004: leaf-1a(eth-spine-1) <-> bridge"
wire_link "leaf-1a" "eth-spine-1" "br004"
echo "  br005: spine-1(eth-leaf-1b) <-> bridge"
wire_link "spine-1" "eth-leaf-1b" "br005"
echo "  br005: leaf-1b(eth-spine-1) <-> bridge"
wire_link "leaf-1b" "eth-spine-1" "br005"
echo "  br006: spine-1(eth-leaf-2a) <-> bridge"
wire_link "spine-1" "eth-leaf-2a" "br006"
echo "  br006: leaf-2a(eth-spine-1) <-> bridge"
wire_link "leaf-2a" "eth-spine-1" "br006"
echo "  br007: spine-1(eth-leaf-2b) <-> bridge"
wire_link "spine-1" "eth-leaf-2b" "br007"
echo "  br007: leaf-2b(eth-spine-1) <-> bridge"
wire_link "leaf-2b" "eth-spine-1" "br007"
echo "  br008: spine-1(eth-leaf-3a) <-> bridge"
wire_link "spine-1" "eth-leaf-3a" "br008"
echo "  br008: leaf-3a(eth-spine-1) <-> bridge"
wire_link "leaf-3a" "eth-spine-1" "br008"
echo "  br009: spine-1(eth-leaf-3b) <-> bridge"
wire_link "spine-1" "eth-leaf-3b" "br009"
echo "  br009: leaf-3b(eth-spine-1) <-> bridge"
wire_link "leaf-3b" "eth-spine-1" "br009"
echo "  br010: spine-1(eth-leaf-4a) <-> bridge"
wire_link "spine-1" "eth-leaf-4a" "br010"
echo "  br010: leaf-4a(eth-spine-1) <-> bridge"
wire_link "leaf-4a" "eth-spine-1" "br010"
echo "  br011: spine-1(eth-leaf-4b) <-> bridge"
wire_link "spine-1" "eth-leaf-4b" "br011"
echo "  br011: leaf-4b(eth-spine-1) <-> bridge"
wire_link "leaf-4b" "eth-spine-1" "br011"
echo "  br012: spine-2(eth-leaf-1a) <-> bridge"
wire_link "spine-2" "eth-leaf-1a" "br012"
echo "  br012: leaf-1a(eth-spine-2) <-> bridge"
wire_link "leaf-1a" "eth-spine-2" "br012"
echo "  br013: spine-2(eth-leaf-1b) <-> bridge"
wire_link "spine-2" "eth-leaf-1b" "br013"
echo "  br013: leaf-1b(eth-spine-2) <-> bridge"
wire_link "leaf-1b" "eth-spine-2" "br013"
echo "  br014: spine-2(eth-leaf-2a) <-> bridge"
wire_link "spine-2" "eth-leaf-2a" "br014"
echo "  br014: leaf-2a(eth-spine-2) <-> bridge"
wire_link "leaf-2a" "eth-spine-2" "br014"
echo "  br015: spine-2(eth-leaf-2b) <-> bridge"
wire_link "spine-2" "eth-leaf-2b" "br015"
echo "  br015: leaf-2b(eth-spine-2) <-> bridge"
wire_link "leaf-2b" "eth-spine-2" "br015"
echo "  br016: spine-2(eth-leaf-3a) <-> bridge"
wire_link "spine-2" "eth-leaf-3a" "br016"
echo "  br016: leaf-3a(eth-spine-2) <-> bridge"
wire_link "leaf-3a" "eth-spine-2" "br016"
echo "  br017: spine-2(eth-leaf-3b) <-> bridge"
wire_link "spine-2" "eth-leaf-3b" "br017"
echo "  br017: leaf-3b(eth-spine-2) <-> bridge"
wire_link "leaf-3b" "eth-spine-2" "br017"
echo "  br018: spine-2(eth-leaf-4a) <-> bridge"
wire_link "spine-2" "eth-leaf-4a" "br018"
echo "  br018: leaf-4a(eth-spine-2) <-> bridge"
wire_link "leaf-4a" "eth-spine-2" "br018"
echo "  br019: spine-2(eth-leaf-4b) <-> bridge"
wire_link "spine-2" "eth-leaf-4b" "br019"
echo "  br019: leaf-4b(eth-spine-2) <-> bridge"
wire_link "leaf-4b" "eth-spine-2" "br019"
echo "  br020: leaf-1a(eth-srv-1-1) <-> bridge"
wire_link "leaf-1a" "eth-srv-1-1" "br020"
echo "  br021: leaf-1b(eth-srv-1-1) <-> bridge"
wire_link "leaf-1b" "eth-srv-1-1" "br021"
echo "  br022: leaf-1a(eth-srv-1-2) <-> bridge"
wire_link "leaf-1a" "eth-srv-1-2" "br022"
echo "  br023: leaf-1b(eth-srv-1-2) <-> bridge"
wire_link "leaf-1b" "eth-srv-1-2" "br023"
echo "  br024: leaf-1a(eth-srv-1-3) <-> bridge"
wire_link "leaf-1a" "eth-srv-1-3" "br024"
echo "  br025: leaf-1b(eth-srv-1-3) <-> bridge"
wire_link "leaf-1b" "eth-srv-1-3" "br025"
echo "  br026: leaf-1a(eth-srv-1-4) <-> bridge"
wire_link "leaf-1a" "eth-srv-1-4" "br026"
echo "  br027: leaf-1b(eth-srv-1-4) <-> bridge"
wire_link "leaf-1b" "eth-srv-1-4" "br027"
echo "  br028: leaf-2a(eth-srv-2-1) <-> bridge"
wire_link "leaf-2a" "eth-srv-2-1" "br028"
echo "  br029: leaf-2b(eth-srv-2-1) <-> bridge"
wire_link "leaf-2b" "eth-srv-2-1" "br029"
echo "  br030: leaf-2a(eth-srv-2-2) <-> bridge"
wire_link "leaf-2a" "eth-srv-2-2" "br030"
echo "  br031: leaf-2b(eth-srv-2-2) <-> bridge"
wire_link "leaf-2b" "eth-srv-2-2" "br031"
echo "  br032: leaf-2a(eth-srv-2-3) <-> bridge"
wire_link "leaf-2a" "eth-srv-2-3" "br032"
echo "  br033: leaf-2b(eth-srv-2-3) <-> bridge"
wire_link "leaf-2b" "eth-srv-2-3" "br033"
echo "  br034: leaf-2a(eth-srv-2-4) <-> bridge"
wire_link "leaf-2a" "eth-srv-2-4" "br034"
echo "  br035: leaf-2b(eth-srv-2-4) <-> bridge"
wire_link "leaf-2b" "eth-srv-2-4" "br035"
echo "  br036: leaf-3a(eth-srv-3-1) <-> bridge"
wire_link "leaf-3a" "eth-srv-3-1" "br036"
echo "  br037: leaf-3b(eth-srv-3-1) <-> bridge"
wire_link "leaf-3b" "eth-srv-3-1" "br037"
echo "  br038: leaf-3a(eth-srv-3-2) <-> bridge"
wire_link "leaf-3a" "eth-srv-3-2" "br038"
echo "  br039: leaf-3b(eth-srv-3-2) <-> bridge"
wire_link "leaf-3b" "eth-srv-3-2" "br039"
echo "  br040: leaf-3a(eth-srv-3-3) <-> bridge"
wire_link "leaf-3a" "eth-srv-3-3" "br040"
echo "  br041: leaf-3b(eth-srv-3-3) <-> bridge"
wire_link "leaf-3b" "eth-srv-3-3" "br041"
echo "  br042: leaf-3a(eth-srv-3-4) <-> bridge"
wire_link "leaf-3a" "eth-srv-3-4" "br042"
echo "  br043: leaf-3b(eth-srv-3-4) <-> bridge"
wire_link "leaf-3b" "eth-srv-3-4" "br043"
echo "  br044: leaf-4a(eth-srv-4-1) <-> bridge"
wire_link "leaf-4a" "eth-srv-4-1" "br044"
echo "  br045: leaf-4b(eth-srv-4-1) <-> bridge"
wire_link "leaf-4b" "eth-srv-4-1" "br045"
echo "  br046: leaf-4a(eth-srv-4-2) <-> bridge"
wire_link "leaf-4a" "eth-srv-4-2" "br046"
echo "  br047: leaf-4b(eth-srv-4-2) <-> bridge"
wire_link "leaf-4b" "eth-srv-4-2" "br047"
echo "  br048: leaf-4a(eth-srv-4-3) <-> bridge"
wire_link "leaf-4a" "eth-srv-4-3" "br048"
echo "  br049: leaf-4b(eth-srv-4-3) <-> bridge"
wire_link "leaf-4b" "eth-srv-4-3" "br049"
echo "  br050: leaf-4a(eth-srv-4-4) <-> bridge"
wire_link "leaf-4a" "eth-srv-4-4" "br050"
echo "  br051: leaf-4b(eth-srv-4-4) <-> bridge"
wire_link "leaf-4b" "eth-srv-4-4" "br051"

echo ""
echo "NetWatch: Connecting containers to management network..."

# --- Management network ---
echo "  border-1 -> $MGMT_BRIDGE (192.168.0.10)"
wire_mgmt "border-1" "192.168.0.10" "02:4E:57:01:00:01"
echo "  border-2 -> $MGMT_BRIDGE (192.168.0.11)"
wire_mgmt "border-2" "192.168.0.11" "02:4E:57:01:00:02"
echo "  leaf-1a -> $MGMT_BRIDGE (192.168.0.30)"
wire_mgmt "leaf-1a" "192.168.0.30" "02:4E:57:03:00:01"
echo "  leaf-1b -> $MGMT_BRIDGE (192.168.0.31)"
wire_mgmt "leaf-1b" "192.168.0.31" "02:4E:57:03:00:02"
echo "  leaf-2a -> $MGMT_BRIDGE (192.168.0.32)"
wire_mgmt "leaf-2a" "192.168.0.32" "02:4E:57:03:00:03"
echo "  leaf-2b -> $MGMT_BRIDGE (192.168.0.33)"
wire_mgmt "leaf-2b" "192.168.0.33" "02:4E:57:03:00:04"
echo "  leaf-3a -> $MGMT_BRIDGE (192.168.0.34)"
wire_mgmt "leaf-3a" "192.168.0.34" "02:4E:57:03:00:05"
echo "  leaf-3b -> $MGMT_BRIDGE (192.168.0.35)"
wire_mgmt "leaf-3b" "192.168.0.35" "02:4E:57:03:00:06"
echo "  leaf-4a -> $MGMT_BRIDGE (192.168.0.36)"
wire_mgmt "leaf-4a" "192.168.0.36" "02:4E:57:03:00:07"
echo "  leaf-4b -> $MGMT_BRIDGE (192.168.0.37)"
wire_mgmt "leaf-4b" "192.168.0.37" "02:4E:57:03:00:08"
echo "  spine-1 -> $MGMT_BRIDGE (192.168.0.20)"
wire_mgmt "spine-1" "192.168.0.20" "02:4E:57:02:00:01"
echo "  spine-2 -> $MGMT_BRIDGE (192.168.0.21)"
wire_mgmt "spine-2" "192.168.0.21" "02:4E:57:02:00:02"

echo ""
echo "NetWatch: Applying sysctls..."

# --- Sysctls (ip_forward + rp_filter) ---
PID_border_1=$(get_pid "border-1")
nsenter -t $PID_border_1 -n sysctl -w net.ipv4.ip_forward=1 >/dev/null
nsenter -t $PID_border_1 -n sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
nsenter -t $PID_border_1 -n sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null
PID_border_2=$(get_pid "border-2")
nsenter -t $PID_border_2 -n sysctl -w net.ipv4.ip_forward=1 >/dev/null
nsenter -t $PID_border_2 -n sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
nsenter -t $PID_border_2 -n sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null
PID_leaf_1a=$(get_pid "leaf-1a")
nsenter -t $PID_leaf_1a -n sysctl -w net.ipv4.ip_forward=1 >/dev/null
nsenter -t $PID_leaf_1a -n sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
nsenter -t $PID_leaf_1a -n sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null
PID_leaf_1b=$(get_pid "leaf-1b")
nsenter -t $PID_leaf_1b -n sysctl -w net.ipv4.ip_forward=1 >/dev/null
nsenter -t $PID_leaf_1b -n sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
nsenter -t $PID_leaf_1b -n sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null
PID_leaf_2a=$(get_pid "leaf-2a")
nsenter -t $PID_leaf_2a -n sysctl -w net.ipv4.ip_forward=1 >/dev/null
nsenter -t $PID_leaf_2a -n sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
nsenter -t $PID_leaf_2a -n sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null
PID_leaf_2b=$(get_pid "leaf-2b")
nsenter -t $PID_leaf_2b -n sysctl -w net.ipv4.ip_forward=1 >/dev/null
nsenter -t $PID_leaf_2b -n sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
nsenter -t $PID_leaf_2b -n sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null
PID_leaf_3a=$(get_pid "leaf-3a")
nsenter -t $PID_leaf_3a -n sysctl -w net.ipv4.ip_forward=1 >/dev/null
nsenter -t $PID_leaf_3a -n sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
nsenter -t $PID_leaf_3a -n sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null
PID_leaf_3b=$(get_pid "leaf-3b")
nsenter -t $PID_leaf_3b -n sysctl -w net.ipv4.ip_forward=1 >/dev/null
nsenter -t $PID_leaf_3b -n sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
nsenter -t $PID_leaf_3b -n sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null
PID_leaf_4a=$(get_pid "leaf-4a")
nsenter -t $PID_leaf_4a -n sysctl -w net.ipv4.ip_forward=1 >/dev/null
nsenter -t $PID_leaf_4a -n sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
nsenter -t $PID_leaf_4a -n sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null
PID_leaf_4b=$(get_pid "leaf-4b")
nsenter -t $PID_leaf_4b -n sysctl -w net.ipv4.ip_forward=1 >/dev/null
nsenter -t $PID_leaf_4b -n sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
nsenter -t $PID_leaf_4b -n sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null
PID_spine_1=$(get_pid "spine-1")
nsenter -t $PID_spine_1 -n sysctl -w net.ipv4.ip_forward=1 >/dev/null
nsenter -t $PID_spine_1 -n sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
nsenter -t $PID_spine_1 -n sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null
PID_spine_2=$(get_pid "spine-2")
nsenter -t $PID_spine_2 -n sysctl -w net.ipv4.ip_forward=1 >/dev/null
nsenter -t $PID_spine_2 -n sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
nsenter -t $PID_spine_2 -n sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null

echo ""
echo "NetWatch: Starting frr_exporter sidecars..."

# --- frr_exporter (Prometheus metrics for FRR via vtysh) ---
# Each container runs frr_exporter on :9342, accessible via mgmt IP
docker exec -d border-1 /usr/local/bin/frr_exporter --web.listen-address=:9342
echo "  border-1: frr_exporter on :9342"
docker exec -d border-2 /usr/local/bin/frr_exporter --web.listen-address=:9342
echo "  border-2: frr_exporter on :9342"
docker exec -d leaf-1a /usr/local/bin/frr_exporter --web.listen-address=:9342
echo "  leaf-1a: frr_exporter on :9342"
docker exec -d leaf-1b /usr/local/bin/frr_exporter --web.listen-address=:9342
echo "  leaf-1b: frr_exporter on :9342"
docker exec -d leaf-2a /usr/local/bin/frr_exporter --web.listen-address=:9342
echo "  leaf-2a: frr_exporter on :9342"
docker exec -d leaf-2b /usr/local/bin/frr_exporter --web.listen-address=:9342
echo "  leaf-2b: frr_exporter on :9342"
docker exec -d leaf-3a /usr/local/bin/frr_exporter --web.listen-address=:9342
echo "  leaf-3a: frr_exporter on :9342"
docker exec -d leaf-3b /usr/local/bin/frr_exporter --web.listen-address=:9342
echo "  leaf-3b: frr_exporter on :9342"
docker exec -d leaf-4a /usr/local/bin/frr_exporter --web.listen-address=:9342
echo "  leaf-4a: frr_exporter on :9342"
docker exec -d leaf-4b /usr/local/bin/frr_exporter --web.listen-address=:9342
echo "  leaf-4b: frr_exporter on :9342"
docker exec -d spine-1 /usr/local/bin/frr_exporter --web.listen-address=:9342
echo "  spine-1: frr_exporter on :9342"
docker exec -d spine-2 /usr/local/bin/frr_exporter --web.listen-address=:9342
echo "  spine-2: frr_exporter on :9342"

echo ""
echo "NetWatch: All 12 FRR containers running and wired."
echo "  - Fabric interfaces: up with IPs"
echo "  - Management interfaces: up on $MGMT_BRIDGE"
echo "  - ip_forward=1, rp_filter=2 (loose mode)"
echo "  - frr_exporter: metrics on :9342"
echo "  - Loki logging: $([ -n "$LOKI_DRIVER_ARGS" ] && echo 'enabled' || echo 'disabled')"
echo ""
echo "Verify: curl -s http://192.168.0.10:9342/metrics | head"
