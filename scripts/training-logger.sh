#!/bin/bash
# Log signal + GPS for route training
LOGDIR="/var/lib/pathsteer/training"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/$(date +%Y%m%d).jsonl"

while true; do
    TS=$(date +%s.%3N)
    GPS=$(gpspipe -w -n 5 2>/dev/null | grep -m1 TPV | jq -c '{lat:.lat,lon:.lon,speed:.speed}' 2>/dev/null || echo '{}')
    CELL=$(/opt/pathsteer/scripts/cell-stats.sh | jq -sc '.')
    SL_A=$(/opt/pathsteer/scripts/starlink-stats.sh ns_sl_a 2>/dev/null)
    SL_B=$(/opt/pathsteer/scripts/starlink-stats.sh ns_sl_b 2>/dev/null)
    
    echo "{\"ts\":$TS,\"gps\":$GPS,\"cell\":$CELL,\"sl_a\":$SL_A,\"sl_b\":$SL_B}" >> "$LOGFILE"
    sleep 5
done
