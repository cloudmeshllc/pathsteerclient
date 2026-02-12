#!/bin/bash
###############################################################################
# setup-rt-tables.sh — Populate PathSteer routing tables
#
# Creates entries in /etc/iproute2/rt_tables (idempotent) and populates
# default routes in each table so ip-rule actuation actually moves traffic.
#
# Run after: netns-init, wg-setup, modem-connect
# Run before: pathsteerd
###############################################################################
set -euo pipefail

log() { echo "[rt-tables] $*"; }

# ── Ensure table names exist ────────────────────────────────────────────────
declare -A TABLES=(
    [tmo_cA]=111
    [att_cA]=120
    [sl_a]=113
    [sl_b]=114
    [fa]=115
    [fb]=116
)

for name in "${!TABLES[@]}"; do
    num="${TABLES[$name]}"
    if ! grep -q "^${num} " /etc/iproute2/rt_tables; then
        echo "${num} ${name}" >> /etc/iproute2/rt_tables
        log "Added rt_table: ${num} ${name}"
    fi
done

# ── Helper: get QMI gateway for a cellular device ──────────────────────────
get_cell_gw() {
    local dev="$1"
    qmicli -d "$dev" -p --wds-get-current-settings 2>/dev/null \
        | grep -i 'gateway' | awk '{print $NF}' || true
}

# ── Cell A (T-Mobile) → table tmo_cA via wwan0 ────────────────────────────
GW_CELL_A=$(get_cell_gw /dev/cdc-wdm0)
if [[ -n "$GW_CELL_A" ]]; then
    ip route replace default via "$GW_CELL_A" dev wwan0 table tmo_cA
    log "tmo_cA: default via $GW_CELL_A dev wwan0"
else
    # Fallback: if WG tunnel is up, route through it
    if ip link show wg-ca-cA &>/dev/null; then
        ip route replace default dev wg-ca-cA table tmo_cA
        log "tmo_cA: default dev wg-ca-cA (WG fallback)"
    else
        log "WARN: tmo_cA — no gateway found, no WG tunnel"
    fi
fi

# ── Cell B (AT&T) → table att_cA via wwan1 ────────────────────────────────
GW_CELL_B=$(get_cell_gw /dev/cdc-wdm1)
if [[ -n "$GW_CELL_B" ]]; then
    ip route replace default via "$GW_CELL_B" dev wwan1 table att_cA
    log "att_cA: default via $GW_CELL_B dev wwan1"
else
    if ip link show wg-cb-cA &>/dev/null; then
        ip route replace default dev wg-cb-cA table att_cA
        log "att_cA: default dev wg-cb-cA (WG fallback)"
    else
        log "WARN: att_cA — no gateway found, no WG tunnel"
    fi
fi

# ── Starlink A → table sl_a via veth into ns_sl_a ─────────────────────────
# veth_sl_a (main side) peers with veth_sl_a_ns (namespace side)
# Traffic enters the namespace where WG or default route handles it
if ip link show veth_sl_a &>/dev/null; then
    # Get the namespace-side IP as the gateway
    PEER_SL_A=$(ip netns exec ns_sl_a ip -4 addr show veth_sl_a_ns 2>/dev/null \
        | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 || true)
    if [[ -n "$PEER_SL_A" ]]; then
        ip route replace default via "$PEER_SL_A" dev veth_sl_a table sl_a
        log "sl_a: default via $PEER_SL_A dev veth_sl_a"
    else
        # Try the known veth pair address from netns-init
        ip route replace default via 10.201.3.2 dev veth_sl_a table sl_a 2>/dev/null && \
            log "sl_a: default via 10.201.3.2 dev veth_sl_a (static)" || \
            log "WARN: sl_a — no peer address found"
    fi
else
    log "WARN: sl_a — veth_sl_a not found"
fi

# ── Starlink B → table sl_b via veth into ns_sl_b ─────────────────────────
if ip link show veth_sl_b &>/dev/null; then
    PEER_SL_B=$(ip netns exec ns_sl_b ip -4 addr show veth_sl_b_ns 2>/dev/null \
        | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 || true)
    if [[ -n "$PEER_SL_B" ]]; then
        ip route replace default via "$PEER_SL_B" dev veth_sl_b table sl_b
        log "sl_b: default via $PEER_SL_B dev veth_sl_b"
    else
        ip route replace default via 10.201.4.2 dev veth_sl_b table sl_b 2>/dev/null && \
            log "sl_b: default via 10.201.4.2 dev veth_sl_b (static)" || \
            log "WARN: sl_b — no peer address found"
    fi
else
    log "WARN: sl_b — veth_sl_b not found"
fi

# ── Fiber A (Google) → table fa via veth into ns_fa ────────────────────────
if ip link show veth_fa &>/dev/null; then
    PEER_FA=$(ip netns exec ns_fa ip -4 addr show veth_fa_ns 2>/dev/null \
        | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 || true)
    if [[ -n "$PEER_FA" ]]; then
        ip route replace default via "$PEER_FA" dev veth_fa table fa
        log "fa: default via $PEER_FA dev veth_fa"
    else
        ip route replace default via 10.201.1.2 dev veth_fa table fa 2>/dev/null && \
            log "fa: default via 10.201.1.2 dev veth_fa (static)" || \
            log "WARN: fa — no peer address found"
    fi
else
    log "WARN: fa — veth_fa not found"
fi

# ── Fiber B (AT&T) → table fb via veth into ns_fb ─────────────────────────
if ip link show veth_fb &>/dev/null; then
    PEER_FB=$(ip netns exec ns_fb ip -4 addr show veth_fb_ns 2>/dev/null \
        | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 || true)
    if [[ -n "$PEER_FB" ]]; then
        ip route replace default via "$PEER_FB" dev veth_fb table fb
        log "fb: default via $PEER_FB dev veth_fb"
    else
        ip route replace default via 10.201.2.2 dev veth_fb table fb 2>/dev/null && \
            log "fb: default via 10.201.2.2 dev veth_fb (static)" || \
            log "WARN: fb — no peer address found"
    fi
else
    log "WARN: fb — veth_fb not found"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
log "=== Route Table Summary ==="
for t in tmo_cA att_cA sl_a sl_b fa fb; do
    dflt=$(ip route show table "$t" 2>/dev/null | grep default || echo "(empty)")
    log "  $t: $dflt"
done

echo ""
log "=== Verify with: ip route show table <name> ==="
log "Done."
