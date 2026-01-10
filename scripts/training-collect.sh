#!/bin/bash
# Collect training data every 5 seconds

DB="/opt/pathsteer/data/training.db"

# Create table if not exists
sqlite3 $DB "CREATE TABLE IF NOT EXISTS samples (
    timestamp TEXT,
    lat REAL, lon REAL, speed REAL, heading REAL,
    cell_a_rtt REAL, cell_a_rsrp REAL, cell_a_sinr REAL,
    cell_b_rtt REAL, cell_b_rsrp REAL, cell_b_sinr REAL,
    sl_a_rtt REAL, sl_a_obstructed INT,
    sl_b_rtt REAL, sl_b_obstructed INT,
    active_uplink TEXT, risk REAL
);"

while true; do
    STATUS=$(cat /run/pathsteer/status.json 2>/dev/null)
    if [ -n "$STATUS" ]; then
        TS=$(date -Iseconds)
        LAT=$(echo $STATUS | jq -r '.gps.lat // 0')
        LON=$(echo $STATUS | jq -r '.gps.lon // 0')
        SPD=$(echo $STATUS | jq -r '.gps.speed // 0')
        HDG=$(echo $STATUS | jq -r '.gps.heading // 0')
        
        CA_RTT=$(echo $STATUS | jq -r '.uplinks[] | select(.name=="cell_a") | .rtt_ms // 0')
        CA_RSRP=$(echo $STATUS | jq -r '.uplinks[] | select(.name=="cell_a") | .cellular.rsrp // 0')
        CA_SINR=$(echo $STATUS | jq -r '.uplinks[] | select(.name=="cell_a") | .cellular.sinr // 0')
        
        CB_RTT=$(echo $STATUS | jq -r '.uplinks[] | select(.name=="cell_b") | .rtt_ms // 0')
        CB_RSRP=$(echo $STATUS | jq -r '.uplinks[] | select(.name=="cell_b") | .cellular.rsrp // 0')
        CB_SINR=$(echo $STATUS | jq -r '.uplinks[] | select(.name=="cell_b") | .cellular.sinr // 0')
        
        SLA_RTT=$(echo $STATUS | jq -r '.uplinks[] | select(.name=="sl_a") | .rtt_ms // 0')
        SLA_OBS=$(echo $STATUS | jq -r '.uplinks[] | select(.name=="sl_a") | .starlink.obstructed // false' | grep -q true && echo 1 || echo 0)
        
        SLB_RTT=$(echo $STATUS | jq -r '.uplinks[] | select(.name=="sl_b") | .rtt_ms // 0')
        SLB_OBS=$(echo $STATUS | jq -r '.uplinks[] | select(.name=="sl_b") | .starlink.obstructed // false' | grep -q true && echo 1 || echo 0)
        
        ACTIVE=$(echo $STATUS | jq -r '.active_uplink // "none"')
        RISK=$(echo $STATUS | jq -r '.risk // 0')
        
        sqlite3 $DB "INSERT INTO samples VALUES ('$TS', $LAT, $LON, $SPD, $HDG, $CA_RTT, $CA_RSRP, $CA_SINR, $CB_RTT, $CB_RSRP, $CB_SINR, $SLA_RTT, $SLA_OBS, $SLB_RTT, $SLB_OBS, '$ACTIVE', $RISK);"
    fi
    sleep 5
done
