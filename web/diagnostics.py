"""
PathSteer Guardian — Diagnostics & Stats API
"""
import subprocess
import re
import time
import json
import os
from flask import jsonify, request, render_template

WG_TUNNEL_MAP = {
    'ns_fa':     [('wg-fa-cA', '10.200.9.1'),  ('wg-fa-cB', '10.200.10.1')],
    'ns_fb':     [('wg-fb-cA', '10.200.11.1'), ('wg-fb-cB', '10.200.12.1')],
    'ns_sl_a':   [('wg-sa-cA', '10.200.3.1'),  ('wg-sa-cB', '10.200.7.1')],
    'ns_sl_b':   [('wg-sb-cA', '10.200.4.1'),  ('wg-sb-cB', '10.200.8.1')],
    'ns_cell_a': [('wg-ca-cA', '10.200.1.1'),  ('wg-ca-cB', '10.200.5.1')],
    'ns_cell_b': [('wg-cb-cA', '10.200.2.1'),  ('wg-cb-cB', '10.200.6.1')],
}

UPLINK_LABELS = {
    'fa': 'Fiber A', 'fb': 'Fiber B',
    'sl_a': 'Starlink A', 'sl_b': 'Starlink B',
    'cell_a': 'T-Mobile', 'cell_b': 'AT&T',
}

TUNNEL_CONTROLLER = {
    'wg-fa-cA': 'A', 'wg-fa-cB': 'B', 'wg-fb-cA': 'A', 'wg-fb-cB': 'B',
    'wg-sa-cA': 'A', 'wg-sa-cB': 'B', 'wg-sb-cA': 'A', 'wg-sb-cB': 'B',
    'wg-ca-cA': 'A', 'wg-ca-cB': 'B', 'wg-cb-cA': 'A', 'wg-cb-cB': 'B',
}

def _to_bytes(val, unit):
    m = {'B': 1, 'KiB': 1024, 'MiB': 1048576, 'GiB': 1073741824}
    return int(val * m.get(unit, 1))

def _format_bytes(b):
    if b >= 1073741824: return f"{b/1073741824:.2f} GiB"
    if b >= 1048576: return f"{b/1048576:.2f} MiB"
    if b >= 1024: return f"{b/1024:.1f} KiB"
    return f"{b} B"

def _format_duration(sec):
    if sec < 60: return f"{int(sec)}s"
    if sec < 3600: return f"{int(sec//60)}m {int(sec%60)}s"
    if sec < 86400: return f"{int(sec//3600)}h {int((sec%3600)//60)}m"
    return f"{int(sec//86400)}d {int((sec%86400)//3600)}h"

def _parse_wg_show(ns, tunnel):
    try:
        out = subprocess.check_output(
            ['ip', 'netns', 'exec', ns, 'wg', 'show', tunnel],
            text=True, timeout=3, stderr=subprocess.DEVNULL)
    except:
        return None
    r = {'tunnel': tunnel, 'namespace': ns, 'controller': TUNNEL_CONTROLLER.get(tunnel, '?'),
         'peer': '', 'endpoint': '', 'last_handshake_sec': -1,
         'last_handshake_display': 'never', 'tx_bytes': 0, 'rx_bytes': 0, 'allowed_ips': ''}
    for line in out.strip().split('\n'):
        line = line.strip()
        if line.startswith('peer:'): r['peer'] = line.split(':',1)[1].strip()
        elif line.startswith('endpoint:'): r['endpoint'] = line.split(':',1)[1].strip()
        elif line.startswith('allowed ips:'): r['allowed_ips'] = line.split(':',1)[1].strip()
        elif line.startswith('latest handshake:'):
            hs = line.split(':',1)[1].strip()
            r['last_handshake_display'] = hs
            total = 0
            for m in re.finditer(r'(\d+)\s+(hour|minute|second)', hs):
                v = int(m.group(1)); u = m.group(2)
                if u == 'hour': total += v*3600
                elif u == 'minute': total += v*60
                else: total += v
            r['last_handshake_sec'] = total
        elif line.startswith('transfer:'):
            ts = line.split(':',1)[1].strip()
            r['transfer_display'] = ts
            rx_m = re.search(r'([\d.]+)\s+(B|KiB|MiB|GiB)\s+received', ts)
            tx_m = re.search(r'([\d.]+)\s+(B|KiB|MiB|GiB)\s+sent', ts)
            if rx_m: r['rx_bytes'] = _to_bytes(float(rx_m.group(1)), rx_m.group(2))
            if tx_m: r['tx_bytes'] = _to_bytes(float(tx_m.group(1)), tx_m.group(2))
    return r

def _probe_rtt(ns, tunnel, peer_ip):
    try:
        out = subprocess.check_output(
            ['ip', 'netns', 'exec', ns, 'ping', '-c', '3', '-W', '2', '-I', tunnel, peer_ip],
            text=True, timeout=8, stderr=subprocess.DEVNULL)
        m = re.search(r'rtt min/avg/max/mdev = [\d.]+/([\d.]+)/', out)
        if m: return round(float(m.group(1)), 1)
    except: pass
    return None

def get_all_wg_diagnostics(probe=False):
    tunnels = []
    for ns, tun_list in WG_TUNNEL_MAP.items():
        for tname, peer_ip in tun_list:
            info = _parse_wg_show(ns, tname)
            if info is None:
                info = {'tunnel': tname, 'namespace': ns, 'controller': TUNNEL_CONTROLLER.get(tname,'?'),
                        'status': 'DOWN', 'error': 'wg show failed', 'rx_bytes':0, 'tx_bytes':0}
            else:
                hs = info.get('last_handshake_sec', -1)
                info['status'] = 'NO_HANDSHAKE' if hs < 0 else ('STALE' if hs > 180 else 'UP')
                info['rx_display'] = _format_bytes(info['rx_bytes'])
                info['tx_display'] = _format_bytes(info['tx_bytes'])
            if probe:
                info['probe_rtt_ms'] = _probe_rtt(ns, tname, peer_ip)
                info['probe_target'] = peer_ip
            uplink = ns.replace('ns_', '')
            info['uplink'] = uplink
            info['uplink_label'] = UPLINK_LABELS.get(uplink, uplink)
            tunnels.append(info)
    return tunnels

def get_active_path_verification():
    result = {}
    try:
        out = subprocess.check_output(
            ['ip', 'netns', 'exec', 'ns_vip', 'ip', 'route', 'show', 'default'],
            text=True, timeout=2).strip()
        result['ns_vip_default'] = out
        m = re.search(r'dev\s+(\S+)', out)
        dev = m.group(1) if m else 'unknown'
        dm = {'vip_fa':'fa','vip_fb':'fb','vip_sl_a':'sl_a','vip_sl_b':'sl_b',
              'vip_cell_a':'cell_a','vip_cell_b':'cell_b'}
        result['active_from_route'] = dm.get(dev, 'unknown')
        result['has_src'] = 'src 104.204.138.50' in out
        try:
            with open('/run/pathsteer/status.json') as f:
                s = json.load(f)
            result['daemon_says'] = s.get('active_uplink', 'unknown')
            result['match'] = result['active_from_route'] == result['daemon_says']
        except:
            result['daemon_says'] = 'unknown'; result['match'] = False
    except:
        result['error'] = 'Failed to read ns_vip routes'
    return result

def get_namespace_health():
    health = {}
    for ns in ['ns_fa','ns_fb','ns_sl_a','ns_sl_b','ns_cell_a','ns_cell_b','ns_vip']:
        info = {'exists': False}
        try:
            subprocess.check_output(['ip','netns','exec',ns,'ip','link','show','lo'],
                                    text=True, timeout=2, stderr=subprocess.DEVNULL)
            info['exists'] = True
            out = subprocess.check_output(['ip','netns','exec',ns,'ip','link','show'],text=True,timeout=2)
            info['ifaces_up'] = out.count('state UP')
            try: info['ipv4_forward'] = int(subprocess.check_output(['ip','netns','exec',ns,'sysctl','-n','net.ipv4.ip_forward'],text=True,timeout=1).strip())
            except: info['ipv4_forward'] = 0
            try: info['ipv6_forward'] = int(subprocess.check_output(['ip','netns','exec',ns,'sysctl','-n','net.ipv6.conf.all.forwarding'],text=True,timeout=1).strip())
            except: info['ipv6_forward'] = 0
            try:
                nat_out = subprocess.check_output(['ip','netns','exec',ns,'iptables','-t','nat','-L','POSTROUTING','-n'],text=True,timeout=2,stderr=subprocess.DEVNULL)
                info['nat_rules'] = nat_out.count('MASQUERADE') + nat_out.count('SNAT')
            except: info['nat_rules'] = 0
            try:
                nat6_out = subprocess.check_output(['ip','netns','exec',ns,'ip6tables','-t','nat','-L','POSTROUTING','-n'],text=True,timeout=2,stderr=subprocess.DEVNULL)
                info['nat6_rules'] = nat6_out.count('MASQUERADE')
            except: info['nat6_rules'] = 0
        except: pass
        health[ns] = info
    return health

# Enterprise metrics store
METRICS_FILE = '/opt/pathsteer/data/metrics.json'
_metrics = {
    'failover': {'events': [], 'total_tests': 0, 'total_success': 0},
    'stability': {'start_time': time.time(), 'failures': [], 'route_flaps': 0, 'oscillation_events': 0},
    'load': {'samples': []}
}

def _load_metrics():
    global _metrics
    try:
        with open(METRICS_FILE) as f: _metrics.update(json.load(f))
    except: pass
_load_metrics()

def _save_metrics():
    try:
        os.makedirs(os.path.dirname(METRICS_FILE), exist_ok=True)
        with open(METRICS_FILE, 'w') as f: json.dump(_metrics, f, indent=2)
    except: pass

def record_failover_event(detection_ms, convergence_ms, from_uplink, to_uplink, success=True):
    _metrics['failover']['events'].append({
        'timestamp': time.time(), 'detection_ms': detection_ms,
        'convergence_ms': convergence_ms, 'from': from_uplink, 'to': to_uplink, 'success': success})
    _metrics['failover']['total_tests'] += 1
    if success: _metrics['failover']['total_success'] += 1
    _metrics['failover']['events'] = _metrics['failover']['events'][-1000:]
    _save_metrics()

def get_failover_stats():
    events = _metrics['failover']['events']
    if not events:
        return {'total_tests':0,'success_rate':0,'detection_p50':0,'detection_p95':0,'detection_p99':0,
                'convergence_p50':0,'convergence_p95':0,'convergence_p99':0,'worst_total_ms':0,'last_10':[]}
    def pct(arr,p):
        if not arr: return 0
        return arr[min(int(len(arr)*p/100), len(arr)-1)]
    det = sorted([e['detection_ms'] for e in events])
    conv = sorted([e['convergence_ms'] for e in events])
    tot = sorted([e['detection_ms']+e['convergence_ms'] for e in events])
    return {
        'total_tests': len(events),
        'success_rate': round(sum(1 for e in events if e['success'])/len(events)*100, 1),
        'detection_p50': round(pct(det,50),1), 'detection_p95': round(pct(det,95),1), 'detection_p99': round(pct(det,99),1),
        'convergence_p50': round(pct(conv,50),1), 'convergence_p95': round(pct(conv,95),1), 'convergence_p99': round(pct(conv,99),1),
        'worst_total_ms': round(tot[-1],1) if tot else 0, 'last_10': events[-10:]}

def get_stability_stats():
    up = time.time() - _metrics['stability'].get('start_time', time.time())
    fails = _metrics['stability'].get('failures', [])
    down = sum(f.get('duration_sec',0) for f in fails)
    return {
        'uptime_sec': round(up), 'uptime_display': _format_duration(up),
        'availability_pct': round((up-down)/max(up,1)*100, 3),
        'total_failures': len(fails),
        'mtbf_sec': round(up/max(len(fails),1)), 'mtbf_display': _format_duration(up/max(len(fails),1)),
        'mttr_sec': round(down/max(len(fails),1)) if fails else 0,
        'mttr_display': _format_duration(down/max(len(fails),1)) if fails else '0s',
        'route_flaps': _metrics['stability'].get('route_flaps',0),
        'oscillation_events': _metrics['stability'].get('oscillation_events',0)}

def get_load_stats():
    r = {}
    try:
        with open('/proc/loadavg') as f:
            p = f.read().split()
            r['load_1m']=float(p[0]); r['load_5m']=float(p[1]); r['load_15m']=float(p[2])
        with open('/proc/meminfo') as f:
            mem = {}
            for line in f:
                parts = line.split(); mem[parts[0].rstrip(':')] = int(parts[1])
            total = mem.get('MemTotal',1); avail = mem.get('MemAvailable',0)
            r['mem_total_mb'] = round(total/1024); r['mem_used_mb'] = round((total-avail)/1024)
            r['mem_pct'] = round((total-avail)/total*100, 1)
        try:
            out = subprocess.check_output(['grep','cpu ','/proc/stat'], text=True, timeout=1)
            vals = [int(x) for x in out.split()[1:]]
            idle = vals[3]; total_cpu = sum(vals)
            r['cpu_pct'] = round((1 - idle/total_cpu)*100, 1)
        except:
            r['cpu_pct'] = r.get('load_1m',0) * 100 / max(os.cpu_count(),1)
    except: pass
    return r

def register_diagnostics_routes(app):

    @app.route('/api/diagnostics')
    def api_diagnostics():
        probe = request.args.get('probe','false').lower() == 'true'
        return jsonify({'timestamp': time.time(),
            'tunnels': get_all_wg_diagnostics(probe=probe),
            'active_path': get_active_path_verification(),
            'namespaces': get_namespace_health()})

    @app.route('/api/diagnostics/wg')
    def api_diagnostics_wg():
        return jsonify({'timestamp': time.time(), 'tunnels': get_all_wg_diagnostics(probe=False)})

    @app.route('/api/diagnostics/quick')
    def api_diagnostics_quick():
        return jsonify(get_active_path_verification())

    @app.route('/api/diagnostics/probe')
    def api_diagnostics_probe():
        return jsonify({'timestamp': time.time(), 'tunnels': get_all_wg_diagnostics(probe=True)})

    @app.route('/api/metrics')
    def api_metrics():
        return jsonify({'failover': get_failover_stats(), 'stability': get_stability_stats(), 'load': get_load_stats()})

    @app.route('/api/metrics/failover', methods=['POST'])
    def api_record_failover():
        d = request.get_json()
        record_failover_event(d.get('detection_ms',0), d.get('convergence_ms',0),
            d.get('from',''), d.get('to',''), d.get('success',True))
        return jsonify({'status': 'ok'})
