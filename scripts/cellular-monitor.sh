#!/bin/bash
# Persistent QMI client for cellular signal polling
# Allocates one NAS client per modem, reuses CID to avoid exhaustion

STATE_DIR="/run/pathsteer"
mkdir -p "$STATE_DIR"

# Allocate persistent client for a modem
allocate_client() {
    local dev=$1  # /dev/cdc-wdm0 or /dev/cdc-wdm1
    local name=$2 # cell_a or cell_b
    local cid_file="$STATE_DIR/${name}_cid"
    
    # Check if we already have a valid CID
    if [ -f "$cid_file" ]; then
        local cid=$(cat "$cid_file")
        # Test if it's still valid
        if qmicli -d "$dev" -p --client-cid="$cid" --nas-get-signal-strength &>/dev/null; then
            echo "$cid"
            return 0
        fi
        rm -f "$cid_file"
    fi
    
    # Allocate new client
    local output=$(qmicli -d "$dev" -p --nas-noop --client-no-release-cid 2>&1)
    local cid=$(echo "$output" | grep -oP "CID: '\K\d+")
    
    if [ -n "$cid" ]; then
        echo "$cid" > "$cid_file"
        echo "$cid"
        return 0
    fi
    return 1
}

# Poll signal using persistent client
poll_signal() {
    local dev=$1
    local name=$2
    local cid_file="$STATE_DIR/${name}_cid"
    
    if [ ! -f "$cid_file" ]; then
        allocate_client "$dev" "$name" >/dev/null
    fi
    
    local cid=$(cat "$cid_file" 2>/dev/null)
    if [ -z "$cid" ]; then
        echo "ERROR: No CID for $name"
        return 1
    fi
    
    timeout 5 qmicli -d "$dev" -p --client-cid="$cid" --nas-get-signal-strength 2>/dev/null
}

# Reset modem on error
reset_modem() {
    local dev=$1
    local name=$2
    
    echo "Resetting $name..."
    rm -f "$STATE_DIR/${name}_cid"
    
    # Try NAS reset first
    qmicli -d "$dev" -p --nas-reset 2>/dev/null
    sleep 2
    
    # If still bad, DMS reset
    qmicli -d "$dev" -p --dms-reset 2>/dev/null
    sleep 5
}

# Main
case "$1" in
    allocate)
        allocate_client "/dev/cdc-wdm0" "cell_a"
        allocate_client "/dev/cdc-wdm1" "cell_b"
        ;;
    poll)
        poll_signal "/dev/cdc-wdm${2:-0}" "${3:-cell_a}"
        ;;
    reset)
        reset_modem "/dev/cdc-wdm${2:-0}" "${3:-cell_a}"
        ;;
    status)
        echo "cell_a CID: $(cat $STATE_DIR/cell_a_cid 2>/dev/null || echo 'none')"
        echo "cell_b CID: $(cat $STATE_DIR/cell_b_cid 2>/dev/null || echo 'none')"
        ;;
    *)
        echo "Usage: $0 {allocate|poll|reset|status}"
        ;;
esac
