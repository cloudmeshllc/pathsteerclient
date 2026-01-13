#!/usr/bin/env python3
"""
radiomgrd - Dual-modem coexistence daemon for PathSteer Guardian
Detects desense and applies mitigation profiles
"""

import subprocess
import json
import time
import re
import logging
from pathlib import Path

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s %(levelname)s %(message)s'
)
log = logging.getLogger('radiomgrd')

CONFIG = {
    "modems": {
        "att": {"mm_id": None, "at_port": None, "net_if": None, "carrier_match": "VoLTE-ATT"},
        "tmo": {"mm_id": None, "at_port": None, "net_if": None, "carrier_match": "Commercial-TMO"}
    },
    "profiles": {
        "dual_active": {
            "att": {"mode": "auto"},
            "tmo": {"mode": "auto"}
        },
        "mitigate": {
            "att": {"mode": "lte_only"},
            "tmo": {"mode": "5g_prefer"}
        },
        "quiet_standby": {
            "att": {"mode": "lte_only", "quiet": True},
            "tmo": {"mode": "auto"}
        }
    },
    "thresholds": {
        "sinr_bad_db": 5,
        "desense_delta_sinr_db": 6,
        "hysteresis_intervals": 3,
        "cooldown_seconds": 30
    },
    "poll_interval_ms": 1000,
    "hints_file": "/run/pathsteer/radio_hints.json"
}

STATE = {
    "current_profile": "dual_active",
    "last_profile_change": 0,
    "metrics_history": []
}


def run_cmd(cmd, timeout=5):
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return result.stdout.strip()
    except:
        return None


def discover_modems():
    output = run_cmd("mmcli -L")
    if not output:
        return False
    
    modem_ids = re.findall(r'/Modem/(\d+)', output)
    
    for mm_id in modem_ids:
        info = run_cmd(f"mmcli -m {mm_id}")
        if not info:
            continue
        
        carrier_match = re.search(r'carrier config:\s*(\S+)', info)
        ports_match = re.search(r'ports:\s*(.+)', info)
        if not carrier_match or not ports_match:
            continue
        
        carrier = carrier_match.group(1)
        ports_line = ports_match.group(1)
        
        # Get second AT port (first sometimes busy)
        at_ports = re.findall(r'(ttyUSB\d+)\s*\(at\)', ports_line)
        at_port = at_ports[1] if len(at_ports) > 1 else at_ports[0] if at_ports else None
        net_if = re.search(r'(wwan\d+)\s*\(net\)', ports_line)
        
        for name, cfg in CONFIG["modems"].items():
            if cfg["carrier_match"] in carrier:
                cfg["mm_id"] = mm_id
                cfg["at_port"] = f"/dev/{at_port}" if at_port else None
                cfg["net_if"] = net_if.group(1) if net_if else None
                log.info(f"Discovered {name}: MM={mm_id}, AT={cfg['at_port']}, NET={cfg['net_if']}")
    
    return all(cfg["mm_id"] for cfg in CONFIG["modems"].values())


def get_serving_cell(at_port):
    output = run_cmd(f"echo 'AT+QENG=\"servingcell\"' | socat - {at_port},crnl 2>/dev/null")
    if not output:
        return None
    
    result = {"tech": None, "band": None, "rsrp": None, "sinr": None}
    
    lte_match = re.search(r'"LTE","FDD",\d+,\d+,[^,]+,\d+,\d+,(\d+),.*?,(-?\d+),(-?\d+),(-?\d+),(-?\d+)', output)
    if lte_match:
        result["tech"] = "LTE"
        result["band"] = int(lte_match.group(1))
        result["rsrp"] = int(lte_match.group(4))
        result["sinr"] = int(lte_match.group(5))
    
    if "NR5G-NSA" in output:
        result["tech"] = "LTE+NR"
    
    return result


def get_traffic_stats(net_if):
    tx = run_cmd(f"cat /sys/class/net/{net_if}/statistics/tx_bytes 2>/dev/null")
    rx = run_cmd(f"cat /sys/class/net/{net_if}/statistics/rx_bytes 2>/dev/null")
    return {"tx_bytes": int(tx) if tx else 0, "rx_bytes": int(rx) if rx else 0}


def apply_mode(modem_name, mode):
    mm_id = CONFIG["modems"][modem_name]["mm_id"]
    
    if mode == "lte_only":
        cmd = f"mmcli -m {mm_id} --set-allowed-modes='4g' --set-preferred-mode='none'"
    elif mode == "5g_prefer":
        cmd = f"mmcli -m {mm_id} --set-allowed-modes='3g|4g|5g' --set-preferred-mode='5g'"
    else:  # auto
        cmd = f"mmcli -m {mm_id} --set-allowed-modes='3g|4g|5g' --set-preferred-mode='5g'"
    
    result = run_cmd(cmd)
    log.info(f"Applied {mode} to {modem_name}")
    return result is not None


def apply_profile(profile_name):
    if profile_name == STATE["current_profile"]:
        return
    
    elapsed = time.time() - STATE["last_profile_change"]
    if elapsed < CONFIG["thresholds"]["cooldown_seconds"]:
        return
    
    profile = CONFIG["profiles"].get(profile_name)
    if not profile:
        return
    
    log.info(f"Profile: {STATE['current_profile']} -> {profile_name}")
    
    for modem_name, settings in profile.items():
        if "mode" in settings:
            apply_mode(modem_name, settings["mode"])
    
    STATE["current_profile"] = profile_name
    STATE["last_profile_change"] = time.time()


def write_hints():
    hints = {}
    profile = CONFIG["profiles"][STATE["current_profile"]]
    for name, cfg in CONFIG["modems"].items():
        quiet = profile.get(name, {}).get("quiet", False)
        hints[name] = {
            "available": cfg["mm_id"] is not None,
            "weight_factor": 0.3 if quiet else 1.0,
            "net_if": cfg["net_if"]
        }
    
    Path("/run/pathsteer").mkdir(parents=True, exist_ok=True)
    Path(CONFIG["hints_file"]).write_text(json.dumps(hints, indent=2))


def detect_desense():
    if len(STATE["metrics_history"]) < 3:
        return False
    
    current = STATE["metrics_history"][-1]
    prev = STATE["metrics_history"][-2]
    
    for name in ["att", "tmo"]:
        other = "tmo" if name == "att" else "att"
        
        if not all(k in current and k in prev for k in [name, other]):
            continue
        
        other_tx_delta = current[other].get("tx_bytes", 0) - prev[other].get("tx_bytes", 0)
        sinr_drop = (prev[name].get("sinr") or 0) - (current[name].get("sinr") or 0)
        
        if other_tx_delta > 10000 and sinr_drop > CONFIG["thresholds"]["desense_delta_sinr_db"]:
            log.warning(f"Desense: {name} SINR dropped {sinr_drop}dB when {other} TX'd")
            return True
    
    return False


def evaluate():
    if not STATE["metrics_history"]:
        return "dual_active"
    
    m = STATE["metrics_history"][-1]
    att_sinr = m.get("att", {}).get("sinr") or 0
    tmo_sinr = m.get("tmo", {}).get("sinr") or 0
    threshold = CONFIG["thresholds"]["sinr_bad_db"]
    
    att_ok = att_sinr > threshold
    tmo_ok = tmo_sinr > threshold
    desense = detect_desense()
    
    if att_ok and tmo_ok and not desense:
        return "dual_active"
    elif desense:
        return "mitigate"
    else:
        return "quiet_standby"


def main():
    log.info("radiomgrd starting")
    
    if not discover_modems():
        log.error("Modem discovery failed")
        return
    
    while True:
        try:
            metrics = {}
            for name, cfg in CONFIG["modems"].items():
                if cfg["at_port"] and cfg["net_if"]:
                    cell = get_serving_cell(cfg["at_port"]) or {}
                    traffic = get_traffic_stats(cfg["net_if"])
                    metrics[name] = {**cell, **traffic}
            
            STATE["metrics_history"].append(metrics)
            STATE["metrics_history"] = STATE["metrics_history"][-10:]
            
            profile = evaluate()
            apply_profile(profile)
            write_hints()
            
        except Exception as e:
            log.error(f"Error: {e}")
        
        time.sleep(CONFIG["poll_interval_ms"] / 1000)


if __name__ == "__main__":
    main()
