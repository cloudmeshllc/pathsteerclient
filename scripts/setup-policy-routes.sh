#!/bin/bash
# Setup policy routes for cellular WireGuard binding

# Ensure tables exist
grep -q "cell_a" /etc/iproute2/rt_tables || echo "100 cell_a" >> /etc/iproute2/rt_tables
grep -q "cell_b" /etc/iproute2/rt_tables || echo "101 cell_b" >> /etc/iproute2/rt_tables

# Add fwmark rules
ip rule add fwmark 0x64 table cell_a 2>/dev/null || true
ip rule add fwmark 0x65 table cell_b 2>/dev/null || true

# Get gateway from bearer, not guessing
for iface in wwan0 wwan1; do
    IP=$(ip -4 addr show $iface 2>/dev/null | grep -oP 'inet \K[\d.]+')
    [[ -z "$IP" ]] && continue
    
    # Gateway is in routing table
    GW=$(ip route show dev $iface 2>/dev/null | awk '/^[0-9]/{print $1}' | head -1)
    
    if [[ "$IP" == 162.191.* ]]; then
        echo "cell_a (T-Mobile): $iface $IP via $GW"
        ip route replace default via $GW dev $iface table cell_a
    else
        echo "cell_b (AT&T): $iface $IP via $GW"
        ip route replace default via $GW dev $iface table cell_b
    fi
done

echo "Policy routes configured"
