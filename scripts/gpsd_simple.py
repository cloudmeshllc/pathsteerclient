#!/usr/bin/env python3
"""
gpsd_simple.py - Simple GPS polling daemon for PathSteer Guardian

Connects to gpsd, reads TPV (position) messages, and writes to
/run/pathsteer/gps.json for the main daemon to consume.
"""

import socket
import json
import time
import os

GPSD_HOST = "localhost"
GPSD_PORT = 2947
OUTPUT_FILE = "/run/pathsteer/gps.json"

def connect_gpsd():
    """Connect to gpsd and enable watch mode"""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(5)
    sock.connect((GPSD_HOST, GPSD_PORT))
    sock.send(b'?WATCH={"enable":true,"json":true}\n')
    return sock

def parse_tpv(data):
    """Parse TPV message and extract relevant fields"""
    result = {
        "fix": False,
        "lat": 0,
        "lon": 0,
        "speed_mph": 0,
        "heading": 0,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ")
    }
    
    if data.get("class") != "TPV":
        return None
    
    mode = data.get("mode", 0)
    if mode >= 2:  # 2D or 3D fix
        result["fix"] = True
        result["lat"] = data.get("lat", 0)
        result["lon"] = data.get("lon", 0)
        
        # Speed: gpsd gives m/s, convert to mph
        speed_mps = data.get("speed", 0)
        result["speed_mph"] = speed_mps * 2.237
        
        result["heading"] = data.get("track", 0)
    
    return result

def write_output(data):
    """Write GPS data to output file"""
    os.makedirs(os.path.dirname(OUTPUT_FILE), exist_ok=True)
    tmp = OUTPUT_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.rename(tmp, OUTPUT_FILE)

def main():
    print("PathSteer GPS daemon starting...")
    
    while True:
        try:
            sock = connect_gpsd()
            buffer = ""
            
            while True:
                chunk = sock.recv(4096).decode("utf-8", errors="ignore")
                if not chunk:
                    break
                
                buffer += chunk
                while "\n" in buffer:
                    line, buffer = buffer.split("\n", 1)
                    if not line.strip():
                        continue
                    
                    try:
                        data = json.loads(line)
                        result = parse_tpv(data)
                        if result:
                            write_output(result)
                    except json.JSONDecodeError:
                        pass
                        
        except socket.error as e:
            print(f"Connection error: {e}, retrying in 5s...")
            time.sleep(5)
        except Exception as e:
            print(f"Error: {e}, retrying in 5s...")
            time.sleep(5)

if __name__ == "__main__":
    main()
