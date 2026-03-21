#!/bin/bash
# NetWatch — Bridge Setup
# Generated from topology.yml — DO NOT HAND-EDIT
# 54 P2P fabric bridges + 1 management bridge.
# STP disabled on all fabric bridges (L3 routing, not L2 switching).
# Uses sudo internally for ip link commands. Run as your user.

set -euo pipefail

echo "NetWatch: Creating fabric bridges..."

# --- Management bridge ---
# Managed by libvirt (virbr2) — do NOT create or delete it here.
echo "  [mgmt] virbr2 (libvirt-managed, skipping creation)"

# --- Fabric bridges (STP disabled, no IP) ---
echo "  [border_bastion] br000 (border-1 <-> bastion)"
sudo ip link add br000 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br000/bridge/stp_state'
sudo ip link set br000 up
echo "  [border_bastion] br001 (border-2 <-> bastion)"
sudo ip link add br001 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br001/bridge/stp_state'
sudo ip link set br001 up
echo "  [border_spine] br002 (border-1 <-> spine-1)"
sudo ip link add br002 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br002/bridge/stp_state'
sudo ip link set br002 up
echo "  [border_spine] br003 (border-1 <-> spine-2)"
sudo ip link add br003 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br003/bridge/stp_state'
sudo ip link set br003 up
echo "  [border_spine] br004 (border-2 <-> spine-1)"
sudo ip link add br004 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br004/bridge/stp_state'
sudo ip link set br004 up
echo "  [border_spine] br005 (border-2 <-> spine-2)"
sudo ip link add br005 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br005/bridge/stp_state'
sudo ip link set br005 up
echo "  [spine_leaf] br006 (spine-1 <-> leaf-1a)"
sudo ip link add br006 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br006/bridge/stp_state'
sudo ip link set br006 up
echo "  [spine_leaf] br007 (spine-1 <-> leaf-1b)"
sudo ip link add br007 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br007/bridge/stp_state'
sudo ip link set br007 up
echo "  [spine_leaf] br008 (spine-1 <-> leaf-2a)"
sudo ip link add br008 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br008/bridge/stp_state'
sudo ip link set br008 up
echo "  [spine_leaf] br009 (spine-1 <-> leaf-2b)"
sudo ip link add br009 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br009/bridge/stp_state'
sudo ip link set br009 up
echo "  [spine_leaf] br010 (spine-1 <-> leaf-3a)"
sudo ip link add br010 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br010/bridge/stp_state'
sudo ip link set br010 up
echo "  [spine_leaf] br011 (spine-1 <-> leaf-3b)"
sudo ip link add br011 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br011/bridge/stp_state'
sudo ip link set br011 up
echo "  [spine_leaf] br012 (spine-1 <-> leaf-4a)"
sudo ip link add br012 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br012/bridge/stp_state'
sudo ip link set br012 up
echo "  [spine_leaf] br013 (spine-1 <-> leaf-4b)"
sudo ip link add br013 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br013/bridge/stp_state'
sudo ip link set br013 up
echo "  [spine_leaf] br014 (spine-2 <-> leaf-1a)"
sudo ip link add br014 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br014/bridge/stp_state'
sudo ip link set br014 up
echo "  [spine_leaf] br015 (spine-2 <-> leaf-1b)"
sudo ip link add br015 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br015/bridge/stp_state'
sudo ip link set br015 up
echo "  [spine_leaf] br016 (spine-2 <-> leaf-2a)"
sudo ip link add br016 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br016/bridge/stp_state'
sudo ip link set br016 up
echo "  [spine_leaf] br017 (spine-2 <-> leaf-2b)"
sudo ip link add br017 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br017/bridge/stp_state'
sudo ip link set br017 up
echo "  [spine_leaf] br018 (spine-2 <-> leaf-3a)"
sudo ip link add br018 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br018/bridge/stp_state'
sudo ip link set br018 up
echo "  [spine_leaf] br019 (spine-2 <-> leaf-3b)"
sudo ip link add br019 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br019/bridge/stp_state'
sudo ip link set br019 up
echo "  [spine_leaf] br020 (spine-2 <-> leaf-4a)"
sudo ip link add br020 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br020/bridge/stp_state'
sudo ip link set br020 up
echo "  [spine_leaf] br021 (spine-2 <-> leaf-4b)"
sudo ip link add br021 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br021/bridge/stp_state'
sudo ip link set br021 up
echo "  [leaf_server] br022 (leaf-1a <-> srv-1-1)"
sudo ip link add br022 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br022/bridge/stp_state'
sudo ip link set br022 up
echo "  [leaf_server] br023 (leaf-1b <-> srv-1-1)"
sudo ip link add br023 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br023/bridge/stp_state'
sudo ip link set br023 up
echo "  [leaf_server] br024 (leaf-1a <-> srv-1-2)"
sudo ip link add br024 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br024/bridge/stp_state'
sudo ip link set br024 up
echo "  [leaf_server] br025 (leaf-1b <-> srv-1-2)"
sudo ip link add br025 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br025/bridge/stp_state'
sudo ip link set br025 up
echo "  [leaf_server] br026 (leaf-1a <-> srv-1-3)"
sudo ip link add br026 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br026/bridge/stp_state'
sudo ip link set br026 up
echo "  [leaf_server] br027 (leaf-1b <-> srv-1-3)"
sudo ip link add br027 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br027/bridge/stp_state'
sudo ip link set br027 up
echo "  [leaf_server] br028 (leaf-1a <-> srv-1-4)"
sudo ip link add br028 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br028/bridge/stp_state'
sudo ip link set br028 up
echo "  [leaf_server] br029 (leaf-1b <-> srv-1-4)"
sudo ip link add br029 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br029/bridge/stp_state'
sudo ip link set br029 up
echo "  [leaf_server] br030 (leaf-2a <-> srv-2-1)"
sudo ip link add br030 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br030/bridge/stp_state'
sudo ip link set br030 up
echo "  [leaf_server] br031 (leaf-2b <-> srv-2-1)"
sudo ip link add br031 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br031/bridge/stp_state'
sudo ip link set br031 up
echo "  [leaf_server] br032 (leaf-2a <-> srv-2-2)"
sudo ip link add br032 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br032/bridge/stp_state'
sudo ip link set br032 up
echo "  [leaf_server] br033 (leaf-2b <-> srv-2-2)"
sudo ip link add br033 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br033/bridge/stp_state'
sudo ip link set br033 up
echo "  [leaf_server] br034 (leaf-2a <-> srv-2-3)"
sudo ip link add br034 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br034/bridge/stp_state'
sudo ip link set br034 up
echo "  [leaf_server] br035 (leaf-2b <-> srv-2-3)"
sudo ip link add br035 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br035/bridge/stp_state'
sudo ip link set br035 up
echo "  [leaf_server] br036 (leaf-2a <-> srv-2-4)"
sudo ip link add br036 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br036/bridge/stp_state'
sudo ip link set br036 up
echo "  [leaf_server] br037 (leaf-2b <-> srv-2-4)"
sudo ip link add br037 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br037/bridge/stp_state'
sudo ip link set br037 up
echo "  [leaf_server] br038 (leaf-3a <-> srv-3-1)"
sudo ip link add br038 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br038/bridge/stp_state'
sudo ip link set br038 up
echo "  [leaf_server] br039 (leaf-3b <-> srv-3-1)"
sudo ip link add br039 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br039/bridge/stp_state'
sudo ip link set br039 up
echo "  [leaf_server] br040 (leaf-3a <-> srv-3-2)"
sudo ip link add br040 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br040/bridge/stp_state'
sudo ip link set br040 up
echo "  [leaf_server] br041 (leaf-3b <-> srv-3-2)"
sudo ip link add br041 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br041/bridge/stp_state'
sudo ip link set br041 up
echo "  [leaf_server] br042 (leaf-3a <-> srv-3-3)"
sudo ip link add br042 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br042/bridge/stp_state'
sudo ip link set br042 up
echo "  [leaf_server] br043 (leaf-3b <-> srv-3-3)"
sudo ip link add br043 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br043/bridge/stp_state'
sudo ip link set br043 up
echo "  [leaf_server] br044 (leaf-3a <-> srv-3-4)"
sudo ip link add br044 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br044/bridge/stp_state'
sudo ip link set br044 up
echo "  [leaf_server] br045 (leaf-3b <-> srv-3-4)"
sudo ip link add br045 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br045/bridge/stp_state'
sudo ip link set br045 up
echo "  [leaf_server] br046 (leaf-4a <-> srv-4-1)"
sudo ip link add br046 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br046/bridge/stp_state'
sudo ip link set br046 up
echo "  [leaf_server] br047 (leaf-4b <-> srv-4-1)"
sudo ip link add br047 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br047/bridge/stp_state'
sudo ip link set br047 up
echo "  [leaf_server] br048 (leaf-4a <-> srv-4-2)"
sudo ip link add br048 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br048/bridge/stp_state'
sudo ip link set br048 up
echo "  [leaf_server] br049 (leaf-4b <-> srv-4-2)"
sudo ip link add br049 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br049/bridge/stp_state'
sudo ip link set br049 up
echo "  [leaf_server] br050 (leaf-4a <-> srv-4-3)"
sudo ip link add br050 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br050/bridge/stp_state'
sudo ip link set br050 up
echo "  [leaf_server] br051 (leaf-4b <-> srv-4-3)"
sudo ip link add br051 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br051/bridge/stp_state'
sudo ip link set br051 up
echo "  [leaf_server] br052 (leaf-4a <-> srv-4-4)"
sudo ip link add br052 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br052/bridge/stp_state'
sudo ip link set br052 up
echo "  [leaf_server] br053 (leaf-4b <-> srv-4-4)"
sudo ip link add br053 type bridge 2>/dev/null || true
sudo bash -c 'echo 0 > /sys/class/net/br053/bridge/stp_state'
sudo ip link set br053 up

echo ""
echo "NetWatch: 54 fabric bridges created (STP disabled)."
echo "  Mgmt bridge: virbr2 (libvirt-managed)."
