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
#
# Prerequisites: setup-bridges.sh has already run.
# Run as root: sudo ./setup-frr-containers.sh

set -euo pipefail

FRR_IMAGE="quay.io/frrouting/frr:9.1.0"
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

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
    -v "$PROJECT_ROOT/generated/frr/border-1:/etc/frr" \
    "$FRR_IMAGE"
echo "  Starting border-2..."
docker rm -f border-2 2>/dev/null || true
docker run -d \
    --name border-2 \
    --network=none \
    --privileged \
    --hostname border-2 \
    --label netwatch=frr \
    -v "$PROJECT_ROOT/generated/frr/border-2:/etc/frr" \
    "$FRR_IMAGE"
echo "  Starting leaf-1a..."
docker rm -f leaf-1a 2>/dev/null || true
docker run -d \
    --name leaf-1a \
    --network=none \
    --privileged \
    --hostname leaf-1a \
    --label netwatch=frr \
    -v "$PROJECT_ROOT/generated/frr/leaf-1a:/etc/frr" \
    "$FRR_IMAGE"
echo "  Starting leaf-1b..."
docker rm -f leaf-1b 2>/dev/null || true
docker run -d \
    --name leaf-1b \
    --network=none \
    --privileged \
    --hostname leaf-1b \
    --label netwatch=frr \
    -v "$PROJECT_ROOT/generated/frr/leaf-1b:/etc/frr" \
    "$FRR_IMAGE"
echo "  Starting leaf-2a..."
docker rm -f leaf-2a 2>/dev/null || true
docker run -d \
    --name leaf-2a \
    --network=none \
    --privileged \
    --hostname leaf-2a \
    --label netwatch=frr \
    -v "$PROJECT_ROOT/generated/frr/leaf-2a:/etc/frr" \
    "$FRR_IMAGE"
echo "  Starting leaf-2b..."
docker rm -f leaf-2b 2>/dev/null || true
docker run -d \
    --name leaf-2b \
    --network=none \
    --privileged \
    --hostname leaf-2b \
    --label netwatch=frr \
    -v "$PROJECT_ROOT/generated/frr/leaf-2b:/etc/frr" \
    "$FRR_IMAGE"
echo "  Starting leaf-3a..."
docker rm -f leaf-3a 2>/dev/null || true
docker run -d \
    --name leaf-3a \
    --network=none \
    --privileged \
    --hostname leaf-3a \
    --label netwatch=frr \
    -v "$PROJECT_ROOT/generated/frr/leaf-3a:/etc/frr" \
    "$FRR_IMAGE"
echo "  Starting leaf-3b..."
docker rm -f leaf-3b 2>/dev/null || true
docker run -d \
    --name leaf-3b \
    --network=none \
    --privileged \
    --hostname leaf-3b \
    --label netwatch=frr \
    -v "$PROJECT_ROOT/generated/frr/leaf-3b:/etc/frr" \
    "$FRR_IMAGE"
echo "  Starting leaf-4a..."
docker rm -f leaf-4a 2>/dev/null || true
docker run -d \
    --name leaf-4a \
    --network=none \
    --privileged \
    --hostname leaf-4a \
    --label netwatch=frr \
    -v "$PROJECT_ROOT/generated/frr/leaf-4a:/etc/frr" \
    "$FRR_IMAGE"
echo "  Starting leaf-4b..."
docker rm -f leaf-4b 2>/dev/null || true
docker run -d \
    --name leaf-4b \
    --network=none \
    --privileged \
    --hostname leaf-4b \
    --label netwatch=frr \
    -v "$PROJECT_ROOT/generated/frr/leaf-4b:/etc/frr" \
    "$FRR_IMAGE"
echo "  Starting spine-1..."
docker rm -f spine-1 2>/dev/null || true
docker run -d \
    --name spine-1 \
    --network=none \
    --privileged \
    --hostname spine-1 \
    --label netwatch=frr \
    -v "$PROJECT_ROOT/generated/frr/spine-1:/etc/frr" \
    "$FRR_IMAGE"
echo "  Starting spine-2..."
docker rm -f spine-2 2>/dev/null || true
docker run -d \
    --name spine-2 \
    --network=none \
    --privileged \
    --hostname spine-2 \
    --label netwatch=frr \
    -v "$PROJECT_ROOT/generated/frr/spine-2:/etc/frr" \
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
    local ip_addr="$4"
    local prefix_len="$5"

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

    # Configure inside container namespace
    nsenter -t "$pid" -n ip addr add "${ip_addr}/${prefix_len}" dev "$ifname"
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
    ip link set "$host_veth" master br-mgmt
    ip link set "$host_veth" up

    nsenter -t "$pid" -n ip link set "eth-mgmt" address "$mac"
    nsenter -t "$pid" -n ip addr add "${mgmt_ip}/24" dev "eth-mgmt"
    nsenter -t "$pid" -n ip link set "eth-mgmt" up
}

# --- Wire fabric links ---
echo "  br000: border-1(eth-spine-1) <-> bridge"
wire_link "border-1" "eth-spine-1" "br000" "172.16.1.1" "30"
echo "  br000: spine-1(eth-border-1) <-> bridge"
wire_link "spine-1" "eth-border-1" "br000" "172.16.1.2" "30"
echo "  br001: border-1(eth-spine-2) <-> bridge"
wire_link "border-1" "eth-spine-2" "br001" "172.16.1.5" "30"
echo "  br001: spine-2(eth-border-1) <-> bridge"
wire_link "spine-2" "eth-border-1" "br001" "172.16.1.6" "30"
echo "  br002: border-2(eth-spine-1) <-> bridge"
wire_link "border-2" "eth-spine-1" "br002" "172.16.1.9" "30"
echo "  br002: spine-1(eth-border-2) <-> bridge"
wire_link "spine-1" "eth-border-2" "br002" "172.16.1.10" "30"
echo "  br003: border-2(eth-spine-2) <-> bridge"
wire_link "border-2" "eth-spine-2" "br003" "172.16.1.13" "30"
echo "  br003: spine-2(eth-border-2) <-> bridge"
wire_link "spine-2" "eth-border-2" "br003" "172.16.1.14" "30"
echo "  br004: spine-1(eth-leaf-1a) <-> bridge"
wire_link "spine-1" "eth-leaf-1a" "br004" "172.16.2.1" "30"
echo "  br004: leaf-1a(eth-spine-1) <-> bridge"
wire_link "leaf-1a" "eth-spine-1" "br004" "172.16.2.2" "30"
echo "  br005: spine-1(eth-leaf-1b) <-> bridge"
wire_link "spine-1" "eth-leaf-1b" "br005" "172.16.2.5" "30"
echo "  br005: leaf-1b(eth-spine-1) <-> bridge"
wire_link "leaf-1b" "eth-spine-1" "br005" "172.16.2.6" "30"
echo "  br006: spine-1(eth-leaf-2a) <-> bridge"
wire_link "spine-1" "eth-leaf-2a" "br006" "172.16.2.9" "30"
echo "  br006: leaf-2a(eth-spine-1) <-> bridge"
wire_link "leaf-2a" "eth-spine-1" "br006" "172.16.2.10" "30"
echo "  br007: spine-1(eth-leaf-2b) <-> bridge"
wire_link "spine-1" "eth-leaf-2b" "br007" "172.16.2.13" "30"
echo "  br007: leaf-2b(eth-spine-1) <-> bridge"
wire_link "leaf-2b" "eth-spine-1" "br007" "172.16.2.14" "30"
echo "  br008: spine-1(eth-leaf-3a) <-> bridge"
wire_link "spine-1" "eth-leaf-3a" "br008" "172.16.2.17" "30"
echo "  br008: leaf-3a(eth-spine-1) <-> bridge"
wire_link "leaf-3a" "eth-spine-1" "br008" "172.16.2.18" "30"
echo "  br009: spine-1(eth-leaf-3b) <-> bridge"
wire_link "spine-1" "eth-leaf-3b" "br009" "172.16.2.21" "30"
echo "  br009: leaf-3b(eth-spine-1) <-> bridge"
wire_link "leaf-3b" "eth-spine-1" "br009" "172.16.2.22" "30"
echo "  br010: spine-1(eth-leaf-4a) <-> bridge"
wire_link "spine-1" "eth-leaf-4a" "br010" "172.16.2.25" "30"
echo "  br010: leaf-4a(eth-spine-1) <-> bridge"
wire_link "leaf-4a" "eth-spine-1" "br010" "172.16.2.26" "30"
echo "  br011: spine-1(eth-leaf-4b) <-> bridge"
wire_link "spine-1" "eth-leaf-4b" "br011" "172.16.2.29" "30"
echo "  br011: leaf-4b(eth-spine-1) <-> bridge"
wire_link "leaf-4b" "eth-spine-1" "br011" "172.16.2.30" "30"
echo "  br012: spine-2(eth-leaf-1a) <-> bridge"
wire_link "spine-2" "eth-leaf-1a" "br012" "172.16.2.33" "30"
echo "  br012: leaf-1a(eth-spine-2) <-> bridge"
wire_link "leaf-1a" "eth-spine-2" "br012" "172.16.2.34" "30"
echo "  br013: spine-2(eth-leaf-1b) <-> bridge"
wire_link "spine-2" "eth-leaf-1b" "br013" "172.16.2.37" "30"
echo "  br013: leaf-1b(eth-spine-2) <-> bridge"
wire_link "leaf-1b" "eth-spine-2" "br013" "172.16.2.38" "30"
echo "  br014: spine-2(eth-leaf-2a) <-> bridge"
wire_link "spine-2" "eth-leaf-2a" "br014" "172.16.2.41" "30"
echo "  br014: leaf-2a(eth-spine-2) <-> bridge"
wire_link "leaf-2a" "eth-spine-2" "br014" "172.16.2.42" "30"
echo "  br015: spine-2(eth-leaf-2b) <-> bridge"
wire_link "spine-2" "eth-leaf-2b" "br015" "172.16.2.45" "30"
echo "  br015: leaf-2b(eth-spine-2) <-> bridge"
wire_link "leaf-2b" "eth-spine-2" "br015" "172.16.2.46" "30"
echo "  br016: spine-2(eth-leaf-3a) <-> bridge"
wire_link "spine-2" "eth-leaf-3a" "br016" "172.16.2.49" "30"
echo "  br016: leaf-3a(eth-spine-2) <-> bridge"
wire_link "leaf-3a" "eth-spine-2" "br016" "172.16.2.50" "30"
echo "  br017: spine-2(eth-leaf-3b) <-> bridge"
wire_link "spine-2" "eth-leaf-3b" "br017" "172.16.2.53" "30"
echo "  br017: leaf-3b(eth-spine-2) <-> bridge"
wire_link "leaf-3b" "eth-spine-2" "br017" "172.16.2.54" "30"
echo "  br018: spine-2(eth-leaf-4a) <-> bridge"
wire_link "spine-2" "eth-leaf-4a" "br018" "172.16.2.57" "30"
echo "  br018: leaf-4a(eth-spine-2) <-> bridge"
wire_link "leaf-4a" "eth-spine-2" "br018" "172.16.2.58" "30"
echo "  br019: spine-2(eth-leaf-4b) <-> bridge"
wire_link "spine-2" "eth-leaf-4b" "br019" "172.16.2.61" "30"
echo "  br019: leaf-4b(eth-spine-2) <-> bridge"
wire_link "leaf-4b" "eth-spine-2" "br019" "172.16.2.62" "30"
echo "  br020: leaf-1a(eth-srv-1-1) <-> bridge"
wire_link "leaf-1a" "eth-srv-1-1" "br020" "172.16.3.1" "30"
echo "  br021: leaf-1b(eth-srv-1-1) <-> bridge"
wire_link "leaf-1b" "eth-srv-1-1" "br021" "172.16.3.5" "30"
echo "  br022: leaf-1a(eth-srv-1-2) <-> bridge"
wire_link "leaf-1a" "eth-srv-1-2" "br022" "172.16.3.9" "30"
echo "  br023: leaf-1b(eth-srv-1-2) <-> bridge"
wire_link "leaf-1b" "eth-srv-1-2" "br023" "172.16.3.13" "30"
echo "  br024: leaf-1a(eth-srv-1-3) <-> bridge"
wire_link "leaf-1a" "eth-srv-1-3" "br024" "172.16.3.17" "30"
echo "  br025: leaf-1b(eth-srv-1-3) <-> bridge"
wire_link "leaf-1b" "eth-srv-1-3" "br025" "172.16.3.21" "30"
echo "  br026: leaf-1a(eth-srv-1-4) <-> bridge"
wire_link "leaf-1a" "eth-srv-1-4" "br026" "172.16.3.25" "30"
echo "  br027: leaf-1b(eth-srv-1-4) <-> bridge"
wire_link "leaf-1b" "eth-srv-1-4" "br027" "172.16.3.29" "30"
echo "  br028: leaf-2a(eth-srv-2-1) <-> bridge"
wire_link "leaf-2a" "eth-srv-2-1" "br028" "172.16.4.1" "30"
echo "  br029: leaf-2b(eth-srv-2-1) <-> bridge"
wire_link "leaf-2b" "eth-srv-2-1" "br029" "172.16.4.5" "30"
echo "  br030: leaf-2a(eth-srv-2-2) <-> bridge"
wire_link "leaf-2a" "eth-srv-2-2" "br030" "172.16.4.9" "30"
echo "  br031: leaf-2b(eth-srv-2-2) <-> bridge"
wire_link "leaf-2b" "eth-srv-2-2" "br031" "172.16.4.13" "30"
echo "  br032: leaf-2a(eth-srv-2-3) <-> bridge"
wire_link "leaf-2a" "eth-srv-2-3" "br032" "172.16.4.17" "30"
echo "  br033: leaf-2b(eth-srv-2-3) <-> bridge"
wire_link "leaf-2b" "eth-srv-2-3" "br033" "172.16.4.21" "30"
echo "  br034: leaf-2a(eth-srv-2-4) <-> bridge"
wire_link "leaf-2a" "eth-srv-2-4" "br034" "172.16.4.25" "30"
echo "  br035: leaf-2b(eth-srv-2-4) <-> bridge"
wire_link "leaf-2b" "eth-srv-2-4" "br035" "172.16.4.29" "30"
echo "  br036: leaf-3a(eth-srv-3-1) <-> bridge"
wire_link "leaf-3a" "eth-srv-3-1" "br036" "172.16.5.1" "30"
echo "  br037: leaf-3b(eth-srv-3-1) <-> bridge"
wire_link "leaf-3b" "eth-srv-3-1" "br037" "172.16.5.5" "30"
echo "  br038: leaf-3a(eth-srv-3-2) <-> bridge"
wire_link "leaf-3a" "eth-srv-3-2" "br038" "172.16.5.9" "30"
echo "  br039: leaf-3b(eth-srv-3-2) <-> bridge"
wire_link "leaf-3b" "eth-srv-3-2" "br039" "172.16.5.13" "30"
echo "  br040: leaf-3a(eth-srv-3-3) <-> bridge"
wire_link "leaf-3a" "eth-srv-3-3" "br040" "172.16.5.17" "30"
echo "  br041: leaf-3b(eth-srv-3-3) <-> bridge"
wire_link "leaf-3b" "eth-srv-3-3" "br041" "172.16.5.21" "30"
echo "  br042: leaf-3a(eth-srv-3-4) <-> bridge"
wire_link "leaf-3a" "eth-srv-3-4" "br042" "172.16.5.25" "30"
echo "  br043: leaf-3b(eth-srv-3-4) <-> bridge"
wire_link "leaf-3b" "eth-srv-3-4" "br043" "172.16.5.29" "30"
echo "  br044: leaf-4a(eth-srv-4-1) <-> bridge"
wire_link "leaf-4a" "eth-srv-4-1" "br044" "172.16.6.1" "30"
echo "  br045: leaf-4b(eth-srv-4-1) <-> bridge"
wire_link "leaf-4b" "eth-srv-4-1" "br045" "172.16.6.5" "30"
echo "  br046: leaf-4a(eth-srv-4-2) <-> bridge"
wire_link "leaf-4a" "eth-srv-4-2" "br046" "172.16.6.9" "30"
echo "  br047: leaf-4b(eth-srv-4-2) <-> bridge"
wire_link "leaf-4b" "eth-srv-4-2" "br047" "172.16.6.13" "30"
echo "  br048: leaf-4a(eth-srv-4-3) <-> bridge"
wire_link "leaf-4a" "eth-srv-4-3" "br048" "172.16.6.17" "30"
echo "  br049: leaf-4b(eth-srv-4-3) <-> bridge"
wire_link "leaf-4b" "eth-srv-4-3" "br049" "172.16.6.21" "30"
echo "  br050: leaf-4a(eth-srv-4-4) <-> bridge"
wire_link "leaf-4a" "eth-srv-4-4" "br050" "172.16.6.25" "30"
echo "  br051: leaf-4b(eth-srv-4-4) <-> bridge"
wire_link "leaf-4b" "eth-srv-4-4" "br051" "172.16.6.29" "30"

echo ""
echo "NetWatch: Connecting containers to management network..."

# --- Management network ---
echo "  border-1 → br-mgmt (192.168.0.10)"
wire_mgmt "border-1" "192.168.0.10" "02:4E:57:01:00:01"
echo "  border-2 → br-mgmt (192.168.0.11)"
wire_mgmt "border-2" "192.168.0.11" "02:4E:57:01:00:02"
echo "  leaf-1a → br-mgmt (192.168.0.30)"
wire_mgmt "leaf-1a" "192.168.0.30" "02:4E:57:03:00:01"
echo "  leaf-1b → br-mgmt (192.168.0.31)"
wire_mgmt "leaf-1b" "192.168.0.31" "02:4E:57:03:00:02"
echo "  leaf-2a → br-mgmt (192.168.0.32)"
wire_mgmt "leaf-2a" "192.168.0.32" "02:4E:57:03:00:03"
echo "  leaf-2b → br-mgmt (192.168.0.33)"
wire_mgmt "leaf-2b" "192.168.0.33" "02:4E:57:03:00:04"
echo "  leaf-3a → br-mgmt (192.168.0.34)"
wire_mgmt "leaf-3a" "192.168.0.34" "02:4E:57:03:00:05"
echo "  leaf-3b → br-mgmt (192.168.0.35)"
wire_mgmt "leaf-3b" "192.168.0.35" "02:4E:57:03:00:06"
echo "  leaf-4a → br-mgmt (192.168.0.36)"
wire_mgmt "leaf-4a" "192.168.0.36" "02:4E:57:03:00:07"
echo "  leaf-4b → br-mgmt (192.168.0.37)"
wire_mgmt "leaf-4b" "192.168.0.37" "02:4E:57:03:00:08"
echo "  spine-1 → br-mgmt (192.168.0.20)"
wire_mgmt "spine-1" "192.168.0.20" "02:4E:57:02:00:01"
echo "  spine-2 → br-mgmt (192.168.0.21)"
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
echo "NetWatch: All 12 FRR containers running and wired."
echo "  - Fabric interfaces: up with IPs"
echo "  - Management interfaces: up with DHCP-ready MACs"
echo "  - ip_forward=1, rp_filter=2 (loose mode)"
echo ""
echo "Next: deploy FRR configs and start routing daemons."
