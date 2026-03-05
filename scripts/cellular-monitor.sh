#!/bin/bash
###############################################################################
# cellular-monitor.sh - Poll cellular signal metrics via qmicli
#
# Usage:
#   cellular-monitor.sh poll <dev_num> <name>
#   cellular-monitor.sh status
###############################################################################

CMD="${1:-status}"
DEV_NUM="${2:-0}"
NAME="${3:-cell_a}"

poll_signal() {
    local cdc="/dev/cdc-wdm${DEV_NUM}"
    
    if [[ ! -c "$cdc" ]]; then
        echo "Device not found: $cdc"
        return 1
    fi
    
    # Get signal strength via qmicli
    qmicli -d "$cdc" --nas-get-signal-strength 2>/dev/null
}

case "$CMD" in
    poll)
        poll_signal
        ;;
    status)
        echo "Cellular Monitor"
        for i in 0 1; do
            if [[ -c "/dev/cdc-wdm${i}" ]]; then
                echo "  cdc-wdm${i}: present"
            fi
        done
        ;;
    *)
        echo "Usage: $0 {poll <dev_num> <name>|status}"
        exit 1
        ;;
esac
