#!/bin/bash
# PathSteer Guardian Boot Init

# DNS
echo "nameserver 4.2.2.2" > /etc/resolv.conf

# IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward

# Management interface
ip addr add 10.1.1.1/24 dev enp6s0 2>/dev/null || true

# WiFi AP interface  
ip addr add 10.1.1.250/24 dev wlp7s0 2>/dev/null || true
echo 1 > /proc/sys/net/ipv4/conf/wlp7s0/proxy_arp
echo 1 > /proc/sys/net/ipv4/conf/enp6s0/proxy_arp

# Routing rules
ip rule add to 10.1.1.0/24 lookup main priority 50 2>/dev/null || true
ip rule add from 10.1.1.1 lookup main priority 51 2>/dev/null || true
ip rule add from 104.204.136.48/28 lookup service priority 90 2>/dev/null || true

# NAT for management/WiFi
iptables -t nat -C POSTROUTING -s 10.1.1.0/24 -o wwan1 -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s 10.1.1.0/24 -o wwan1 -j MASQUERADE

# WiFi forwarding
iptables -A FORWARD -i wlp7s0 -j ACCEPT 2>/dev/null || true
iptables -A INPUT -i wlp7s0 -j ACCEPT 2>/dev/null || true

echo "PathSteer boot init complete"
