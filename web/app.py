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
DB_PATH = '/opt/pathsteer/data/training.db'

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
            with open('/run/pathsteer/command', 'w') as cf:
                cf.write(cmd)
        return jsonify({'name': name, 'enabled': new_state})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

if __name__ == '__main__':
    # Ensure directories exist
    os.makedirs('/run/pathsteer', exist_ok=True)
    
    # Run with threading for SSE support
    app.run(host='0.0.0.0', port=8080, debug=False, threaded=True)

