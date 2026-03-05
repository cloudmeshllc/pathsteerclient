
# Management routing fix
ip rule add to 10.1.1.0/24 lookup main priority 50 2>/dev/null || true
ip rule add from 10.1.1.1 lookup main priority 51 2>/dev/null || true

# WiFi routing fix
echo 1 > /proc/sys/net/ipv4/conf/wlp7s0/proxy_arp
echo 1 > /proc/sys/net/ipv4/conf/enp6s0/proxy_arp
ip addr add 10.1.1.250/24 dev wlp7s0 2>/dev/null || true

# NAT for WiFi/management to internet
iptables -t nat -A POSTROUTING -s 10.1.1.0/24 -o wwan1 -j MASQUERADE
iptables -A FORWARD -i wlp7s0 -j ACCEPT
iptables -A INPUT -i wlp7s0 -j ACCEPT

# Management routing - local stays local
ip rule add to 10.1.1.0/24 lookup main priority 50 2>/dev/null || true
ip rule add from 10.1.1.1 lookup main priority 51 2>/dev/null || true

# Service subnet routing through fiber tunnel
ip route add 104.204.136.48/28 via 10.201.1.2 dev veth_fa table service 2>/dev/null || true
ip rule add from 104.204.136.48/28 lookup service priority 90 2>/dev/null || true
ip netns exec ns_fa ip route add 104.204.136.48/28 via 10.201.1.1 dev veth_fa_i 2>/dev/null || true
ip netns exec ns_fa iptables -t nat -A POSTROUTING -s 104.204.136.48/28 -o enp1s0 -j MASQUERADE 2>/dev/null || true

# Service subnet routing through fiber tunnel
ip route add 104.204.136.48/28 via 10.201.1.2 dev veth_fa table service 2>/dev/null || true
ip rule add from 104.204.136.48/28 lookup service priority 90 2>/dev/null || true
ip netns exec ns_fa ip route add 104.204.136.48/28 via 10.201.1.1 dev veth_fa_i 2>/dev/null || true
ip netns exec ns_fa iptables -t nat -A POSTROUTING -s 104.204.136.48/28 -o enp1s0 -j MASQUERADE 2>/dev/null || true
