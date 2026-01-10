#!/bin/bash
###############################################################################
# PathSteer Guardian - Universal Installer
# 
# Reads configuration from JSON file and installs appropriate components
# Works for both Edge devices and Controllers
#
# Usage:
#   ./install.sh --config /path/to/config.json
#   ./install.sh --config config.edge.json --generate-keys
#   ./install.sh --config config.controller.json
#
# Copyright (c) 2025 PathSteer Networks
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/pathsteer"
CONFIG_DIR="/etc/pathsteer"
DATA_DIR="/var/lib/pathsteer"
RUN_DIR="/run/pathsteer"
WG_DIR="/etc/wireguard"
USER="pathsteer"
GROUP="pathsteer"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $*"; }
log_bold()  { echo -e "${BOLD}$*${NC}"; }

# Default values
CONFIG_FILE=""
GENERATE_KEYS=0
SKIP_DEPS=0

###############################################################################
# Parse command line arguments
###############################################################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config|-c)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --generate-keys)
                GENERATE_KEYS=1
                shift
                ;;
            --skip-deps)
                SKIP_DEPS=1
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

show_help() {
    cat << 'EOF'
PathSteer Guardian - Universal Installer

Usage:
  ./install.sh --config <config.json> [options]

Options:
  --config, -c <file>   Configuration JSON file (required)
  --generate-keys       Generate WireGuard keys and exit
  --skip-deps           Skip dependency installation
  --help, -h            Show this help

Examples:
  ./install.sh --config config/config.edge.json
  ./install.sh --config config/config.edge.json --generate-keys
  ./install.sh --config config/config.controller.json
EOF
}

###############################################################################
# JSON parsing helpers (using jq)
###############################################################################
json_get() {
    local file="$1"
    local path="$2"
    local default="${3:-}"
    local result
    result=$(jq -r "$path // empty" "$file" 2>/dev/null) || result=""
    if [[ -z "$result" || "$result" == "null" ]]; then
        echo "$default"
    else
        echo "$result"
    fi
}

###############################################################################
# Pre-flight checks
###############################################################################
preflight() {
    log_step "Running pre-flight checks..."
    
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
    
    if [[ -z "$CONFIG_FILE" ]]; then
        log_error "Configuration file required (--config)"
        show_help
        exit 1
    fi
    
    # Resolve config path
    if [[ ! -f "$CONFIG_FILE" ]]; then
        if [[ -f "${SCRIPT_DIR}/${CONFIG_FILE}" ]]; then
            CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE}"
        elif [[ -f "${SCRIPT_DIR}/config/${CONFIG_FILE}" ]]; then
            CONFIG_FILE="${SCRIPT_DIR}/config/${CONFIG_FILE}"
        else
            log_error "Config file not found: $CONFIG_FILE"
            exit 1
        fi
    fi
    
    # jq required
    if ! command -v jq &>/dev/null; then
        log_info "Installing jq..."
        apt-get update -qq && apt-get install -y -qq jq
    fi
    
    NODE_ROLE=$(json_get "$CONFIG_FILE" '.node.role')
    NODE_ID=$(json_get "$CONFIG_FILE" '.node.id')
    TOPO_MODE=$(json_get "$CONFIG_FILE" '.topology_mode' 'chaos')
    
    if [[ -z "$NODE_ROLE" ]]; then
        log_error "node.role not set in config"
        exit 1
    fi
    
    log_info "Configuration: $CONFIG_FILE"
    log_info "Node Role: $NODE_ROLE | ID: $NODE_ID | Topology: $TOPO_MODE"
}

###############################################################################
# Install dependencies
###############################################################################
install_deps() {
    [[ $SKIP_DEPS -eq 1 ]] && { log_info "Skipping deps"; return; }
    
    log_step "Installing dependencies (this may take a few minutes)..."
    export DEBIAN_FRONTEND=noninteractive
    
    log_info "Updating package lists..."
    apt-get update -q
    
    # Core packages
    log_info "Installing core packages..."
    apt-get install -y wireguard-tools nftables jq iproute2 tcpdump curl wget sqlite3 rsync expect || {
        log_error "Failed to install core packages"
        exit 1
    }
    
    # Build tools
    log_info "Installing build tools..."
    apt-get install -y build-essential pkg-config libsqlite3-dev libcurl4-openssl-dev libmnl-dev || {
        log_error "Failed to install build tools"
        exit 1
    }
    
    # Python
    log_info "Installing Python packages..."
    apt-get install -y python3 python3-pip python3-flask || {
        log_error "Failed to install Python packages"
        exit 1
    }
    
    # Edge-specific
    if [[ "$NODE_ROLE" == "edge" ]]; then
        log_info "Installing edge packages (modem, gps, wifi, dhcp)..."
        apt-get install -y modemmanager gpsd gpsd-clients hostapd dnsmasq bridge-utils iw || {
            log_error "Failed to install edge packages"
            exit 1
        }
    fi
    
    # Controller-specific
    if [[ "$NODE_ROLE" == "controller" ]]; then
        log_info "Installing controller packages..."
        apt-get install -y haproxy || true
    fi
    
    # Python pip packages
    log_info "Installing Python pip packages..."
    pip3 install --quiet flask requests 2>/dev/null || true
    
    log_info "All dependencies installed"
}

###############################################################################
# Setup directories
###############################################################################
setup_dirs() {
    log_step "Setting up directories..."
    id "$USER" &>/dev/null || useradd -r -s /bin/false -d "$INSTALL_DIR" "$USER"
    mkdir -p "$INSTALL_DIR"/{bin,config,scripts,web}
    mkdir -p "$CONFIG_DIR"/keys
    mkdir -p "$DATA_DIR"/{logs,pcap,runs}
    mkdir -p "$RUN_DIR"
    mkdir -p "$WG_DIR"
    chown -R "$USER:$GROUP" "$DATA_DIR" "$RUN_DIR"
    chmod 700 "$WG_DIR" "${CONFIG_DIR}/keys"
    log_info "Directories created"
}

###############################################################################
# Generate WireGuard keys
###############################################################################
generate_wg_keys() {
    log_step "Generating WireGuard keys..."
    local key_dir="${CONFIG_DIR}/keys"
    
    if [[ ! -f "${key_dir}/privatekey" ]]; then
        wg genkey > "${key_dir}/privatekey"
        chmod 600 "${key_dir}/privatekey"
        wg pubkey < "${key_dir}/privatekey" > "${key_dir}/publickey"
        log_info "Generated new keypair"
    fi
    
    local pubkey=$(cat "${key_dir}/publickey")
    echo ""
    echo "=============================================="
    echo -e "${CYAN}YOUR WIREGUARD PUBLIC KEY:${NC}"
    echo -e "${GREEN}${pubkey}${NC}"
    echo "=============================================="
    echo ""
    
    [[ $GENERATE_KEYS -eq 1 ]] && exit 0
}

###############################################################################
# Install files
###############################################################################
install_files() {
    log_step "Installing application files..."
    rsync -a "${SCRIPT_DIR}/" "${INSTALL_DIR}/" --exclude='.git' --exclude='__pycache__'
    find "${INSTALL_DIR}" -name "*.sh" -exec chmod +x {} \;
    chmod +x "${INSTALL_DIR}/web/app.py" 2>/dev/null || true
    cp "$CONFIG_FILE" "${CONFIG_DIR}/config.json"
    log_info "Files installed"
}

###############################################################################
# Build daemons
###############################################################################
build_daemons() {
    log_step "Building daemons..."
    
    if [[ "$NODE_ROLE" == "edge" && -d "${INSTALL_DIR}/src/pathsteerd" ]]; then
        cd "${INSTALL_DIR}/src/pathsteerd"
        make clean 2>/dev/null || true
        make && install -m 755 pathsteerd /usr/local/bin/
        log_info "Built pathsteerd"
    fi
    
    if [[ "$NODE_ROLE" == "controller" && -d "${INSTALL_DIR}/src/dedupe" ]]; then
        cd "${INSTALL_DIR}/src/dedupe"
        make clean 2>/dev/null || true
        make && install -m 755 dedupe /usr/local/bin/
        log_info "Built dedupe"
    fi
}

###############################################################################
# Configure systemd services
###############################################################################
configure_systemd() {
    log_step "Configuring systemd..."
    
    if [[ "$NODE_ROLE" == "edge" ]]; then
        cat > /etc/systemd/system/pathsteer-netns.service << EOF
[Unit]
Description=PathSteer Network Namespace Init
Before=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_DIR}/scripts/netns-init.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

        cat > /etc/systemd/system/pathsteerd.service << EOF
[Unit]
Description=PathSteer Guardian Daemon
After=pathsteer-netns.service
Requires=pathsteer-netns.service

[Service]
Type=simple
ExecStart=/usr/local/bin/pathsteerd --config /etc/pathsteer/config.json
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    fi
    
    cat > /etc/systemd/system/pathsteer-web.service << EOF
[Unit]
Description=PathSteer Web UI
After=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=${INSTALL_DIR}/web
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/web/app.py
Restart=always
Environment=CONFIG_FILE=/etc/pathsteer/config.json

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log_info "Systemd configured"
}

###############################################################################
# Configure sysctls
###############################################################################
configure_sysctls() {
    log_step "Configuring kernel parameters..."
    cat > /etc/sysctl.d/99-pathsteer.conf << 'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF
    sysctl -p /etc/sysctl.d/99-pathsteer.conf >/dev/null
    log_info "Kernel parameters set"
}

###############################################################################
# Initialize database
###############################################################################
init_database() {
    log_step "Initializing database..."
    sqlite3 "${DATA_DIR}/training.db" << 'SQL'
CREATE TABLE IF NOT EXISTS measurements (
    id INTEGER PRIMARY KEY, timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    run_id TEXT, latitude REAL, longitude REAL, speed_mps REAL, heading REAL,
    uplink TEXT, rsrp REAL, rsrq REAL, sinr REAL, carrier TEXT, cell_id TEXT,
    rtt_ms REAL, loss_pct REAL, risk_now REAL, risk_ahead REAL, state TEXT
);
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY, timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    run_id TEXT, event_type TEXT, trigger TEXT, description TEXT,
    latitude REAL, longitude REAL
);
CREATE TABLE IF NOT EXISTS risk_zones (
    id INTEGER PRIMARY KEY, geohash TEXT UNIQUE, latitude REAL, longitude REAL,
    heading_min REAL, heading_max REAL, uplink TEXT, risk_score REAL,
    sample_count INTEGER, last_updated DATETIME
);
CREATE INDEX IF NOT EXISTS idx_meas_ts ON measurements(timestamp);
CREATE INDEX IF NOT EXISTS idx_meas_geo ON measurements(latitude, longitude);
CREATE INDEX IF NOT EXISTS idx_zones_geo ON risk_zones(geohash);
SQL
    chown "$USER:$GROUP" "${DATA_DIR}/training.db"
    log_info "Database initialized"
}

###############################################################################
# Enable services
###############################################################################
enable_services() {
    log_step "Enabling services..."
    [[ "$NODE_ROLE" == "edge" ]] && systemctl enable pathsteer-netns pathsteerd
    systemctl enable pathsteer-web
    log_info "Services enabled"
}

###############################################################################
# Setup LAN bridge (Edge only)
###############################################################################
setup_bridge() {
    [[ "$NODE_ROLE" != "edge" ]] && return
    
    log_step "Setting up LAN bridge..."
    
    local bridge ipv4_gw prefix_len
    bridge=$(json_get "$CONFIG_FILE" '.lan.bridge' 'br-lan')
    ipv4_gw=$(json_get "$CONFIG_FILE" '.lan.ipv4_gateway' '104.204.136.49')
    prefix_len=$(json_get "$CONFIG_FILE" '.lan.ipv4_block' '104.204.136.48/28' | cut -d/ -f2)
    
    # Create bridge if not exists
    if ! ip link show "$bridge" &>/dev/null; then
        ip link add name "$bridge" type bridge
        log_info "Created bridge $bridge"
    fi
    
    ip link set "$bridge" up
    
    # Add gateway IP
    if ! ip addr show "$bridge" | grep -q "$ipv4_gw"; then
        ip addr add "${ipv4_gw}/${prefix_len}" dev "$bridge" 2>/dev/null || true
        log_info "Added ${ipv4_gw}/${prefix_len} to $bridge"
    fi
    
    # Create persistent netplan/networkd config
    mkdir -p /etc/systemd/network
    cat > /etc/systemd/network/10-br-lan.netdev << EOF
[NetDev]
Name=$bridge
Kind=bridge
EOF
    
    cat > /etc/systemd/network/11-br-lan.network << EOF
[Match]
Name=$bridge

[Network]
Address=${ipv4_gw}/${prefix_len}
IPForward=yes
ConfigureWithoutCarrier=yes
EOF
    
    log_info "Bridge $bridge configured"
}

###############################################################################
# Setup WiFi AP (Edge only)
###############################################################################
setup_wifi() {
    [[ "$NODE_ROLE" != "edge" ]] && return
    
    local wifi_enabled
    wifi_enabled=$(json_get "$CONFIG_FILE" '.wifi.enabled' 'false')
    [[ "$wifi_enabled" != "true" ]] && { log_info "WiFi AP disabled in config"; return; }
    
    log_step "Setting up WiFi AP..."
    
    local wifi_if ssid password channel bridge
    wifi_if=$(json_get "$CONFIG_FILE" '.wifi.interface' 'wlp7s0')
    ssid=$(json_get "$CONFIG_FILE" '.wifi.ssid' 'guardiandemo')
    password=$(json_get "$CONFIG_FILE" '.wifi.password' '9723528362')
    channel=$(json_get "$CONFIG_FILE" '.wifi.channel' '6')
    bridge=$(json_get "$CONFIG_FILE" '.lan.bridge' 'br-lan')
    
    # Check interface exists
    if ! ip link show "$wifi_if" &>/dev/null; then
        log_warn "WiFi interface $wifi_if not found, skipping AP setup"
        return
    fi
    
    # Create hostapd config
    mkdir -p /etc/hostapd
    cat > /etc/hostapd/hostapd.conf << EOF
# PathSteer Guardian WiFi AP
interface=$wifi_if
bridge=$bridge
ssid=$ssid
wpa=2
wpa_passphrase=$password
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
driver=nl80211
hw_mode=g
channel=$channel
ieee80211n=1
wmm_enabled=1
country_code=US
ap_isolate=0
EOF
    chmod 600 /etc/hostapd/hostapd.conf
    
    # Configure hostapd daemon
    if [[ -f /etc/default/hostapd ]]; then
        sed -i 's|^#*DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
    fi
    
    # Unmask and enable
    systemctl unmask hostapd 2>/dev/null || true
    systemctl enable hostapd
    
    log_info "WiFi AP configured: SSID=$ssid on $wifi_if"
}

###############################################################################
# Setup DHCP/DNS (Edge only)
###############################################################################
setup_dnsmasq() {
    [[ "$NODE_ROLE" != "edge" ]] && return
    
    log_step "Setting up DHCP/DNS..."
    
    local bridge ipv4_gw dhcp_start dhcp_end
    bridge=$(json_get "$CONFIG_FILE" '.lan.bridge' 'br-lan')
    ipv4_gw=$(json_get "$CONFIG_FILE" '.lan.ipv4_gateway' '104.204.136.49')
    dhcp_start=$(json_get "$CONFIG_FILE" '.lan.dhcp_range_start' '104.204.136.50')
    dhcp_end=$(json_get "$CONFIG_FILE" '.lan.dhcp_range_end' '104.204.136.62')
    
    # Copy dnsmasq config
    if [[ -f "${SCRIPT_DIR}/config/dnsmasq.conf" ]]; then
        cp "${SCRIPT_DIR}/config/dnsmasq.conf" /etc/dnsmasq.d/pathsteer.conf
    else
        cat > /etc/dnsmasq.d/pathsteer.conf << EOF
interface=$bridge
bind-interfaces
no-resolv
server=8.8.8.8
server=8.8.4.4
dhcp-range=${dhcp_start},${dhcp_end},255.255.255.240,12h
dhcp-option=option:router,${ipv4_gw}
dhcp-option=option:dns-server,${ipv4_gw}
domain=pathsteer.local
dhcp-leasefile=/var/lib/pathsteer/dhcp.leases
log-dhcp
EOF
    fi
    
    # Disable systemd-resolved if it conflicts
    if systemctl is-active --quiet systemd-resolved; then
        log_info "Disabling systemd-resolved (conflicts with dnsmasq)"
        systemctl stop systemd-resolved
        systemctl disable systemd-resolved
        rm -f /etc/resolv.conf
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
    fi
    
    systemctl enable dnsmasq
    log_info "DHCP/DNS configured"
}

###############################################################################
# Setup GPS (Edge only)
###############################################################################
setup_gps() {
    [[ "$NODE_ROLE" != "edge" ]] && return
    
    log_step "Setting up GPS..."
    
    # Find GPS device (usually /dev/ttyUSB* or /dev/ttyACM*)
    local gps_dev=""
    for dev in /dev/ttyUSB0 /dev/ttyACM0 /dev/gps0; do
        [[ -e "$dev" ]] && { gps_dev="$dev"; break; }
    done
    
    if [[ -z "$gps_dev" ]]; then
        log_warn "No GPS device found, skipping GPS setup"
        return
    fi
    
    # Configure gpsd
    cat > /etc/default/gpsd << EOF
START_DAEMON="true"
GPSD_OPTIONS="-n"
DEVICES="$gps_dev"
USBAUTO="true"
EOF
    
    systemctl enable gpsd
    log_info "GPS configured: $gps_dev"
}

###############################################################################
# Print summary
###############################################################################
print_summary() {
    local pubkey=$(cat "${CONFIG_DIR}/keys/publickey" 2>/dev/null || echo "N/A")
    echo ""
    log_bold "=============================================="
    log_bold " PathSteer Guardian - Installation Complete"
    log_bold "=============================================="
    echo ""
    echo "Role: $NODE_ROLE | ID: $NODE_ID"
    echo "Public Key: $pubkey"
    echo ""
    
    if [[ "$NODE_ROLE" == "edge" ]]; then
        log_bold "NEXT STEPS:"
        echo ""
        echo "1. Find your modem IMEIs:"
        echo "   ${INSTALL_DIR}/scripts/modem-init.sh list"
        echo ""
        echo "2. Edit config with IMEIs and controller pubkeys:"
        echo "   nano ${CONFIG_DIR}/config.json"
        echo ""
        echo "3. Initialize modems:"
        echo "   ${INSTALL_DIR}/scripts/modem-init.sh init"
        echo ""
        echo "4. Start services:"
        echo "   systemctl start pathsteer-netns"
        echo "   systemctl start pathsteerd"
        echo "   systemctl start pathsteer-web"
        echo "   systemctl start hostapd"
        echo "   systemctl start dnsmasq"
        echo ""
        echo "5. Open dashboard:"
        echo "   http://localhost:8080"
        echo ""
        local ssid=$(json_get "$CONFIG_FILE" '.wifi.ssid' 'guardiandemo')
        echo "WiFi AP: $ssid"
    else
        log_bold "NEXT STEPS:"
        echo ""
        echo "1. Edit config with edge pubkey:"
        echo "   nano ${CONFIG_DIR}/config.json"
        echo ""
        echo "2. Start WireGuard:"
        echo "   wg-quick up wg0"
        echo ""
        echo "3. Start services:"
        echo "   systemctl start pathsteer-web"
    fi
    echo ""
    log_bold "=============================================="
}

###############################################################################
# Main
###############################################################################
main() {
    parse_args "$@"
    preflight
    setup_dirs
    generate_wg_keys
    install_deps
    install_files
    configure_systemd
    configure_sysctls
    init_database
    setup_bridge
    setup_wifi
    setup_dnsmasq
    setup_gps
    build_daemons
    enable_services
    print_summary
}

main "$@"
