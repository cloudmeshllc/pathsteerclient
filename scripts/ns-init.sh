#!/bin/bash
# PathSteer Guardian — ns_vip Layer Initialization
# Adds ns_vip namespace and veth pairs to existing path namespaces.
# Runs AFTER pathsteer-netns.service and pathsteer-*-tunnels.service
# Version: 2026-02-17

LOG="/var/log/pathsteer/ns-vip-init.log"
mkdir -p /var/log/pathsteer
exec > >(tee -a "$LOG") 2>&1
echo "=== ns-init.sh starting $(date) ==="

# Wait for path namespaces to be ready
for ns in ns_fa ns_fb ns_sl_a ns_sl_b ns_cell_a ns_cell_b; do
    for i in $(seq 1 30); do
        ip netns exec $ns true 2>/dev/null && break
        echo "Waiting for $ns ($i/30)..."
        sleep 2
    done
done

###############################################################################
# 1. Create ns_vip
###############################################################################
ip netns add ns_vip 2>/dev/null || true
ip netns exec ns_vip ip link set lo up
ip netns exec ns_vip ip addr add 104.204.136.50/28 dev lo 2>/dev/null || true
ip netns exec ns_vip sysctl -qw net.ipv4.ip_forward=1

###############################################################################
# 2. ns_vip <-> path namespace veth pairs
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
# 3. Return routes: /28 back to ns_vip from each path namespace
###############################################################################
ip netns exec ns_fa ip route replace 104.204.136.48/28 via 10.201.10.1 dev vip_fa_i
ip netns exec ns_fb ip route replace 104.204.136.48/28 via 10.201.10.5 dev vip_fb_i
ip netns exec ns_sl_a ip route replace 104.204.136.48/28 via 10.201.10.9 dev vip_sl_a_i
ip netns exec ns_sl_b ip route replace 104.204.136.48/28 via 10.201.10.13 dev vip_sl_b_i
ip netns exec ns_cell_a ip route replace 104.204.136.48/28 via 10.201.10.17 dev vip_cell_a_i
ip netns exec ns_cell_b ip route replace 104.204.136.48/28 via 10.201.10.21 dev vip_cell_b_i
echo "Return routes set"

###############################################################################
# 4. Policy routing: /28 service traffic through WG (table pathsteer = 100)
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
echo "Policy routes set"

###############################################################################
# 5. Controller endpoint routes for cellular (via main ns veth)
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
# 6. ISP default routes for fiber/starlink (for daemon probes)
#    Controller endpoint routes via ISP
###############################################################################
for ns_gw in "ns_fa ps_ter_a 192.168.0.1" \
             "ns_fb ps_ter_b 192.168.12.1" \
             "ns_sl_a ps_sl_a 100.64.0.1" \
             "ns_sl_b ps_sl_b 192.168.2.1"; do
    set -- $ns_gw
    ns=$1; dev=$2; gw=$3
    # Try DHCP gateway first, fallback to hardcoded
    LIVE_GW=$(ip netns exec $ns ip route show default 2>/dev/null | grep -v wg | awk '{print $3}' | head -1)
    [ -n "$LIVE_GW" ] && gw=$LIVE_GW
    ip netns exec $ns ip route replace default via $gw dev $dev 2>/dev/null || true
    ip netns exec $ns ip route replace 104.204.136.13 via $gw dev $dev 2>/dev/null || true
    ip netns exec $ns ip route replace 104.204.136.14 via $gw dev $dev 2>/dev/null || true
    echo "$ns: default via $gw dev $dev"
done

###############################################################################
# 7. Default ns_vip route (daemon will override on start)
###############################################################################
ip netns exec ns_vip ip route replace default via 10.201.10.2 dev vip_fa

echo "=== ns-init.sh complete $(date) ==="
echo "ns_vip VIP: $(ip netns exec ns_vip ip addr show lo | grep 104.204)"
echo "ns_vip veths: $(ip netns exec ns_vip ip link show | grep -c UP) UP"
