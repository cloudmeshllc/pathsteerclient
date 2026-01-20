#!/bin/bash
# Setup policy routes for cellular WireGuard binding

# Ensure tables exist (pathsteer names to match ip rules)
grep -q "^100 pathsteer$" /etc/iproute2/rt_tables || echo "100 pathsteer" >> /etc/iproute2/rt_tables
grep -q "^101 pathsteer_lte1$" /etc/iproute2/rt_tables || echo "101 pathsteer_lte1" >> /etc/iproute2/rt_tables

# Add fwmark rules if not present
ip rule list | grep -q "fwmark 0x64 lookup pathsteer" || ip rule add fwmark 0x64 table pathsteer pref 5209
ip rule list | grep -q "fwmark 0x65 lookup pathsteer_lte1" || ip rule add fwmark 0x65 table pathsteer_lte1 pref 5208

# Get gateway from QMI settings
get_gateway() {
    local dev=$1
    qmicli -d "$dev" -p --wds-get-current-settings 2>/dev/null | grep "gateway" | awk '{print $NF}'
}

# Wait for modems to have IP
sleep 2

# Setup wwan0 (cell_a / T-Mobile) -> table pathsteer (fwmark 0x64)
GW0=$(get_gateway /dev/cdc-wdm0)
if [[ -n "$GW0" ]]; then
    ip route add $GW0 dev wwan0 2>/dev/null || true
    ip route replace default via $GW0 dev wwan0 table pathsteer
    echo "cell_a (T-Mobile): wwan0 via $GW0 -> table pathsteer"
fi

# Setup wwan1 (cell_b / AT&T) -> table pathsteer_lte1 (fwmark 0x65)
GW1=$(get_gateway /dev/cdc-wdm1)
if [[ -n "$GW1" ]]; then
    ip route add $GW1 dev wwan1 2>/dev/null || true
    ip route replace default via $GW1 dev wwan1 table pathsteer_lte1
    echo "cell_b (AT&T): wwan1 via $GW1 -> table pathsteer_lte1"
fi

echo "Policy routes configured"
