
---

## Session Notes (Jan 20-21, 2026)

### Fixes Applied

**1. Cellular RTT Measurement**
- Problem: 7ms (fiber) instead of 60-120ms (cellular)
- Fix: `probe_rtt_iface()` in pathsteerd.c pings through WG interface: `ping -I wg-ca-cA 10.200.1.1`
- Result: cell_a ~80ms, cell_b ~100-120ms

**2. Cellular Signal Polling**
- Simplified `/opt/pathsteer/scripts/cellular-monitor.sh` to use QMI proxy directly

**3. Policy Routes**
- Fixed `/opt/pathsteer/scripts/setup-policy-routes.sh` to use correct table names
- Tables: `100 pathsteer` (cell_a/fwmark 0x64), `101 pathsteer_lte1` (cell_b/fwmark 0x65)

**4. RF Interference**
- Physical fix: 10ft antenna separation between modems

**5. UI Fixes**
- Toggle immediate update in `toggleUplink()`
- Disabled uplinks excluded from prediction badges
- Mobile responsive CSS added

**6. Config Enabled State**
- Daemon now loads `enabled: false` from config.json on startup

### Pending Issues

- **GPS**: Prolific PL2303 adapter failing. Need FTDI-based or u-blox USB GPS
- **cell_b**: Modem physically disconnected
- **sl_b boot**: Needs auto-config script for CGNAT IP + namespace move

### Quick Commands
```bash
# Status
cat /run/pathsteer/status.json | jq '.uplinks[] | {name, enabled, available, rtt_ms}'

# Test cellular
ping -c3 -I wg-ca-cA 10.200.1.1

# Policy routes
ip route show table pathsteer
/opt/pathsteer/scripts/setup-policy-routes.sh

# Rebuild daemon
cd /opt/pathsteer/src/pathsteerd && make && systemctl restart pathsteerd
```
