#!/usr/bin/env python3
"""
PathSteer Guardian Web UI
Chaos Dashboard with real-time updates

Features:
- Real-time status via SSE
- Manual force-fail per uplink
- Mode switching (Training/Tripwire/Mirror)
- Controller switching (A/B)
- Decision logic feed
- GPS + speed (mph)
- RSSI/Signal displays
"""

import json
import os
import time
import sqlite3
from datetime import datetime
from flask import Flask, render_template, jsonify, request, Response

app = Flask(__name__)

# Map GUI uplink names to daemon internal names
UPLINK_MAP = {'fa': 'fiber1', 'fb': 'fiber2', 'cell_a': 'cell_a', 'cell_b': 'cell_b', 'sl_a': 'sl_a', 'sl_b': 'sl_b'}
UPLINK_MAP_REV = {v: k for k, v in UPLINK_MAP.items()}

def map_uplink(name):
    """Convert GUI name to daemon name"""
    return UPLINK_MAP.get(name, name)


# Paths
STATUS_PATH = '/run/pathsteer/status.json'
COMMAND_PATH = '/run/pathsteer/command'
CONFIG_PATH = os.environ.get('CONFIG_FILE', '/etc/pathsteer/config.json')
DB_PATH = '/opt/pathsteer/data/training.db'

def get_config():
    """Load configuration"""
    try:
        with open(CONFIG_PATH) as f:
            return json.load(f)
    except:
        return {}


# Throughput tracking
_prev_bytes = {}
_prev_time = 0

def get_throughput():
    global _prev_bytes, _prev_time
    import subprocess
    now = time.time()
    try:
        out = subprocess.check_output(
            ["ip", "netns", "exec", "ns_vip", "cat", "/proc/net/dev"],
            text=True, timeout=1)
    except:
        return 0, 0
    curr = {}
    for line in out.strip().split("\n"):
        if ":" not in line or "face" in line:
            continue
        iface, data = line.split(":", 1)
        iface = iface.strip()
        if iface.startswith("vip_"):
            fields = data.split()
            curr[iface] = {"rx": int(fields[0]), "tx": int(fields[8])}
    total_rx = sum(v["rx"] for v in curr.values())
    total_tx = sum(v["tx"] for v in curr.values())
    dt = now - _prev_time if _prev_time > 0 else 1
    prev_rx = sum(v.get("rx", 0) for v in _prev_bytes.values())
    prev_tx = sum(v.get("tx", 0) for v in _prev_bytes.values())
    down_mbps = ((total_rx - prev_rx) * 8 / dt / 1000000) if _prev_time > 0 else 0
    up_mbps = ((total_tx - prev_tx) * 8 / dt / 1000000) if _prev_time > 0 else 0
    _prev_bytes = curr
    _prev_time = now
    return max(0, round(down_mbps, 2)), max(0, round(up_mbps, 2))

def get_status():
    """Read current status from daemon"""
    try:
        with open(STATUS_PATH) as f:
            status = json.load(f)
            # Add config info
            config = get_config()
            status['node_id'] = config.get('node', {}).get('id', 'unknown')
            down, up = get_throughput()
            status["throughput_down_mbps"] = down
            status["throughput_up_mbps"] = up
            status['topology_mode'] = config.get('topology_mode', 'chaos')
            # Merge GPS data
            try:
                with open('/run/pathsteer/gps.json') as gf:
                    gps_data = json.load(gf)
                    status['gps'] = {'valid': gps_data.get('fix', False), 'lat': gps_data.get('lat', 0), 'lon': gps_data.get('lon', 0), 'speed_mph': 0, 'heading': 0}
            except:
                pass
            return status
    except:
        return {
            'mode': 'OFFLINE',
            'state': 'OFFLINE',
            'trigger': 'none',
            'active_uplink': 'unknown',
            'dup_enabled': False,
            'hold_remaining': 0,
            'clean_remaining': 0,
            'flap_suppressed': False,
            'global_risk': 0,
            'recommendation': 'OFFLINE',
            'run_id': '--',
            'node_id': 'offline',
            'gps': {'valid': False, 'lat': 0, 'lon': 0, 'speed_mph': 0, 'heading': 0},
            'uplinks': []
        }

def send_command(cmd):
    """Send command to daemon"""
    try:
        os.makedirs('/run/pathsteer', exist_ok=True)
        with open(COMMAND_PATH, 'w') as f:
            f.write(cmd + '\n')
        return True
    except Exception as e:
        print(f"Command error: {e}")
        return False

# Routes
@app.route('/')
def index():
    config = get_config()
    return render_template('index.html', config=config)

@app.route('/api/status')
def api_status():
    return jsonify(get_status())

@app.route('/api/config')
def api_config():
    return jsonify(get_config())

@app.route('/api/stream')
def api_stream():
    """Server-sent events for real-time updates"""
    def generate():
        while True:
            status = get_status()
            yield f"data: {json.dumps(status)}\n\n"
            time.sleep(0.1)  # 10 Hz
    return Response(generate(), mimetype='text/event-stream',
                   headers={'Cache-Control': 'no-cache', 'X-Accel-Buffering': 'no'})

@app.route('/api/control/mode', methods=['POST'])
def api_set_mode():
    """Set operating mode: training, tripwire, mirror"""
    data = request.get_json()
    mode = data.get('mode', 'tripwire')
    if mode in ['training', 'tripwire', 'mirror']:
        send_command(f'mode:{mode}')
        return jsonify({'status': 'ok', 'mode': mode})
    return jsonify({'error': 'Invalid mode'}), 400

@app.route('/api/control/force', methods=['POST'])
def api_force_uplink():
    """Force switch to specific uplink"""
    data = request.get_json()
    uplink = data.get('uplink', 'auto')
    send_command(f'force:{map_uplink(uplink)}')
    return jsonify({'status': 'ok', 'uplink': uplink})

@app.route('/api/control/fail', methods=['POST'])
def api_force_fail():
    """Force fail an uplink (trigger protection)"""
    data = request.get_json()
    uplink = data.get('uplink')
    send_command(f'fail:{map_uplink(uplink)}')
    return jsonify({'status': 'ok', 'uplink': uplink, 'action': 'force_fail'})

@app.route('/api/control/trigger', methods=['POST'])
def api_trigger():
    """Manually trigger protection mode"""
    send_command('trigger')
    return jsonify({'status': 'ok', 'action': 'trigger_protection'})

@app.route('/api/control/controller', methods=['POST'])
def api_switch_controller():
    """Switch active controller (A/B) via C8000"""
    data = request.get_json()
    ctrl = data.get('controller', 0)
    send_command(f'c8000:{ctrl}')
    return jsonify({'status': 'ok', 'controller': ctrl})

@app.route('/api/events')
def api_events():
    """Get recent events from database"""
    limit = request.args.get('limit', 50, type=int)
    try:
        conn = sqlite3.connect(DB_PATH)
        cursor = conn.cursor()
        cursor.execute('''
            SELECT timestamp, event_type, trigger, description, latitude, longitude
            FROM events ORDER BY timestamp DESC LIMIT ?
        ''', (limit,))
        rows = cursor.fetchall()
        conn.close()
        return jsonify([{
            'timestamp': r[0], 'type': r[1], 'trigger': r[2],
            'description': r[3], 'lat': r[4], 'lon': r[5]
        } for r in rows])
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/heatmap')
def api_heatmap():
    """Get GPS + signal data for heat map"""
    hours = request.args.get('hours', 24, type=int)
    uplink = request.args.get('uplink', None)
    try:
        conn = sqlite3.connect(DB_PATH)
        cursor = conn.cursor()
        
        query = '''
            SELECT lat, lon, risk, active_uplink, 
                   cell_a_rsrp, cell_a_sinr, cell_a_rtt, cell_b_rsrp, cell_b_sinr, cell_b_rtt, speed
            FROM samples 
            WHERE lat IS NOT NULL AND lat != 0
              AND timestamp > datetime('now', '-' || ? || ' hours')
        '''
        params = [hours]
        
        if uplink:
            query += ' AND uplink = ?'
            params.append(uplink)
            
        query += ' ORDER BY timestamp DESC LIMIT 5000'
        
        cursor.execute(query, params)
        rows = cursor.fetchall()
        conn.close()
        
        results = []
        for r in rows:
            if not r[0] or not r[1]:
                continue
            uplink = r[3]
            # cell_a=TMO (index 4,5,6), cell_b=ATT (index 7,8,9)
            if uplink == 'cell_a':
                rsrp, sinr, rtt = r[4], r[5], r[6]
            elif uplink == 'cell_b':
                rsrp, sinr, rtt = r[7], r[8], r[9]
            else:
                rsrp, sinr, rtt = 0, 0, r[6] or r[9] or 0
            results.append({
                'lat': r[0], 'lng': r[1], 'risk': r[2] or 0,
                'uplink': uplink, 'rsrp': rsrp, 'sinr': sinr,
                'rtt': rtt, 'speed': r[10]
            })
        return jsonify(results)
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/risk_zones')
def api_risk_zones():
    """Get learned risk zones"""
    try:
        conn = sqlite3.connect(DB_PATH)
        cursor = conn.cursor()
        cursor.execute('''
            SELECT latitude, longitude, uplink, risk_score, sample_count,
                   heading_min, heading_max
            FROM risk_zones WHERE risk_score > 0.3
            ORDER BY risk_score DESC LIMIT 500
        ''')
        rows = cursor.fetchall()
        conn.close()
        return jsonify([{
            'lat': r[0], 'lng': r[1], 'uplink': r[2],
            'risk': r[3], 'samples': r[4],
            'heading_min': r[5], 'heading_max': r[6]
        } for r in rows])
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/uplink/toggle', methods=['POST'])
def toggle_uplink():
    """Toggle uplink enabled state"""
    data = request.get_json()
    name = data.get('name')
    config_path = '/etc/pathsteer/config.json'
    try:
        with open(config_path, 'r') as f:
            config = json.load(f)
        new_state = False
        if name in config.get('uplinks', {}):
            current = config['uplinks'][name].get('enabled', True)
            config['uplinks'][name]['enabled'] = not current
            new_state = config['uplinks'][name]['enabled']
            with open(config_path, 'w') as f:
                json.dump(config, f, indent=2)
            # Write command for daemon
            cmd = 'enable:' + name if new_state else 'disable:' + name
            send_command(cmd)
        return jsonify({'name': name, 'enabled': new_state})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

# =============================================================================
# CHAOS CONTROL PANEL ROUTES
# =============================================================================

# Store chaos injection state
chaos_state = {}
pcap_process = None
pcap_file = None

@app.route('/demo')
def chaos_panel():
    """Chaos Control Panel for demos"""
    return render_template('chaos.html')

@app.route('/api/chaos/inject', methods=['POST'])
def api_chaos_inject():
    """Inject chaos (RTT/jitter/loss) into an uplink"""
    global chaos_state
    data = request.get_json()
    uplink = data.get('uplink')
    rtt = data.get('rtt', 0)
    jitter = data.get('jitter', 0)
    loss = data.get('loss', 0)
    
    chaos_state[uplink] = {'rtt': rtt, 'jitter': jitter, 'loss': loss}
    
    # Write to file for daemon to read
    chaos_file = '/run/pathsteer/chaos.json'
    with open(chaos_file, 'w') as f:
        json.dump(chaos_state, f)
    
    return jsonify({'status': 'ok', 'uplink': uplink, 'chaos': chaos_state[uplink]})

@app.route('/api/chaos/reset', methods=['POST'])
def api_chaos_reset():
    """Reset all chaos injection"""
    global chaos_state
    chaos_state = {}
    chaos_file = '/run/pathsteer/chaos.json'
    with open(chaos_file, 'w') as f:
        json.dump({}, f)
    return jsonify({'status': 'ok'})

@app.route('/api/pcap/start', methods=['POST'])
def api_pcap_start():
    """Start packet capture"""
    global pcap_process, pcap_file
    import subprocess
    from datetime import datetime
    
    data = request.get_json()
    duration = data.get('duration', 60)
    
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    pcap_file = f'chaos_{timestamp}.pcap'
    pcap_path = f'/opt/pathsteer/data/pcaps/{pcap_file}'
    
    os.makedirs('/opt/pathsteer/data/pcaps', exist_ok=True)
    
    # Capture on all interfaces
    cmd = ['tcpdump', '-i', 'any', '-w', pcap_path]
    if duration > 0:
        cmd.extend(['-G', str(duration), '-W', '1'])
    
    pcap_process = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return jsonify({'status': 'recording', 'file': pcap_file})

@app.route('/api/pcap/stop', methods=['POST'])
def api_pcap_stop():
    """Stop packet capture"""
    global pcap_process, pcap_file
    import subprocess
    
    if pcap_process:
        pcap_process.terminate()
        pcap_process.wait()
        pcap_process = None
    
    return jsonify({'status': 'stopped', 'file': pcap_file})

@app.route('/api/pcap/download/<filename>')
def api_pcap_download(filename):
    """Download PCAP file"""
    from flask import send_file
    pcap_path = f'/opt/pathsteer/data/pcaps/{filename}'
    if os.path.exists(pcap_path):
        return send_file(pcap_path, as_attachment=True)
    return jsonify({'error': 'File not found'}), 404


# =============================================================================
# PERSISTENT EVENTS API
# =============================================================================

@app.route('/api/events/log', methods=['POST'])
def api_log_event():
    """Log an event to persistent storage"""
    data = request.get_json()
    event_type = data.get('type', 'info')
    message = data.get('message', '')
    detail = data.get('detail', '')
    
    try:
        conn = sqlite3.connect(DB_PATH)
        cursor = conn.cursor()
        cursor.execute(
            'INSERT INTO events (type, message, detail) VALUES (?, ?, ?)',
            (event_type, message, detail)
        )
        conn.commit()
        conn.close()
        return jsonify({'status': 'ok'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/events/history')
def api_events_history():
    """Get event history"""
    limit = request.args.get('limit', 100, type=int)
    event_type = request.args.get('type', None)
    
    try:
        conn = sqlite3.connect(DB_PATH)
        cursor = conn.cursor()
        
        query = 'SELECT timestamp, type, message, detail FROM events'
        params = []
        
        if event_type:
            query += ' WHERE type = ?'
            params.append(event_type)
        
        query += ' ORDER BY timestamp DESC LIMIT ?'
        params.append(limit)
        
        cursor.execute(query, params)
        rows = cursor.fetchall()
        conn.close()
        
        events = [{'timestamp': r[0], 'type': r[1], 'message': r[2], 'detail': r[3]} for r in rows]
        return jsonify(events)
    except Exception as e:
        return jsonify({'error': str(e)}), 500


# =============================================================================
# SETTINGS PAGE
# =============================================================================

SETTINGS_FILE = '/opt/pathsteer/data/settings.json'
DEFAULT_SETTINGS = {
    'rtt_spike_pct': 50,
    'loss_threshold_pct': 10,
    'rsrp_drop_db': 10,
    'consec_fail_threshold': 3,
    'probe_interval_sec': 1,
    'preroll_ms': 200,
    'min_hold_sec': 10,
    'clean_exit_sec': 5,
    'controller_a': '10.42.0.1',
    'controller_b': '10.42.0.2',
    'c8000_enabled': False,
    'gps_sample_interval': 5,
    'data_retention_days': 14
}

@app.route('/settings')
def settings_page():
    return render_template('settings.html')

@app.route('/api/settings', methods=['GET'])
def api_get_settings():
    try:
        with open(SETTINGS_FILE, 'r') as f:
            return jsonify(json.load(f))
    except:
        return jsonify(DEFAULT_SETTINGS)

@app.route('/api/settings', methods=['POST'])
def api_save_settings():
    settings = request.get_json()
    os.makedirs(os.path.dirname(SETTINGS_FILE), exist_ok=True)
    with open(SETTINGS_FILE, 'w') as f:
        json.dump(settings, f, indent=2)
    return jsonify({'status': 'ok'})

@app.route('/api/settings/defaults', methods=['POST'])
def api_restore_defaults():
    with open(SETTINGS_FILE, 'w') as f:
        json.dump(DEFAULT_SETTINGS, f, indent=2)
    return jsonify({'status': 'ok'})


# =============================================================================
# CONFIG API
# =============================================================================

CONFIG_FILE = '/opt/pathsteer/data/config.json'

@app.route('/api/config')
def api_get_config():
    try:
        with open(CONFIG_FILE, 'r') as f:
            return jsonify(json.load(f))
    except:
        return jsonify({"deployment_type": "mobile", "show_map": True})

@app.route('/api/config', methods=['POST'])
def api_save_config():
    config = request.get_json()
    with open(CONFIG_FILE, 'w') as f:
        json.dump(config, f, indent=2)
    return jsonify({'status': 'ok'})



# RF Mitigation state
rf_mitigation_enabled = False

@app.route('/api/radio/mitigation', methods=['GET', 'POST'])
def api_radio_mitigation():
    """Get or set RF mitigation status"""
    global rf_mitigation_enabled
    
    if request.method == 'POST':
        data = request.get_json()
        rf_mitigation_enabled = data.get('enabled', False)
        
        # Call the actual mitigation script
        import subprocess
        if rf_mitigation_enabled:
            subprocess.run(['/opt/pathsteer/scripts/rf-mitigation.sh', 'enable'], capture_output=True)
        else:
            subprocess.run(['/opt/pathsteer/scripts/rf-mitigation.sh', 'disable'], capture_output=True)
        
        return jsonify({'status': 'ok', 'enabled': rf_mitigation_enabled})
    
    return jsonify({'enabled': rf_mitigation_enabled})


# =============================================================================
# LLM TEST API
# =============================================================================
import threading
import requests as http_requests

llm_state = {
    'running': False,
    'prompt': 'Write a short poem about network resilience',
    'total_tokens': 0,
    'total_requests': 0,
    'tokens_per_sec': 0.0,
    'last_response': '', 'full_log': '',
    'loop_count': 0,
    'loops_done': 0,
    'errors': 0,
    'target': 'http://104.204.136.12:8080'
}
llm_lock = threading.Lock()
llm_thread = None

def llm_worker():
    global llm_state
    while True:
        with llm_lock:
            if not llm_state['running']:
                break
            if llm_state['loop_count'] > 0 and llm_state['loops_done'] >= llm_state['loop_count']:
                llm_state['running'] = False
                break
            prompt = llm_state['prompt']
            target = llm_state['target']
        try:
            start = time.time()
            resp = http_requests.post(f"{target}/v1/completions",
                json={'prompt': prompt, 'max_tokens': 128, 'temperature': 0.7, 'stream': False},
                timeout=30)
            elapsed = time.time() - start
            data = resp.json()
            tokens = data.get('usage', {}).get('completion_tokens', 0)
            text = data['choices'][0].get('text', '') if data.get('choices') else ''
            tps = tokens / elapsed if elapsed > 0 else 0
            with llm_lock:
                llm_state['total_tokens'] += tokens
                llm_state['total_requests'] += 1
                llm_state['tokens_per_sec'] = round(tps, 1)
                llm_state['last_response'] = text[:200]; llm_state['full_log'] += text + '\n---\n'
                llm_state['loops_done'] += 1
        except Exception as e:
            with llm_lock:
                llm_state['errors'] += 1
                llm_state['last_response'] = f'ERROR: {str(e)[:100]}'
        time.sleep(0.5)

@app.route('/api/llm/start', methods=['POST'])
def api_llm_start():
    global llm_thread, llm_state
    data = request.get_json() or {}
    with llm_lock:
        if llm_state['running']:
            return jsonify({'status': 'already running'})
        llm_state['running'] = True
        llm_state['prompt'] = data.get('prompt', llm_state['prompt'])
        llm_state['loop_count'] = data.get('loop_count', 0)
        llm_state['loops_done'] = 0
        llm_state['total_tokens'] = 0
        llm_state['total_requests'] = 0
        llm_state['errors'] = 0; llm_state['full_log'] = ''
    llm_thread = threading.Thread(target=llm_worker, daemon=True)
    llm_thread.start()
    return jsonify({'status': 'started'})

@app.route('/api/llm/stop', methods=['POST'])
def api_llm_stop():
    global llm_state
    with llm_lock:
        llm_state['running'] = False
    return jsonify({'status': 'stopped'})

@app.route('/api/llm/status')
def api_llm_status():
    with llm_lock:
        return jsonify(dict(llm_state))
@app.route('/api/sip/status')

@app.route('/api/flows')
def api_flows():
    try:
        with open('/run/pathsteer/flows.json', 'r') as f:
            return jsonify(json.load(f))
    except:
        return jsonify({'active_flows': 0, 'flows': [], 'sip_calls': []})

@app.route('/api/sip/status')
def api_sip_status():
    try:
        with open('/run/pathsteer/sip.json', 'r') as f:
            return jsonify(json.load(f))
    except:
        return jsonify({'active_calls': 0, 'calls': [], 'regs': []})

# =============================================================================
# EVENT LOG API
# =============================================================================
EVENT_LOG = '/opt/pathsteer/data/logs/events.jsonl'

@app.route('/api/log/write', methods=['POST'])
def api_log_write():
    """Write event from frontend to persistent log"""
    data = request.get_json()
    data['server_time'] = datetime.utcnow().isoformat() + 'Z'
    try:
        with open(EVENT_LOG, 'a') as f:
            f.write(json.dumps(data) + '\n')
    except: pass
    return jsonify({'status': 'ok'})

@app.route('/api/log/query')
def api_log_query():
    """Query events by timestamp range"""
    start = request.args.get('start', '')
    end = request.args.get('end', '')
    etype = request.args.get('type', 'all')
    limit = int(request.args.get('limit', '500'))
    events = []
    try:
        with open(EVENT_LOG, 'r') as f:
            for line in f:
                try:
                    e = json.loads(line.strip())
                    if start and e.get('server_time', '') < start: continue
                    if end and e.get('server_time', '') > end: continue
                    if etype != 'all' and e.get('type', '') != etype: continue
                    events.append(e)
                except: pass
    except FileNotFoundError: pass
    return jsonify({'events': events[-limit:]})

@app.route('/api/log/status')
def api_log_status_json():
    """Read latest daemon status with full uplink details"""
    try:
        with open('/run/pathsteer/status.json', 'r') as f:
            return jsonify(json.load(f))
    except:
        return jsonify({})

if __name__ == '__main__':
    # Ensure directories exist
    os.makedirs('/run/pathsteer', exist_ok=True)
    os.makedirs('/opt/pathsteer/data/logs', exist_ok=True)
    app.run(host='0.0.0.0', port=8080, debug=False, threaded=True)
