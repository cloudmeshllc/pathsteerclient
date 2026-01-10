#!/bin/bash
###############################################################################
# PathSteer Guardian - Complete Installation
#
# Run this if install.sh stopped early (after key generation)
# This script completes the remaining steps
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/pathsteer"
CONFIG_DIR="/etc/pathsteer"
DATA_DIR="/var/lib/pathsteer"

log() { echo -e "\033[0;32m[INFO]\033[0m $*"; }
step() { echo -e "\033[0;36m[STEP]\033[0m $*"; }
err() { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

# Check we're root
[[ $EUID -ne 0 ]] && { err "Must be root"; exit 1; }

step "Installing missing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -q

# Install in groups so we can see what fails
apt-get install -y build-essential gcc make pkg-config || err "Build tools failed"
apt-get install -y libsqlite3-dev libcurl4-openssl-dev libmnl-dev || err "Libs failed"
apt-get install -y python3-pip sqlite3 expect || err "Python/tools failed"
apt-get install -y bridge-utils hostapd dnsmasq || err "Network tools failed"
apt-get install -y gpsd gpsd-clients || err "GPS failed"

pip3 install flask requests 2>/dev/null || true

step "Copying files to ${INSTALL_DIR}..."
rsync -a "${SCRIPT_DIR}/" "${INSTALL_DIR}/" --exclude='.git'
chmod +x ${INSTALL_DIR}/scripts/*.sh
chmod +x ${INSTALL_DIR}/install.sh

step "Copying config..."
cp "${SCRIPT_DIR}/config/config.edge.json" "${CONFIG_DIR}/config.json"

step "Creating systemd services..."

cat > /etc/systemd/system/pathsteer-modem.service << 'EOF'
[Unit]
Description=PathSteer Modem Initialization
Before=pathsteer-netns.service
After=ModemManager.service
Wants=ModemManager.service

[Service]
Type=oneshot
ExecStart=/opt/pathsteer/scripts/modem-init.sh init
RemainAfterExit=yes
StandardOutput=journal

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/pathsteer-netns.service << 'EOF'
[Unit]
Description=PathSteer Network Namespace Init
After=pathsteer-modem.service network.target
Wants=pathsteer-modem.service

[Service]
Type=oneshot
ExecStart=/opt/pathsteer/scripts/netns-init.sh
RemainAfterExit=yes
StandardOutput=journal

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/pathsteer-tunnels.service << 'EOF'
[Unit]
Description=PathSteer WireGuard Tunnels
After=pathsteer-netns.service
Requires=pathsteer-netns.service

[Service]
Type=oneshot
ExecStart=/opt/pathsteer/scripts/wg-setup.sh --start
RemainAfterExit=yes
StandardOutput=journal

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/pathsteerd.service << 'EOF'
[Unit]
Description=PathSteer Guardian Daemon
After=pathsteer-tunnels.service
Requires=pathsteer-tunnels.service

[Service]
Type=simple
ExecStart=/usr/local/bin/pathsteerd --config /etc/pathsteer/config.json
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/pathsteer-web.service << 'EOF'
[Unit]
Description=PathSteer Web UI
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/pathsteer/web
ExecStart=/usr/bin/python3 /opt/pathsteer/web/app.py
Restart=always
Environment=CONFIG_FILE=/etc/pathsteer/config.json

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

step "Setting kernel parameters..."
cat > /etc/sysctl.d/99-pathsteer.conf << 'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
EOF
sysctl -p /etc/sysctl.d/99-pathsteer.conf

step "Initializing database..."
mkdir -p ${DATA_DIR}/{logs,pcap,runs}
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
SQL

step "Building pathsteerd..."
cd ${INSTALL_DIR}/src/pathsteerd
make clean 2>/dev/null || true
if make; then
    install -m 755 pathsteerd /usr/local/bin/
    log "pathsteerd built and installed"
else
    err "pathsteerd build failed - will need to fix manually"
fi

step "Setting up bridge..."
BRIDGE="br-lan"
if ! ip link show "$BRIDGE" &>/dev/null; then
    ip link add name "$BRIDGE" type bridge
fi
ip link set "$BRIDGE" up
ip addr add 104.204.136.49/28 dev "$BRIDGE" 2>/dev/null || true
log "Bridge $BRIDGE ready"

step "Enabling services..."
systemctl enable pathsteer-modem pathsteer-netns pathsteer-tunnels pathsteer-web

echo ""
echo "=============================================="
echo " Installation Complete"
echo "=============================================="
echo ""
echo "NEXT STEPS:"
echo ""
echo "1. Find your modem IMEIs:"
echo "   ${INSTALL_DIR}/scripts/modem-init.sh list"
echo ""
echo "2. Edit config with IMEIs and controller pubkeys:"
echo "   nano ${CONFIG_DIR}/config.json"
echo ""
echo "3. Test modem init:"
echo "   ${INSTALL_DIR}/scripts/modem-init.sh init"
echo ""
echo "4. Test netns creation:"
echo "   ${INSTALL_DIR}/scripts/netns-init.sh"
echo "   ip netns list"
echo ""
echo "5. Create WireGuard tunnels (after adding controller pubkeys):"
echo "   ${INSTALL_DIR}/scripts/wg-setup.sh create"
echo ""
echo "6. Start everything:"
echo "   systemctl start pathsteer-netns"
echo "   systemctl start pathsteer-tunnels"
echo "   systemctl start pathsteer-web"
echo ""
echo "Your WireGuard public key:"
cat ${CONFIG_DIR}/keys/publickey
echo "=============================================="
