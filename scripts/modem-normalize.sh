#!/bin/bash
###############################################################################
# PathSteer Guardian - Cellular Modem Normalization
# 
# Discovers modems, connects them, gets IP/gateway from bearers,
# configures interfaces, and optionally binds to netns.
#
# Features:
# - Auto-discovery via ModemManager
# - IPv4 and IPv6 support
# - Bearer IP extraction (no DHCP needed for QMI)
# - Netns binding for uplink isolation
# - Hotplug handling (USB reconnect)
# - Signal monitoring setup
#
# Usage:
#   ./modem-normalize.sh status       # Show all modems
#   ./modem-normalize.sh connect      # Connect all modems
#   ./modem-normalize.sh configure    # Configure interfaces with IPs
#   ./modem-normalize.sh bind-netns   # Move interfaces to namespaces
#   ./modem-normalize.sh full         # Do all of the above
#   ./modem-normalize.sh watch        # Continuous monitoring/recovery
###############################################################################
set -euo pipefail

CONFIG_FILE="/etc/pathsteer/config.json"
STATE_DIR="/var/lib/pathsteer/modems"
LOG_FILE="/var/log/pathsteer/modem-normalize.log"

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"

# Modem definitions: IMEI -> (name, apn, netns)
declare -A MODEM_CONFIG=(
    ["868371055098699"]="cell_a:fast.t-mobile.com:ns_cell_a:wwan0"
    ["868371055076786"]="cell_b:broadband:ns_cell_b:wwan1"
)

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

err() {
    log "ERROR: $*"
}

# Get modem number by IMEI
get_modem_by_imei() {
    local imei=$1
    mmcli -L 2>/dev/null | while read -r line; do
        local modem_path=$(echo "$line" | grep -oP '/org/freedesktop/ModemManager1/Modem/\d+')
        if [[ -n "$modem_path" ]]; then
            local modem_num=$(echo "$modem_path" | grep -oP '\d+$')
            local modem_imei=$(mmcli -m "$modem_num" --output-keyvalue 2>/dev/null | grep "modem.3gpp.imei" | cut -d: -f2 | tr -d ' ')
            if [[ "$modem_imei" == "$imei" ]]; then
                echo "$modem_num"
                return 0
            fi
        fi
    done
    return 1
}

# Get all modems
get_all_modems() {
    mmcli -L 2>/dev/null | grep -oP '/org/freedesktop/ModemManager1/Modem/\K\d+' || true
}

# Get modem info
get_modem_info() {
    local modem_num=$1
    local info=$(mmcli -m "$modem_num" --output-keyvalue 2>/dev/null)
    
    local imei=$(echo "$info" | grep "modem.3gpp.imei" | cut -d: -f2 | tr -d ' ')
    local state=$(echo "$info" | grep "modem.generic.state" | head -1 | cut -d: -f2 | tr -d ' ')
    local signal=$(echo "$info" | grep "modem.generic.signal-quality.value" | cut -d: -f2 | tr -d ' ')
    local operator=$(echo "$info" | grep "modem.3gpp.operator-name" | cut -d: -f2 | tr -d ' ')
    local access_tech=$(echo "$info" | grep "modem.generic.access-technologies" | cut -d: -f2 | tr -d ' ')
    local net_if=$(echo "$info" | grep -oP 'wwan\d+' | head -1)
    
    echo "modem=$modem_num imei=$imei state=$state signal=$signal% operator=$operator tech=$access_tech iface=$net_if"
}

# Get bearer IP info
get_bearer_ip() {
    local modem_num=$1
    local bearer_path=$(mmcli -m "$modem_num" 2>/dev/null | grep -oP "Bearer.*paths: \K/[^\s]+" | head -1)
    
    if [[ -z "$bearer_path" ]]; then
        # Try to find bearer from list
        bearer_path=$(mmcli -m "$modem_num" --list-bearers 2>/dev/null | grep -oP '/org/freedesktop/ModemManager1/Bearer/\d+' | tail -1)
    fi
    
    if [[ -z "$bearer_path" ]]; then
        return 1
    fi
    
    local bearer_num=$(echo "$bearer_path" | grep -oP '\d+$')
    local bearer_info=$(mmcli -b "$bearer_num" 2>/dev/null)
    
    local ipv4_addr=$(echo "$bearer_info" | grep -A5 "IPv4 configuration" | grep "address:" | head -1 | grep -oP '[\d.]+')
    local ipv4_gw=$(echo "$bearer_info" | grep -A5 "IPv4 configuration" | grep "gateway:" | head -1 | grep -oP '[\d.]+')
    local ipv4_dns=$(echo "$bearer_info" | grep -A5 "IPv4 configuration" | grep "dns:" | head -1 | grep -oP '[\d.]+' | head -1)
    
    local ipv6_addr=$(echo "$bearer_info" | grep -A5 "IPv6 configuration" | grep "address:" | head -1 | grep -oP '[a-fA-F0-9:]+/\d+' || true)
    local ipv6_gw=""  # IPv6 gateway disabled for now
    
    echo "ipv4_addr=$ipv4_addr ipv4_gw=$ipv4_gw ipv4_dns=$ipv4_dns ipv6_addr=$ipv6_addr ipv6_gw=$ipv6_gw"
}

# Connect modem
connect_modem() {
    local modem_num=$1
    local apn=$2
    
    local state=$(mmcli -m "$modem_num" --output-keyvalue 2>/dev/null | grep "modem.generic.state" | head -1 | cut -d: -f2 | tr -d ' ')
    
    if [[ "$state" == "connected" ]]; then
        log "Modem $modem_num already connected"
        return 0
    fi
    
    if [[ "$state" == "disabled" ]]; then
        log "Enabling modem $modem_num..."
        mmcli -m "$modem_num" --enable
        sleep 3
    fi
    
    log "Connecting modem $modem_num with APN $apn..."
    if mmcli -m "$modem_num" --simple-connect="apn=$apn,ip-type=ipv4v6" 2>/dev/null; then
        log "Modem $modem_num connected"
        return 0
    else
        err "Failed to connect modem $modem_num"
        return 1
    fi
}

# Configure network interface with bearer IPs
configure_interface() {
    local iface=$1
    local ipv4_addr=$2
    local ipv4_gw=$3
    local ipv6_addr=${4:-}
    local ipv6_gw=""  # IPv6 gateway disabled for now
    local metric=${6:-100}
    
    log "Configuring $iface: IPv4=$ipv4_addr gw=$ipv4_gw IPv6=$ipv6_addr"
    
    # Bring up interface
    ip link set "$iface" up
    
    # Flush existing IPs
    ip addr flush dev "$iface" 2>/dev/null || true
    
    # Add IPv4
    if [[ -n "$ipv4_addr" ]]; then
        ip addr add "${ipv4_addr}/32" dev "$iface"
        ip route add "$ipv4_gw" dev "$iface" 2>/dev/null || true
        ip route add default via "$ipv4_gw" dev "$iface" metric "$metric" 2>/dev/null || true
    fi
    
    # Add IPv6 if available
    if [[ -n "$ipv6_addr" && "$ipv6_addr" != "/" ]]; then
        ip -6 addr add "$ipv6_addr" dev "$iface" 2>/dev/null || true
        if [[ -n "$ipv6_gw" ]]; then
            ip -6 route add default via "$ipv6_gw" dev "$iface" metric "$metric" 2>/dev/null || true
        fi
    fi
    
    log "Interface $iface configured"
}

# Move interface to netns
bind_to_netns() {
    local iface=$1
    local netns=$2
    
    # Create netns if doesn't exist
    ip netns add "$netns" 2>/dev/null || true
    ip netns exec "$netns" ip link set lo up 2>/dev/null || true
    
    # Check if interface exists in main namespace
    if ip link show "$iface" &>/dev/null; then
        log "Moving $iface to $netns"
        ip link set "$iface" netns "$netns"
        ip netns exec "$netns" ip link set "$iface" up
        return 0
    fi
    
    # Check if already in netns
    if ip netns exec "$netns" ip link show "$iface" &>/dev/null; then
        log "$iface already in $netns"
        return 0
    fi
    
    err "Interface $iface not found"
    return 1
}

# Configure interface inside netns
configure_interface_in_netns() {
    local netns=$1
    local iface=$2
    local ipv4_addr=$3
    local ipv4_gw=$4
    local ipv6_addr=${5:-}
    local ipv6_gw=""  # IPv6 gateway disabled for now
    
    log "Configuring $iface in $netns: IPv4=$ipv4_addr"
    
    ip netns exec "$netns" ip link set "$iface" up
    ip netns exec "$netns" ip addr flush dev "$iface" 2>/dev/null || true
    
    if [[ -n "$ipv4_addr" ]]; then
        ip netns exec "$netns" ip addr add "${ipv4_addr}/32" dev "$iface"
        ip netns exec "$netns" ip route add "$ipv4_gw" dev "$iface" 2>/dev/null || true
        ip netns exec "$netns" ip route add default via "$ipv4_gw" dev "$iface" 2>/dev/null || true
    fi
    
    if [[ -n "$ipv6_addr" && "$ipv6_addr" != "/" ]]; then
        ip netns exec "$netns" ip -6 addr add "$ipv6_addr" dev "$iface" 2>/dev/null || true
        if [[ -n "$ipv6_gw" ]]; then
            ip netns exec "$netns" ip -6 route add default via "$ipv6_gw" dev "$iface" 2>/dev/null || true
        fi
    fi
}

# Enable signal monitoring
enable_signal_monitoring() {
    local modem_num=$1
    mmcli -m "$modem_num" --signal-setup=5 2>/dev/null || true
}

# Get detailed signal info
get_signal_info() {
    local modem_num=$1
    mmcli -m "$modem_num" --signal-get 2>/dev/null | grep -E "rssi|rsrp|rsrq|snr|sinr" || echo "no signal data"
}

# Save state
save_state() {
    local name=$1
    shift
    echo "$@" > "$STATE_DIR/${name}.state"
}

# Load state
load_state() {
    local name=$1
    cat "$STATE_DIR/${name}.state" 2>/dev/null || echo ""
}

# Status command
cmd_status() {
    echo "=== PathSteer Modem Status ==="
    echo ""
    
    for modem_num in $(get_all_modems); do
        echo "--- Modem $modem_num ---"
        get_modem_info "$modem_num"
        
        local state=$(mmcli -m "$modem_num" --output-keyvalue 2>/dev/null | grep "modem.generic.state" | head -1 | cut -d: -f2 | tr -d ' ')
        if [[ "$state" == "connected" ]]; then
            echo "Bearer IP:"
            get_bearer_ip "$modem_num" | tr ' ' '\n' | sed 's/^/  /'
            echo "Signal:"
            get_signal_info "$modem_num" | sed 's/^/  /'
        fi
        echo ""
    done
    
    echo "=== Network Interfaces ==="
    ip -br addr show | grep -E "wwan|wlan" || echo "No wwan/wlan interfaces"
    
    echo ""
    echo "=== Namespaces ==="
    ip netns list 2>/dev/null || echo "No namespaces"
}

# Connect all modems
cmd_connect() {
    log "Connecting all configured modems..."
    
    for imei in "${!MODEM_CONFIG[@]}"; do
        IFS=':' read -r name apn netns iface <<< "${MODEM_CONFIG[$imei]}"
        
        local modem_num=$(get_modem_by_imei "$imei")
        if [[ -z "$modem_num" ]]; then
            err "Modem with IMEI $imei ($name) not found"
            continue
        fi
        
        log "Found $name: modem $modem_num (IMEI: $imei)"
        connect_modem "$modem_num" "$apn"
        enable_signal_monitoring "$modem_num"
        
        # Save state
        save_state "$name" "modem=$modem_num imei=$imei apn=$apn netns=$netns iface=$iface"
    done
}

# Configure interfaces
cmd_configure() {
    log "Configuring network interfaces..."
    
    for imei in "${!MODEM_CONFIG[@]}"; do
        IFS=':' read -r name apn netns expected_iface <<< "${MODEM_CONFIG[$imei]}"
        
        local modem_num=$(get_modem_by_imei "$imei")
        if [[ -z "$modem_num" ]]; then
            err "Modem $name not found"
            continue
        fi
        
        # Get actual interface from modem info
        local iface=$(mmcli -m "$modem_num" 2>/dev/null | grep -oP 'wwan\d+' | head -1)
        if [[ -z "$iface" ]]; then
            iface="$expected_iface"
        fi
        
        # Get bearer IPs
        local bearer_info=$(get_bearer_ip "$modem_num")
        if [[ -z "$bearer_info" ]]; then
            err "No bearer info for $name"
            continue
        fi
        
        eval "$bearer_info"
        
        # Determine metric based on modem
        local metric=100
        [[ "$name" == "cell_b" ]] && metric=101
        
        # Configure interface
        configure_interface "$iface" "$ipv4_addr" "$ipv4_gw" "$ipv6_addr" "$ipv6_gw" "$metric"
        
        # Save state
        save_state "$name" "modem=$modem_num iface=$iface ipv4=$ipv4_addr ipv4_gw=$ipv4_gw ipv6=$ipv6_addr ipv6_gw=$ipv6_gw"
        
        log "$name: $iface configured with $ipv4_addr"
    done
}

# Bind to namespaces
cmd_bind_netns() {
    log "Binding interfaces to namespaces..."
    
    for imei in "${!MODEM_CONFIG[@]}"; do
        IFS=':' read -r name apn netns expected_iface <<< "${MODEM_CONFIG[$imei]}"
        
        local modem_num=$(get_modem_by_imei "$imei")
        if [[ -z "$modem_num" ]]; then
            err "Modem $name not found"
            continue
        fi
        
        local iface=$(mmcli -m "$modem_num" 2>/dev/null | grep -oP 'wwan\d+' | head -1)
        if [[ -z "$iface" ]]; then
            iface="$expected_iface"
        fi
        
        # Get bearer IPs before moving (MM won't work from netns)
        local bearer_info=$(get_bearer_ip "$modem_num")
        eval "$bearer_info"
        
        # Move to netns
        bind_to_netns "$iface" "$netns"
        
        # Configure inside netns
        configure_interface_in_netns "$netns" "$iface" "$ipv4_addr" "$ipv4_gw" "$ipv6_addr" "$ipv6_gw"
        
        log "$name: $iface bound to $netns with $ipv4_addr"
    done
}

# Full setup
cmd_full() {
    cmd_connect
    sleep 2
    cmd_configure
}

# Watch/recover mode
cmd_watch() {
    log "Starting modem watch mode (Ctrl+C to stop)..."
    
    while true; do
        for imei in "${!MODEM_CONFIG[@]}"; do
            IFS=':' read -r name apn netns iface <<< "${MODEM_CONFIG[$imei]}"
            
            local modem_num=$(get_modem_by_imei "$imei")
            
            if [[ -z "$modem_num" ]]; then
                log "WARN: Modem $name (IMEI: $imei) not found - may be unplugged"
                continue
            fi
            
            local state=$(mmcli -m "$modem_num" --output-keyvalue 2>/dev/null | grep "modem.generic.state" | head -1 | cut -d: -f2 | tr -d ' ')
            
            if [[ "$state" != "connected" ]]; then
                log "Modem $name disconnected (state: $state), reconnecting..."
                connect_modem "$modem_num" "$apn"
                sleep 2
                
                # Reconfigure interface
                local bearer_info=$(get_bearer_ip "$modem_num")
                if [[ -n "$bearer_info" ]]; then
                    eval "$bearer_info"
                    local actual_iface=$(mmcli -m "$modem_num" 2>/dev/null | grep -oP 'wwan\d+' | head -1)
                    configure_interface "$actual_iface" "$ipv4_addr" "$ipv4_gw" "$ipv6_addr" "$ipv6_gw"
                fi
            fi
        done
        
        sleep 10
    done
}

# JSON output for API
cmd_json() {
    echo "{"
    echo '  "modems": ['
    
    local first=true
    for modem_num in $(get_all_modems); do
        local info=$(mmcli -m "$modem_num" --output-keyvalue 2>/dev/null)
        local imei=$(echo "$info" | grep "modem.3gpp.imei" | cut -d: -f2 | tr -d ' ')
        local state=$(echo "$info" | grep "modem.generic.state" | head -1 | cut -d: -f2 | tr -d ' ')
        local signal=$(echo "$info" | grep "modem.generic.signal-quality.value" | cut -d: -f2 | tr -d ' ')
        local operator=$(echo "$info" | grep "modem.3gpp.operator-name" | cut -d: -f2 | tr -d ' ')
        local tech=$(echo "$info" | grep "modem.generic.access-technologies" | cut -d: -f2 | tr -d ' ')
        local iface=$(echo "$info" | grep -oP 'wwan\d+' | head -1)
        
        local name="unknown"
        local config="${MODEM_CONFIG[$imei]:-}"
        if [[ -n "$config" ]]; then
            name=$(echo "$config" | cut -d: -f1)
        fi
        
        local ipv4=""
        local ipv4_gw=""
        if [[ "$state" == "connected" ]]; then
            local bearer_info=$(get_bearer_ip "$modem_num" 2>/dev/null)
            ipv4=$(echo "$bearer_info" | grep -oP 'ipv4_addr=\K[\d.]+')
            ipv4_gw=$(echo "$bearer_info" | grep -oP 'ipv4_gw=\K[\d.]+')
        fi
        
        # Get signal details
        local rsrp="" rsrq="" sinr=""
        if [[ "$state" == "connected" ]]; then
            local sig_info=$(mmcli -m "$modem_num" --signal-get 2>/dev/null)
            rsrp=$(echo "$sig_info" | grep -oP 'rsrp:\s*\K-?[\d.]+' | head -1)
            rsrq=$(echo "$sig_info" | grep -oP 'rsrq:\s*\K-?[\d.]+' | head -1)
            sinr=$(echo "$sig_info" | grep -oP 'snr:\s*\K-?[\d.]+' | head -1)
        fi
        
        [[ "$first" == "true" ]] || echo ","
        first=false
        
        cat << JSONITEM
    {
      "name": "$name",
      "modem": $modem_num,
      "imei": "$imei",
      "state": "$state",
      "signal_percent": ${signal:-0},
      "operator": "$operator",
      "technology": "$tech",
      "interface": "$iface",
      "ipv4": "$ipv4",
      "gateway": "$ipv4_gw",
      "rsrp": "${rsrp:-null}",
      "rsrq": "${rsrq:-null}",
      "sinr": "${sinr:-null}"
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
    connect)
        cmd_connect
        ;;
    configure)
        cmd_configure
        ;;
    bind-netns|bind)
        cmd_bind_netns
        ;;
    full)
        cmd_full
        ;;
    watch)
        cmd_watch
        ;;
    json)
        cmd_json
        ;;
    *)
        echo "Usage: $0 {status|connect|configure|bind-netns|full|watch|json}"
        exit 1
        ;;
esac
