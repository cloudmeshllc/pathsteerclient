#!/usr/bin/env python3
"""GPS reader using gpsd - writes location to JSON"""

import json
import time
import socket
from pathlib import Path

OUTPUT = "/run/pathsteer/gps.json"
GPSD_HOST = "localhost"
GPSD_PORT = 2947

def get_gps_data():
    """Get GPS data from gpsd"""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(3)
        sock.connect((GPSD_HOST, GPSD_PORT))
        sock.sendall(b'?WATCH={"enable":true,"json":true}\n')
        
        buffer = ""
        deadline = time.time() + 2
        while time.time() < deadline:
            data = sock.recv(1024).decode('utf-8', errors='ignore')
            buffer += data
            for line in buffer.split('\n'):
                if '"class":"TPV"' in line:
                    try:
                        tpv = json.loads(line)
                        if tpv.get('mode', 0) >= 2:
                            sock.close()
                            return {
                                "lat": round(tpv.get('lat', 0), 6),
                                "lon": round(tpv.get('lon', 0), 6),
                                "speed_mph": round(tpv.get('speed', 0) * 2.237, 1),
                                "heading": round(tpv.get('track', 0), 1),
                                "fix": True,
                                "timestamp": time.time()
                            }
                    except:
                        pass
        sock.close()
    except Exception as e:
        pass
    return {"fix": False, "lat": 0, "lon": 0, "speed_mph": 0, "timestamp": time.time()}

def main():
    Path("/run/pathsteer").mkdir(exist_ok=True)
    while True:
        data = get_gps_data()
        Path(OUTPUT).write_text(json.dumps(data))
        time.sleep(1)

if __name__ == "__main__":
    main()
