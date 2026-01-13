#!/bin/bash
# Setup GPS dongle - BU-353N on ttyUSB0

# Wait for device
for i in {1..10}; do
    if [ -e /dev/ttyUSB0 ]; then
        stty -F /dev/ttyUSB0 4800
        echo "GPS configured on /dev/ttyUSB0 at 4800 baud"
        exit 0
    fi
    sleep 1
done

echo "GPS device not found"
exit 1
