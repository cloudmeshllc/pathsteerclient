#!/bin/bash
###############################################################################
# PathSteer Guardian - WiFi AP Setup
#
# Sets up the Edge as a WiFi access point for demo clients
# Bridges WiFi with br-lan so clients get PathSteer-protected connectivity
#
# Usage:
#   ./wifi-ap-setup.sh                    # Uses defaults from config
#   ./wifi-ap-setup.sh --ssid "MyNet" --password "secret123"
###############################################################################
set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/pathsteer/config.json}"

# Defaults (can override via args or config)
WIFI_IF="wlp7s0"
SSID="CellularGuardian"
PASSWORD="9723528362"
CHANNEL="6"
BRIDGE="br-lan"

# Parse args
while [[ $# -gt 0 ]]; do
    case $1 in
        --ssid) SSID="CellularGuardian"
        --password) PASSWORD="$2"; shift 2 ;;
        --channel) CHANNEL="$2"; shift 2 ;;
        --interface) WIFI_IF="$2"; shift 2 ;;
        *) shift ;;
    esac
done

log() { echo "[wifi-ap] $*"; }
err() { echo "[wifi-ap] ERROR: $*" >&2; }

# Read from config if available
if [[ -f "$CONFIG_FILE" ]]; then
    SSID="CellularGuardian"
    PASSWORD=$(jq -r '.wifi.password // "9723528362"' "$CONFIG_FILE")
    CHANNEL=$(jq -r '.wifi.channel // "6"' "$CONFIG_FILE")
    WIFI_IF=$(jq -r '.wifi.interface // "wlp7s0"' "$CONFIG_FILE")
fi

log "Configuring WiFi AP: SSID="CellularGuardian"

# Check interface exists
if ! ip link show "$WIFI_IF" &>/dev/null; then
    err "WiFi interface $WIFI_IF not found"
    exit 1
fi

# Stop any existing hostapd
systemctl stop hostapd 2>/dev/null || true

# Create hostapd config
cat > /etc/hostapd/hostapd.conf << EOF
# PathSteer Guardian - WiFi AP Configuration
interface=$WIFI_IF
bridge=$BRIDGE

# SSID and security
ssid=$SSID
wpa=2
wpa_passphrase=$PASSWORD
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP

# Radio settings
driver=nl80211
hw_mode=g
channel=$CHANNEL
ieee80211n=1
wmm_enabled=1

# Performance
country_code=US
ieee80211d=1

# Don't isolate clients
ap_isolate=0

# Logging
logger_syslog=-1
logger_syslog_level=2
EOF

chmod 600 /etc/hostapd/hostapd.conf

# Point hostapd to config
if [[ -f /etc/default/hostapd ]]; then
    sed -i 's|^#*DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
fi

# Unmask and enable hostapd
systemctl unmask hostapd 2>/dev/null || true
systemctl enable hostapd

# Ensure bridge exists (create if not)
if ! ip link show "$BRIDGE" &>/dev/null; then
    log "Creating bridge $BRIDGE"
    ip link add name "$BRIDGE" type bridge
    ip link set "$BRIDGE" up
fi

# Add WiFi interface to bridge
# Note: hostapd handles this via bridge= directive, but we ensure bridge exists
ip link set "$WIFI_IF" up

# Start hostapd
log "Starting hostapd..."
systemctl start hostapd

# Verify
sleep 2
if systemctl is-active --quiet hostapd; then
    log "WiFi AP started successfully"
    log "  SSID: $SSID"
    log "  Interface: $WIFI_IF"
    log "  Bridge: $BRIDGE"
else
    err "hostapd failed to start"
    journalctl -u hostapd -n 20 --no-pager
    exit 1
fi
