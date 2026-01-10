#!/bin/bash
###############################################################################
# PathSteer Guardian - Namespace Initialization v2
#
# Reads config and sets up isolated namespaces for each enabled uplink.
# Handles DHCP (fiber/starlink) and bearer (cellular) automatically.
###############################################################################
set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/pathsteer/config.json}"
LOG_FILE="/var/log/pathsteer/netns-init.log"
STATE_DIR="/run/pathsteer"

mkdir -p "$(dirname "$LOG_FILE")" "$STATE_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
err() { log "ERROR: $*"; }

# Check dependencies
for cmd in jq ip dhclient mmcli; do
    if ! command -v "$cmd" &>/dev/null; then
        log "Installing $cmd..."
        apt-get update && apt-get install -y "$cmd" 2>/dev/null || true
    fi
done

# Config helpers
get_json() {
    jq -r "$1 // empty" "$CONFIG_FILE" 2>/dev/null
}

# Get management interface (protected)
MGMT_IFACE=$(get_json '.management.interface')
MGMT_FALLBACK=$(get_json '.management.fallback')
log "Management interface: $MGMT_IFACE (fallback: $MGMT_FALLBACK)"

is_protected() {
    local iface=$1
    [[ "$iface" == "$MGMT_IFACE" || "$iface" == "$MGMT_FALLBACK" || "$iface" == "lo" ]]
}

# Check if interface exists (in any namespace)
iface_exists() {
    local iface=$1
    ip link show "$iface" &>/dev/null 2>&1 && return 0
    for ns in $(ip netns list 2>/dev/null | awk '{print $1}'); do
        ip netns exec "$ns" ip link show "$iface" &>/dev/null 2>&1 && return 0
    done
    return 1
}

# Get interface's current namespace
iface_namespace() {
    local iface=$1
    if ip link show "$iface" &>/dev/null 2>&1; then
        echo "main"
        return 0
    fi
    for ns in $(ip netns list 2>/dev/null | awk '{print $1}'); do
        if ip netns exec "$ns" ip link show "$iface" &>/dev/null 2>&1; then
            echo "$ns"
            return 0
        fi
    done
    echo "none"
}

# Create namespace with veth pair
create_namespace() {
    local name=$1
    local ip_main=$2
    local ip_ns=$3
    local ns="ns_${name}"
    local veth_main="veth_${name}"
    local veth_ns="veth_${name: 0:8}_i"

    log "  Creating namespace $ns..."

    # Create namespace
    ip netns add "$ns" 2>/dev/null || true
    ip netns exec "$ns" ip link set lo up

    # Clean existing veth
    ip link del "$veth_main" 2>/dev/null || true

    # Create veth pair
    ip link add "$veth_main" type veth peer name "$veth_ns"
    ip link set "$veth_ns" netns "$ns"

    # Configure IPs
    ip addr add "${ip_main}/30" dev "$veth_main" 2>/dev/null || true
    ip link set "$veth_main" up

    ip netns exec "$ns" ip addr add "${ip_ns}/30" dev "$veth_ns"
    ip netns exec "$ns" ip link set "$veth_ns" up

    log "    veth: $veth_main ($ip_main) <-> $veth_ns ($ip_ns)"
}

# Move interface to namespace
move_to_namespace() {
    local iface=$1
    local ns=$2

    local current=$(iface_namespace "$iface")
    
    if [[ "$current" == "none" ]]; then
        err "Interface $iface not found anywhere"
        return 1
    fi

    if [[ "$current" == "$ns" ]]; then
        log "    $iface already in $ns"
        ip netns exec "$ns" ip link set "$iface" up
        return 0
    fi

    if [[ "$current" == "main" ]]; then
        log "    Moving $iface to $ns"
        ip link set "$iface" netns "$ns"
    else
        log "    Moving $iface from $current to $ns"
        ip netns exec "$current" ip link set "$iface" netns 1
        ip link set "$iface" netns "$ns"
    fi

    ip netns exec "$ns" ip link set "$iface" up
    return 0
}

# Configure DHCP in namespace
configure_dhcp() {
    local ns=$1
    local iface=$2

    log "    DHCP on $iface..."
    
    # Kill existing
    ip netns exec "$ns" pkill -f "dhclient.*$iface" 2>/dev/null || true
    sleep 1

    # Start DHCP
    ip netns exec "$ns" dhclient -v "$iface" 2>&1 | head -5 &
    sleep 4

    # Get results
    local ip=$(ip netns exec "$ns" ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
    local gw=$(ip netns exec "$ns" ip route 2>/dev/null | grep "default.*$iface" | awk '{print $3}' | head -1)

    # Try common gateways if not found
    if [[ -z "$gw" && -n "$ip" ]]; then
        for try in $(echo "$ip" | sed 's/\.[0-9]*$/.1/') $(echo "$ip" | sed 's/\.[0-9]*$/.254/'); do
            if ip netns exec "$ns" ping -c 1 -W 1 "$try" &>/dev/null; then
                gw="$try"
                ip netns exec "$ns" ip route add default via "$gw" dev "$iface" 2>/dev/null || true
                break
            fi
        done
    fi

    log "    Result: IP=${ip:-NONE} GW=${gw:-NONE}"

    # Starlink dish route
    if [[ -n "$gw" ]]; then
        ip netns exec "$ns" ip route add 192.168.100.1 via "$gw" dev "$iface" 2>/dev/null || true
    fi

    # Save state
    echo "{\"ip\":\"$ip\",\"gw\":\"$gw\",\"iface\":\"$iface\"}" > "$STATE_DIR/${ns}.json"
}

# Configure cellular in namespace
configure_cellular() {
    local ns=$1
    local iface=$2
    local imei=$3

    log "    Cellular $iface (IMEI: $imei)..."

    # Find modem by IMEI
    local modem_num=""
    while read -r line; do
        local m=$(echo "$line" | grep -oP 'Modem/\K\d+')
        [[ -z "$m" ]] && continue
        local m_imei=$(mmcli -m "$m" 2>/dev/null | grep "imei:" | grep -oP '[\d]+' | head -1)
        if [[ "$m_imei" == "$imei" ]]; then
            modem_num=$m
            break
        fi
    done < <(mmcli -L 2>/dev/null)

    if [[ -z "$modem_num" ]]; then
        err "Modem with IMEI $imei not found"
        return 1
    fi

    log "    Found modem $modem_num"

    # Get bearer
    local bearer=$(mmcli -m "$modem_num" --list-bearers 2>/dev/null | grep -oP 'Bearer/\K\d+' | tail -1)
    if [[ -z "$bearer" ]]; then
        err "No bearer for modem $modem_num"
        return 1
    fi

    # Get IP info from bearer
    local bearer_info=$(mmcli -b "$bearer" 2>/dev/null)
    local ipv4=$(echo "$bearer_info" | grep -A10 "IPv4" | grep "address:" | grep -oP '[\d.]+' | head -1)
    local gw=$(echo "$bearer_info" | grep -A10 "IPv4" | grep "gateway:" | grep -oP '[\d.]+' | head -1)

    if [[ -z "$ipv4" || -z "$gw" ]]; then
        err "Could not get IP/GW from bearer $bearer"
        return 1
    fi

    # Configure in namespace
    ip netns exec "$ns" ip addr flush dev "$iface" 2>/dev/null || true
    ip netns exec "$ns" ip addr add "${ipv4}/32" dev "$iface"
    ip netns exec "$ns" ip route add "$gw" dev "$iface"
    ip netns exec "$ns" ip route add default via "$gw" dev "$iface"

    log "    Result: IP=$ipv4 GW=$gw"

    # Save state
    echo "{\"ip\":\"$ipv4\",\"gw\":\"$gw\",\"iface\":\"$iface\",\"modem\":$modem_num}" > "$STATE_DIR/${ns}.json"
}

# Setup one uplink
setup_uplink() {
    local name=$1
    local uplink_json=$(get_json ".uplinks[\"$name\"]")
    
    local enabled=$(echo "$uplink_json" | jq -r '.enabled')
    [[ "$enabled" != "true" ]] && return 0

    local iface=$(echo "$uplink_json" | jq -r '.interface')
    local type=$(echo "$uplink_json" | jq -r '.type')
    local ip_mode=$(echo "$uplink_json" | jq -r '.ip_mode')
    local veth_main=$(echo "$uplink_json" | jq -r '.veth_main')
    local veth_ns=$(echo "$uplink_json" | jq -r '.veth_ns')
    local desc=$(echo "$uplink_json" | jq -r '.description')
    local ns="ns_${name}"

    log ""
    log "=== $name: $desc ==="

log "  Interface: $iface, Type: $type, IP mode: $ip_mode"

    # Skip cellular - uses policy routing, not namespaces
    if [[ "$ip_mode" == "bearer" ]]; then
        log "  SKIP: Cellular uses policy routing (managed by modem-normalize.sh)"
        return 0
    fi

    # Check protected

    # Check protected
    if is_protected "$iface"; then
        log "  SKIP: $iface is management interface"
        return 0
    fi

    # Check exists
    if ! iface_exists "$iface"; then
        err "$iface does not exist"
        return 1
    fi

    # Create namespace
    create_namespace "$name" "$veth_main" "$veth_ns"

    # Move interface
    if ! move_to_namespace "$iface" "$ns"; then
        return 1
    fi

    # Configure IP
    case "$ip_mode" in
        dhcp)
            configure_dhcp "$ns" "$iface"
            ;;
        bearer)
            local imei=$(echo "$uplink_json" | jq -r '.imei')
            configure_cellular "$ns" "$iface" "$imei"
            ;;
        *)
            err "Unknown ip_mode: $ip_mode"
            ;;
    esac
}

# Main setup
cmd_setup() {
    log "============================================"
    log "PathSteer Namespace Setup"
    log "Config: $CONFIG_FILE"
    log "============================================"

    # Get uplink names
    local uplinks=$(get_json '.uplinks | keys[]')
    
    for name in $uplinks; do
        setup_uplink "$name" || true
    done

    log ""
    log "============================================"
    log "Setup complete"
    log "============================================"
}

# Cleanup
cmd_cleanup() {
    log "Cleaning up namespaces..."

    local uplinks=$(get_json '.uplinks | keys[]' 2>/dev/null || echo "link1 link2 cell_a cell_b")
    
    for name in $uplinks; do
        local iface=$(get_json ".uplinks[\"$name\"].interface")
        local ns="ns_${name}"
        local veth="veth_${name}"

        # Move interface back
        ip netns exec "$ns" ip link set "$iface" netns 1 2>/dev/null || true
        
        # Delete namespace
        ip netns del "$ns" 2>/dev/null || true
        
        # Delete veth
        ip link del "$veth" 2>/dev/null || true

        log "  Cleaned $ns"
    done

    rm -f "$STATE_DIR"/ns_*.json
}

# Status
cmd_status() {
    echo "============================================"
    echo "PathSteer Namespace Status"
    echo "============================================"
    echo ""
    echo "Management: $MGMT_IFACE"
    echo ""

    local uplinks=$(get_json '.uplinks | keys[]')
    
    for name in $uplinks; do
        local enabled=$(get_json ".uplinks[\"$name\"].enabled")
        local iface=$(get_json ".uplinks[\"$name\"].interface")
        local desc=$(get_json ".uplinks[\"$name\"].description")
        local ns="ns_${name}"

        echo "--- $name ($desc) ---"
        echo "  Enabled: $enabled"
        echo "  Interface: $iface"

        if [[ "$enabled" != "true" ]]; then
            echo "  Status: DISABLED"
            echo ""
            continue
        fi

        if ip netns list 2>/dev/null | grep -q "^${ns}"; then
            echo "  Namespace: OK"

            local current_ns=$(iface_namespace "$iface")
            if [[ "$current_ns" == "$ns" ]]; then
                local ip=$(ip netns exec "$ns" ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1)
                echo "  Interface: IN NS ($ip)"

                if ip netns exec "$ns" ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
                    echo "  Internet: OK"
                else
                    echo "  Internet: FAIL"
                fi

                # Starlink dish check
                if ip netns exec "$ns" ping -c 1 -W 2 192.168.100.1 &>/dev/null; then
                    echo "  Dish: OK (Starlink detected)"
                fi
            else
                echo "  Interface: NOT IN NS (in $current_ns)"
            fi
        else
            echo "  Namespace: NOT FOUND"
        fi
        echo ""
    done
}

# Main
case "${1:-status}" in
    setup|start)   cmd_setup ;;
    cleanup|stop)  cmd_cleanup ;;
    status)        cmd_status ;;
    restart)       cmd_cleanup; sleep 2; cmd_setup ;;
    *)
        echo "Usage: $0 {setup|cleanup|status|restart}"
        exit 1
        ;;
esac
