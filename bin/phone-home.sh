#!/bin/bash
# PathSteer Phone Home - saves IPv6 addresses for emergency access

OUTFILE="/run/pathsteer/emergency-access.txt"
mkdir -p /run/pathsteer

# Collect all IPv6 global addresses
IPV6_MAIN=$(ip -6 addr show 2>/dev/null | grep 'inet6.*global' | grep -v deprecated | awk '{print $2}' | cut -d/ -f1 | head -1)
IPV6_SL=$(ip netns exec ns_sl_a ip -6 addr show 2>/dev/null | grep 'inet6.*global' | awk '{print $2}' | cut -d/ -f1 | head -1)
IPV6_FA=$(ip netns exec ns_fa ip -6 addr show 2>/dev/null | grep 'inet6.*global' | awk '{print $2}' | cut -d/ -f1 | head -1)

# Tailscale IPs
TS_IP=$(tailscale ip -4 2>/dev/null)
TS_IP6=$(tailscale ip -6 2>/dev/null)

cat > $OUTFILE << EEOF
=== PATHSTEER EMERGENCY ACCESS ===
Generated: $(date)
Hostname: $(hostname)

SSH Access (try in order):

1. Tailscale (best):
   ssh pathsteer@$TS_IP
   ssh pathsteer@$TS_IP6

2. Main IPv6 (if firewall allows):
   ssh pathsteer@$IPV6_MAIN

3. Fiber Namespace IPv6:
   ssh pathsteer@$IPV6_FA

4. Starlink Namespace IPv6:
   ssh pathsteer@$IPV6_SL

5. Local Network:
   ssh pathsteer@192.168.0.139

6. WiFi Management:
   ssh pathsteer@104.204.136.50

Current Default Routes:
$(ip route | grep default)

IPv6 Addresses:
- Main:     ${IPV6_MAIN:-NONE}
- Fiber NS: ${IPV6_FA:-NONE}
- SL NS:    ${IPV6_SL:-NONE}
- Tailscale: ${TS_IP6:-NONE}
EEOF

cat $OUTFILE
