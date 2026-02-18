#!/bin/bash
###############################################################################
# controller-route-switch.sh — Move /28 return route in controller ns_svc
#
# With per-tunnel namespaces, just change the route in ns_svc.
# No more AllowedIPs juggling.
# Usage: controller-route-switch.sh <uplink_name>
###############################################################################
UPLINK="$1"
SERVICE_PREFIX="104.204.136.48/28"
CTRL_A="pathsteer@104.204.136.13"
CTRL_B="pathsteer@104.204.136.14"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no"

# Map edge uplink to controller ns_svc veth + gateway
declare -A SVC_DEV=(
    [fa]="svc_fa"
    [fb]="svc_fb"
    [sl_a]="svc_sl_a"
    [sl_b]="svc_sl_b"
    [cell_a]="svc_ca"
    [cell_b]="svc_cb"
)
declare -A SVC_GW=(
    [fa]="10.203.1.2"
    [fb]="10.203.2.2"
    [sl_a]="10.203.3.2"
    [sl_b]="10.203.4.2"
    [cell_a]="10.203.5.2"
    [cell_b]="10.203.6.2"
)

DEV="${SVC_DEV[$UPLINK]}"
GW="${SVC_GW[$UPLINK]}"

if [[ -z "$DEV" ]]; then
    echo "ERROR: unknown uplink '$UPLINK'" >&2
    exit 1
fi

# Switch controller A — just one route replace in ns_svc
ssh $SSH_OPTS $CTRL_A "sudo ip netns exec ns_svc ip route replace ${SERVICE_PREFIX} via ${GW} dev ${DEV}" &

# Switch controller B
ssh $SSH_OPTS $CTRL_B "sudo ip netns exec ns_svc ip route replace ${SERVICE_PREFIX} via ${GW} dev ${DEV}" &

wait
echo "Route switched to ${DEV} (${UPLINK}) on both controllers"
