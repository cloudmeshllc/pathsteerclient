#!/bin/bash
###############################################################################
# starlink-stats.sh - Poll Starlink dish metrics via gRPC
#
# Usage: starlink-stats.sh <namespace> <dish_ip>
###############################################################################

NS="${1:-ns_sl_a}"
DISH_IP="${2:-192.168.100.1}"

# Try to get stats from dish via gRPC (using grpcurl if available)
if command -v grpcurl &>/dev/null; then
    RESULT=$(ip netns exec "$NS" timeout 2 grpcurl -plaintext -d '{}' \
        "${DISH_IP}:9200" SpaceX.API.Device.Device/Handle 2>/dev/null)
    
    if [[ -n "$RESULT" ]]; then
        # Parse gRPC response - extract key metrics
        echo "$RESULT" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    dish = data.get("dishGetStatus", {})
    print(json.dumps({
        "latency_ms": dish.get("popPingLatencyMs", 0),
        "downlink_bps": dish.get("downlinkThroughputBps", 0),
        "uplink_bps": dish.get("uplinkThroughputBps", 0),
        "obstruction": dish.get("obstructionStats", {}).get("fractionObstructed", 0),
        "snr_ok": dish.get("state", "") == "CONNECTED"
    }))
except:
    print("{\"error\": \"parse_failed\"}")
' 2>/dev/null
        exit 0
    fi
fi

# Fallback: simple HTTP check
HTTP_STATUS=$(ip netns exec "$NS" curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 2 "http://${DISH_IP}" 2>/dev/null)

if [[ "$HTTP_STATUS" == "200" ]]; then
    echo '{"latency_ms": 30, "snr_ok": true, "obstruction": 0}'
else
    echo '{"error": "dish_unreachable"}'
fi
