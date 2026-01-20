#!/bin/bash
# Cellular signal polling using QMI proxy (safe, no CID management)

poll_signal() {
    local dev=$1
    timeout 5 qmicli -d "$dev" -p --nas-get-signal-strength 2>/dev/null
}

case "$1" in
    poll)
        poll_signal "/dev/cdc-wdm${2:-0}"
        ;;
    status)
        echo "Using QMI proxy mode (no CID tracking)"
        ;;
    *)
        echo "Usage: $0 {poll|status} [dev_num]"
        ;;
esac
