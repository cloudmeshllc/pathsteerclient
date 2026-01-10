# PathSteer - Session Continuity Fabric

---

## Core Technology

IPv6/SRv6 orchestrated session continuity. Traffic is encapsulated with shim headers (flow_id + seq#), duplicated across multiple paths pre-encryption, deduplicated at controller. 5-tuple preserved through path changes. Sub-500ms failover without session reset.

Patents granted on tunnel-free approach using BGP for anchor mobility.

---

## Products

### Guardian Edge (SMB/Prosumer) - Current Build
- Protectli box with 4-6 uplinks (Starlink x2, LTE x2, Fiber x2)
- 12 WireGuard tunnels to dual controllers
- Three modes: TRAINING (observe), TRIPWIRE (on-demand), MIRROR (always-on)
- Starlink gRPC + cellular mmcli for predictive switching
- GPS-indexed training data builds route risk maps
- Target: Mobile command centers, RVs, yachts, remote work, first responders
- Peplink replacement but with actual session continuity

### Enterprise Edge (Future)
- Same fabric, bigger scale
- VIP mobility: /32 addresses move between edge clients
- Client mesh with shortest-path routing
- SRv6 carries traffic during BGP convergence
- Pre-announce /24 at POP for instant failover
- Cisco SD-WAN replacement

### Cellular Overlay (Future)
- Session continuity across carrier handoffs
- Single device, multiple carrier profiles
- Not dependent on MVNO - overlay handles continuity
- Google Fi done right

---

## Network Architecture

```
VLAN 100 - Survivable     10.100.0.0/24 + IPv6    Always tunneled
VLAN 110 - Service        104.204.136.48/29       Raw, no NAT
VLAN 200 - Mixed          10.200.0.0/24 + NAT66   fwmark selects survivable
VLAN 300 - Guest          10.30.0.0/24 + NAT66    Never tunneled, best effort
```

fwmark classification: User defines survivable traffic via IP/port rules or profiles (SIP, WebEx, games). Default = best effort. Critical = duplicated.

---

## Infrastructure

- Controller A: Dallas (104.204.136.13)
- Controller B: Dallas (104.204.136.14)  
- Controller C: PNAP Phoenix (planned) - SRv6, AWS/GCP onramps
- Edge: 12 tunnels (4 cell, 4 Starlink, 4 fiber) to both controllers
- Session anchoring: Kamailio (SIP), rtpengine (RTP), HAProxy (HTTPS)

---

## Differentiation

| Feature | Peplink/SD-WAN | PathSteer |
|---------|----------------|-----------|
| Failover | Seconds | <500ms |
| Session continuity | No (TCP resets) | Yes (5-tuple preserved) |
| Duplication | None | Pre-encryption, per-packet |
| Prediction | None | GPS + signal + training data |
| Path selection | Simple metrics | ML on actual route history |

---

## Markets

1. **Guardian** - SMB mobile (\$500-2000 hardware + \$50-200/mo)
2. **Enterprise** - SD-WAN replacement (\$\$\$)
3. **Cellular** - Consumer/prosumer mobile overlay
4. **Military/Gov** - Tactical edge, denied environments
5. **Maritime/Aviation** - Multi-SATCOM continuity

---

## Demo Story

Voice call + LLM token stream running. Pull Starlink cable. Zero audio glitch, zero token loss. PCAP shows 5-tuple unchanged. Duplication absorbed the failure before it happened.

**"The network broke. The session didn't."**

---

## Current State (Jan 2026)

### Working
- 12 WireGuard tunnels (4 cell, 4 Starlink, 4 fiber) with handshakes
- Dual cellular modems (T-Mobile + AT&T) via policy routing
- Dual Starlink dishes via namespaces
- Starlink gRPC API polling (latency, obstruction, SNR)
- Cellular mmcli polling (RSRP, RSRQ, SINR)
- GPS integration (gpsd + GlobalSat receiver)
- Boot persistence for all services
- Training logger ready

### In Progress
- pathsteerd (edge daemon) - needs updates for current architecture
- pathsteer-ctrl (controller daemon) - running, needs traffic routing
- Web UI integration
- Fiber namespace setup

### Todo
- Route traffic through shim layer
- Deduplication at controller
- Mode switching (TRAINING/TRIPWIRE/MIRROR)
- Session anchoring proxies (Kamailio, rtpengine, HAProxy)
- Route risk prediction engine
- CoverageMap API integration (14-day trial for demo)
