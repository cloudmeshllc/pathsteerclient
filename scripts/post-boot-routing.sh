#!/bin/bash
###############################################################################
# post-boot-routing.sh — PathSteer Guardian post-boot routing configuration
#
# Run AFTER namespaces, veths, and WG tunnels are created.
# Makes all runtime routing fixes persistent across reboots.
#
# What this script does:
#   1. Service IP on loopback
#   2. rp_filter=0 on all veths
#   3. ip_forward=1
#   4. Namespace WG allowed-ips → 0.0.0.0/0
#   5. Namespace default routes → WG (not ISP)
#   6. Controller host routes via ISP in each namespace
#   7. VIP route overrides → regular veth (not ns_vip)
#   8. Cell namespace NAT (iptables-legacy)
#   9. Raw modem routing tables for cell NAT
#  10. Service ip rule at priority 90
#  11. Disable survivor.sh interference
###############################################################################
set -e
log() { echo "[$(date '+%H:%M:%S')] $*"; }

EDGE_PRIVKEY="YKl9JIpPFZxfZb4EnVmIHToN1gjIN0Uhl9tM8d0Bqk8="
CTRL_A_PUBKEY="ocnNjGlV/bTB+OZLtkzZUYC+1OuMadNAE5K4SRaXnyI="
CTRL_B_PUBKEY="Wz3m/cfp+4yE8GNklKC+i5WEr61RVTxcd77foCpyrXI="
CTRL_A_IP="104.204.136.13"
CTRL_B_IP="104.204.136.14"
SERVICE_PREFIX="104.204.136.48/28"
SERVICE_VIP="104.204.136.50/28"

###############################################################################
# 1. Service IP on loopback
###############################################################################
log "1. Binding service IP to loopback"
ip addr show lo | grep -q 104.204.136.50 || ip addr add $SERVICE_VIP dev lo

###############################################################################
# 2. rp_filter=0 on all veths
###############################################################################
log "2. Disabling rp_filter on veths"
for iface in veth_fa veth_fb veth_sl_a veth_sl_b veth_cell_a veth_cell_b; do
    sysctl -qw net.ipv4.conf.${iface}.rp_filter=0 2>/dev/null || true
done
sysctl -qw net.ipv4.conf.all.rp_filter=0

###############################################################################
# 3. ip_forward
###############################################################################
log "3. Enabling IP forwarding"
sysctl -qw net.ipv4.ip_forward=1

###############################################################################
# 4. Namespace WG allowed-ips → 0.0.0.0/0 (controller A tunnels)
###############################################################################
log "4. Widening namespace WG allowed-ips"
ip netns exec ns_fa    wg set wg-fa-cA peer $CTRL_A_PUBKEY allowed-ips 0.0.0.0/0 2>/dev/null || true
ip netns exec ns_fb    wg set wg-fb-cA peer $CTRL_A_PUBKEY allowed-ips 0.0.0.0/0 2>/dev/null || true
ip netns exec ns_sl_a  wg set wg-sa-cA peer $CTRL_A_PUBKEY allowed-ips 0.0.0.0/0 2>/dev/null || true
ip netns exec ns_sl_b  wg set wg-sb-cA peer $CTRL_A_PUBKEY allowed-ips 0.0.0.0/0 2>/dev/null || true
ip netns exec ns_cell_a wg set wg-ca-cA peer $CTRL_A_PUBKEY allowed-ips 0.0.0.0/0 2>/dev/null || true
ip netns exec ns_cell_b wg set wg-cb-cA peer $CTRL_A_PUBKEY allowed-ips 0.0.0.0/0 2>/dev/null || true

# Controller B tunnels
ip netns exec ns_fa    wg set wg-fa-cB peer $CTRL_B_PUBKEY allowed-ips 0.0.0.0/0 2>/dev/null || true
ip netns exec ns_fb    wg set wg-fb-cB peer $CTRL_B_PUBKEY allowed-ips 0.0.0.0/0 2>/dev/null || true
ip netns exec ns_sl_a  wg set wg-sa-cB peer $CTRL_B_PUBKEY allowed-ips 0.0.0.0/0 2>/dev/null || true
ip netns exec ns_sl_b  wg set wg-sb-cB peer $CTRL_B_PUBKEY allowed-ips 0.0.0.0/0 2>/dev/null || true
ip netns exec ns_cell_a wg set wg-ca-cB peer $CTRL_B_PUBKEY allowed-ips 0.0.0.0/0 2>/dev/null || true
ip netns exec ns_cell_b wg set wg-cb-cB peer $CTRL_B_PUBKEY allowed-ips 0.0.0.0/0 2>/dev/null || true

###############################################################################
# 5 & 6. Namespace default routes → WG + controller host routes via ISP
###############################################################################
log "5. Setting namespace default routes via WG"

# ns_fa: ISP gateway 192.168.0.1 on ps_ter_a
ip netns exec ns_fa ip route replace $CTRL_A_IP via 192.168.0.1 dev ps_ter_a 2>/dev/null || true
ip netns exec ns_fa ip route replace $CTRL_B_IP via 192.168.0.1 dev ps_ter_a 2>/dev/null || true
ip netns exec ns_fa ip route replace default dev wg-fa-cA 2>/dev/null || true

# ns_fb: ISP gateway 192.168.12.1 on ps_ter_b
ip netns exec ns_fb ip route replace $CTRL_A_IP via 192.168.12.1 dev ps_ter_b 2>/dev/null || true
ip netns exec ns_fb ip route replace $CTRL_B_IP via 192.168.12.1 dev ps_ter_b 2>/dev/null || true
ip netns exec ns_fb ip route replace default dev wg-fb-cA 2>/dev/null || true

# ns_sl_a: ISP gateway 100.64.0.1 on ps_sl_a
ip netns exec ns_sl_a ip route replace $CTRL_A_IP via 100.64.0.1 dev ps_sl_a 2>/dev/null || true
ip netns exec ns_sl_a ip route replace $CTRL_B_IP via 100.64.0.1 dev ps_sl_a 2>/dev/null || true
ip netns exec ns_sl_a ip route replace default dev wg-sa-cA 2>/dev/null || true

# ns_sl_b: ISP gateway 192.168.2.1 on ps_sl_b
ip netns exec ns_sl_b ip route replace $CTRL_A_IP via 192.168.2.1 dev ps_sl_b 2>/dev/null || true
ip netns exec ns_sl_b ip route replace $CTRL_B_IP via 192.168.2.1 dev ps_sl_b 2>/dev/null || true
ip netns exec ns_sl_b ip route replace default dev wg-sb-cA 2>/dev/null || true

# ns_cell_a: via veth to main namespace
ip netns exec ns_cell_a ip route replace $CTRL_A_IP via 10.201.5.1 dev veth_cell_a_i 2>/dev/null || true
ip netns exec ns_cell_a ip route replace $CTRL_B_IP via 10.201.5.1 dev veth_cell_a_i 2>/dev/null || true
ip netns exec ns_cell_a ip route replace default dev wg-ca-cA 2>/dev/null || true

# ns_cell_b: via veth to main namespace
ip netns exec ns_cell_b ip route replace $CTRL_A_IP via 10.201.6.1 dev veth_cell_b_i 2>/dev/null || true
ip netns exec ns_cell_b ip route replace $CTRL_B_IP via 10.201.6.1 dev veth_cell_b_i 2>/dev/null || true
ip netns exec ns_cell_b ip route replace default dev wg-cb-cA 2>/dev/null || true

###############################################################################
# 7. VIP route overrides → regular veth (not ns_vip dead-end)
###############################################################################
log "6. Overriding VIP routes"
ip netns exec ns_fa     ip route replace $SERVICE_PREFIX via 10.201.1.1 dev veth_fa_i     2>/dev/null || true
ip netns exec ns_fb     ip route replace $SERVICE_PREFIX via 10.201.2.1 dev veth_fb_i     2>/dev/null || true
ip netns exec ns_sl_a   ip route replace $SERVICE_PREFIX via 10.201.3.1 dev veth_sl_a_i   2>/dev/null || true
ip netns exec ns_sl_b   ip route replace $SERVICE_PREFIX via 10.201.4.1 dev veth_sl_b_i   2>/dev/null || true
ip netns exec ns_cell_a ip route replace $SERVICE_PREFIX via 10.201.5.1 dev veth_cell_a_i 2>/dev/null || true
ip netns exec ns_cell_b ip route replace $SERVICE_PREFIX via 10.201.6.1 dev veth_cell_b_i 2>/dev/null || true

###############################################################################
# 8. Cell namespace NAT (iptables-legacy)
###############################################################################
log "7. Configuring cell NAT (iptables-legacy)"

# Cell A → wwan0
iptables-legacy -C FORWARD -i veth_cell_a -o wwan0 -j ACCEPT 2>/dev/null || \
    iptables-legacy -A FORWARD -i veth_cell_a -o wwan0 -j ACCEPT
iptables-legacy -C FORWARD -i wwan0 -o veth_cell_a -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables-legacy -A FORWARD -i wwan0 -o veth_cell_a -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables-legacy -t nat -C POSTROUTING -s 10.201.5.0/30 -o wwan0 -j MASQUERADE 2>/dev/null || \
    iptables-legacy -t nat -A POSTROUTING -s 10.201.5.0/30 -o wwan0 -j MASQUERADE

# Cell B → wwan1
iptables-legacy -C FORWARD -i veth_cell_b -o wwan1 -j ACCEPT 2>/dev/null || \
    iptables-legacy -A FORWARD -i veth_cell_b -o wwan1 -j ACCEPT
iptables-legacy -C FORWARD -i wwan1 -o veth_cell_b -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables-legacy -A FORWARD -i wwan1 -o veth_cell_b -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables-legacy -t nat -C POSTROUTING -s 10.201.6.0/30 -o wwan1 -j MASQUERADE 2>/dev/null || \
    iptables-legacy -t nat -A POSTROUTING -s 10.201.6.0/30 -o wwan1 -j MASQUERADE

###############################################################################
# 9. Raw modem routing tables for cell NAT source routing
###############################################################################
log "8. Configuring raw modem routing tables"

# Get current modem gateways
WWAN0_GW=$(ip route show dev wwan0 | grep -oP 'via \K[0-9.]+' | head -1)
WWAN1_GW=$(ip route show dev wwan1 | grep -oP 'via \K[0-9.]+' | head -1)
[ -z "$WWAN0_GW" ] && WWAN0_GW=$(ip route show dev wwan0 | awk '/scope link/{print $1}' | head -1)
[ -z "$WWAN1_GW" ] && WWAN1_GW=$(ip route show dev wwan1 | awk '/scope link/{print $1}' | head -1)

if [ -n "$WWAN0_GW" ]; then
    ip route replace default via $WWAN0_GW dev wwan0 table raw_wwan0
    log "   raw_wwan0: default via $WWAN0_GW dev wwan0"
fi
if [ -n "$WWAN1_GW" ]; then
    ip route replace default via $WWAN1_GW dev wwan1 table raw_wwan1
    log "   raw_wwan1: default via $WWAN1_GW dev wwan1"
fi

# Source routing rules for cell namespace traffic
ip rule show | grep -q 'from 10.201.5.0/30 lookup raw_wwan0' || \
    ip rule add from 10.201.5.0/30 lookup raw_wwan0 priority 80
ip rule show | grep -q 'from 10.201.6.0/30 lookup raw_wwan1' || \
    ip rule add from 10.201.6.0/30 lookup raw_wwan1 priority 81

###############################################################################
# 10. Routing tables for all uplinks
###############################################################################
log "9. Populating uplink routing tables"
ip route replace default via 10.201.1.2 dev veth_fa     table fa      2>/dev/null || true
ip route replace default via 10.201.2.2 dev veth_fb     table fb      2>/dev/null || true
ip route replace default via 10.201.3.2 dev veth_sl_a   table sl_a    2>/dev/null || true
ip route replace default via 10.201.4.2 dev veth_sl_b   table sl_b    2>/dev/null || true
ip route replace default via 10.201.5.2 dev veth_cell_a table tmo_cA  2>/dev/null || true
ip route replace default via 10.201.6.2 dev veth_cell_b table att_cA  2>/dev/null || true

###############################################################################
# 11. Default service ip rule (daemon will manage this)
###############################################################################
log "10. Setting default service ip rule"
# Remove any stale rules
while ip -4 rule del from $SERVICE_PREFIX priority 0 2>/dev/null; do true; done
while ip -4 rule del from $SERVICE_PREFIX priority 90 2>/dev/null; do true; done
ip -4 rule add from $SERVICE_PREFIX lookup fa priority 90

###############################################################################
# 12. Flush stale conntrack for cell WG ports
###############################################################################
log "11. Flushing stale conntrack"
conntrack -D -p udp --dport 51821 2>/dev/null || true
conntrack -D -p udp --dport 51822 2>/dev/null || true
conntrack -D -p udp --dport 51825 2>/dev/null || true
conntrack -D -p udp --dport 51826 2>/dev/null || true

###############################################################################
# 13. Namespace forwarding
###############################################################################
log "12. Enabling namespace forwarding"
for ns in ns_fa ns_fb ns_sl_a ns_sl_b ns_cell_a ns_cell_b; do
    ip netns exec $ns sysctl -qw net.ipv4.ip_forward=1 2>/dev/null || true
done

###############################################################################
# 14. Disable survivor.sh
###############################################################################
log "13. Disabling survivor.sh"
systemctl disable pathsteer-survivor 2>/dev/null || true
systemctl stop pathsteer-survivor 2>/dev/null || true
pkill -f survivor.sh 2>/dev/null || true

ip route flush cache

log ""
log "=== Post-boot routing complete ==="
log "Test: ping -c2 -W3 -I 104.204.136.50 8.8.8.8"
