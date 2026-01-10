#!/bin/bash
###############################################################################
# PathSteer Guardian - WireGuard Tunnel Setup
#
# Creates 8 WireGuard tunnels:
#   - 4 uplinks (cell_a, cell_b, sl_a, sl_b) × 2 controllers (ctrl_a, ctrl_b)
#
# Each tunnel is configured to run INSIDE its uplink's network namespace
# This is critical: WG must egress via the correct physical interface
#
# Usage:
#   ./wg-setup.sh                    # Create all configs
#   ./wg-setup.sh --start            # Create and bring up
#   ./wg-setup.sh --status           # Show tunnel status
###############################################################################
set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/pathsteer/config.json}"
WG_DIR="/etc/wireguard"
KEYS_DIR="/etc/pathsteer/keys"

log() { echo "[wg-setup] $*"; }
err() { echo "[wg-setup] ERROR: $*" >&2; }

# Read config values
json_get() {
    jq -r "$1 // empty" "$CONFIG_FILE" 2>/dev/null || echo "${2:-}"
}

# Get our private key
get_private_key() {
    if [[ -f "${KEYS_DIR}/privatekey" ]]; then
        cat "${KEYS_DIR}/privatekey"
    else
        err "Private key not found. Run install.sh first."
        exit 1
    fi
}

# Tunnel IP addressing scheme:
# 10.200.{uplink}.{controller}/32
# uplink: cell_a=1, cell_b=2, sl_a=3, sl_b=4
# controller: ctrl_a=1, ctrl_b=2
get_tunnel_ip() {
    local uplink="$1"
    local controller="$2"
    
    local uplink_num
    case "$uplink" in
        cell_a) uplink_num=1 ;;
        cell_b) uplink_num=2 ;;
        sl_a)   uplink_num=3 ;;
        sl_b)   uplink_num=4 ;;
        fiber1) uplink_num=5 ;;
        fiber2) uplink_num=6 ;;
        *)      uplink_num=9 ;;
    esac
    
    local ctrl_num
    case "$controller" in
        ctrl_a) ctrl_num=1 ;;
        ctrl_b) ctrl_num=2 ;;
        *)      ctrl_num=9 ;;
    esac
    
    echo "10.200.${uplink_num}.${ctrl_num}"
}

# Create WireGuard config for one tunnel
create_tunnel_config() {
    local uplink="$1"
    local controller="$2"
    local privkey="$3"
    
    local uplink_enabled ctrl_enabled endpoint pubkey netns
    uplink_enabled=$(json_get ".uplinks.${uplink}.enabled" "false")
    ctrl_enabled=$(json_get ".controllers.${controller}.enabled" "false")
    
    [[ "$uplink_enabled" != "true" || "$ctrl_enabled" != "true" ]] && return 0
    
    endpoint=$(json_get ".controllers.${controller}.wg_endpoint")
    pubkey=$(json_get ".controllers.${controller}.wg_pubkey")
    netns=$(json_get ".uplinks.${uplink}.netns" "ns_${uplink}")
    
    if [[ -z "$endpoint" || -z "$pubkey" || "$pubkey" == "REPLACE"* ]]; then
        log "Skipping ${uplink}-${controller}: endpoint or pubkey not configured"
        return 0
    fi
    
    local tunnel_name="wg-${uplink}-${controller}"
    local tunnel_ip=$(get_tunnel_ip "$uplink" "$controller")
    local listen_port=$((51820 + $(get_tunnel_ip "$uplink" "$controller" | cut -d. -f3) * 10 + $(get_tunnel_ip "$uplink" "$controller" | cut -d. -f4)))
    
    log "Creating tunnel: $tunnel_name ($tunnel_ip) -> $endpoint in $netns"
    
    cat > "${WG_DIR}/${tunnel_name}.conf" << EOF
# PathSteer Guardian WireGuard Tunnel
# Uplink: $uplink | Controller: $controller
# Namespace: $netns
# 
# To bring up manually:
#   ip netns exec $netns wg-quick up ${tunnel_name}

[Interface]
PrivateKey = $privkey
Address = ${tunnel_ip}/32
ListenPort = $listen_port
MTU = 1380
Table = off

# Post-up: Add route to controller's client network
PostUp = ip route add 104.204.136.0/22 dev %i || true

[Peer]
# Controller: $controller
PublicKey = $pubkey
Endpoint = $endpoint
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 15
EOF
    
    chmod 600 "${WG_DIR}/${tunnel_name}.conf"
    
    # Create systemd service for this tunnel in its namespace
    cat > "/etc/systemd/system/wg-${tunnel_name}.service" << EOF
[Unit]
Description=WireGuard Tunnel ${tunnel_name} in ${netns}
After=pathsteer-netns.service
Requires=pathsteer-netns.service
PartOf=pathsteer-tunnels.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/ip netns exec ${netns} /usr/bin/wg-quick up ${tunnel_name}
ExecStop=/usr/bin/ip netns exec ${netns} /usr/bin/wg-quick down ${tunnel_name}

[Install]
WantedBy=pathsteer-tunnels.target
EOF
    
    return 0
}

# Create all tunnel configs
create_all_tunnels() {
    log "Creating WireGuard tunnel configurations..."
    
    local privkey
    privkey=$(get_private_key)
    
    local created=0
    
    for uplink in cell_a cell_b sl_a sl_b fiber1 fiber2; do
        for controller in ctrl_a ctrl_b; do
            if create_tunnel_config "$uplink" "$controller" "$privkey"; then
                ((created++)) || true
            fi
        done
    done
    
    # Create target for all tunnels
    cat > "/etc/systemd/system/pathsteer-tunnels.target" << EOF
[Unit]
Description=PathSteer WireGuard Tunnels
After=pathsteer-netns.service
Requires=pathsteer-netns.service

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    
    log "Created tunnel configurations"
    ls -la ${WG_DIR}/wg-*.conf 2>/dev/null || log "No tunnel configs created (check controller pubkeys)"
}

# Bring up all tunnels
start_tunnels() {
    log "Starting WireGuard tunnels..."
    
    for conf in ${WG_DIR}/wg-*.conf; do
        [[ -f "$conf" ]] || continue
        
        local name=$(basename "$conf" .conf)
        local netns=$(grep "^# Namespace:" "$conf" | cut -d: -f2 | tr -d ' ')
        
        if [[ -n "$netns" ]] && ip netns list | grep -q "^${netns}"; then
            log "Starting $name in $netns..."
            ip netns exec "$netns" wg-quick up "$name" 2>/dev/null || {
                log "Warning: Failed to start $name"
            }
        else
            log "Skipping $name: namespace $netns not found"
        fi
    done
}

# Show status of all tunnels
show_status() {
    echo "=== WireGuard Tunnel Status ==="
    echo ""
    
    for conf in ${WG_DIR}/wg-*.conf; do
        [[ -f "$conf" ]] || continue
        
        local name=$(basename "$conf" .conf)
        local netns=$(grep "^# Namespace:" "$conf" | cut -d: -f2 | tr -d ' ')
        
        echo "--- $name ($netns) ---"
        if [[ -n "$netns" ]] && ip netns list | grep -q "^${netns}"; then
            ip netns exec "$netns" wg show "$name" 2>/dev/null || echo "  Not running"
        else
            echo "  Namespace not found"
        fi
        echo ""
    done
}

# Main
case "${1:-create}" in
    create)
        create_all_tunnels
        ;;
    --start|start)
        create_all_tunnels
        start_tunnels
        ;;
    --status|status)
        show_status
        ;;
    *)
        echo "Usage: $0 {create|--start|--status}"
        exit 1
        ;;
esac
