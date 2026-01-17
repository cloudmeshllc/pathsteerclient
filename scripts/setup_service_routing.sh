#!/bin/bash
# PathSteer Service Routing - sets up NAT and default routes

# Wait for namespaces to be ready
sleep 2

# Enable NAT for all namespaces
for ns in ns_fa ns_fb ns_sl_a ns_sl_b; do
    if ip netns list | grep -q "^$ns"; then
        iface=$(ip netns exec $ns ip route 2>/dev/null | grep default | awk '{print $5}')
        if [ -n "$iface" ]; then
            ip netns exec $ns iptables -t nat -C POSTROUTING -o $iface -j MASQUERADE 2>/dev/null || \
            ip netns exec $ns iptables -t nat -A POSTROUTING -o $iface -j MASQUERADE
            echo "NAT enabled: $ns -> $iface"
        fi
    fi
done

# Add default route via best available path
if ip netns exec ns_fa ping -c1 -W2 8.8.8.8 &>/dev/null; then
    ip route del default 2>/dev/null
    ip route add default via 10.201.1.2 dev veth_fa
    echo "Default route: fiber (ns_fa)"
elif ip netns exec ns_sl_a ping -c1 -W2 8.8.8.8 &>/dev/null; then
    ip route del default 2>/dev/null
    ip route add default via 10.201.3.2 dev veth_sl_a
    echo "Default route: starlink (ns_sl_a)"
fi

# WireGuard peer configs (existing)
ip netns exec ns_fa wg set wg-fa-cA peer ocnNjGlV/bTB+OZLtkzZUYC+1OuMadNAE5K4SRaXnyI= allowed-ips 0.0.0.0/0 2>/dev/null
ip netns exec ns_sl_a wg set wg-sa-cA peer ocnNjGlV/bTB+OZLtkzZUYC+1OuMadNAE5K4SRaXnyI= allowed-ips 0.0.0.0/0 2>/dev/null

# Controller routes
ip netns exec ns_fa ip route add 104.204.136.13 via 192.168.0.1 dev enp1s0 2>/dev/null
ip netns exec ns_fa ip route add 104.204.136.48/28 via 10.201.1.1 dev veth_fa_i 2>/dev/null

echo "Service routing complete"
