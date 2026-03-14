#!/bin/bash
# PathSteer Guardian — 12-way ECMP route setup
# Persists the WireGuard ECMP route in rt_vip table
# Called by pathsteer-ecmp-routes.service at boot

set -e

# Wait for WireGuard interfaces to come up
for iface in wg-fa-cA wg-fa-cB wg-fb-cA wg-fb-cB wg-sa-cA wg-sa-cB wg-sb-cA wg-sb-cB wg-ca-cA wg-ca-cB wg-cb-cA wg-cb-cB; do
    i=0
    while ! ip link show "$iface" up > /dev/null 2>&1 && [ $i -lt 30 ]; do
        sleep 1; i=$((i+1))
    done
done

# Add fwmark rule if not present
ip rule show | grep -q 'fwmark 0x6e lookup rt_vip' || \
    ip rule add fwmark 0x6e table rt_vip priority 900

# Flush existing rt_vip default route
ip route flush table rt_vip 2>/dev/null || true

# Add 12-way ECMP default route
ip route add default table rt_vip \
    nexthop dev wg-fa-cA weight 1 \
    nexthop dev wg-fa-cB weight 1 \
    nexthop dev wg-fb-cA weight 1 \
    nexthop dev wg-fb-cB weight 1 \
    nexthop dev wg-sa-cA weight 1 \
    nexthop dev wg-sa-cB weight 1 \
    nexthop dev wg-sb-cA weight 1 \
    nexthop dev wg-sb-cB weight 1 \
    nexthop dev wg-ca-cA weight 1 \
    nexthop dev wg-ca-cB weight 1 \
    nexthop dev wg-cb-cA weight 1 \
    nexthop dev wg-cb-cB weight 1

echo "PathSteer ECMP routes configured"
