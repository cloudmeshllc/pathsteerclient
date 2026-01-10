#!/bin/bash
###############################################################################
# PathSteer Guardian - Starlink Normalization
#
# Binds Starlink interfaces to namespaces, queries dish stats via gRPC
#
# Usage:
#   ./starlink-normalize.sh status     # Show Starlink status
#   ./starlink-normalize.sh bind       # Bind interfaces to netns
#   ./starlink-normalize.sh stats      # Query dish stats
#   ./starlink-normalize.sh json       # JSON output for API
###############################################################################
set -euo pipefail

# Starlink config: name -> interface:netns:dish_ip
declare -A STARLINK_CONFIG=(
    ["sl_a"]="enp3s0:ns_sl_a:192.168.100.1"
    ["sl_b"]="enp4s0:ns_sl_b:192.168.100.1"
)

STATE_DIR="/var/lib/pathsteer/starlink"
LOG_FILE="/var/log/pathsteer/starlink-normalize.log"

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

# Bring up interface and get DHCP
configure_interface() {
    local name=$1
    local iface=$2
    local metric=$3
    
    ip link set "$iface" up
    
    # Kill existing dhclient
    pkill -f "dhclient.*$iface" 2>/dev/null || true
    
    # Get DHCP
    dhclient -v "$iface" 2>&1 | head -5 &
    sleep 3
    
    local ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
    local gw=$(ip route show dev "$iface" 2>/dev/null | grep default | awk '{print $3}' | head -1)
    
    if [[ -z "$gw" ]]; then
        # Try common Starlink gateways
        for try_gw in 192.168.1.1 192.168.2.1 100.64.0.1; do
            if ping -c 1 -W 1 -I "$iface" "$try_gw" &>/dev/null; then
                gw="$try_gw"
                ip route add default via "$gw" dev "$iface" metric "$metric" 2>/dev/null || true
                break
            fi
        done
    fi
    
    log "$name: $iface = $ip via $gw"
    echo "ip=$ip gw=$gw"
}

# Bind interface to netns
bind_to_netns() {
    local name=$1
    local iface=$2
    local netns=$3
    
    # Create netns
    ip netns add "$netns" 2>/dev/null || true
    ip netns exec "$netns" ip link set lo up
    
    # Check if already in netns
    if ip netns exec "$netns" ip link show "$iface" &>/dev/null; then
        log "$iface already in $netns"
        return 0
    fi
    
    # Move interface
    if ip link show "$iface" &>/dev/null; then
        log "Moving $iface to $netns"
        ip link set "$iface" netns "$netns"
        ip netns exec "$netns" ip link set "$iface" up
        
        # Get DHCP inside netns
        ip netns exec "$netns" dhclient -nw "$iface" 2>/dev/null &
        sleep 3
        
        return 0
    fi
    
    log "Interface $iface not found"
    return 1
}

# Query dish stats via gRPC (must be called from correct netns or with route)
get_dish_stats() {
    local dish_ip=$1
    local netns=${2:-}
    
    local cmd="grpcurl -plaintext -d '{\"get_status\":{}}' ${dish_ip}:9200 SpaceX.API.Device.Device/Handle"
    
    if [[ -n "$netns" ]]; then
        ip netns exec "$netns" bash -c "$cmd" 2>/dev/null
    else
        eval "$cmd" 2>/dev/null
    fi
}

# Parse dish stats to JSON
parse_dish_stats() {
    local raw_stats=$1
    
    if [[ -z "$raw_stats" ]]; then
        echo '{"error": "no stats"}'
        return
    fi
    
    # Extract key fields using grep/sed (basic parsing)
    local state=$(echo "$raw_stats" | grep -oP '"state":\s*"\K[^"]+' | head -1)
    local uptime=$(echo "$raw_stats" | grep -oP '"uptimeS":\s*\K\d+' | head -1)
    local snr=$(echo "$raw_stats" | grep -oP '"snr":\s*\K[\d.]+' | head -1)
    local downlink=$(echo "$raw_stats" | grep -oP '"downlinkThroughputBps":\s*\K[\d.]+' | head -1)
    local uplink=$(echo "$raw_stats" | grep -oP '"uplinkThroughputBps":\s*\K[\d.]+' | head -1)
    local latency=$(echo "$raw_stats" | grep -oP '"popPingLatencyMs":\s*\K[\d.]+' | head -1)
    local obstructed=$(echo "$raw_stats" | grep -oP '"fractionObstructed":\s*\K[\d.]+' | head -1)
    
    cat << EOF
{
  "state": "${state:-unknown}",
  "uptime_s": ${uptime:-0},
  "snr": ${snr:-0},
  "downlink_bps": ${downlink:-0},
  "uplink_bps": ${uplink:-0},
  "latency_ms": ${latency:-0},
  "fraction_obstructed": ${obstructed:-0}
}
EOF
}

# Status command
cmd_status() {
    echo "=== PathSteer Starlink Status ==="
    echo ""
    
    for name in "${!STARLINK_CONFIG[@]}"; do
        IFS=':' read -r iface netns dish_ip <<< "${STARLINK_CONFIG[$name]}"
        
        echo "--- $name ($iface) ---"
        
        # Check interface location
        if ip link show "$iface" &>/dev/null; then
            echo "  Location: main namespace"
            local ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
            echo "  IP: ${ip:-none}"
            
            # Try to ping dish
            if ping -c 1 -W 2 -I "$iface" "$dish_ip" &>/dev/null; then
                echo "  Dish: reachable at $dish_ip"
            else
                echo "  Dish: NOT reachable"
            fi
            
        elif ip netns exec "$netns" ip link show "$iface" &>/dev/null 2>&1; then
            echo "  Location: $netns"
            local ip=$(ip netns exec "$netns" ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
            echo "  IP: ${ip:-none}"
            
            if ip netns exec "$netns" ping -c 1 -W 2 "$dish_ip" &>/dev/null; then
                echo "  Dish: reachable at $dish_ip"
            else
                echo "  Dish: NOT reachable"
            fi
        else
            echo "  Interface: NOT FOUND"
        fi
        echo ""
    done
}

# Bind command
cmd_bind() {
    log "Binding Starlink interfaces to namespaces..."
    
    local metric=200
    for name in "${!STARLINK_CONFIG[@]}"; do
        IFS=':' read -r iface netns dish_ip <<< "${STARLINK_CONFIG[$name]}"
        
        bind_to_netns "$name" "$iface" "$netns"
        
        # Add route to dish inside netns
        ip netns exec "$netns" ip route add "$dish_ip" dev "$iface" 2>/dev/null || true
        
        ((metric++))
    done
}

# Configure without netns (for testing)
cmd_configure() {
    log "Configuring Starlink interfaces (no netns)..."
    
    local metric=200
    for name in "${!STARLINK_CONFIG[@]}"; do
        IFS=':' read -r iface netns dish_ip <<< "${STARLINK_CONFIG[$name]}"
        
        configure_interface "$name" "$iface" "$metric"
        
        # Add route to dish
        ip route add "$dish_ip" dev "$iface" metric 10 2>/dev/null || true
        
        ((metric++))
    done
}

# Stats command
cmd_stats() {
    echo "=== Starlink Dish Stats ==="
    
    for name in "${!STARLINK_CONFIG[@]}"; do
        IFS=':' read -r iface netns dish_ip <<< "${STARLINK_CONFIG[$name]}"
        
        echo ""
        echo "--- $name ---"
        
        local netns_param=""
        if ip netns exec "$netns" ip link show "$iface" &>/dev/null 2>&1; then
            netns_param="$netns"
        fi
        
        local stats=$(get_dish_stats "$dish_ip" "$netns_param")
        if [[ -n "$stats" ]]; then
            parse_dish_stats "$stats"
        else
            echo "Could not reach dish at $dish_ip"
        fi
    done
}

# JSON output
cmd_json() {
    echo "{"
    echo '  "starlinks": ['
    
    local first=true
    for name in "${!STARLINK_CONFIG[@]}"; do
        IFS=':' read -r iface netns dish_ip <<< "${STARLINK_CONFIG[$name]}"
        
        [[ "$first" == "true" ]] || echo ","
        first=false
        
        local location="unknown"
        local ip=""
        local reachable="false"
        
        if ip link show "$iface" &>/dev/null; then
            location="main"
            ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
            ping -c 1 -W 1 -I "$iface" "$dish_ip" &>/dev/null && reachable="true"
        elif ip netns exec "$netns" ip link show "$iface" &>/dev/null 2>&1; then
            location="$netns"
            ip=$(ip netns exec "$netns" ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
            ip netns exec "$netns" ping -c 1 -W 1 "$dish_ip" &>/dev/null && reachable="true"
        fi
        
        cat << JSONITEM
    {
      "name": "$name",
      "interface": "$iface",
      "netns": "$netns",
      "location": "$location",
      "ip": "$ip",
      "dish_ip": "$dish_ip",
      "reachable": $reachable
    }
JSONITEM
    done
    
    echo ""
    echo "  ]"
    echo "}"
}

# Main
case "${1:-status}" in
    status)
        cmd_status
        ;;
    bind)
        cmd_bind
        ;;
    configure)
        cmd_configure
        ;;
    stats)
        cmd_stats
        ;;
    json)
        cmd_json
        ;;
    *)
        echo "Usage: $0 {status|bind|configure|stats|json}"
        exit 1
        ;;
esac
