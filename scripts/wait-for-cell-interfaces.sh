#!/bin/bash
MAX_WAIT=120
WAITED=0

while [[ $WAITED -lt $MAX_WAIT ]]; do
    IP0=$(ip -4 addr show wwan0 2>/dev/null | grep -oP 'inet \K[\d.]+')
    IP1=$(ip -4 addr show wwan1 2>/dev/null | grep -oP 'inet \K[\d.]+')
    
    if [[ -n "$IP0" && -n "$IP1" ]]; then
        echo "Both interfaces ready: wwan0=$IP0 wwan1=$IP1 after ${WAITED}s"
        exit 0
    fi
    echo "Waiting... wwan0=${IP0:-none} wwan1=${IP1:-none}"
    sleep 5
    WAITED=$((WAITED + 5))
done

echo "Timeout - continuing with available interfaces"
exit 0  # Don't fail, just continue with what we have
