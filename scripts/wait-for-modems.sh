#!/bin/bash
MAX_WAIT=60
WAITED=0

while [[ $WAITED -lt $MAX_WAIT ]]; do
    COUNT=$(mmcli -L 2>/dev/null | grep -c "Modem" || echo 0)
    if [[ $COUNT -gt 0 ]]; then
        echo "Found $COUNT modem(s) after ${WAITED}s"
        exit 0
    fi
    sleep 5
    WAITED=$((WAITED + 5))
done

echo "Timeout waiting for modems"
exit 1
