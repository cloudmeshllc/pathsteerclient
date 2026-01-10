#!/bin/bash
###############################################################################
# PathSteer Guardian - Modem Initialization & Normalization
#
# PROBLEM:
#   ModemManager assigns random indices on each boot (1, 52, etc.)
#   We need stable identification to map modems to config
#
# SOLUTION:
#   Identify modems by IMEI or USB path, not index
#   Create bearers, get IP, identify interface name
#   Output: /run/pathsteer/modems.json with stable mapping
#
# RUNS: Before netns-init.sh (so we know which wwan interface to move)
###############################################################################
set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/pathsteer/config.json}"
OUTPUT_FILE="/run/pathsteer/modems.json"

log() { echo "[modem-init] $*"; }
err() { echo "[modem-init] ERROR: $*" >&2; }

# Ensure output directory
mkdir -p /run/pathsteer

# Wait for ModemManager to settle
wait_for_mm() {
    log "Waiting for ModemManager..."
    local tries=0
    while ! mmcli -L &>/dev/null; do
        sleep 1
        ((tries++))
        if [[ $tries -gt 30 ]]; then
            err "ModemManager not responding after 30s"
            return 1
        fi
    done
    # Extra settle time for modems to enumerate
    sleep 3
    log "ModemManager ready"
}

# Get modem details by index
get_modem_info() {
    local idx="$1"
    local info
    info=$(mmcli -m "$idx" 2>/dev/null) || return 1
    
    # Extract fields
    local imei model primary_port device state
    imei=$(echo "$info" | grep -oP "imei:\s+\K\d+" || echo "")
    model=$(echo "$info" | grep -oP "model:\s+\K\S+" || echo "unknown")
    primary_port=$(echo "$info" | grep -oP "primary port:\s+\K\S+" || echo "")
    device=$(echo "$info" | grep -oP "device:\s+\K\S+" || echo "")
    state=$(echo "$info" | grep -oP "state:\s+\K\S+" || echo "unknown")
    
    # Extract USB path from device (e.g., /sys/devices/.../usb1/1-1/... -> 1-1)
    local usb_path=""
    if [[ "$device" =~ usb[0-9]+/([0-9]+-[0-9.]+) ]]; then
        usb_path="${BASH_REMATCH[1]}"
    fi
    
    echo "{\"index\":$idx,\"imei\":\"$imei\",\"model\":\"$model\",\"port\":\"$primary_port\",\"usb\":\"$usb_path\",\"state\":\"$state\"}"
}

# Find modem by identifier (IMEI:xxx or USB:x-x)
find_modem_by_id() {
    local identifier="$1"
    local type="${identifier%%:*}"
    local value="${identifier#*:}"
    
    # List all modems
    local modems
    modems=$(mmcli -L 2>/dev/null | grep -oP '/Modem/\K\d+' || echo "")
    
    for idx in $modems; do
        local info
        info=$(get_modem_info "$idx") || continue
        
        case "$type" in
            IMEI|imei)
                local modem_imei
                modem_imei=$(echo "$info" | grep -oP '"imei":"?\K[^",]+')
                if [[ "$modem_imei" == "$value" ]]; then
                    echo "$info"
                    return 0
                fi
                ;;
            USB|usb)
                local modem_usb
                modem_usb=$(echo "$info" | grep -oP '"usb":"?\K[^",]+')
                if [[ "$modem_usb" == "$value" ]]; then
                    echo "$info"
                    return 0
                fi
                ;;
            *)
                err "Unknown identifier type: $type (use IMEI:xxx or USB:x-x)"
                return 1
                ;;
        esac
    done
    
    return 1
}

# Connect modem and get interface
connect_modem() {
    local idx="$1"
    local apn="${2:-}"
    
    log "Connecting modem $idx..."
    
    # Check if already connected
    local state
    state=$(mmcli -m "$idx" 2>/dev/null | grep -oP "state:\s+\K\S+" || echo "")
    
    if [[ "$state" == "connected" ]]; then
        log "Modem $idx already connected"
    else
        # Simple connect (uses default APN or SIM's provisioned APN)
        if [[ -n "$apn" ]]; then
            mmcli -m "$idx" --simple-connect="apn=$apn" 2>/dev/null || true
        else
            mmcli -m "$idx" --simple-connect="" 2>/dev/null || true
        fi
        sleep 2
    fi
    
    # Get bearer and interface
    local bearer_path interface ip
    bearer_path=$(mmcli -m "$idx" 2>/dev/null | grep -oP "Bearer/\K\d+" | head -1 || echo "")
    
    if [[ -n "$bearer_path" ]]; then
        interface=$(mmcli -b "$bearer_path" 2>/dev/null | grep -oP "interface:\s+\K\S+" || echo "")
        ip=$(mmcli -b "$bearer_path" 2>/dev/null | grep -oP "address:\s+\K[0-9.]+" || echo "")
        log "Modem $idx: interface=$interface ip=$ip"
        echo "$interface"
    else
        err "No bearer for modem $idx"
        echo ""
    fi
}

# Main: Discover and map modems
main() {
    log "Starting modem initialization..."
    
    wait_for_mm || exit 1
    
    # Start JSON output
    echo "{" > "$OUTPUT_FILE"
    echo "  \"timestamp\": \"$(date -Iseconds)\"," >> "$OUTPUT_FILE"
    echo "  \"modems\": {" >> "$OUTPUT_FILE"
    
    # Read config and find each LTE uplink
    local first=true
    for uplink in cell_a cell_b; do
        local enabled type identifier apn
        enabled=$(jq -r ".uplinks.$uplink.enabled // false" "$CONFIG_FILE")
        type=$(jq -r ".uplinks.$uplink.type // \"\"" "$CONFIG_FILE")
        
        [[ "$enabled" != "true" || "$type" != "lte" ]] && continue
        
        identifier=$(jq -r ".uplinks.$uplink.identifier // \"\"" "$CONFIG_FILE")
        apn=$(jq -r ".uplinks.$uplink.apn // \"\"" "$CONFIG_FILE")
        
        log "Processing $uplink (identifier: ${identifier:-auto})"
        
        local modem_info=""
        local modem_idx=""
        local interface=""
        
        if [[ -n "$identifier" ]]; then
            # Find by IMEI or USB path
            modem_info=$(find_modem_by_id "$identifier") || {
                err "Could not find modem for $uplink with identifier $identifier"
                continue
            }
            modem_idx=$(echo "$modem_info" | grep -oP '"index":\K\d+')
        else
            # Auto-assign by order (fallback, not recommended)
            log "Warning: No identifier for $uplink, using auto-assignment"
            local all_modems
            all_modems=$(mmcli -L 2>/dev/null | grep -oP '/Modem/\K\d+' | head -n2)
            if [[ "$uplink" == "cell_a" ]]; then
                modem_idx=$(echo "$all_modems" | head -1)
            else
                modem_idx=$(echo "$all_modems" | tail -1)
            fi
            [[ -z "$modem_idx" ]] && continue
            modem_info=$(get_modem_info "$modem_idx")
        fi
        
        # Connect and get interface
        interface=$(connect_modem "$modem_idx" "$apn")
        
        # Write to JSON
        [[ "$first" != "true" ]] && echo "," >> "$OUTPUT_FILE"
        first=false
        
        cat >> "$OUTPUT_FILE" << EOF
    "$uplink": {
      "modem_index": $modem_idx,
      "interface": "$interface",
      "info": $modem_info
    }
EOF
        
        log "$uplink -> modem $modem_idx -> $interface"
    done
    
    echo "" >> "$OUTPUT_FILE"
    echo "  }" >> "$OUTPUT_FILE"
    echo "}" >> "$OUTPUT_FILE"
    
    log "Modem mapping written to $OUTPUT_FILE"
    cat "$OUTPUT_FILE"
}

# Utility: List all modems with details
list_modems() {
    log "Enumerating all modems..."
    
    local modems
    modems=$(mmcli -L 2>/dev/null | grep -oP '/Modem/\K\d+' || echo "")
    
    if [[ -z "$modems" ]]; then
        log "No modems found"
        return
    fi
    
    echo "{"
    echo "  \"modems\": ["
    local first=true
    for idx in $modems; do
        local info
        info=$(get_modem_info "$idx") || continue
        [[ "$first" != "true" ]] && echo ","
        first=false
        echo "    $info"
    done
    echo ""
    echo "  ]"
    echo "}"
}

case "${1:-init}" in
    init)
        main
        ;;
    list)
        list_modems
        ;;
    connect)
        connect_modem "$2" "${3:-}"
        ;;
    find)
        find_modem_by_id "$2"
        ;;
    *)
        echo "Usage: $0 {init|list|connect <idx> [apn]|find <IMEI:xxx|USB:x-x>}"
        exit 1
        ;;
esac
