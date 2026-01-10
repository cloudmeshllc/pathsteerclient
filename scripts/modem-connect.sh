#!/bin/bash
# Connect cellular modems and configure interfaces

connect_modem() {
    local modem=$1
    local iface=$2
    local apn=$3
    local metric=$4

    echo "=== Connecting modem $modem ($iface) ==="
    
    # Connect
    mmcli -m "$modem" --simple-connect="apn=$apn" 2>/dev/null
    sleep 3
    
    # Find data bearer (not initial-bearer)
    local bearer=$(mmcli -m "$modem" | grep "Bearer.*paths:" | grep -oP 'Bearer/\K\d+')
    if [[ -z "$bearer" ]]; then
        echo "ERROR: No bearer found"
        return 1
    fi
    
    # Get IP info
    local ip=$(mmcli -b "$bearer" | grep "address:" | awk '{print $NF}')
    local gw=$(mmcli -b "$bearer" | grep "gateway:" | awk '{print $NF}')
    
    if [[ -z "$ip" || -z "$gw" ]]; then
        echo "ERROR: No IP/GW from bearer $bearer"
        return 1
    fi
    
    echo "  Bearer $bearer: IP=$ip GW=$gw"
    
    # Configure interface
    ip addr flush dev "$iface" 2>/dev/null
    ip link set "$iface" up
    ip addr add "${ip}/32" dev "$iface"
    ip route add "$gw" dev "$iface"
    ip route add default via "$gw" dev "$iface" metric "$metric" 2>/dev/null
    
    # Test
    if ping -c 1 -W 2 -I "$iface" 8.8.8.8 &>/dev/null; then
        echo "  OK: $iface connected"
        return 0
    else
        echo "  WARN: $iface no ping"
        return 1
    fi
}

# T-Mobile (modem 53, wwan0)
connect_modem 53 wwan0 "fast.t-mobile.com" 100

# AT&T (modem 64, wwan1)  
connect_modem 64 wwan1 "broadband" 101
