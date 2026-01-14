#!/bin/bash
# Smart training data collection - only when moving or signal changes significantly

DB="/opt/pathsteer/data/training.db"
LAST_LAT=0
LAST_LON=0
LAST_RSRP=0

sqlite3 $DB "CREATE TABLE IF NOT EXISTS samples (
    timestamp TEXT, lat REAL, lon REAL, speed REAL, heading REAL,
    cell_a_rtt REAL, cell_a_rsrp REAL, cell_a_sinr REAL,
    cell_b_rtt REAL, cell_b_rsrp REAL, cell_b_sinr REAL,
    sl_a_rtt REAL, sl_a_obstructed INT, sl_b_rtt REAL, sl_b_obstructed INT,
    active_uplink TEXT, risk REAL
);"

while true; do
    STATUS=$(cat /run/pathsteer/status.json 2>/dev/null)
    GPS=$(cat /run/pathsteer/gps.json 2>/dev/null)
    RADIO=$(cat /run/pathsteer/radio_hints.json 2>/dev/null)
    
    if [ -n "$STATUS" ] && [ -n "$GPS" ]; then
        LAT=$(echo $GPS | jq -r '.lat // 0')
        LON=$(echo $GPS | jq -r '.lon // 0')
        
        CA_RSRP=$(echo $RADIO | jq -r '.tmo.rsrp // 0')
        CB_RSRP=$(echo $RADIO | jq -r '.att.rsrp // 0')
        
        # Calculate distance moved (rough approximation)
        DLAT=$(echo "$LAT - $LAST_LAT" | bc -l 2>/dev/null || echo "1")
        DLON=$(echo "$LON - $LAST_LON" | bc -l 2>/dev/null || echo "1")
        
        # Only record if moved >10m or RSRP changed >5dB
        MOVED=$(echo "scale=6; sqrt($DLAT*$DLAT + $DLON*$DLON) > 0.0001" | bc -l 2>/dev/null || echo "1")
        RSRP_CHANGED=$(echo "scale=0; ($CA_RSRP - $LAST_RSRP) * ($CA_RSRP - $LAST_RSRP) > 25" | bc -l 2>/dev/null || echo "1")
        
        if [ "$MOVED" = "1" ] || [ "$RSRP_CHANGED" = "1" ]; then
            TS=$(date -Iseconds)
            CA_RTT=$(echo $STATUS | jq -r '.uplinks[] | select(.name=="cell_a") | .rtt_ms // 0')
            CB_RTT=$(echo $STATUS | jq -r '.uplinks[] | select(.name=="cell_b") | .rtt_ms // 0')
            CA_SINR=$(echo $RADIO | jq -r '.tmo.sinr // 0')
            CB_SINR=$(echo $RADIO | jq -r '.att.sinr // 0')
            SLA_RTT=$(echo $STATUS | jq -r '.uplinks[] | select(.name=="sl_a") | .rtt_ms // 0')
            SLA_OBS=$(echo $STATUS | jq -r '.uplinks[] | select(.name=="sl_a") | .starlink.obstructed // false' | grep -q true && echo 1 || echo 0)
            SLB_RTT=$(echo $STATUS | jq -r '.uplinks[] | select(.name=="sl_b") | .rtt_ms // 0')
            SLB_OBS=$(echo $STATUS | jq -r '.uplinks[] | select(.name=="sl_b") | .starlink.obstructed // false' | grep -q true && echo 1 || echo 0)
            ACTIVE=$(echo $STATUS | jq -r '.active_uplink // "none"')
            RISK=$(echo $STATUS | jq -r '.global_risk // 0')
            
            # Delete old samples at this location (within ~20m) older than 14 days
            sqlite3 $DB "DELETE FROM samples WHERE 
                abs(lat - $LAT) < 0.0002 AND abs(lon - $LON) < 0.0002 
                AND timestamp < datetime('now', '-14 days');"
            
            sqlite3 $DB "INSERT INTO samples VALUES ('$TS', $LAT, $LON, 0, 0, $CA_RTT, $CA_RSRP, $CA_SINR, $CB_RTT, $CB_RSRP, $CB_SINR, $SLA_RTT, $SLA_OBS, $SLB_RTT, $SLB_OBS, '$ACTIVE', $RISK);"
            
            LAST_LAT=$LAT
            LAST_LON=$LON
            LAST_RSRP=$CA_RSRP
        fi
    fi
    sleep 5
done
