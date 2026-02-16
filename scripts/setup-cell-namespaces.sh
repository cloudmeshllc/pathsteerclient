#!/bin/bash
###############################################################################
# setup-cell-namespaces.sh — Create namespaces for cellular WG tunnels
#
# Pattern: modem stays in main NS, veth bridges to cell NS, WG lives in NS
# Same architecture as fiber/starlink namespaces
###############################################################################
set -e

EDGE_PRIVKEY="YKl9JIpPFZxfZb4EnVmIHToN1gjIN0Uhl9tM8d0Bqk8="
CTRL_A_PUBKEY="ocnNjGlV/bTB+OZLtkzZUYC+1OuMadNAE5K4SRaXnyI="
CTRL_B_PUBKEY="Wz3m/cfp+4yE8GNklKC+i5WEr61RVTxcd77foCpyrXI="

log() { echo "[$(date '+%H:%M:%S')] $*"; }

###############################################################################
# CELL A — T-Mobile / wwan0
###############################################################################
setup_cell_a() {
    log "=== Setting up ns_cell_a (T-Mobile / wwan0) ==="

    # Clean up existing WG interfaces from main namespace
    ip link del wg-ca-cA 2>/dev/null || true
    ip link del wg-ca-cB 2>/dev/null || true

    # Create namespace
    ip netns del ns_cell_a 2>/dev/null || true
    ip netns add ns_cell_a

    # Create veth pair
    ip link del veth_cell_a 2>/dev/null || true
    ip link add veth_cell_a type veth peer name veth_cell_a_i

    # Move inner end to namespace
    ip link set veth_cell_a_i netns ns_cell_a

    # Configure main side
    ip addr add 10.201.5.1/30 dev veth_cell_a
    ip link set veth_cell_a up

    # Configure namespace side
    ip netns exec ns_cell_a ip addr add 10.201.5.2/30 dev veth_cell_a_i
    ip netns exec ns_cell_a ip link set veth_cell_a_i up
    ip netns exec ns_cell_a ip link set lo up

    # Default route in namespace — out through veth to main
    ip netns exec ns_cell_a ip route add default via 10.201.5.1 dev veth_cell_a_i

    # Create WG tunnels inside namespace
    ip netns exec ns_cell_a ip link add wg-ca-cA type wireguard
    ip netns exec ns_cell_a ip addr add 10.200.1.2/32 dev wg-ca-cA
    ip netns exec ns_cell_a wg set wg-ca-cA \
        private-key <(echo "$EDGE_PRIVKEY") \
        peer "$CTRL_A_PUBKEY" \
        endpoint 104.204.136.13:51821 \
        allowed-ips 0.0.0.0/0 \
        persistent-keepalive 15
    ip netns exec ns_cell_a ip link set wg-ca-cA up mtu 1380

    ip netns exec ns_cell_a ip link add wg-ca-cB type wireguard
    ip netns exec ns_cell_a ip addr add 10.200.5.2/32 dev wg-ca-cB
    ip netns exec ns_cell_a wg set wg-ca-cB \
        private-key <(echo "$EDGE_PRIVKEY") \
        peer "$CTRL_B_PUBKEY" \
        endpoint 104.204.136.14:51825 \
        allowed-ips 0.0.0.0/0 \
        persistent-keepalive 15
    ip netns exec ns_cell_a ip link set wg-ca-cB up mtu 1380

    # Route for service prefix back through veth
    ip netns exec ns_cell_a ip route add 104.204.136.48/28 via 10.201.5.1 dev veth_cell_a_i

    # NAT: masquerade traffic from cell_a namespace going out wwan0
    iptables -t nat -A POSTROUTING -s 10.201.5.0/30 -o wwan0 -j MASQUERADE
    iptables -A FORWARD -i veth_cell_a -o wwan0 -j ACCEPT
    iptables -A FORWARD -i wwan0 -o veth_cell_a -m state --state RELATED,ESTABLISHED -j ACCEPT

    sysctl -w net.ipv4.ip_forward=1 > /dev/null

    # Update routing table: tmo_cA via veth (same as fiber pattern)
    ip route replace default via 10.201.5.2 dev veth_cell_a table tmo_cA

    log "ns_cell_a: Testing connectivity..."
    ip netns exec ns_cell_a ping -c1 -W3 104.204.136.13 2>&1 | tail -1
}

###############################################################################
# CELL B — AT&T / wwan1
###############################################################################
setup_cell_b() {
    log "=== Setting up ns_cell_b (AT&T / wwan1) ==="

    ip link del wg-cb-cA 2>/dev/null || true
    ip link del wg-cb-cB 2>/dev/null || true

    ip netns del ns_cell_b 2>/dev/null || true
    ip netns add ns_cell_b

    ip link del veth_cell_b 2>/dev/null || true
    ip link add veth_cell_b type veth peer name veth_cell_b_i

    ip link set veth_cell_b_i netns ns_cell_b

    ip addr add 10.201.6.1/30 dev veth_cell_b
    ip link set veth_cell_b up

    ip netns exec ns_cell_b ip addr add 10.201.6.2/30 dev veth_cell_b_i
    ip netns exec ns_cell_b ip link set veth_cell_b_i up
    ip netns exec ns_cell_b ip link set lo up

    ip netns exec ns_cell_b ip route add default via 10.201.6.1 dev veth_cell_b_i

    ip netns exec ns_cell_b ip link add wg-cb-cA type wireguard
    ip netns exec ns_cell_b ip addr add 10.200.2.2/32 dev wg-cb-cA
    ip netns exec ns_cell_b wg set wg-cb-cA \
        private-key <(echo "$EDGE_PRIVKEY") \
        peer "$CTRL_A_PUBKEY" \
        endpoint 104.204.136.13:51822 \
        allowed-ips 0.0.0.0/0 \
        persistent-keepalive 15
    ip netns exec ns_cell_b ip link set wg-cb-cA up mtu 1380

    ip netns exec ns_cell_b ip link add wg-cb-cB type wireguard
    ip netns exec ns_cell_b ip addr add 10.200.6.2/32 dev wg-cb-cB
    ip netns exec ns_cell_b wg set wg-cb-cB \
        private-key <(echo "$EDGE_PRIVKEY") \
        peer "$CTRL_B_PUBKEY" \
        endpoint 104.204.136.14:51826 \
        allowed-ips 0.0.0.0/0 \
        persistent-keepalive 15
    ip netns exec ns_cell_b ip link set wg-cb-cB up mtu 1380

    ip netns exec ns_cell_b ip route add 104.204.136.48/28 via 10.201.6.1 dev veth_cell_b_i

    iptables -t nat -A POSTROUTING -s 10.201.6.0/30 -o wwan1 -j MASQUERADE
    iptables -A FORWARD -i veth_cell_b -o wwan1 -j ACCEPT
    iptables -A FORWARD -i wwan1 -o veth_cell_b -m state --state RELATED,ESTABLISHED -j ACCEPT

    ip route replace default via 10.201.6.2 dev veth_cell_b table att_cA

    log "ns_cell_b: Testing connectivity..."
    ip netns exec ns_cell_b ping -c1 -W3 104.204.136.13 2>&1 | tail -1
}

###############################################################################
# MAIN
###############################################################################
log "PathSteer Cell Namespace Setup"
log "=============================="

# Remove old fwmark rules (no longer needed)
ip rule del fwmark 0x64 table pathsteer 2>/dev/null || true
ip rule del fwmark 0x65 table pathsteer_lte1 2>/dev/null || true
ip route flush table pathsteer 2>/dev/null || true
ip route flush table pathsteer_lte1 2>/dev/null || true

setup_cell_a
setup_cell_b

log ""
log "=== Verification ==="
ip netns show
echo ""
echo "Cell A WG:"
ip netns exec ns_cell_a wg show | grep -E 'interface|endpoint|allowed|handshake'
echo ""
echo "Cell B WG:"
ip netns exec ns_cell_b wg show | grep -E 'interface|endpoint|allowed|handshake'
echo ""
echo "Tables:"
echo "tmo_cA: $(ip route show table tmo_cA)"
echo "att_cA: $(ip route show table att_cA)"
