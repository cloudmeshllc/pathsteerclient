#!/bin/bash
# PathSteer Emergency Failover - runs every 60s via cron
# Simple, bulletproof - no dependencies on modems or complex services

LOG="/var/log/pathsteer-failover.log"
PROBE_TARGETS="8.8.8.8 1.1.1.1"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> $LOG; }

# Test connectivity via a specific gateway
test_path() {
    local gw=$1
    local dev=$2
    for target in $PROBE_TARGETS; do
        if ping -c1 -W2 -I $dev $target &>/dev/null; then
            return 0
        fi
    done
    return 1
}

# Get current default route
CURRENT=$(ip route | grep "^default" | head -1 | awk '{print $3}')

# Priority order - try each path
# 1. Starlink (via veth)
if test_path 10.201.3.2 veth_sl_a; then
    BEST_GW="10.201.3.2"
    BEST_DEV="veth_sl_a"
# 2. Fiber (via namespace veth) 
elif test_path 10.201.1.2 veth_fa; then
    BEST_GW="10.201.1.2"
    BEST_DEV="veth_fa"
# 3. Direct fiber (fallback)
elif test_path 192.168.0.1 enp1s0; then
    BEST_GW="192.168.0.1"
    BEST_DEV="enp1s0"
fi

# Switch if needed
if [ -n "$BEST_GW" ] && [ "$BEST_GW" != "$CURRENT" ]; then
    log "Switching default route: $CURRENT -> $BEST_GW ($BEST_DEV)"
    ip route del default 2>/dev/null
    ip route add default via $BEST_GW dev $BEST_DEV
fi

# Ensure Tailscale is running
if ! systemctl is-active tailscaled &>/dev/null; then
    log "Restarting tailscaled"
    systemctl restart tailscaled
fi
