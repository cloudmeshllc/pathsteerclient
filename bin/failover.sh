#!/bin/bash
# PathSteer Emergency Failover - runs every 60s via cron
# Simple, bulletproof

LOG="/var/log/pathsteer-failover.log"
PROBE_TARGETS="8.8.8.8 1.1.1.1 4.2.2.2"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> $LOG; }

# Test connectivity - try namespace first, then direct
test_path() {
    local ns=$1
    local target="8.8.8.8"
    
    if [ -n "$ns" ]; then
        ip netns exec $ns ping -c1 -W2 $target &>/dev/null && return 0
    else
        ping -c1 -W2 $target &>/dev/null && return 0
    fi
    return 1
}

# Get current default route
CURRENT=$(ip route | grep "^default" | head -1)

# Priority order - test each path via its namespace
BEST=""

# 1. Starlink namespace
if test_path ns_sl_a; then
    BEST="default via 10.201.3.2 dev veth_sl_a"
    BEST_NAME="Starlink"
# 2. Fiber namespace  
elif test_path ns_fa; then
    BEST="default via 10.201.1.2 dev veth_fa"
    BEST_NAME="Fiber"
fi

# Apply if different
if [ -n "$BEST" ]; then
    if ! echo "$CURRENT" | grep -q "$(echo $BEST | awk '{print $3}')"; then
        log "Switching to $BEST_NAME: $BEST"
        ip route del default 2>/dev/null
        ip route add $BEST
    fi
fi

# Ensure Tailscale is running
if ! pgrep -x tailscaled &>/dev/null; then
    log "Restarting tailscaled"
    systemctl restart tailscaled
fi
