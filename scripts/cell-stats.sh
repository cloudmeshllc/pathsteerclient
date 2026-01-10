#!/bin/bash
# Poll cellular modem signal stats

for modem in $(mmcli -L 2>/dev/null | grep -oP 'Modem/\K\d+'); do
    INFO=$(mmcli -m $modem --output-keyvalue 2>/dev/null)
    SIGNAL=$(mmcli -m $modem --signal-get 2>/dev/null)
    
    IMEI=$(echo "$INFO" | grep "modem.3gpp.imei" | head -1 | cut -d: -f2 | tr -d ' ')
    STATE=$(echo "$INFO" | grep "modem.generic.state" | head -1 | cut -d: -f2 | tr -d ' ')
    OPERATOR=$(echo "$INFO" | grep "modem.3gpp.operator-name" | head -1 | cut -d: -f2 | tr -d ' ')
    TECH=$(echo "$INFO" | grep "modem.generic.access-tech" | head -1 | cut -d: -f2 | tr -d ' ')
    
    RSRP=$(echo "$SIGNAL" | grep -oP 'rsrp:\s*\K-?[\d.]+' | head -1)
    RSRQ=$(echo "$SIGNAL" | grep -oP 'rsrq:\s*\K-?[\d.]+' | head -1)
    SINR=$(echo "$SIGNAL" | grep -oP 'snr:\s*\K-?[\d.]+' | head -1)
    
    echo "{\"imei\":\"$IMEI\",\"state\":\"$STATE\",\"operator\":\"$OPERATOR\",\"tech\":\"$TECH\",\"rsrp\":$RSRP,\"rsrq\":$RSRQ,\"sinr\":$SINR}"
done
