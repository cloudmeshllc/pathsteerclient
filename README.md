# PathSteer Guardian V1

**Session Survivability for Hostile Mobile Environments**

## Quick Start

```bash
# Extract
tar xzf pathsteer-guardian-v1.tar.gz && cd pathsteer

# Generate keys
sudo ./install.sh --config config/config.edge.json --generate-keys

# Edit config with your keys
nano config/config.edge.json

# Install
sudo ./install.sh --config config/config.edge.json

# Start
sudo systemctl start pathsteer-netns pathsteerd pathsteer-web

# Dashboard
open http://localhost:8080
```

## Roles

| Role | What Gets Installed |
|------|---------------------|
| **Edge** | 4 netns, 8 WG tunnels, pathsteerd, tc mirred, web UI |
| **Controller** | WG peers, dedupe daemon, forwarding |

## Operating Modes

| Mode | Duplication | Use Case |
|------|-------------|----------|
| **TRAINING** | Off | Build route risk maps |
| **TRIPWIRE** | On-demand | Normal operation |
| **MIRROR** | Always-on | Demo/critical |

## Dashboard Features

- Speed (mph)
- Per-uplink metrics (RTT, RSRP, SINR, loss)
- Force Fail / Force Active buttons
- Decision feed with timestamps
- Protection countdowns
- GPS map with trail
- Controller switching

## Topology

```
EDGE (Protectli)                    PoP (Datacenter)
                                    
ns_cell_a ─┬─ wg → ctrl_a ─────────→ Controller A
ns_cell_b ─┤                         (dedupe)
ns_sl_a ───┤                              │
ns_sl_b ───┘                              ↓
    │                               C8000 (BGP)
    └── br-lan (clients)                  │
                                          ↓
                                     Internet
```

## Config

Edit `config/config.edge.json`:
- `uplinks.*`: Enable/disable, set interfaces
- `controllers.*`: WireGuard endpoints and pubkeys
- `tripwire.*`: Detection thresholds
- `switching.*`: Hold times, clean exit

## Troubleshooting

```bash
systemctl status pathsteerd
journalctl -u pathsteerd -f
ip netns list
wg show
cat /run/pathsteer/status.json | jq
```
# pathsteerclient
