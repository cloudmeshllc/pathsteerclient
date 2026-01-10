#!/bin/bash
###############################################################################
# PathSteer Guardian - LAN Bridge Setup
#
# Creates br-lan bridge with IPv4 and IPv6 addressing
# Called during install and at boot
###############################################################################
set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/pathsteer/config.json}"

log() { echo "[bridge-setup] $*"; }

# Read config
BRIDGE=$(jq -r '.lan.bridge // "br-lan"' "$CONFIG_FILE")
IPV4_BLOCK=$(jq -r '.lan.ipv4_block // "104.204.136.48/28"' "$CONFIG_FILE")
IPV4_GW=$(jq -r '.lan.ipv4_gateway // "104.204.136.49"' "$CONFIG_FILE")
IPV6_PREFIX=$(jq -r '.lan.ipv6_prefix // "2602:F644:70:100::/64"' "$CONFIG_FILE")

log "Setting up bridge: $BRIDGE"

# Create bridge if not exists
if ! ip link show "$BRIDGE" &>/dev/null; then
    ip link add name "$BRIDGE" type bridge
    log "Created bridge $BRIDGE"
fi

# Bring up
ip link set "$BRIDGE" up

# Add IPv4 address (gateway address for clients)
if ! ip addr show "$BRIDGE" | grep -q "$IPV4_GW"; then
    # Extract prefix length from block
    PREFIX_LEN="${IPV4_BLOCK#*/}"
    ip addr add "${IPV4_GW}/${PREFIX_LEN}" dev "$BRIDGE" 2>/dev/null || true
    log "Added IPv4: ${IPV4_GW}/${PREFIX_LEN}"
fi

# Add IPv6 address
IPV6_ADDR="${IPV6_PREFIX%::*}::1/64"
if ! ip -6 addr show "$BRIDGE" | grep -q "${IPV6_PREFIX%::*}::1"; then
    ip -6 addr add "$IPV6_ADDR" dev "$BRIDGE" 2>/dev/null || true
    log "Added IPv6: $IPV6_ADDR"
fi

# Enable forwarding
sysctl -q net.ipv4.ip_forward=1
sysctl -q net.ipv6.conf.all.forwarding=1

log "Bridge $BRIDGE ready"
ip addr show "$BRIDGE" | grep -E "inet |inet6 " | head -4
