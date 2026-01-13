#!/bin/bash
# /opt/pathsteer/scripts/setup_management_egress.sh
# Emergency management plane - tries each path until one works

set -e

# Always ensure enp6s0 is up for direct access
ip link set enp6s0 up 2>/dev/null || true
ip addr add 10.1.1.1/24 dev enp6s0 2>/dev/null || true

# Enable NAT in all namespaces (so they can forward management traffic)
for ns in ns_fb ns_fa ns_sl_a ns_sl_b; do
    ip netns exec $ns sysctl -qw net.ipv4.ip_forward=1
done

# NAT rules for each namespace's physical interface
ip netns exec ns_fb iptables -t nat -C POSTROUTING -o enp2s0 -j MASQUERADE 2>/dev/null || \
    ip netns exec ns_fb iptables -t nat -A POSTROUTING -o enp2s0 -j MASQUERADE

ip netns exec ns_fa iptables -t nat -C POSTROUTING -o enp1s0 -j MASQUERADE 2>/dev/null || \
    ip netns exec ns_fa iptables -t nat -A POSTROUTING -o enp1s0 -j MASQUERADE

ip netns exec ns_sl_a iptables -t nat -C POSTROUTING -o enp3s0 -j MASQUERADE 2>/dev/null || \
    ip netns exec ns_sl_a iptables -t nat -A POSTROUTING -o enp3s0 -j MASQUERADE

ip netns exec ns_sl_b iptables -t nat -C POSTROUTING -o enp4s0 -j MASQUERADE 2>/dev/null || \
    ip netns exec ns_sl_b iptables -t nat -A POSTROUTING -o enp4s0 -j MASQUERADE

# Raw internet routes inside each namespace (table 200)
ip netns exec ns_fb ip route replace default via 192.168.12.1 dev enp2s0 table 200
ip netns exec ns_fa ip route replace default via 192.168.0.1 dev enp1s0 table 200
ip netns exec ns_sl_a ip route replace default via 192.168.2.1 dev enp3s0 table 200
ip netns exec ns_sl_b ip route replace default via 192.168.1.1 dev enp4s0 table 200

# Rules to use table 200 for namespace-originated traffic
ip netns exec ns_fb ip rule add from 192.168.12.223 lookup 200 priority 100 2>/dev/null || true
ip netns exec ns_fa ip rule add from 192.168.0.129 lookup 200 priority 100 2>/dev/null || true
ip netns exec ns_sl_a ip rule add from 192.168.2.101 lookup 200 priority 100 2>/dev/null || true
ip netns exec ns_sl_b ip rule add from 192.168.1.191 lookup 200 priority 100 2>/dev/null || true

# Function to test a path
test_path() {
    local gw=$1
    local dev=$2
    timeout 3 ping -c 1 -I $dev $gw >/dev/null 2>&1
}

# Find working path and set as default
set_management_route() {
    # Remove old management default if exists
    ip route del default via 10.201.2.2 dev veth_fb metric 50 2>/dev/null || true
    ip route del default via 10.201.1.2 dev veth_fa metric 50 2>/dev/null || true
    ip route del default via 10.201.3.2 dev veth_sl_a metric 50 2>/dev/null || true
    ip route del default via 10.201.4.2 dev veth_sl_b metric 50 2>/dev/null || true

    # Try fiber B first
    if ip netns exec ns_fb ping -c 1 -W 2 192.168.12.1 >/dev/null 2>&1; then
        ip route add default via 10.201.2.2 dev veth_fb metric 50
        echo "Management via Fiber B (ns_fb)"
        return 0
    fi

    # Try fiber A
    if ip netns exec ns_fa ping -c 1 -W 2 192.168.0.1 >/dev/null 2>&1; then
        ip route add default via 10.201.1.2 dev veth_fa metric 50
        echo "Management via Fiber A (ns_fa)"
        return 0
    fi

    # Try Starlink A
    if ip netns exec ns_sl_a ping -c 1 -W 2 192.168.2.1 >/dev/null 2>&1; then
        ip route add default via 10.201.3.2 dev veth_sl_a metric 50
        echo "Management via Starlink A (ns_sl_a)"
        return 0
    fi

    # Try Starlink B
    if ip netns exec ns_sl_b ping -c 1 -W 2 192.168.1.1 >/dev/null 2>&1; then
        ip route add default via 10.201.4.2 dev veth_sl_b metric 50
        echo "Management via Starlink B (ns_sl_b)"
        return 0
    fi

    # Fallback: cellular (already default at metric 100)
    echo "Management via cellular (fallback)"
    return 0
}

set_management_route
echo "Management egress configured"
