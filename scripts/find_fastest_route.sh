#!/bin/bash
# PathSteer - Find fastest route and set as default
# Runs on boot before pathsteerd, keeps SSH/IPv6 open

LOG="/var/log/pathsteer/fastest-route.log"
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1

echo "=== $(date) - Finding fastest route ==="

# Test file URL (change to POP-hosted for accuracy)
TEST_URL="http://speedtest.tele2.net/1MB.zip"
TEST_SIZE=1048576  # 1MB

declare -A SPEEDS

# Test each veth path
test_path() {
    local name=$1
    local veth=$2
    local veth_ip=$3
    
    # Check if veth exists and is up
    if ! ip link show "$veth" &>/dev/null; then
        echo "  $name: veth $veth not found"
        return
    fi
    
    # Add temporary route for test
    ip route add "$TEST_URL_IP" via "$veth_ip" dev "$veth" 2>/dev/null
    
    # Download and measure
    local start=$(date +%s.%N)
    if timeout 10 curl -s -o /dev/null "$TEST_URL" 2>/dev/null; then
        local end=$(date +%s.%N)
        local duration=$(echo "$end - $start" | bc)
        local speed=$(echo "scale=2; $TEST_SIZE / $duration / 1024" | bc)
        echo "  $name: ${speed} KB/s (${duration}s)"
        SPEEDS[$name]="$speed|$veth|$veth_ip"
    else
        echo "  $name: FAILED"
    fi
    
    # Remove temporary route
    ip route del "$TEST_URL_IP" via "$veth_ip" dev "$veth" 2>/dev/null
}

# Resolve test URL to IP
TEST_URL_HOST=$(echo "$TEST_URL" | sed 's|http://||' | cut -d'/' -f1)
TEST_URL_IP=$(getent hosts "$TEST_URL_HOST" | awk '{print $1}' | head -1)

if [[ -z "$TEST_URL_IP" ]]; then
    echo "Cannot resolve $TEST_URL_HOST, using ping test instead"
    # Fallback to ping-based selection
    for path in "fa|veth_fa|10.201.1.2" "fb|veth_fb|10.201.2.2" "sl_a|veth_sl_a|10.201.3.2" "sl_b|veth_sl_b|10.201.4.2"; do
        IFS='|' read -r name veth veth_ip <<< "$path"
        if ip link show "$veth" &>/dev/null; then
            if ping -c1 -W2 -I "$veth" 8.8.8.8 &>/dev/null; then
                echo "  $name: reachable"
                ip route replace default via "$veth_ip" dev "$veth"
                echo "Default route set to $name ($veth)"
                exit 0
            fi
        fi
    done
    echo "No working path found, using cellular"
    exit 1
fi

echo "Testing paths to $TEST_URL_IP..."

# Test each namespace path
test_path "fa" "veth_fa" "10.201.1.2"
test_path "fb" "veth_fb" "10.201.2.2"
test_path "sl_a" "veth_sl_a" "10.201.3.2"
test_path "sl_b" "veth_sl_b" "10.201.4.2"

# Find fastest
best_name=""
best_speed=0
best_veth=""
best_ip=""

for name in "${!SPEEDS[@]}"; do
    IFS='|' read -r speed veth veth_ip <<< "${SPEEDS[$name]}"
    if (( $(echo "$speed > $best_speed" | bc -l) )); then
        best_speed=$speed
        best_name=$name
        best_veth=$veth
        best_ip=$veth_ip
    fi
done

if [[ -n "$best_name" ]]; then
    echo ""
    echo "Winner: $best_name (${best_speed} KB/s)"
    ip route replace default via "$best_ip" dev "$best_veth"
    echo "Default route set to $best_name via $best_veth"
else
    echo "No working paths, keeping cellular default"
fi

echo "=== Done ==="
