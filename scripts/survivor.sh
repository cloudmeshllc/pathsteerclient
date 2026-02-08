#!/bin/bash
###############################################################################
# PathSteer Survivor - Never give up connectivity
###############################################################################

LOG="/var/log/pathsteer/survivor.log"
mkdir -p "$(dirname "$LOG")" /run/pathsteer
exec >> "$LOG" 2>&1

log() { echo "[$(date '+%H:%M:%S')] $*"; }

CONTROLLER="ctrl-a.pathsteerlabs.com"
PHONE_HOME_PORT="8888"

# Namespace configs: ns|iface|veth_main|veth_ip_main|veth_ip_ns|gateway_hint
PATHS=(
    "ns_fa|ps_ter_a|veth_fa|10.201.1.1|10.201.1.2|192.168.0.1"
    "ns_fb|ps_ter_b|veth_fb|10.201.2.1|10.201.2.2|192.168.12.1"
    "ns_sl_a|ps_sl_a|veth_sl_a|10.201.3.1|10.201.3.2|100.64.0.1"
    "ns_sl_b|ps_sl_b|veth_sl_b|10.201.4.1|10.201.4.2|192.168.2.1"
)


# Start SSH forwarders in each namespace
start_ssh_forwarders() {
    log "Starting SSH forwarders..."
    for path in "${PATHS[@]}"; do
        IFS="|" read -r ns iface veth veth_ip_main veth_ip_ns gw <<< "$path"
        pkill -f "socat.*$ns.*:22" 2>/dev/null || true
        ip netns exec "$ns" socat TCP4-LISTEN:22,fork,reuseaddr TCP4:${veth_ip_main}:22 2>/dev/null &
        ip netns exec "$ns" socat TCP6-LISTEN:22,fork,reuseaddr TCP6:[${veth_ip_main}]:22 2>/dev/null &
        log "[$ns] SSH forwarder started"
    done
}
# Preserve Tailscale connectivity before any route changes
preserve_tailscale() {
    # Find current cellular gateway
    local wwan_gw=$(ip route show dev wwan1 | grep default | awk '{print $3}' | head -1)
    if [[ -z "$wwan_gw" ]]; then
        wwan_gw=$(ip -4 addr show wwan1 | grep -oP 'inet \K[\d.]+')
    fi
    
    if [[ -n "$wwan_gw" ]]; then
        # Route Tailscale CGNAT range through cellular
        ip route replace 100.64.0.0/10 via "$wwan_gw" dev wwan1 2>/dev/null || \
        ip route replace 100.64.0.0/10 dev wwan1 2>/dev/null
        log "Tailscale route preserved via wwan1"
    fi
}

# Phone home - POST all IPs to controller
phone_home() {
    local data="hostname=$(hostname)&time=$(date -Iseconds)"
    
    for iface in wwan0 wwan1; do
        ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d.]+')
        [[ -n "$ip" ]] && data+="&${iface}=${ip}"
    done
    
    for path in "${PATHS[@]}"; do
        IFS='|' read -r ns iface veth veth_ip_main veth_ip_ns gw <<< "$path"
        ip=$(ip netns exec "$ns" ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d.]+')
        ipv6=$(ip netns exec "$ns" ip -6 addr show "$iface" scope global 2>/dev/null | grep -oP 'inet6 \K[^/]+' | head -1)
        [[ -n "$ip" ]] && data+="&${ns}_v4=${ip}"
        [[ -n "$ipv6" ]] && data+="&${ns}_v6=${ipv6}"
    done
    
    data+="&current_path=$(cat /run/pathsteer/current_path 2>/dev/null)"
    
    curl -s --max-time 5 -X POST -d "$data" "http://${CONTROLLER}:${PHONE_HOME_PORT}/phonehome" 2>/dev/null || true
    log "Phone home sent"
}

# Bring up a single path
bring_up_path() {
    local ns=$1 iface=$2 veth=$3 veth_ip_main=$4 veth_ip_ns=$5 gw_hint=$6
    
    log "[$ns] Starting..."
    
    ip netns add "$ns" 2>/dev/null || true
    ip netns exec "$ns" ip link set lo up 2>/dev/null
    
    if ! ip link show "$veth" &>/dev/null; then
        ip link add "$veth" type veth peer name "${veth}_i"
        ip link set "${veth}_i" netns "$ns"
        ip addr add "${veth_ip_main}/30" dev "$veth" 2>/dev/null
        ip netns exec "$ns" ip addr add "${veth_ip_ns}/30" dev "${veth}_i" 2>/dev/null
    fi
    ip link set "$veth" up
    ip netns exec "$ns" ip link set "${veth}_i" up 2>/dev/null
    
    if ip link show "$iface" &>/dev/null; then
        ip link set "$iface" netns "$ns"
    fi
    
    ip netns exec "$ns" ip link set "$iface" up 2>/dev/null || return 1
    
    # DHCP retry in background
    (
        while true; do
            if ! ip netns exec "$ns" ip -4 addr show "$iface" 2>/dev/null | grep -q inet; then
                ip netns exec "$ns" dhclient -1 "$iface" 2>/dev/null
            fi
            sleep 30
        done
    ) &
    
    sleep 3
    
    local ip=$(ip netns exec "$ns" ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d.]+')
    if [[ -z "$ip" ]]; then
        log "[$ns] No IP yet, DHCP continuing in background"
        return 1
    fi
    log "[$ns] Got IP: $ip"
    
    # NAT with correct interface name
    ip netns exec "$ns" iptables -t nat -F POSTROUTING 2>/dev/null
    ip netns exec "$ns" iptables -t nat -A POSTROUTING -o "$iface" -j MASQUERADE
    ip netns exec "$ns" sysctl -qw net.ipv4.ip_forward=1
    
    # Disable rp_filter
    sysctl -qw "net.ipv4.conf.${veth}.rp_filter=0" 2>/dev/null
    ip netns exec "$ns" sysctl -qw net.ipv4.conf.all.rp_filter=0 2>/dev/null
    
    local gw=$(ip netns exec "$ns" ip route | grep default | awk '{print $3}')
    [[ -z "$gw" ]] && gw="$gw_hint"
    ip netns exec "$ns" ip route replace default via "$gw" dev "$iface" 2>/dev/null
    
    log "[$ns] Ready"
    return 0
}

# Test a path and return latency in ms (or 9999 if failed)
test_path() {
    local ns=$1
    local result=$(ip netns exec "$ns" ping -c1 -W2 8.8.8.8 2>/dev/null | grep -oP 'time=\K[\d.]+')
    echo "${result:-9999}"
}

# Find and set best path
set_best_path() {
    local best_ns="" best_veth="" best_veth_ip="" best_latency=9999
    
    for path in "${PATHS[@]}"; do
        IFS='|' read -r ns iface veth veth_ip_main veth_ip_ns gw <<< "$path"
        local latency=$(test_path "$ns")
        log "[$ns] latency: ${latency}ms"
        
        if (( $(echo "$latency < $best_latency" | bc -l) )); then
            best_latency=$latency
            best_ns=$ns
            best_veth=$veth
            best_veth_ip=$veth_ip_ns
        fi
    done
    
    if [[ -n "$best_ns" && "$best_latency" != "9999" ]]; then
        log "Best path: $best_ns (${best_latency}ms)"
        ip route replace default via "$best_veth_ip" dev "$best_veth"
        echo "$best_ns" > /run/pathsteer/current_path
        return 0
    fi
    
    log "No working path found, keeping current default"
    return 1
}

###############################################################################
# MAIN
###############################################################################
log "=========================================="
log "PathSteer Survivor starting"
log "=========================================="

# Preserve Tailscale FIRST
preserve_tailscale

# Bring up all paths in parallel
for path in "${PATHS[@]}"; do
    IFS='|' read -r ns iface veth veth_ip_main veth_ip_ns gw <<< "$path"
    bring_up_path "$ns" "$iface" "$veth" "$veth_ip_main" "$veth_ip_ns" "$gw" &
done

sleep 15

set_best_path
start_ssh_forwarders
phone_home

# Monitor loop
phone_home_counter=0
while true; do
    sleep 30
    
    ((phone_home_counter++))
    if (( phone_home_counter >= 4 )); then
        phone_home
        phone_home_counter=0
    fi
    
    current=$(cat /run/pathsteer/current_path 2>/dev/null)
    current_latency=$(test_path "$current")
    
    for path in "${PATHS[@]}"; do
        IFS='|' read -r ns iface veth veth_ip_main veth_ip_ns gw <<< "$path"
        [[ "$ns" == "$current" ]] && continue
        
        latency=$(test_path "$ns")
        if (( $(echo "$latency < $current_latency - 20" | bc -l 2>/dev/null || echo 0) )); then
            log "Switching from $current (${current_latency}ms) to $ns (${latency}ms)"
            ip route replace default via "$veth_ip_ns" dev "$veth"
            echo "$ns" > /run/pathsteer/current_path
            phone_home
            break
        fi
    done
done

