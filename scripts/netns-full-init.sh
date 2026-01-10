#!/bin/bash
###############################################################################
# PathSteer Guardian - Full Namespace Initialization
#
# Creates isolated namespaces for each uplink with veth bridges back to main.
# Handles DHCP for terrestrial/Starlink, bearer IPs for cellular.
#
# Architecture:
#   main namespace (daemon + management)
#     ├── enp6s0 (management - untouched)
#     ├── pathsteer-tun0 (daemon)
#     ├── veth_fiber1 ←→ ns_fiber1/veth_fiber1_ns + enp1s0
#     ├── veth_fiber2 ←→ ns_fiber2/veth_fiber2_ns + enp2s0
#     ├── veth_sl_a ←→ ns_sl_a/veth_sl_a_ns + enp3s0
#     ├── veth_sl_b ←→ ns_sl_b/veth_sl_b_ns + enp4s0
#     ├── veth_cell_a ←→ ns_cell_a/veth_cell_a_ns + wwan0
#     └── veth_cell_b ←→ ns_cell_b/veth_cell_b_ns + wwan1
###############################################################################
set -euo pipefail

LOG_FILE="/var/log/pathsteer/netns-init.log"
mkdir -p "$(dirname "$LOG_FILE")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# Configuration
declare -A UPLINKS=(
    # name -> "type:interface:veth_ip_main:veth_ip_ns"
    ["fiber1"]="dhcp:enp1s0:10.201.1.1:10.201.1.2"
    ["fiber2"]="dhcp:enp2s0:10.201.2.1:10.201.2.2"
    ["sl_a"]="dhcp:enp3s0:10.201.3.1:10.201.3.2"
    ["sl_b"]="dhcp:enp4s0:10.201.4.1:10.201.4.2"
    ["cell_a"]="cellular:wwan0:10.201.5.1:10.201.5.2"
    ["cell_b"]="cellular:wwan1:10.201.6.1:10.201.6.2"
)

# Protected interfaces - never touch these
PROTECTED_INTERFACES="enp6s0 lo"

is_protected() {
    local iface=$1
    for p in $PROTECTED_INTERFACES; do
        [[ "$iface" == "$p" ]] && return 0
    done
    return 1
}

# Create namespace with veth pair
create_namespace() {
    local name=$1
    local ns="ns_${name}"
    local veth_main="veth_${name}"
    local veth_ns="veth_${name}_ns"
    local ip_main=$2
    local ip_ns=$3

    log "Creating namespace $ns with veth pair..."

    # Create namespace
    ip netns add "$ns" 2>/dev/null || true
    ip netns exec "$ns" ip link set lo up

    # Delete existing veth if present
    ip link del "$veth_main" 2>/dev/null || true

    # Create veth pair
    ip link add "$veth_main" type veth peer name "$veth_ns"
    
    # Move one end to namespace
    ip link set "$veth_ns" netns "$ns"

    # Configure main side
    ip addr add "${ip_main}/30" dev "$veth_main" 2>/dev/null || true
    ip link set "$veth_main" up

    # Configure namespace side
    ip netns exec "$ns" ip addr add "${ip_ns}/30" dev "$veth_ns"
    ip netns exec "$ns" ip link set "$veth_ns" up

    # Route from main to namespace (for daemon to send packets)
    ip route add "${ip_ns}/32" dev "$veth_main" 2>/dev/null || true

    log "  $ns: veth pair $veth_main <-> $veth_ns ($ip_main <-> $ip_ns)"
}

# Move physical interface to namespace
move_interface_to_ns() {
    local iface=$1
    local ns=$2

    if is_protected "$iface"; then
        log "  SKIP: $iface is protected"
        return 1
    fi

    # Check if interface exists in main
    if ip link show "$iface" &>/dev/null; then
        log "  Moving $iface to $ns..."
        ip link set "$iface" netns "$ns"
        ip netns exec "$ns" ip link set "$iface" up
        return 0
    fi

    # Check if already in namespace
    if ip netns exec "$ns" ip link show "$iface" &>/dev/null 2>&1; then
        log "  $iface already in $ns"
        ip netns exec "$ns" ip link set "$iface" up
        return 0
    fi

    log "  WARNING: Interface $iface not found"
    return 1
}

# Configure DHCP interface inside namespace
configure_dhcp_interface() {
    local ns=$1
    local iface=$2
    local dish_route=${3:-}

    log "  Running DHCP on $iface in $ns..."
    
    # Kill any existing dhclient for this interface
    ip netns exec "$ns" pkill -f "dhclient.*$iface" 2>/dev/null || true
    
    # Run DHCP
    ip netns exec "$ns" dhclient -nw "$iface" 2>/dev/null &
    sleep 3

    # Get assigned IP and gateway
    local ip=$(ip netns exec "$ns" ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
    local gw=$(ip netns exec "$ns" ip route show dev "$iface" 2>/dev/null | grep default | awk '{print $3}' | head -1)

    if [[ -z "$gw" ]]; then
        # Try to find gateway from DHCP lease or common defaults
        for try_gw in $(echo "$ip" | sed 's/\.[0-9]*$/.1/') $(echo "$ip" | sed 's/\.[0-9]*$/.254/'); do
            if ip netns exec "$ns" ping -c 1 -W 1 "$try_gw" &>/dev/null; then
                gw="$try_gw"
                ip netns exec "$ns" ip route add default via "$gw" dev "$iface" 2>/dev/null || true
                break
            fi
        done
    fi

    log "  $iface: IP=$ip GW=$gw"

    # Add route to Starlink dish if specified
    if [[ -n "$dish_route" ]]; then
        ip netns exec "$ns" ip route add 192.168.100.1 via "$gw" dev "$iface" 2>/dev/null || true
        log "  Added route to dish 192.168.100.1 via $gw"
    fi
}

# Configure cellular interface inside namespace
configure_cellular_interface() {
    local ns=$1
    local iface=$2
    local modem_num=$3

    log "  Configuring cellular $iface in $ns (modem $modem_num)..."

    # Get bearer IP from ModemManager (run from main namespace)
    local bearer_path=$(mmcli -m "$modem_num" 2>/dev/null | grep -oP "Bearer.*paths: \K/[^\s]+" | head -1)
    if [[ -z "$bearer_path" ]]; then
        bearer_path=$(mmcli -m "$modem_num" --list-bearers 2>/dev/null | grep -oP '/org/freedesktop/ModemManager1/Bearer/\d+' | tail -1)
    fi

    if [[ -z "$bearer_path" ]]; then
        log "  WARNING: No bearer found for modem $modem_num"
        return 1
    fi

    local bearer_num=$(echo "$bearer_path" | grep -oP '\d+$')
    local bearer_info=$(mmcli -b "$bearer_num" 2>/dev/null)
    
    local ipv4=$(echo "$bearer_info" | grep -A5 "IPv4" | grep "address:" | grep -oP '[\d.]+' | head -1)
    local gw=$(echo "$bearer_info" | grep -A5 "IPv4" | grep "gateway:" | grep -oP '[\d.]+' | head -1)

    if [[ -z "$ipv4" || -z "$gw" ]]; then
        log "  WARNING: Could not get IP/GW from bearer"
        return 1
    fi

    # Configure inside namespace
    ip netns exec "$ns" ip addr flush dev "$iface" 2>/dev/null || true
    ip netns exec "$ns" ip addr add "${ipv4}/32" dev "$iface"
    ip netns exec "$ns" ip route add "$gw" dev "$iface"
    ip netns exec "$ns" ip route add default via "$gw" dev "$iface"

    log "  $iface: IP=$ipv4 GW=$gw"
}

# Find modem number by interface
get_modem_for_interface() {
    local iface=$1
    mmcli -L 2>/dev/null | while read -r line; do
        local modem_path=$(echo "$line" | grep -oP '/org/freedesktop/ModemManager1/Modem/\d+')
        if [[ -n "$modem_path" ]]; then
            local modem_num=$(echo "$modem_path" | grep -oP '\d+$')
            local modem_iface=$(mmcli -m "$modem_num" 2>/dev/null | grep -oP 'wwan\d+' | head -1)
            if [[ "$modem_iface" == "$iface" ]]; then
                echo "$modem_num"
                return 0
            fi
        fi
    done
}

# Setup WireGuard tunnel inside namespace
setup_wg_in_namespace() {
    local ns=$1
    local wg_conf=$2
    local wg_name=$(basename "$wg_conf" .conf)

    if [[ ! -f "$wg_conf" ]]; then
        log "  No WG config: $wg_conf"
        return 1
    fi

    log "  Setting up WireGuard $wg_name in $ns..."
    
    # Bring up WG inside namespace
    ip netns exec "$ns" wg-quick up "$wg_conf" 2>/dev/null || true
}

# Main setup
main() {
    log "=== PathSteer Namespace Initialization ==="
    
    for name in "${!UPLINKS[@]}"; do
        IFS=':' read -r type iface ip_main ip_ns <<< "${UPLINKS[$name]}"
        local ns="ns_${name}"

        log "Setting up $name ($type: $iface)..."

        # Create namespace with veth
        create_namespace "$name" "$ip_main" "$ip_ns"

        # Move physical interface to namespace
        if ! move_interface_to_ns "$iface" "$ns"; then
            continue
        fi

        # Configure based on type
        case "$type" in
            dhcp)
                # Check if this is Starlink (needs dish route)
                if [[ "$name" == sl_* ]]; then
                    configure_dhcp_interface "$ns" "$iface" "dish"
                else
                    configure_dhcp_interface "$ns" "$iface"
                fi
                ;;
            cellular)
                local modem_num=$(get_modem_for_interface "$iface")
                if [[ -n "$modem_num" ]]; then
                    configure_cellular_interface "$ns" "$iface" "$modem_num"
                else
                    log "  WARNING: No modem found for $iface"
                fi
                ;;
        esac

        log ""
    done

    log "=== Namespace Setup Complete ==="
    log ""
    log "Namespaces:"
    ip netns list
    log ""
    log "Test connectivity:"
    log "  ip netns exec ns_fiber1 ping -c 1 8.8.8.8"
    log "  ip netns exec ns_sl_a ping -c 1 192.168.100.1"
    log "  ip netns exec ns_cell_a ping -c 1 8.8.8.8"
}

# Cleanup
cleanup() {
    log "=== Cleaning up namespaces ==="
    
    for name in "${!UPLINKS[@]}"; do
        IFS=':' read -r type iface ip_main ip_ns <<< "${UPLINKS[$name]}"
        local ns="ns_${name}"
        local veth_main="veth_${name}"

        # Move interface back to main (if possible)
        ip netns exec "$ns" ip link set "$iface" netns 1 2>/dev/null || true
        
        # Delete namespace
        ip netns del "$ns" 2>/dev/null || true
        
        # Delete veth
        ip link del "$veth_main" 2>/dev/null || true

        log "Cleaned up $ns"
    done
}

# Status
status() {
    echo "=== PathSteer Namespace Status ==="
    echo ""
    
    for name in "${!UPLINKS[@]}"; do
        IFS=':' read -r type iface ip_main ip_ns <<< "${UPLINKS[$name]}"
        local ns="ns_${name}"

        echo "--- $name ($ns) ---"
        
        if ip netns list | grep -q "^${ns}"; then
            echo "  Namespace: EXISTS"
            
            # Check interface
            if ip netns exec "$ns" ip link show "$iface" &>/dev/null; then
                local ip=$(ip netns exec "$ns" ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1)
                echo "  Interface: $iface ($ip)"
            else
                echo "  Interface: NOT IN NS"
            fi
            
            # Check connectivity
            if ip netns exec "$ns" ping -c 1 -W 1 8.8.8.8 &>/dev/null; then
                echo "  Internet: OK"
            else
                echo "  Internet: FAIL"
            fi
            
            # Check dish for Starlink
            if [[ "$name" == sl_* ]]; then
                if ip netns exec "$ns" ping -c 1 -W 1 192.168.100.1 &>/dev/null; then
                    echo "  Dish: OK"
                else
                    echo "  Dish: FAIL"
                fi
            fi
        else
            echo "  Namespace: NOT FOUND"
        fi
        echo ""
    done
}

case "${1:-setup}" in
    setup|start)
        main
        ;;
    cleanup|stop)
        cleanup
        ;;
    status)
        status
        ;;
    restart)
        cleanup
        sleep 2
        main
        ;;
    *)
        echo "Usage: $0 {setup|cleanup|status|restart}"
        exit 1
        ;;
esac
