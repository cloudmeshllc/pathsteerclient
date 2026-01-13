#!/usr/bin/env python3
"""Simple GPS reader - writes location to JSON"""

import serial
import json
import time
from pathlib import Path

GPS_PORT = "/dev/ttyUSB0"
GPS_BAUD = 4800
OUTPUT = "/run/pathsteer/gps.json"

def parse_gprmc(line):
    """Parse $GPRMC sentence"""
    parts = line.split(',')
    if len(parts) < 7 or parts[2] != 'A':  # A = valid fix
        return None
    
    # Parse lat/lon
    lat = float(parts[3][:2]) + float(parts[3][2:]) / 60
    if parts[4] == 'S':
        lat = -lat
    
    lon = float(parts[5][:3]) + float(parts[5][3:]) / 60
    if parts[6] == 'W':
        lon = -lon
    
    return {"lat": round(lat, 6), "lon": round(lon, 6), "fix": True, "timestamp": time.time()}

def main():
    Path("/run/pathsteer").mkdir(parents=True, exist_ok=True)
    
    try:
        ser = serial.Serial(GPS_PORT, GPS_BAUD, timeout=1)
    except Exception as e:
        print(f"GPS port error: {e}")
        Path(OUTPUT).write_text(json.dumps({"fix": False, "error": str(e)}))
        return
    
    while True:
        try:
            line = ser.readline().decode('ascii', errors='ignore').strip()
            if line.startswith('$GPRMC'):
                data = parse_gprmc(line)
                if data:
                    Path(OUTPUT).write_text(json.dumps(data, indent=2))
        except Exception as e:
            print(f"Error: {e}")
        time.sleep(0.1)

if __name__ == "__main__":
    main()
