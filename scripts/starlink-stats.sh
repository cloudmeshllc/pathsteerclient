#!/bin/bash
# Poll Starlink dish stats via gRPC

NS="${1:-ns_sl_a}"
DISH_IP="${2:-192.168.100.1}"

# Get status JSON
STATUS=$(ip netns exec "$NS" grpcurl -plaintext -d '{"get_status":{}}' "$DISH_IP:9200" SpaceX.API.Device.Device/Handle 2>/dev/null)

if [[ -z "$STATUS" ]]; then
    echo '{"error": "no response"}'
    exit 1
fi

# Extract key metrics
echo "$STATUS" | jq '{
    latency_ms: .dishGetStatus.popPingLatencyMs,
    downlink_bps: .dishGetStatus.downlinkThroughputBps,
    uplink_bps: .dishGetStatus.uplinkThroughputBps,
    obstruction: .dishGetStatus.obstructionStats.fractionObstructed,
    snr_ok: .dishGetStatus.isSnrAboveNoiseFloor,
    uptime_s: .dishGetStatus.deviceState.uptimeS,
    alerts: .dishGetStatus.alerts
}'
