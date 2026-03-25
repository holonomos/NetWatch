#!/usr/bin/env bash
# ==========================================================================
# monitor.sh — Availability monitor for the validation workload
# ==========================================================================
# Continuously curls the nginx LoadBalancer service and logs results.
# Run during chaos testing to measure availability.
#
# Usage: bash validation/monitor.sh <service-ip>
# Output: timestamp, HTTP status, latency (ms)
# ==========================================================================
set -uo pipefail

SERVICE_IP="${1:-}"
if [ -z "$SERVICE_IP" ]; then
    echo "Usage: bash validation/monitor.sh <service-ip>"
    echo "  Get the IP: kubectl get svc nginx-validation -o jsonpath='{.status.loadBalancer.ingress[0].ip}'"
    exit 1
fi

INTERVAL="${2:-1}"
LOG_FILE="validation/results/monitor-$(date +%Y%m%d-%H%M%S).csv"
mkdir -p validation/results

echo "timestamp,status,latency_ms" > "$LOG_FILE"
echo "Monitoring http://${SERVICE_IP}/ every ${INTERVAL}s"
echo "  Log: $LOG_FILE"
echo "  Press Ctrl+C to stop"
echo ""

TOTAL=0
SUCCESS=0
FAIL=0
MAX_GAP=0
LAST_SUCCESS=$(date +%s%3N)

while true; do
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S.%3N')
    NOW_MS=$(date +%s%3N)

    RESULT=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" \
        --connect-timeout 2 --max-time 5 \
        "http://${SERVICE_IP}/" 2>/dev/null || echo "000 0")

    STATUS=$(echo "$RESULT" | awk '{print $1}')
    LATENCY=$(echo "$RESULT" | awk '{printf "%.0f", $2 * 1000}')

    TOTAL=$((TOTAL + 1))

    if [ "$STATUS" -ge 200 ] && [ "$STATUS" -lt 400 ]; then
        SUCCESS=$((SUCCESS + 1))
        GAP=$(( (NOW_MS - LAST_SUCCESS) ))
        if [ "$GAP" -gt "$MAX_GAP" ] && [ "$TOTAL" -gt 1 ]; then
            MAX_GAP=$GAP
        fi
        LAST_SUCCESS=$NOW_MS
        printf "\r  %s | %s | %sms | avail: %.1f%% | max_gap: %dms    " \
            "$TIMESTAMP" "$STATUS" "$LATENCY" \
            "$(echo "scale=1; $SUCCESS * 100 / $TOTAL" | bc)" "$MAX_GAP"
    else
        FAIL=$((FAIL + 1))
        printf "\r  %s | %s | FAIL  | avail: %.1f%% | max_gap: %dms    " \
            "$TIMESTAMP" "$STATUS" \
            "$(echo "scale=1; $SUCCESS * 100 / $TOTAL" | bc)" "$MAX_GAP"
    fi

    echo "${TIMESTAMP},${STATUS},${LATENCY}" >> "$LOG_FILE"
    sleep "$INTERVAL"
done
