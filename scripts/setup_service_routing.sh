#!/bin/bash

# Service IP
ip addr add 104.204.136.50/28 dev wlp7s0 2>/dev/null

# WG allowed-ips for service traffic
wg set wg-ca-cA peer ocnNjGlV/bTB+OZLtkzZUYC+1OuMadNAE5K4SRaXnyI= allowed-ips 0.0.0.0/0
wg set wg-ca-cB peer Wz3m/cfp+4yE8GNklKC+i5WEr61RVTxcd77foCpyrXI= allowed-ips 0.0.0.0/0
wg set wg-cb-cA peer ocnNjGlV/bTB+OZLtkzZUYC+1OuMadNAE5K4SRaXnyI= allowed-ips 0.0.0.0/0
wg set wg-cb-cB peer Wz3m/cfp+4yE8GNklKC+i5WEr61RVTxcd77foCpyrXI= allowed-ips 0.0.0.0/0

# Netns allowed-ips
ip netns exec ns_fa wg set wg-fa-cA peer ocnNjGlV/bTB+OZLtkzZUYC+1OuMadNAE5K4SRaXnyI= allowed-ips 0.0.0.0/0
ip netns exec ns_fb wg set wg-fb-cA peer ocnNjGlV/bTB+OZLtkzZUYC+1OuMadNAE5K4SRaXnyI= allowed-ips 0.0.0.0/0
ip netns exec ns_sl_a wg set wg-sa-cA peer ocnNjGlV/bTB+OZLtkzZUYC+1OuMadNAE5K4SRaXnyI= allowed-ips 0.0.0.0/0
ip netns exec ns_sl_b wg set wg-sb-cA peer ocnNjGlV/bTB+OZLtkzZUYC+1OuMadNAE5K4SRaXnyI= allowed-ips 0.0.0.0/0

# Netns routes to controller
ip netns exec ns_fa ip route add 104.204.136.13 via 192.168.0.1 dev enp1s0 2>/dev/null
ip netns exec ns_fa ip route add 104.204.136.14 via 192.168.0.1 dev enp1s0 2>/dev/null
ip netns exec ns_fa ip route add 104.204.136.48/28 via 10.201.1.1 dev veth_fa_i 2>/dev/null

ip netns exec ns_fb ip route add 104.204.136.13 via 192.168.12.1 dev enp2s0 2>/dev/null
ip netns exec ns_fb ip route add 104.204.136.14 via 192.168.12.1 dev enp2s0 2>/dev/null
ip netns exec ns_fb ip route add 104.204.136.48/28 via 10.201.2.1 dev veth_fb_i 2>/dev/null

ip netns exec ns_sl_a ip route add 104.204.136.13 via 192.168.2.1 dev enp3s0 2>/dev/null
ip netns exec ns_sl_a ip route add 104.204.136.14 via 192.168.2.1 dev enp3s0 2>/dev/null
ip netns exec ns_sl_a ip route add 104.204.136.48/28 via 10.201.3.1 dev veth_sl_a_i 2>/dev/null

ip netns exec ns_sl_b ip route add 104.204.136.13 via 192.168.1.1 dev enp4s0 2>/dev/null
ip netns exec ns_sl_b ip route add 104.204.136.14 via 192.168.1.1 dev enp4s0 2>/dev/null
ip netns exec ns_sl_b ip route add 104.204.136.48/28 via 10.201.4.1 dev veth_sl_b_i 2>/dev/null

# Netns forwarding
ip netns exec ns_fa sysctl -w net.ipv4.ip_forward=1
ip netns exec ns_fb sysctl -w net.ipv4.ip_forward=1
ip netns exec ns_sl_a sysctl -w net.ipv4.ip_forward=1
ip netns exec ns_sl_b sysctl -w net.ipv4.ip_forward=1

# Routing tables
ip route replace default dev wg-ca-cA table tmo_cA
ip route replace default dev wg-ca-cB table tmo_cB
ip route replace default dev wg-cb-cA table att_cA
ip route replace default dev wg-cb-cB table att_cB
ip route replace default via 10.201.1.2 dev veth_fa table fa
ip route replace default via 10.201.2.2 dev veth_fb table fb
ip route replace default via 10.201.3.2 dev veth_sl_a table sl_a
ip route replace default via 10.201.4.2 dev veth_sl_b table sl_b

# Default active path (fiber A)
ip rule del from 104.204.136.48/28 2>/dev/null
ip rule add from 104.204.136.48/28 lookup fa priority 90

echo "Service routing configured"
