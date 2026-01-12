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

# Paths
STATUS_PATH = '/run/pathsteer/status.json'
COMMAND_PATH = '/run/pathsteer/command'
CONFIG_PATH = os.environ.get('CONFIG_FILE', '/etc/pathsteer/config.json')
DB_PATH = '/var/lib/pathsteer/training.db'

def get_config():
    """Load configuration"""
    try:
        with open(CONFIG_PATH) as f:
            return json.load(f)
    except:
        return {}

def get_status():
    """Read current status from daemon"""
    try:
        with open(STATUS_PATH) as f:
            status = json.load(f)
            # Add config info
            config = get_config()
            status['node_id'] = config.get('node', {}).get('id', 'unknown')
            status['topology_mode'] = config.get('topology_mode', 'chaos')
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
    send_command(f'force:{uplink}')
    return jsonify({'status': 'ok', 'uplink': uplink})

@app.route('/api/control/fail', methods=['POST'])
def api_force_fail():
    """Force fail an uplink (trigger protection)"""
    data = request.get_json()
    uplink = data.get('uplink')
    send_command(f'fail:{uplink}')
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
            SELECT latitude, longitude, risk_now, uplink, 
                   rsrp, sinr, rtt_ms, speed_mps
            FROM measurements 
            WHERE latitude IS NOT NULL AND latitude != 0
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
        
        return jsonify([{
            'lat': r[0], 'lng': r[1], 'risk': r[2] or 0,
            'uplink': r[3], 'rsrp': r[4], 'sinr': r[5],
            'rtt': r[6], 'speed': r[7]
        } for r in rows if r[0] and r[1]])
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

if __name__ == '__main__':
    # Ensure directories exist
    os.makedirs('/run/pathsteer', exist_ok=True)
    
    # Run with threading for SSE support
    app.run(host='0.0.0.0', port=8080, debug=False, threaded=True)

@app.route('/api/uplink/toggle', methods=['POST'])
def toggle_uplink():
    data = request.get_json()
    name = data.get('name')
    
    # Load config
    with open('/opt/pathsteer/config/config.edge.json', 'r') as f:
        config = json.load(f)
    
    # Toggle enabled state
    for uplink in config.get('uplinks', []):
        if uplink.get('name') == name:
            uplink['enabled'] = not uplink.get('enabled', True)
            new_state = uplink['enabled']
            break
    
    # Save config
    with open('/opt/pathsteer/config/config.edge.json', 'w') as f:
        json.dump(config, f, indent=2)
    
    # Signal daemon to reload (optional)
    os.system('systemctl reload pathsteerd 2>/dev/null || true')
    
    return jsonify({'name': name, 'enabled': new_state})

@app.route('/api/chaos/apply', methods=['POST'])
def apply_chaos():
    """Apply network impairment via tc"""
    data = request.get_json()
    interface = data.get('interface', 'enp1s0')  # fiber interface in ns_fa
    delay_ms = data.get('delay', 0)
    jitter_ms = data.get('jitter', 0)
    loss_pct = data.get('loss', 0)
    namespace = data.get('namespace', 'ns_fa')
    
    # Clear existing
    os.system(f'ip netns exec {namespace} tc qdisc del dev {interface} root 2>/dev/null')
    
    if delay_ms > 0 or jitter_ms > 0 or loss_pct > 0:
        # Apply netem
        cmd = f'ip netns exec {namespace} tc qdisc add dev {interface} root netem'
        if delay_ms > 0:
            cmd += f' delay {delay_ms}ms'
            if jitter_ms > 0:
                cmd += f' {jitter_ms}ms'
        if loss_pct > 0:
            cmd += f' loss {loss_pct}%'
        
        os.system(cmd)
        return jsonify({'status': 'chaos applied', 'cmd': cmd})
    
    return jsonify({'status': 'chaos cleared'})

@app.route('/api/chaos/clear', methods=['POST'])
def clear_chaos():
    """Clear all impairments"""
    for ns in ['ns_fa', 'ns_fb', 'ns_sl_a', 'ns_sl_b']:
        os.system(f'ip netns exec {ns} tc qdisc del dev enp1s0 root 2>/dev/null')
        os.system(f'ip netns exec {ns} tc qdisc del dev enp2s0 root 2>/dev/null')
    # Main namespace cellular
    os.system('tc qdisc del dev wwan0 root 2>/dev/null')
    os.system('tc qdisc del dev wwan1 root 2>/dev/null')
    return jsonify({'status': 'all chaos cleared'})
