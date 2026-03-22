#!/bin/bash
# NetWatch — Chaos Engineering Shared Library
# Sourced by all chaos scripts. Not executable on its own.
#
# Provides:
#   BRIDGE_MAP[]      — associative array: "nodeA:nodeB" -> bridge name (both directions)
#   FRR_NODES[]       — list of all 12 FRR VM names
#   RACK_LEAFS[]      — associative array: "rack-N" -> "leaf-Na leaf-Nb"
#   resolve_bridge()  — look up bridge for a node pair
#   find_veths()      — find host-side veth/tap interfaces on a bridge
#   annotate()        — POST a Grafana annotation
#   log_chaos()       — timestamped log output
#   require_args()    — argument count validation

# --- Configuration ---
GRAFANA_URL="${GRAFANA_URL:-http://192.168.0.3:3000}"
GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASS="${GRAFANA_PASS:-admin}"
VIRSH_PREFIX="NetWatch"

# --- FRR VM names ---
FRR_NODES=(
    border-1 border-2
    spine-1 spine-2
    leaf-1a leaf-1b leaf-2a leaf-2b
    leaf-3a leaf-3b leaf-4a leaf-4b
)

# --- Rack-to-leaf mapping ---
declare -A RACK_LEAFS=(
    [rack-1]="leaf-1a leaf-1b"
    [rack-2]="leaf-2a leaf-2b"
    [rack-3]="leaf-3a leaf-3b"
    [rack-4]="leaf-4a leaf-4b"
)

# --- Bridge map: "nodeA:nodeB" -> bridge name ---
# Derived from topology.yml and setup-bridges.sh.
# Both directions are included so lookup order doesn't matter.
declare -A BRIDGE_MAP=(
    # border <-> bastion (br000-br001)
    [border-1:bastion]=br000    [bastion:border-1]=br000
    [border-2:bastion]=br001    [bastion:border-2]=br001

    # border <-> spine (br002-br005)
    [border-1:spine-1]=br002    [spine-1:border-1]=br002
    [border-1:spine-2]=br003    [spine-2:border-1]=br003
    [border-2:spine-1]=br004    [spine-1:border-2]=br004
    [border-2:spine-2]=br005    [spine-2:border-2]=br005

    # spine-1 <-> leaf (br006-br013)
    [spine-1:leaf-1a]=br006     [leaf-1a:spine-1]=br006
    [spine-1:leaf-1b]=br007     [leaf-1b:spine-1]=br007
    [spine-1:leaf-2a]=br008     [leaf-2a:spine-1]=br008
    [spine-1:leaf-2b]=br009     [leaf-2b:spine-1]=br009
    [spine-1:leaf-3a]=br010     [leaf-3a:spine-1]=br010
    [spine-1:leaf-3b]=br011     [leaf-3b:spine-1]=br011
    [spine-1:leaf-4a]=br012     [leaf-4a:spine-1]=br012
    [spine-1:leaf-4b]=br013     [leaf-4b:spine-1]=br013

    # spine-2 <-> leaf (br014-br021)
    [spine-2:leaf-1a]=br014     [leaf-1a:spine-2]=br014
    [spine-2:leaf-1b]=br015     [leaf-1b:spine-2]=br015
    [spine-2:leaf-2a]=br016     [leaf-2a:spine-2]=br016
    [spine-2:leaf-2b]=br017     [leaf-2b:spine-2]=br017
    [spine-2:leaf-3a]=br018     [leaf-3a:spine-2]=br018
    [spine-2:leaf-3b]=br019     [leaf-3b:spine-2]=br019
    [spine-2:leaf-4a]=br020     [leaf-4a:spine-2]=br020
    [spine-2:leaf-4b]=br021     [leaf-4b:spine-2]=br021

    # leaf <-> server rack 1 (br022-br029)
    [leaf-1a:srv-1-1]=br022     [srv-1-1:leaf-1a]=br022
    [leaf-1b:srv-1-1]=br023     [srv-1-1:leaf-1b]=br023
    [leaf-1a:srv-1-2]=br024     [srv-1-2:leaf-1a]=br024
    [leaf-1b:srv-1-2]=br025     [srv-1-2:leaf-1b]=br025
    [leaf-1a:srv-1-3]=br026     [srv-1-3:leaf-1a]=br026
    [leaf-1b:srv-1-3]=br027     [srv-1-3:leaf-1b]=br027
    [leaf-1a:srv-1-4]=br028     [srv-1-4:leaf-1a]=br028
    [leaf-1b:srv-1-4]=br029     [srv-1-4:leaf-1b]=br029

    # leaf <-> server rack 2 (br030-br037)
    [leaf-2a:srv-2-1]=br030     [srv-2-1:leaf-2a]=br030
    [leaf-2b:srv-2-1]=br031     [srv-2-1:leaf-2b]=br031
    [leaf-2a:srv-2-2]=br032     [srv-2-2:leaf-2a]=br032
    [leaf-2b:srv-2-2]=br033     [srv-2-2:leaf-2b]=br033
    [leaf-2a:srv-2-3]=br034     [srv-2-3:leaf-2a]=br034
    [leaf-2b:srv-2-3]=br035     [srv-2-3:leaf-2b]=br035
    [leaf-2a:srv-2-4]=br036     [srv-2-4:leaf-2a]=br036
    [leaf-2b:srv-2-4]=br037     [srv-2-4:leaf-2b]=br037

    # leaf <-> server rack 3 (br038-br045)
    [leaf-3a:srv-3-1]=br038     [srv-3-1:leaf-3a]=br038
    [leaf-3b:srv-3-1]=br039     [srv-3-1:leaf-3b]=br039
    [leaf-3a:srv-3-2]=br040     [srv-3-2:leaf-3a]=br040
    [leaf-3b:srv-3-2]=br041     [srv-3-2:leaf-3b]=br041
    [leaf-3a:srv-3-3]=br042     [srv-3-3:leaf-3a]=br042
    [leaf-3b:srv-3-3]=br043     [srv-3-3:leaf-3b]=br043
    [leaf-3a:srv-3-4]=br044     [srv-3-4:leaf-3a]=br044
    [leaf-3b:srv-3-4]=br045     [srv-3-4:leaf-3b]=br045

    # leaf <-> server rack 4 (br046-br053)
    [leaf-4a:srv-4-1]=br046     [srv-4-1:leaf-4a]=br046
    [leaf-4b:srv-4-1]=br047     [srv-4-1:leaf-4b]=br047
    [leaf-4a:srv-4-2]=br048     [srv-4-2:leaf-4a]=br048
    [leaf-4b:srv-4-2]=br049     [srv-4-2:leaf-4b]=br049
    [leaf-4a:srv-4-3]=br050     [srv-4-3:leaf-4a]=br050
    [leaf-4b:srv-4-3]=br051     [srv-4-3:leaf-4b]=br051
    [leaf-4a:srv-4-4]=br052     [srv-4-4:leaf-4a]=br052
    [leaf-4b:srv-4-4]=br053     [srv-4-4:leaf-4b]=br053
)

# --- Functions ---

# log_chaos MESSAGE
# Prints a timestamped chaos log line to stderr.
log_chaos() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [chaos] $*" >&2
}

# require_args EXPECTED ACTUAL USAGE
# Exits with usage message if argument count is wrong.
require_args() {
    local expected="$1" actual="$2" usage="$3"
    if (( actual < expected )); then
        echo "ERROR: Expected at least $expected argument(s), got $actual" >&2
        echo "" >&2
        echo "Usage: $usage" >&2
        exit 1
    fi
}

# resolve_bridge NODE_A NODE_B
# Prints the bridge name connecting two nodes. Exits on failure.
resolve_bridge() {
    local node_a="$1" node_b="$2"
    local key="${node_a}:${node_b}"
    local bridge="${BRIDGE_MAP[$key]:-}"

    if [[ -z "$bridge" ]]; then
        log_chaos "ERROR: No bridge found for link ${node_a} <-> ${node_b}"
        log_chaos "  Check node names against topology.yml"
        return 1
    fi

    echo "$bridge"
}

# find_veths BRIDGE
# Prints all host-side veth/tap interfaces attached to the given bridge, one per line.
# These are the interfaces where tc netem rules should be applied.
find_veths() {
    local bridge="$1"

    if ! ip link show "$bridge" &>/dev/null; then
        log_chaos "ERROR: Bridge $bridge does not exist"
        return 1
    fi

    # List all interfaces whose master is this bridge, excluding the bridge itself
    ip -o link show master "$bridge" 2>/dev/null | awk -F'[ :]+' '{print $2}' | grep -v "^${bridge}$"
}

# annotate TEXT TAGS_CSV
# Posts a Grafana annotation. Tags are comma-separated (e.g., "chaos,link-down,spine-1").
# Fails silently if Grafana is unreachable (chaos scripts should not fail on annotation errors).
annotate() {
    local text="$1"
    local tags_csv="$2"

    # Convert comma-separated tags to JSON array
    local tags_json
    tags_json=$(echo "$tags_csv" | awk -F',' '{
        printf "["
        for (i=1; i<=NF; i++) {
            gsub(/^ +| +$/, "", $i)
            printf "\"%s\"", $i
            if (i < NF) printf ","
        }
        printf "]"
    }')

    local payload
    payload=$(printf '{"text":"%s","tags":%s}' \
        "$(echo "$text" | sed 's/"/\\"/g')" \
        "$tags_json")

    curl -s -o /dev/null -w "" \
        -X POST "${GRAFANA_URL}/api/annotations" \
        -H "Content-Type: application/json" \
        -u "${GRAFANA_USER}:${GRAFANA_PASS}" \
        -d "$payload" 2>/dev/null || true

    log_chaos "Grafana annotation: $text [tags: $tags_csv]"
}
