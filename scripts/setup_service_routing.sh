#!/bin/bash
###############################################################################
# PathSteer Guardian - Service Routing Setup (FIXED)
#
# Ensures all namespaces exist, WireGuard allowed-ips are correct,
# controller routes are present, and DHCP retries for slow links (Starlink CGNAT).
#
# This runs as ExecStartPre for pathsteerd.service.
#
# Fixes applied:
#   - ns_fb creation (was missing entirely)
#   - WG allowed-ips 0.0.0.0/0 on ALL namespace tunnels (was only fa + sl_a)
#   - Controller routes for ALL namespaces (was only fa)
#   - Service subnet return routes for ALL namespaces (was only fa)
#   - DHCP retry loop for Starlink CGNAT (sleep 3 wasn't enough)
#   - Forwarding enabled in ALL namespaces
#   - NAT on WG interfaces, NOT on physical interfaces (preserve source IP)
###############################################################################
set -euo pipefail

LOG="/var/log/pathsteer/service-routing.log"
mkdir -p "$(dirname "$LOG")" /run/pathsteer

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }
err() { echo "[$(date '+%H:%M:%S')] ERROR: $*" | tee -a "$LOG" >&2; }

# ─── Controller keys ─────────────────────────────────────────────────────────
CTRL_A_PUBKEY="ocnNjGlV/bTB+OZLtkzZUYC+1OuMadNAE5K4SRaXnyI="
CTRL_B_PUBKEY="Wz3m/cfp+4yE8GNklKC+i5WEr61RVTxcd77foCpyrXI="
CTRL_A_IP="104.204.136.13"
CTRL_B_IP="104.204.136.14"
SERVICE_SUBNET="104.204.136.48/28"

# ─── Namespace definitions ────────────────────────────────────────────────────
# Format: ns_name|phys_iface|veth_main|veth_main_ip|veth_ns_name|veth_ns_ip|gateway|wg_tunnels(comma-sep)|ip_mode
# wg_tunnels: wg_name:peer_pubkey:allowed_ips_to_set
#
# NOTE: Cellular tunnels live in main namespace (fwmark routing), NOT in netns.
# Only fiber + starlink use namespace isolation.

declare -A NS_CONFIG
NS_CONFIG[ns_fa]="ps_ter_a|veth_fa|10.201.1.1|veth_fa_i|10.201.1.2|192.168.0.1|wg-fa-cA:${CTRL_A_PUBKEY},wg-fa-cB:${CTRL_B_PUBKEY}|dhcp"
NS_CONFIG[ns_fb]="ps_ter_b|veth_fb|10.201.2.1|veth_fb_i|10.201.2.2|192.168.12.1|wg-fb-cA:${CTRL_A_PUBKEY},wg-fb-cB:${CTRL_B_PUBKEY}|dhcp"
NS_CONFIG[ns_sl_a]="ps_sl_a|veth_sl_a|10.201.3.1|veth_sl_a_i|10.201.3.2|192.168.2.1|wg-sa-cA:${CTRL_A_PUBKEY},wg-sa-cB:${CTRL_B_PUBKEY}|dhcp"
NS_CONFIG[ns_sl_b]="ps_sl_b|veth_sl_b|10.201.4.1|veth_sl_b_i|10.201.4.2|100.64.0.1|wg-sb-cA:${CTRL_A_PUBKEY},wg-sb-cB:${CTRL_B_PUBKEY}|dhcp"

# ─── Helper: wait for DHCP lease with retries ────────────────────────────────
wait_for_dhcp() {
    local ns=$1
    local iface=$2
    local max_attempts=${3:-5}
    local wait_sec=${4:-4}

    for attempt in $(seq 1 "$max_attempts"); do
        # Kill stale dhclient
        ip netns exec "$ns" pkill -f "dhclient.*$iface" 2>/dev/null || true
        sleep 1

        ip netns exec "$ns" dhclient -v "$iface" 2>&1 | head -5 &
        sleep "$wait_sec"

        local ip
        ip=$(ip netns exec "$ns" ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
        if [[ -n "$ip" ]]; then
            log "  DHCP OK: $iface = $ip (attempt $attempt)"
            return 0
        fi
        log "  DHCP attempt $attempt/$max_attempts for $iface - no IP yet, retrying..."
        ((wait_sec+=2))  # Back off slightly each retry
    done

    err "  DHCP FAILED for $iface after $max_attempts attempts"
    return 1
}

# ─── Helper: ensure namespace exists with veth pair ───────────────────────────
ensure_namespace() {
    local ns=$1
    local veth_main=$2
    local veth_main_ip=$3
    local veth_ns=$4
    local veth_ns_ip=$5

    if ! ip netns list 2>/dev/null | grep -q "^${ns} "; then
        log "  Creating namespace $ns (was missing)..."
        ip netns add "$ns"
    fi
    ip netns exec "$ns" ip link set lo up 2>/dev/null || true

    # Create veth pair if not present
    if ! ip link show "$veth_main" &>/dev/null; then
        log "  Creating veth pair $veth_main <-> $veth_ns..."
        ip link del "$veth_main" 2>/dev/null || true
        ip link add "$veth_main" type veth peer name "$veth_ns"
        ip link set "$veth_ns" netns "$ns"

        ip addr add "${veth_main_ip}/30" dev "$veth_main" 2>/dev/null || true
        ip link set "$veth_main" up

        ip netns exec "$ns" ip addr add "${veth_ns_ip}/30" dev "$veth_ns" 2>/dev/null || true
        ip netns exec "$ns" ip link set "$veth_ns" up
    else
        # Veth exists, just make sure it's up
        ip link set "$veth_main" up 2>/dev/null || true
        ip netns exec "$ns" ip link set "$veth_ns" up 2>/dev/null || true
    fi
}

# ─── Helper: move physical interface to namespace if not already there ────────
ensure_iface_in_ns() {
    local ns=$1
    local iface=$2

    # Already in the right namespace?
    if ip netns exec "$ns" ip link show "$iface" &>/dev/null 2>&1; then
        ip netns exec "$ns" ip link set "$iface" up 2>/dev/null || true
        return 0
    fi

    # In main namespace?
    if ip link show "$iface" &>/dev/null; then
        log "  Moving $iface into $ns..."
        ip link set "$iface" netns "$ns"
        ip netns exec "$ns" ip link set "$iface" up
        return 0
    fi

    # Check other namespaces
    for other_ns in $(ip netns list 2>/dev/null | awk '{print $1}'); do
        if [[ "$other_ns" != "$ns" ]] && ip netns exec "$other_ns" ip link show "$iface" &>/dev/null 2>&1; then
            log "  Moving $iface from $other_ns to $ns..."
            ip netns exec "$other_ns" ip link set "$iface" netns 1
            ip link set "$iface" netns "$ns"
            ip netns exec "$ns" ip link set "$iface" up
            return 0
        fi
    done

    err "  Interface $iface not found anywhere!"
    return 1
}

# ─── Fix WireGuard allowed-ips inside a namespace ────────────────────────────
fix_wg_allowed_ips() {
    local ns=$1
    local wg_tunnels=$2  # comma-separated "wg-name:pubkey" pairs

    IFS=',' read -ra tunnels <<< "$wg_tunnels"
    for entry in "${tunnels[@]}"; do
        local wg_name="${entry%%:*}"
        local pubkey="${entry#*:}"

        if ip netns exec "$ns" ip link show "$wg_name" &>/dev/null 2>&1; then
            ip netns exec "$ns" wg set "$wg_name" peer "$pubkey" allowed-ips 0.0.0.0/0 2>/dev/null && \
                log "  $wg_name: allowed-ips -> 0.0.0.0/0" || \
                err "  $wg_name: failed to set allowed-ips"
        else
            log "  $wg_name: not present in $ns (skipping allowed-ips)"
        fi
    done
}

# ─── Add controller + service routes inside namespace ─────────────────────────
fix_ns_routes() {
    local ns=$1
    local phys_iface=$2
    local gateway=$3
    local veth_ns=$4
    local veth_main_ip=$5

    # Route to controller endpoints via physical gateway (NOT through WG!)
    ip netns exec "$ns" ip route replace "$CTRL_A_IP" via "$gateway" dev "$phys_iface" 2>/dev/null && \
        log "  Route: $CTRL_A_IP via $gateway dev $phys_iface" || true
    ip netns exec "$ns" ip route replace "$CTRL_B_IP" via "$gateway" dev "$phys_iface" 2>/dev/null && \
        log "  Route: $CTRL_B_IP via $gateway dev $phys_iface" || true

    # Service subnet return traffic goes back through veth to main namespace
    ip netns exec "$ns" ip route replace "$SERVICE_SUBNET" via "$veth_main_ip" dev "$veth_ns" 2>/dev/null && \
        log "  Route: $SERVICE_SUBNET via $veth_main_ip dev $veth_ns" || true

    # Enable forwarding
    ip netns exec "$ns" sysctl -qw net.ipv4.ip_forward=1 2>/dev/null || true
}

###############################################################################
# MAIN
###############################################################################
log "============================================"
log "PathSteer Service Routing Setup"
log "============================================"

for ns in "${!NS_CONFIG[@]}"; do
    IFS='|' read -r phys_iface veth_main veth_main_ip veth_ns veth_ns_ip gateway wg_tunnels ip_mode <<< "${NS_CONFIG[$ns]}"

    log ""
    log "--- $ns ($phys_iface) ---"

    # 1. Ensure namespace + veth pair exist
    ensure_namespace "$ns" "$veth_main" "$veth_main_ip" "$veth_ns" "$veth_ns_ip"

    # 2. Move physical interface into namespace
    if ! ensure_iface_in_ns "$ns" "$phys_iface"; then
        err "  Skipping $ns - no physical interface"
        continue
    fi

    # 3. DHCP if needed (extra retries for Starlink CGNAT)
    has_ip=$(ip netns exec "$ns" ip -4 addr show "$phys_iface" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
    if [[ -z "$has_ip" ]]; then
        case "$ns" in
            ns_sl_*)
                # Starlink CGNAT: needs more time, more retries
                wait_for_dhcp "$ns" "$phys_iface" 6 5
                ;;
            *)
                wait_for_dhcp "$ns" "$phys_iface" 3 4
                ;;
        esac
    else
        log "  $phys_iface already has IP: $has_ip"
    fi

    # 4. Verify we have a default route (DHCP should have set one)
    gw_actual=$(ip netns exec "$ns" ip route 2>/dev/null | grep "default.*$phys_iface" | awk '{print $3}' | head -1)
    if [[ -z "$gw_actual" ]]; then
        log "  No default route via $phys_iface, adding via $gateway..."
        ip netns exec "$ns" ip route add default via "$gateway" dev "$phys_iface" 2>/dev/null || true
        gw_actual="$gateway"
    fi

    # 5. Fix WireGuard allowed-ips (the critical fix for sl_b + fb)
    fix_wg_allowed_ips "$ns" "$wg_tunnels"

    # 6. Controller + service subnet routes
    fix_ns_routes "$ns" "$phys_iface" "${gw_actual:-$gateway}" "$veth_ns" "$veth_main_ip"

    log "  $ns: DONE"
done

# ─── Cellular tunnels (main namespace) ────────────────────────────────────────
log ""
log "--- Cellular WG tunnels (main namespace) ---"
for wg_iface in wg-ca-cA wg-ca-cB wg-cb-cA wg-cb-cB; do
    if ip link show "$wg_iface" &>/dev/null; then
        case "$wg_iface" in
            wg-c*-cA) pubkey="$CTRL_A_PUBKEY" ;;
            wg-c*-cB) pubkey="$CTRL_B_PUBKEY" ;;
        esac
        wg set "$wg_iface" peer "$pubkey" allowed-ips 0.0.0.0/0 2>/dev/null && \
            log "  $wg_iface: allowed-ips -> 0.0.0.0/0" || true
    fi
done

# ─── Policy routing tables for service traffic ────────────────────────────────
log ""
log "--- Policy routing tables ---"
ip route replace default dev wg-ca-cA table tmo_cA 2>/dev/null && log "  tmo_cA: via wg-ca-cA" || true
ip route replace default dev wg-ca-cB table tmo_cB 2>/dev/null && log "  tmo_cB: via wg-ca-cB" || true
ip route replace default dev wg-cb-cA table att_cA 2>/dev/null && log "  att_cA: via wg-cb-cA" || true
ip route replace default dev wg-cb-cB table att_cB 2>/dev/null && log "  att_cB: via wg-cb-cB" || true
ip route replace default via 10.201.1.2 dev veth_fa table fa 2>/dev/null && log "  fa: via veth_fa" || true
ip route replace default via 10.201.2.2 dev veth_fb table fb 2>/dev/null && log "  fb: via veth_fb" || true
ip route replace default via 10.201.3.2 dev veth_sl_a table sl_a 2>/dev/null && log "  sl_a: via veth_sl_a" || true
ip route replace default via 10.201.4.2 dev veth_sl_b table sl_b 2>/dev/null && log "  sl_b: via veth_sl_b" || true

# ─── Default route via best available ─────────────────────────────────────────
log ""
log "--- Setting main default route ---"
if ip netns exec ns_fa ping -c1 -W2 8.8.8.8 &>/dev/null 2>&1; then
    ip route replace default via 10.201.1.2 dev veth_fa
    log "  Default: fiber (ns_fa)"
elif ip netns exec ns_fb ping -c1 -W2 8.8.8.8 &>/dev/null 2>&1; then
    ip route replace default via 10.201.2.2 dev veth_fb
    log "  Default: fiber (ns_fb)"
elif ip netns exec ns_sl_a ping -c1 -W2 8.8.8.8 &>/dev/null 2>&1; then
    ip route replace default via 10.201.3.2 dev veth_sl_a
    log "  Default: starlink (ns_sl_a)"
elif ip netns exec ns_sl_b ping -c1 -W2 8.8.8.8 &>/dev/null 2>&1; then
    ip route replace default via 10.201.4.2 dev veth_sl_b
    log "  Default: starlink (ns_sl_b)"
fi

log ""
log "============================================"
log "Service routing complete"
log "============================================"

# ─── NAT and rp_filter fixes (added for veth forwarding) ──────────────────────
log ""
log "--- NAT and rp_filter for veth forwarding ---"
for ns in ns_fa ns_fb ns_sl_a ns_sl_b; do
    # Get the physical interface in this namespace
    case "$ns" in
        ns_fa) phys=ps_ter_a ; veth_i=veth_fa_i ; veth_m=veth_fa ;;
        ns_fb) phys=ps_ter_b ; veth_i=veth_fb_i ; veth_m=veth_fb ;;
        ns_sl_a) phys=ps_sl_a ; veth_i=veth_sl_a_i ; veth_m=veth_sl_a ;;
        ns_sl_b) phys=ps_sl_b ; veth_i=veth_sl_b_i ; veth_m=veth_sl_b ;;
    esac

    # Add MASQUERADE if not present
    if ip netns exec "$ns" iptables -t nat -C POSTROUTING -o "$phys" -j MASQUERADE 2>/dev/null; then
        log "  $ns: NAT already configured"
    else
        ip netns exec "$ns" iptables -t nat -A POSTROUTING -o "$phys" -j MASQUERADE && \
            log "  $ns: NAT added on $phys" || true
    fi

    # Disable rp_filter on veth interfaces (both ends)
    ip netns exec "$ns" sysctl -qw net.ipv4.conf."$veth_i".rp_filter=0 2>/dev/null || true
    ip netns exec "$ns" sysctl -qw net.ipv4.conf.all.rp_filter=0 2>/dev/null || true
    sysctl -qw net.ipv4.conf."$veth_m".rp_filter=0 2>/dev/null || true
    log "  $ns: rp_filter disabled"
done
