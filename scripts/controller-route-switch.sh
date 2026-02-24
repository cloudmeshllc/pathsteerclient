#!/bin/bash
###############################################################################
# controller-route-switch.sh — Switch controller return routes (IPv4 + IPv6)
# Usage: controller-route-switch.sh <uplink_name>
###############################################################################
UPLINK="$1"
SERVICE_PREFIX="104.204.138.48/28"
V6_PREFIX="2602:f644:10::/56"
CTRL_A="pathsteer@104.204.136.13"
CTRL_B="pathsteer@104.204.136.14"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no"

declare -A SVC_DEV=([fa]="svc_fa" [fb]="svc_fb" [sl_a]="svc_sl_a" [sl_b]="svc_sl_b" [cell_a]="svc_ca" [cell_b]="svc_cb")
declare -A SVC_GW=([fa]="10.203.1.2" [fb]="10.203.2.2" [sl_a]="10.203.3.2" [sl_b]="10.203.4.2" [cell_a]="10.203.5.2" [cell_b]="10.203.6.2")
declare -A OUTER_DEV=([fa]="outer_fa" [fb]="outer_fb" [sl_a]="outer_sl_a" [sl_b]="outer_sl_b" [cell_a]="outer_ca" [cell_b]="outer_cb")
declare -A OUTER_GW6=([fa]="fd10:fa::2" [fb]="fd10:fb::2" [sl_a]="fd10:a1::2" [sl_b]="fd10:b1::2" [cell_a]="fd10:ca::2" [cell_b]="fd10:cb::2")

DEV="${SVC_DEV[$UPLINK]}"
GW="${SVC_GW[$UPLINK]}"
O_DEV="${OUTER_DEV[$UPLINK]}"
O_GW6="${OUTER_GW6[$UPLINK]}"

if [[ -z "$DEV" ]]; then
    echo "ERROR: unknown uplink '$UPLINK'" >&2
    exit 1
fi

# Switch controller A — IPv4 (ns_svc) + IPv6 (main namespace)
ssh $SSH_OPTS $CTRL_A "sudo ip netns exec ns_svc ip route replace ${SERVICE_PREFIX} via ${GW} dev ${DEV} && sudo ip -6 route replace ${V6_PREFIX} via ${O_GW6} dev ${O_DEV}" &

# Switch controller B
ssh $SSH_OPTS $CTRL_B "sudo ip netns exec ns_svc ip route replace ${SERVICE_PREFIX} via ${GW} dev ${DEV} && sudo ip -6 route replace ${V6_PREFIX} via ${O_GW6} dev ${O_DEV}" &

wait
echo "Route switched to ${DEV} (${UPLINK}) — IPv4+IPv6 on both controllers"
