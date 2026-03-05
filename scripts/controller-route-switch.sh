#!/bin/bash
###############################################################################
# controller-route-switch.sh - Update controller return route
#
# Called by pathsteerd after switching uplinks to update the return path
# at the controller. This ensures return traffic flows through the same
# uplink as outbound traffic.
#
# Usage: controller-route-switch.sh <uplink_name>
###############################################################################

UPLINK="${1:-fa}"
CONTROLLER="104.204.136.13"
SERVICE_PREFIX="104.204.138.48/28"
SSH_USER="pathsteer"

# Map uplink to controller-side device and gateway
declare -A SVC_DEVS=(
    [cell_a]="svc_ca"   [cell_b]="svc_cb"
    [sl_a]="svc_sl_a"   [sl_b]="svc_sl_b"
    [fa]="svc_fa"       [fb]="svc_fb"
)
declare -A SVC_GWS=(
    [cell_a]="10.203.5.2"   [cell_b]="10.203.6.2"
    [sl_a]="10.203.3.2"     [sl_b]="10.203.4.2"
    [fa]="10.203.1.2"       [fb]="10.203.2.2"
)

DEV="${SVC_DEVS[$UPLINK]}"
GW="${SVC_GWS[$UPLINK]}"

if [[ -z "$DEV" || -z "$GW" ]]; then
    echo "Unknown uplink: $UPLINK"
    exit 1
fi

# Update controller return route via SSH (non-blocking)
ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
    ${SSH_USER}@${CONTROLLER} \
    "sudo ip netns exec ns_svc ip route replace ${SERVICE_PREFIX} via ${GW} dev ${DEV}" &

exit 0
