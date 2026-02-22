#!/bin/bash
###############################################################################
# PathSteer Guardian — Master Boot Initialization
#
# ONE SCRIPT TO RULE THEM ALL
#
# Replaces: pathsteer-interfaces, pathsteer-routing, pathsteer-management,
#           pathsteer-policy-routes, pathsteer-fastest-route, pathsteer-ctrl,
#           pathsteer-training, ns-init.sh, boot-init.sh
#
# Run order: AFTER pathsteer-netns (creates ns_fa/ns_fb/ns_sl_a/ns_sl_b)
#            AFTER pathsteer-*-tunnels (creates WG interfaces in namespaces)
#            AFTER pathsteer-modem (cellular bearers up)
#
# Version: 2026-02-22 (dual-stack + VIP 104.204.138.0/24)
###############################################################################

LOG="/var/log/pathsteer/master-init.log"
mkdir -p /var/log/pathsteer /run/pathsteer
exec > >(tee -a "$LOG") 2>&1
echo "=== master-init.sh starting $(date) ==="

###############################################################################
# 0. IMMEDIATE: Default route + DNS (so Tailscale works RIGHT AWAY)
###############################################################################
echo "nameserver 4.2.2.2" > /etc/resolv.conf
# DNS entries for controller resolution in all namespaces
grep -q "ctrl-a.pathsteerlabs.com" /etc/hosts || echo "104.204.136.13 ctrl-a.pathsteerlabs.com" >> /etc/hosts
grep -q "ctrl-b.pathsteerlabs.com" /etc/hosts || echo "104.204.136.14 ctrl-b.pathsteerlabs.com" >> /etc/hosts
echo 1 > /proc/sys/net/ipv4/ip_forward

# Remove any bad default routes from old services
ip route del default via 10.201.2.2 dev veth_fb 2>/dev/null || true
ip route del default via 10.201.3.2 dev veth_sl_a 2>/dev/null || true
ip route del default via 10.201.1.2 dev veth_fa 2>/dev/null || true

# Set cellular defaults — wwan0 primary, wwan1 backup
ip route replace default dev wwan0 metric 100 2>/dev/null || true
ip route replace default dev wwan1 metric 200 2>/dev/null || true
echo "Default route set via cellular (Tailscale should work now)"

###############################################################################
# 1. Create cellular namespaces (netns service only creates fa/fb/sl_a/sl_b)
###############################################################################
for ns in ns_cell_a ns_cell_b; do
    ip netns add $ns 2>/dev/null || true
    ip netns exec $ns ip link set lo up
    ip netns exec $ns sysctl -qw net.ipv4.ip_forward=1
    ip netns exec $ns sysctl -qw net.ipv4.conf.all.rp_filter=0
done
echo "Cellular namespaces created"

###############################################################################
# 2. Create ns_vip with VIP address
###############################################################################
ip netns add ns_vip 2>/dev/null || true
ip netns exec ns_vip ip link set lo up
ip netns exec ns_vip ip addr add 104.204.138.50/32 dev lo 2>/dev/null || true
ip netns exec ns_vip sysctl -qw net.ipv4.ip_forward=1
echo "ns_vip created with 104.204.138.50/32"

###############################################################################
# 3. Disable rp_filter globally (prevents routing drops)
###############################################################################
sysctl -qw net.ipv4.conf.all.rp_filter=0
sysctl -qw net.ipv4.conf.default.rp_filter=0
for iface in wlp7s0 veth_fa veth_fb veth_sl_a veth_sl_b veth_cell_a veth_cell_b wwan0 wwan1; do
    sysctl -qw net.ipv4.conf.$iface.rp_filter=0 2>/dev/null || true
done
echo "rp_filter disabled"

###############################################################################
# 4. Cellular veth pairs (main <-> cell namespaces) and WG tunnels
###############################################################################
# Stop any old cell WG in main namespace
for tun in wg-ca-cA wg-ca-cB wg-cb-cA wg-cb-cB; do
    wg-quick down $tun 2>/dev/null || true
done

# Cell A veth pair
ip link del veth_cell_a 2>/dev/null || true
ip link add veth_cell_a type veth peer name veth_cell_a_i
ip addr add 10.201.5.1/30 dev veth_cell_a 2>/dev/null || true
ip link set veth_cell_a up
ip link set veth_cell_a_i netns ns_cell_a
ip netns exec ns_cell_a ip addr add 10.201.5.2/30 dev veth_cell_a_i 2>/dev/null || true
ip netns exec ns_cell_a ip link set veth_cell_a_i up

# Cell B veth pair
ip link del veth_cell_b 2>/dev/null || true
ip link add veth_cell_b type veth peer name veth_cell_b_i
ip addr add 10.201.6.1/30 dev veth_cell_b 2>/dev/null || true
ip link set veth_cell_b up
ip link set veth_cell_b_i netns ns_cell_b
ip netns exec ns_cell_b ip addr add 10.201.6.2/30 dev veth_cell_b_i 2>/dev/null || true
ip netns exec ns_cell_b ip link set veth_cell_b_i up
echo "Cellular veth pairs created"

# WG tunnels inside cell namespaces
ip netns exec ns_cell_a wg-quick up wg-ca-cA 2>/dev/null || true
ip netns exec ns_cell_a wg-quick up wg-ca-cB 2>/dev/null || true
ip netns exec ns_cell_b wg-quick up wg-cb-cA 2>/dev/null || true
ip netns exec ns_cell_b wg-quick up wg-cb-cB 2>/dev/null || true
echo "Cellular WG tunnels up"

# NAT for cellular (main namespace)
iptables-legacy -t nat -C POSTROUTING -s 10.201.5.0/30 -o wwan0 -j MASQUERADE 2>/dev/null || \
    iptables-legacy -t nat -A POSTROUTING -s 10.201.5.0/30 -o wwan0 -j MASQUERADE
iptables-legacy -t nat -C POSTROUTING -s 10.201.6.0/30 -o wwan1 -j MASQUERADE 2>/dev/null || \
    iptables-legacy -t nat -A POSTROUTING -s 10.201.6.0/30 -o wwan1 -j MASQUERADE

# Main namespace ip rules for cellular NAT return
ip rule del from 10.201.5.0/30 lookup raw_wwan0 priority 80 2>/dev/null || true
ip rule add from 10.201.5.0/30 lookup raw_wwan0 priority 80
ip rule del from 10.201.6.0/30 lookup raw_wwan1 priority 81 2>/dev/null || true
ip rule add from 10.201.6.0/30 lookup raw_wwan1 priority 81
echo "Cellular NAT and rules configured"

###############################################################################
# 5. ns_vip <-> path namespace veth pairs
###############################################################################
for pair in "fa 10.201.10.1 10.201.10.2 ns_fa" \
            "fb 10.201.10.5 10.201.10.6 ns_fb" \
            "sl_a 10.201.10.9 10.201.10.10 ns_sl_a" \
            "sl_b 10.201.10.13 10.201.10.14 ns_sl_b" \
            "cell_a 10.201.10.17 10.201.10.18 ns_cell_a" \
            "cell_b 10.201.10.21 10.201.10.22 ns_cell_b"; do
    set -- $pair
    name=$1; vip_ip=$2; path_ip=$3; ns=$4
    ip link del vip_$name 2>/dev/null || true
    ip link add vip_$name type veth peer name vip_${name}_i
    ip link set vip_$name netns ns_vip
    ip link set vip_${name}_i netns $ns
    ip netns exec ns_vip ip addr add $vip_ip/30 dev vip_$name
    ip netns exec ns_vip ip link set vip_$name up
    ip netns exec $ns ip addr add $path_ip/30 dev vip_${name}_i 2>/dev/null || true
    ip netns exec $ns ip link set vip_${name}_i up
    echo "veth vip_$name <-> vip_${name}_i ($ns) UP"
done

###############################################################################
# 6. Return routes: /28 back to ns_vip from each path namespace
###############################################################################
ip netns exec ns_fa ip route replace 104.204.138.48/28 via 10.201.10.1 dev vip_fa_i
ip netns exec ns_fb ip route replace 104.204.138.48/28 via 10.201.10.5 dev vip_fb_i
ip netns exec ns_sl_a ip route replace 104.204.138.48/28 via 10.201.10.9 dev vip_sl_a_i
ip netns exec ns_sl_b ip route replace 104.204.138.48/28 via 10.201.10.13 dev vip_sl_b_i
ip netns exec ns_cell_a ip route replace 104.204.138.48/28 via 10.201.10.17 dev vip_cell_a_i
ip netns exec ns_cell_b ip route replace 104.204.138.48/28 via 10.201.10.21 dev vip_cell_b_i
echo "Return routes set"

###############################################################################
# 7. Policy routing: /28 service traffic through WG (table pathsteer = 100)
###############################################################################
for ns in ns_fa ns_fb ns_sl_a ns_sl_b ns_cell_a ns_cell_b; do
    ip netns exec $ns ip rule del from 104.204.138.48/28 lookup pathsteer priority 50 2>/dev/null || true
    ip netns exec $ns ip rule add from 104.204.138.48/28 lookup pathsteer priority 50
done

# WG default route in table pathsteer per namespace
ip netns exec ns_fa ip route replace default dev wg-fa-cA table pathsteer
ip netns exec ns_fb ip route replace default dev wg-fb-cA table pathsteer
ip netns exec ns_sl_a ip route replace default dev wg-sa-cA table pathsteer
ip netns exec ns_sl_b ip route replace default dev wg-sb-cA table pathsteer
ip netns exec ns_cell_a ip route replace default dev wg-ca-cA table pathsteer
ip netns exec ns_cell_b ip route replace default dev wg-cb-cA table pathsteer
echo "Policy routes set"

###############################################################################
# 8. Controller endpoint (ctrl-a=104.204.136.13, ctrl-b=104.204.136.14) routes for cellular (via main ns veth)
###############################################################################
ip netns exec ns_cell_a ip route replace 104.204.136.13 via 10.201.5.1 dev veth_cell_a_i
ip netns exec ns_cell_a ip route replace 104.204.136.14 via 10.201.5.1 dev veth_cell_a_i
ip netns exec ns_cell_b ip route replace 104.204.136.13 via 10.201.6.1 dev veth_cell_b_i
ip netns exec ns_cell_b ip route replace 104.204.136.14 via 10.201.6.1 dev veth_cell_b_i

# Cellular default through WG
ip netns exec ns_cell_a ip route replace default dev wg-ca-cA 2>/dev/null || true
ip netns exec ns_cell_b ip route replace default dev wg-cb-cA 2>/dev/null || true
echo "Cellular routes set"

###############################################################################
# 9. ISP default routes for fiber/starlink (for daemon probes + controller reach)
###############################################################################
for ns_gw in "ns_fa ps_ter_a 192.168.0.1" \
             "ns_fb ps_ter_b 192.168.12.1" \
             "ns_sl_a ps_sl_a 100.64.0.1" \
             "ns_sl_b ps_sl_b 192.168.2.1"; do
    set -- $ns_gw
    ns=$1; dev=$2; gw=$3
    LIVE_GW=$(ip netns exec $ns ip route show default 2>/dev/null | grep -v wg | awk '{print $3}' | head -1)
    [ -n "$LIVE_GW" ] && gw=$LIVE_GW
    ip netns exec $ns ip route replace default via $gw dev $dev 2>/dev/null || true
    ip netns exec $ns ip route replace 104.204.136.13 via $gw dev $dev 2>/dev/null || true
    ip netns exec $ns ip route replace 104.204.136.14 via $gw dev $dev 2>/dev/null || true
    echo "$ns: default via $gw dev $dev"
done

###############################################################################
# 10. Default ns_vip route (daemon will override on start)
###############################################################################
ip netns exec ns_vip ip route replace default via 10.201.10.2 dev vip_fa src 104.204.138.50
echo "ns_vip default route set via fa"

###############################################################################
# 11. Management interface + WiFi AP setup
###############################################################################
# Management port
ip addr add 10.1.1.1/24 dev enp6s0 2>/dev/null || ip addr add 10.1.1.1/24 dev ps_anchor 2>/dev/null || true

# WiFi AP interface
ip addr add 104.204.138.49/28 dev wlp7s0 2>/dev/null || true
echo 1 > /proc/sys/net/ipv4/conf/wlp7s0/proxy_arp 2>/dev/null || true

# WiFi client routing: mark forwarded /28 traffic and route via veth_fa
iptables -t mangle -D PREROUTING -i wlp7s0 -s 104.204.138.48/28 -j MARK --set-mark 100 2>/dev/null || true
iptables -t mangle -A PREROUTING -i wlp7s0 -s 104.204.138.48/28 -j MARK --set-mark 100
ip rule del fwmark 100 lookup service priority 80 2>/dev/null || true
ip rule add fwmark 100 lookup service priority 80

# Table service: route /28 client traffic into ns_fa via veth
ip route replace default via 10.201.1.2 dev veth_fa table service
ip route replace 104.204.138.48/28 via 10.201.1.2 dev veth_fa table service

# NO SNAT — pure routing via vip_wifi veth for return traffic
ip link del vip_wifi 2>/dev/null || true
ip link add vip_wifi type veth peer name vip_wifi_i
ip addr add 10.201.10.25/30 dev vip_wifi 2>/dev/null || true
ip link set vip_wifi up
ip link set vip_wifi_i netns ns_vip
ip netns exec ns_vip ip addr add 10.201.10.26/30 dev vip_wifi_i 2>/dev/null || true
ip netns exec ns_vip ip link set vip_wifi_i up
ip netns exec ns_vip ip route replace 104.204.138.48/28 via 10.201.10.25 dev vip_wifi_i
ip route flush cache

# Accept WiFi client traffic
iptables -D INPUT -i wlp7s0 -j ACCEPT 2>/dev/null || true
iptables -I INPUT 1 -i wlp7s0 -j ACCEPT
iptables -D FORWARD -i wlp7s0 -j ACCEPT 2>/dev/null || true
iptables -I FORWARD 1 -i wlp7s0 -j ACCEPT
iptables -D FORWARD -o wlp7s0 -j ACCEPT 2>/dev/null || true
iptables -I FORWARD 1 -o wlp7s0 -j ACCEPT

echo "WiFi routing configured (NO NAT, vip_wifi veth, fwmark 100 -> table service)"

###############################################################################
# 12. Start hostapd for WiFi AP
###############################################################################
killall hostapd 2>/dev/null || true
sleep 1

# Ensure clean driver state
modprobe -r iwlmvm 2>/dev/null || true
sleep 2
modprobe iwlwifi 2>/dev/null || true
sleep 3

# Re-add IP after driver reload
ip addr add 104.204.138.49/28 dev wlp7s0 2>/dev/null || true
ip link set wlp7s0 down 2>/dev/null || true
hostapd -B /etc/hostapd/hostapd.conf 2>/dev/null && echo "WiFi AP started" || echo "WiFi AP failed (non-fatal)"

###############################################################################
# 13. Start dnsmasq for WiFi DHCP
###############################################################################
systemctl restart dnsmasq 2>/dev/null || true
echo "dnsmasq restarted"

###############################################################################
# 14. Controller initial route
###############################################################################
/opt/pathsteer/scripts/controller-route-switch.sh fa 2>/dev/null || true
echo "Controller initial route set to fa"

###############################################################################
# 15. Forwarding in all namespaces
###############################################################################
for ns in ns_fa ns_fb ns_sl_a ns_sl_b ns_cell_a ns_cell_b ns_vip; do
    ip netns exec $ns sysctl -qw net.ipv4.ip_forward=1
    ip netns exec $ns sysctl -qw net.ipv4.conf.all.rp_filter=0 2>/dev/null || true
done
echo "Forwarding enabled in all namespaces"

###############################################################################
# DONE
###############################################################################
echo "=== master-init.sh complete $(date) ==="
echo "ns_vip VIP: $(ip netns exec ns_vip ip addr show lo | grep 104.204)"
echo "ns_vip veths: $(ip netns exec ns_vip ip link show | grep -c UP) UP"
echo "Namespaces: $(ip netns list | wc -l)"
echo "Default route: $(ip route show default | head -1)"

###############################################################################
# 16. IPv6 Dual-Stack Configuration
###############################################################################
echo "=== Configuring IPv6 dual-stack ==="

# Enable IPv6 forwarding globally
sysctl -qw net.ipv6.conf.all.forwarding=1
sysctl -qw net.ipv6.conf.default.forwarding=1

# VIP IPv6 address on ns_vip loopback
ip netns exec ns_vip ip -6 addr add 2602:F644:10:01::50/128 dev lo 2>/dev/null || true
ip netns exec ns_vip sysctl -qw net.ipv6.conf.all.forwarding=1

# IPv6 on ns_vip <-> path namespace veth pairs
# Using fd10:0:0:X::/64 link-local for veth pairs (ULA for internal transit)
for pair in "fa 1" "fb 2" "sl_a 3" "sl_b 4" "cell_a 5" "cell_b 6"; do
    set -- $pair
    name=$1; idx=$2
    ip netns exec ns_vip ip -6 addr add fd10:0:0:${idx}::1/64 dev vip_$name 2>/dev/null || true
    ns="ns_$name"
    [ "$name" = "sl_a" ] && ns="ns_sl_a"
    [ "$name" = "sl_b" ] && ns="ns_sl_b"
    [ "$name" = "cell_a" ] && ns="ns_cell_a"
    [ "$name" = "cell_b" ] && ns="ns_cell_b"
    ip netns exec $ns ip -6 addr add fd10:0:0:${idx}::2/64 dev vip_${name}_i 2>/dev/null || true
    echo "IPv6 veth vip_$name: fd10:0:0:${idx}::/64"
done

# Return routes: VIP /128 back from each path namespace
for pair in "ns_fa fa 1" "ns_fb fb 2" "ns_sl_a sl_a 3" "ns_sl_b sl_b 4" "ns_cell_a cell_a 5" "ns_cell_b cell_b 6"; do
    set -- $pair
    ns=$1; name=$2; idx=$3
    ip netns exec $ns ip -6 route replace 2602:F644:10:01::50/128 via fd10:0:0:${idx}::1 dev vip_${name}_i 2>/dev/null || true
done

# Policy routing: VIP source through WG (table 100)
for ns in ns_fa ns_fb ns_sl_a ns_sl_b ns_cell_a ns_cell_b; do
    ip netns exec $ns ip -6 rule del from 2602:F644:10::/56 lookup 100 priority 50 2>/dev/null || true
    ip netns exec $ns ip -6 rule add from 2602:F644:10::/56 lookup 100 priority 50
done

# IPv6 default route in table pathsteer per namespace (through WG)
ip netns exec ns_fa ip -6 route replace default dev wg-fa-cA table pathsteer 2>/dev/null || true
ip netns exec ns_fb ip -6 route replace default dev wg-fb-cA table pathsteer 2>/dev/null || true
ip netns exec ns_sl_a ip -6 route replace default dev wg-sa-cA table pathsteer 2>/dev/null || true
ip netns exec ns_sl_b ip -6 route replace default dev wg-sb-cA table pathsteer 2>/dev/null || true
ip netns exec ns_cell_a ip -6 route replace default dev wg-ca-cA table pathsteer 2>/dev/null || true
ip netns exec ns_cell_b ip -6 route replace default dev wg-cb-cA table pathsteer 2>/dev/null || true
echo "IPv6 WG routes in table pathsteer set"

# Default IPv6 route in ns_vip (via fiber A initially, daemon overrides)
ip netns exec ns_vip ip -6 route replace default via fd10:0:0:1::2 dev vip_fa src 2602:f644:10:1::50 2>/dev/null || true

# WiFi IPv6: clients get SLAAC from 2602:F644:10:10::/64
ip -6 addr add 2602:F644:10:10::1/64 dev wlp7s0 2>/dev/null || true

# WiFi vip_wifi veth IPv6
ip -6 addr add fd10:0:0:f0::1/64 dev vip_wifi 2>/dev/null || true
ip netns exec ns_vip ip -6 addr add fd10:0:0:f0::2/64 dev vip_wifi_i 2>/dev/null || true
ip netns exec ns_vip ip -6 route replace 2602:F644:10:10::/64 via fd10:0:0:f0::1 dev vip_wifi_i 2>/dev/null || true

# IPv6 forwarding in all namespaces
for ns in ns_fa ns_fb ns_sl_a ns_sl_b ns_cell_a ns_cell_b ns_vip; do
    ip netns exec $ns sysctl -qw net.ipv6.conf.all.forwarding=1
done

echo "IPv6 dual-stack configured"
echo "VIP IPv6: $(ip netns exec ns_vip ip -6 addr show lo | grep 2602)"
echo "WiFi IPv6: $(ip -6 addr show wlp7s0 | grep 2602)"
