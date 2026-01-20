#!/usr/bin/env python3
"""GPS reader - direct serial NMEA parsing"""

import serial
import json
import time
from pathlib import Path

GPS_PORT = "/dev/gps0"
GPS_BAUD = 4800
OUTPUT = "/run/pathsteer/gps.json"

def parse_gprmc(line):
    """Parse $GPRMC sentence"""
    try:
        parts = line.split(',')
        if len(parts) < 8 or parts[2] != 'A':
            return None
        lat = float(parts[3][:2]) + float(parts[3][2:]) / 60
        if parts[4] == 'S': lat = -lat
        lon = float(parts[5][:3]) + float(parts[5][3:]) / 60
        if parts[6] == 'W': lon = -lon
        speed_knots = float(parts[7]) if parts[7] else 0
        return {
            "lat": round(lat, 6),
            "lon": round(lon, 6),
            "speed_mph": round(speed_knots * 1.151, 1),
            "fix": True,
            "timestamp": time.time()
        }
    except:
        return None

def main():
    Path("/run/pathsteer").mkdir(exist_ok=True)
    while True:
        try:
            ser = serial.Serial(GPS_PORT, GPS_BAUD, timeout=2)
            while True:
                line = ser.readline().decode('ascii', errors='ignore').strip()
                if line.startswith('$GPRMC'):
                    data = parse_gprmc(line)
                    if data:
                        Path(OUTPUT).write_text(json.dumps(data))
        except Exception as e:
            Path(OUTPUT).write_text(json.dumps({"fix": False, "timestamp": time.time()}))
            time.sleep(2)

if __name__ == "__main__":
    main()
