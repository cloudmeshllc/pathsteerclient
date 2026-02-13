#!/bin/bash
###############################################################################
# controller-route-switch.sh — Move /28 return route on controllers
#
# Called by pathsteerd after successful ip rule actuation.
# Usage: controller-route-switch.sh <uplink_name>
###############################################################################
UPLINK="$1"
SERVICE_PREFIX="104.204.136.48/28"
CTRL_A="pathsteer@104.204.136.13"
CTRL_B="pathsteer@104.204.136.14"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no"

# Map edge uplink to controller WG interface name
declare -A WG_MAP=(
    [cell_a]="wg-cell_a"
    [cell_b]="wg-cell_b"
    [sl_a]="wg-sl_a"
    [sl_b]="wg-sl_b"
    [fa]="wg-fa"
    [fb]="wg-fb"
)

WG_IFACE="${WG_MAP[$UPLINK]}"
if [[ -z "$WG_IFACE" ]]; then
    echo "ERROR: unknown uplink '$UPLINK'" >&2
    exit 1
fi

# Map edge uplink to controller WG peer edge-side IP
declare -A PEER_MAP_A=(
    [cell_a]="10.200.1.2/32"
    [cell_b]="10.200.2.2/32"
    [sl_a]="10.200.3.2/32"
    [sl_b]="10.200.4.2/32"
    [fa]="10.200.9.2/32"
    [fb]="10.200.11.2/32"
)
declare -A PEER_MAP_B=(
    [cell_a]="10.200.5.2/32"
    [cell_b]="10.200.6.2/32"
    [sl_a]="10.200.7.2/32"
    [sl_b]="10.200.8.2/32"
    [fa]="10.200.10.2/32"
    [fb]="10.200.12.2/32"
)

EDGE_KEY="FbaOGOhHP5vgSPzH2JszteuNtAJfxSsDfuFdAPCatTs="

# Switch controller A
ssh $SSH_OPTS $CTRL_A "sudo sh -c '
    # Move allowed-ips: add /28 to target, remove from others
    for iface in wg-cell_a wg-cell_b wg-sl_a wg-sl_b wg-fa wg-fb; do
        if [ \"\$iface\" = \"${WG_IFACE}\" ]; then
            continue
        fi
        # Get current peer IP for this interface
        PEER_IP=\$(wg show \$iface allowed-ips 2>/dev/null | awk \"{print \\\$2}\" | grep -v ${SERVICE_PREFIX} | head -1)
        if [ -n \"\$PEER_IP\" ]; then
            wg set \$iface peer ${EDGE_KEY} allowed-ips \$PEER_IP 2>/dev/null
        fi
    done
    # Set target tunnel: peer IP + service prefix
    wg set ${WG_IFACE} peer ${EDGE_KEY} allowed-ips ${PEER_MAP_A[$UPLINK]},${SERVICE_PREFIX}
    # Move route
    ip route replace ${SERVICE_PREFIX} dev ${WG_IFACE}
'" &

# Switch controller B
ssh $SSH_OPTS $CTRL_B "sudo sh -c '
    for iface in wg-cell_a wg-cell_b wg-sl_a wg-sl_b wg-fa wg-fb; do
        if [ \"\$iface\" = \"${WG_IFACE}\" ]; then
            continue
        fi
        PEER_IP=\$(wg show \$iface allowed-ips 2>/dev/null | awk \"{print \\\$2}\" | grep -v ${SERVICE_PREFIX} | head -1)
        if [ -n \"\$PEER_IP\" ]; then
            wg set \$iface peer ${EDGE_KEY} allowed-ips \$PEER_IP 2>/dev/null
        fi
    done
    wg set ${WG_IFACE} peer ${EDGE_KEY} allowed-ips ${PEER_MAP_B[$UPLINK]},${SERVICE_PREFIX}
    ip route replace ${SERVICE_PREFIX} dev ${WG_IFACE}
'" &

wait
echo "Route switched to ${WG_IFACE} on both controllers"
