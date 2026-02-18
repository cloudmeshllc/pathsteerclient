#!/bin/bash
# PathSteer Guardian — Namespace & VIP Initialization
# Run at boot before pathsteerd starts
# Version: 2026-02-17 ns_vip architecture

set -e
LOG="/var/log/pathsteer/ns-init-boot.log"
exec > >(tee -a "$LOG") 2>&1
echo "=== ns-init.sh starting $(date) ==="

###############################################################################
# 1. Create ns_vip
###############################################################################
ip netns add ns_vip 2>/dev/null || true
ip netns exec ns_vip ip link set lo up
ip netns exec ns_vip ip addr add 104.204.136.50/28 dev lo 2>/dev/null || true
ip netns exec ns_vip sysctl -qw net.ipv4.ip_forward=1

###############################################################################
# 2. Create path namespaces (if not already present from netns-init)
###############################################################################
for ns in ns_fa ns_fb ns_sl_a ns_sl_b ns_cell_a ns_cell_b; do
    ip netns add $ns 2>/dev/null || true
    ip netns exec $ns ip link set lo up
    ip netns exec $ns sysctl -qw net.ipv4.ip_forward=1
    ip netns exec $ns sysctl -qw net.ipv4.conf.all.rp_filter=0
done

###############################################################################
# 3. Move physical interfaces into namespaces
###############################################################################
# Google Fiber
ip link set ps_ter_a netns ns_fa 2>/dev/null || true
# ATT Fiber  
ip link set ps_ter_b netns ns_fb 2>/dev/null || true
# Starlink A
ip link set ps_sl_a netns ns_sl_a 2>/dev/null || true
# Starlink B
ip link set ps_sl_b netns ns_sl_b 2>/dev/null || true

###############################################################################
# 4. DHCP on physical interfaces
###############################################################################
ip netns exec ns_fa dhclient -nw ps_ter_a 2>/dev/null || true
ip netns exec ns_fb dhclient -nw ps_ter_b 2>/dev/null || true
ip netns exec ns_sl_a dhclient -nw ps_sl_a 2>/dev/null || true
ip netns exec ns_sl_b dhclient -nw ps_sl_b 2>/dev/null || true
sleep 5

###############################################################################
# 5. Path namespace <-> main namespace veth pairs (cellular)
###############################################################################
# Cell A: ns_cell_a <-> main (for wwan0 NAT)
ip link del veth_cell_a 2>/dev/null || true
ip link add veth_cell_a type veth peer name veth_cell_a_i
ip addr add 10.201.5.1/30 dev veth_cell_a
ip link set veth_cell_a up
ip link set veth_cell_a_i netns ns_cell_a
ip netns exec ns_cell_a ip addr add 10.201.5.2/30 dev veth_cell_a_i
ip netns exec ns_cell_a ip link set veth_cell_a_i up

# Cell B: ns_cell_b <-> main (for wwan1 NAT)
ip link del veth_cell_b 2>/dev/null || true
ip link add veth_cell_b type veth peer name veth_cell_b_i
ip addr add 10.201.6.1/30 dev veth_cell_b
ip link set veth_cell_b up
ip link set veth_cell_b_i netns ns_cell_b
ip netns exec ns_cell_b ip addr add 10.201.6.2/30 dev veth_cell_b_i
ip netns exec ns_cell_b ip link set veth_cell_b_i up

# Fiber/Starlink veth pairs (for legacy compatibility — used by raw path)
for pair in "fa 10.201.1.1 10.201.1.2 ns_fa" \
            "fb 10.201.2.1 10.201.2.2 ns_fb" \
            "sl_a 10.201.3.1 10.201.3.2 ns_sl_a" \
            "sl_b 10.201.4.1 10.201.4.2 ns_sl_b"; do
    set -- $pair
    name=$1; main_ip=$2; ns_ip=$3; ns=$4
    ip link del veth_$name 2>/dev/null || true
    ip link add veth_$name type veth peer name veth_${name}_i
    ip addr add $main_ip/30 dev veth_$name
    ip link set veth_$name up
    ip link set veth_${name}_i netns $ns
    ip netns exec $ns ip addr add $ns_ip/30 dev veth_${name}_i
    ip netns exec $ns ip link set veth_${name}_i up
done

###############################################################################
# 6. ns_vip <-> path namespace veth pairs
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
done

###############################################################################
# 7. WireGuard tunnels in path namespaces
###############################################################################
for conf in fa-cA fa-cB fb-cA fb-cB sa-cA sa-cB sb-cA sb-cB ca-cA ca-cB cb-cA cb-cB; do
    # Determine namespace from conf name
    case $conf in
        fa-*) ns=ns_fa;;
        fb-*) ns=ns_fb;;
        sa-*) ns=ns_sl_a;;
        sb-*) ns=ns_sl_b;;
        ca-*) ns=ns_cell_a;;
        cb-*) ns=ns_cell_b;;
    esac
    ip netns exec $ns wg-quick up wg-$conf 2>/dev/null || true
done
sleep 3

###############################################################################
# 8. ISP default routes in fiber/starlink namespaces (for probes)
#    WG gets service traffic via policy routing table "pathsteer"
###############################################################################
# Google Fiber — gateway from DHCP
GW_FA=$(ip netns exec ns_fa ip route show default 2>/dev/null | grep -v wg | awk '{print $3}' | head -1)
[ -n "$GW_FA" ] || GW_FA="192.168.0.1"
ip netns exec ns_fa ip route replace default via $GW_FA dev ps_ter_a

# ATT Fiber
GW_FB=$(ip netns exec ns_fb ip route show default 2>/dev/null | grep -v wg | awk '{print $3}' | head -1)
[ -n "$GW_FB" ] || GW_FB="192.168.12.1"
ip netns exec ns_fb ip route replace default via $GW_FB dev ps_ter_b

# Starlink A
GW_SLA=$(ip netns exec ns_sl_a ip route show default 2>/dev/null | grep -v wg | awk '{print $3}' | head -1)
[ -n "$GW_SLA" ] || GW_SLA="100.64.0.1"
ip netns exec ns_sl_a ip route replace default via $GW_SLA dev ps_sl_a

# Starlink B
GW_SLB=$(ip netns exec ns_sl_b ip route show default 2>/dev/null | grep -v wg | awk '{print $3}' | head -1)
[ -n "$GW_SLB" ] || GW_SLB="192.168.2.1"
ip netns exec ns_sl_b ip route replace default via $GW_SLB dev ps_sl_b

# Cellular — default through WG (no ISP route needed, NAT via main)
ip netns exec ns_cell_a ip route replace default dev wg-ca-cA 2>/dev/null || true
ip netns exec ns_cell_b ip route replace default dev wg-cb-cA 2>/dev/null || true

###############################################################################
# 9. Controller endpoint routes (so WG can reach controllers via ISP)
###############################################################################
ip netns exec ns_fa ip route replace 104.204.136.13 via $GW_FA dev ps_ter_a
ip netns exec ns_fa ip route replace 104.204.136.14 via $GW_FA dev ps_ter_a
ip netns exec ns_fb ip route replace 104.204.136.13 via $GW_FB dev ps_ter_b
ip netns exec ns_fb ip route replace 104.204.136.14 via $GW_FB dev ps_ter_b
# Starlink — controller routes added only if DHCP gave v4
ip netns exec ns_sl_a ip route replace 104.204.136.13 via $GW_SLA dev ps_sl_a 2>/dev/null || true
ip netns exec ns_sl_a ip route replace 104.204.136.14 via $GW_SLA dev ps_sl_a 2>/dev/null || true
ip netns exec ns_sl_b ip route replace 104.204.136.13 via $GW_SLB dev ps_sl_b 2>/dev/null || true
ip netns exec ns_sl_b ip route replace 104.204.136.14 via $GW_SLB dev ps_sl_b 2>/dev/null || true
# Cellular — via main namespace veth
ip netns exec ns_cell_a ip route replace 104.204.136.13 via 10.201.5.1 dev veth_cell_a_i
ip netns exec ns_cell_a ip route replace 104.204.136.14 via 10.201.5.1 dev veth_cell_a_i
ip netns exec ns_cell_b ip route replace 104.204.136.13 via 10.201.6.1 dev veth_cell_b_i
ip netns exec ns_cell_b ip route replace 104.204.136.14 via 10.201.6.1 dev veth_cell_b_i

###############################################################################
# 10. Policy routing: /28 service traffic through WG (table pathsteer = 100)
###############################################################################
for ns in ns_fa ns_fb ns_sl_a ns_sl_b ns_cell_a ns_cell_b; do
    ip netns exec $ns ip rule del from 104.204.136.48/28 lookup pathsteer priority 50 2>/dev/null || true
    ip netns exec $ns ip rule add from 104.204.136.48/28 lookup pathsteer priority 50
done
# WG default route in table pathsteer per namespace
ip netns exec ns_fa ip route replace default dev wg-fa-cA table pathsteer
ip netns exec ns_fb ip route replace default dev wg-fb-cA table pathsteer
ip netns exec ns_sl_a ip route replace default dev wg-sa-cA table pathsteer
ip netns exec ns_sl_b ip route replace default dev wg-sb-cA table pathsteer
ip netns exec ns_cell_a ip route replace default dev wg-ca-cA table pathsteer
ip netns exec ns_cell_b ip route replace default dev wg-cb-cA table pathsteer

###############################################################################
# 11. Return routes: /28 back to ns_vip from each path namespace
###############################################################################
ip netns exec ns_fa ip route replace 104.204.136.48/28 via 10.201.10.1 dev vip_fa_i
ip netns exec ns_fb ip route replace 104.204.136.48/28 via 10.201.10.5 dev vip_fb_i
ip netns exec ns_sl_a ip route replace 104.204.136.48/28 via 10.201.10.9 dev vip_sl_a_i
ip netns exec ns_sl_b ip route replace 104.204.136.48/28 via 10.201.10.13 dev vip_sl_b_i
ip netns exec ns_cell_a ip route replace 104.204.136.48/28 via 10.201.10.17 dev vip_cell_a_i
ip netns exec ns_cell_b ip route replace 104.204.136.48/28 via 10.201.10.21 dev vip_cell_b_i

###############################################################################
# 12. Main namespace: ip rules and NAT for cellular
###############################################################################
ip rule del from 10.201.5.0/30 lookup raw_wwan0 priority 80 2>/dev/null || true
ip rule add from 10.201.5.0/30 lookup raw_wwan0 priority 80
ip rule del from 10.201.6.0/30 lookup raw_wwan1 priority 81 2>/dev/null || true
ip rule add from 10.201.6.0/30 lookup raw_wwan1 priority 81

# NAT for cellular WG encapsulated traffic
iptables-legacy -t nat -C POSTROUTING -s 10.201.5.0/30 -o wwan0 -j MASQUERADE 2>/dev/null || \
    iptables-legacy -t nat -A POSTROUTING -s 10.201.5.0/30 -o wwan0 -j MASQUERADE
iptables-legacy -t nat -C POSTROUTING -s 10.201.6.0/30 -o wwan1 -j MASQUERADE 2>/dev/null || \
    iptables-legacy -t nat -A POSTROUTING -s 10.201.6.0/30 -o wwan1 -j MASQUERADE

# Forwarding
sysctl -qw net.ipv4.ip_forward=1

###############################################################################
# 13. Default ns_vip route (daemon will override on start)
###############################################################################
ip netns exec ns_vip ip route replace default via 10.201.10.2 dev vip_fa

echo "=== ns-init.sh complete $(date) ==="
echo "Namespaces: $(ip netns list | wc -l)"
echo "VIP: $(ip netns exec ns_vip ip addr show lo | grep 104.204)"
