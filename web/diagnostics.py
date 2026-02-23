"""PathSteer Guardian - Diagnostics & Stats API (Blueprint)"""
import subprocess, re, time, json, os, threading
from flask import Blueprint, jsonify, request, render_template

diag_bp = Blueprint('diagnostics', __name__)

WG_TUNNEL_MAP = {
    'ns_fa':     [('wg-fa-cA', '10.200.9.1'),  ('wg-fa-cB', '10.200.10.1')],
    'ns_fb':     [('wg-fb-cA', '10.200.11.1'), ('wg-fb-cB', '10.200.12.1')],
    'ns_sl_a':   [('wg-sa-cA', '10.200.3.1'),  ('wg-sa-cB', '10.200.7.1')],
    'ns_sl_b':   [('wg-sb-cA', '10.200.4.1'),  ('wg-sb-cB', '10.200.8.1')],
    'ns_cell_a': [('wg-ca-cA', '10.200.1.1'),  ('wg-ca-cB', '10.200.5.1')],
    'ns_cell_b': [('wg-cb-cA', '10.200.2.1'),  ('wg-cb-cB', '10.200.6.1')],
}
UPLINK_LABELS = {'fa':'Fiber A','fb':'Fiber B','sl_a':'Starlink A','sl_b':'Starlink B','cell_a':'T-Mobile','cell_b':'AT&T'}
TUNNEL_CONTROLLER = {'wg-fa-cA':'A','wg-fa-cB':'B','wg-fb-cA':'A','wg-fb-cB':'B','wg-sa-cA':'A','wg-sa-cB':'B','wg-sb-cA':'A','wg-sb-cB':'B','wg-ca-cA':'A','wg-ca-cB':'B','wg-cb-cA':'A','wg-cb-cB':'B'}

# --- Throughput sampling ---
_throughput_lock = threading.Lock()
_throughput_samples = []  # list of {timestamp, uplink, rx_bps, tx_bps}
_prev_bytes = {}  # key: "ns/tun" -> {rx, tx, ts}

def _sample_throughput():
    """Read WG byte counters and compute rates"""
    global _prev_bytes
    now = time.time()
    samples = []
    for ns, tun_list in WG_TUNNEL_MAP.items():
        for tname, _ in tun_list:
            key = f"{ns}/{tname}"
            try:
                rx = int(subprocess.check_output(
                    ['ip','netns','exec',ns,'cat',f'/sys/class/net/{tname}/statistics/rx_bytes'],
                    text=True, timeout=2).strip())
                tx = int(subprocess.check_output(
                    ['ip','netns','exec',ns,'cat',f'/sys/class/net/{tname}/statistics/tx_bytes'],
                    text=True, timeout=2).strip())
            except:
                continue
            if key in _prev_bytes:
                prev = _prev_bytes[key]
                dt = now - prev['ts']
                if dt > 0:
                    rx_bps = (rx - prev['rx']) * 8 / dt
                    tx_bps = (tx - prev['tx']) * 8 / dt
                    if rx_bps >= 0 and tx_bps >= 0:
                        samples.append({
                            'tunnel': tname, 'namespace': ns,
                            'uplink': ns.replace('ns_',''),
                            'rx_bps': round(rx_bps), 'tx_bps': round(tx_bps),
                            'rx_mbps': round(rx_bps/1e6, 2), 'tx_mbps': round(tx_bps/1e6, 2),
                        })
            _prev_bytes[key] = {'rx': rx, 'tx': tx, 'ts': now}
    with _throughput_lock:
        _throughput_samples.append({'timestamp': now, 'tunnels': samples})
        if len(_throughput_samples) > 300:
            _throughput_samples[:] = _throughput_samples[-300:]
    return samples

def _bg_sampler():
    while True:
        try:
            _sample_throughput()
        except:
            pass
        time.sleep(2)

_sampler_thread = threading.Thread(target=_bg_sampler, daemon=True)
_sampler_thread.start()

# --- Helpers ---
def _to_bytes(v,u):
    m={'B':1,'KiB':1024,'MiB':1048576,'GiB':1073741824}
    return int(v*m.get(u,1))

def _format_bytes(b):
    if b>=1073741824: return f"{b/1073741824:.2f} GiB"
    if b>=1048576: return f"{b/1048576:.2f} MiB"
    if b>=1024: return f"{b/1024:.1f} KiB"
    return f"{b} B"

def _parse_wg_show(ns, tunnel):
    try:
        out=subprocess.check_output(['ip','netns','exec',ns,'wg','show',tunnel],text=True,timeout=3,stderr=subprocess.DEVNULL)
    except:
        return None
    r={'tunnel':tunnel,'namespace':ns,'controller':TUNNEL_CONTROLLER.get(tunnel,'?'),'peer':'','endpoint':'','last_handshake_sec':-1,'last_handshake_display':'never','tx_bytes':0,'rx_bytes':0,'allowed_ips':''}
    for line in out.strip().split('\n'):
        line=line.strip()
        if line.startswith('peer:'): r['peer']=line.split(':',1)[1].strip()
        elif line.startswith('endpoint:'): r['endpoint']=line.split(':',1)[1].strip()
        elif line.startswith('allowed ips:'): r['allowed_ips']=line.split(':',1)[1].strip()
        elif line.startswith('latest handshake:'):
            hs=line.split(':',1)[1].strip(); r['last_handshake_display']=hs; total=0
            for m in re.finditer(r'(\d+)\s+(hour|minute|second)',hs):
                v,u=int(m.group(1)),m.group(2); total+=v*3600 if u=='hour' else v*60 if u=='minute' else v
            r['last_handshake_sec']=total
        elif line.startswith('transfer:'):
            ts=line.split(':',1)[1].strip(); r['transfer_display']=ts
            rx=re.search(r'([\d.]+)\s+(B|KiB|MiB|GiB)\s+received',ts)
            tx=re.search(r'([\d.]+)\s+(B|KiB|MiB|GiB)\s+sent',ts)
            if rx: r['rx_bytes']=_to_bytes(float(rx.group(1)),rx.group(2))
            if tx: r['tx_bytes']=_to_bytes(float(tx.group(1)),tx.group(2))
    return r

def get_all_wg_diagnostics():
    tunnels=[]
    for ns,tun_list in WG_TUNNEL_MAP.items():
        for tname,peer_ip in tun_list:
            info=_parse_wg_show(ns,tname)
            if info is None:
                info={'tunnel':tname,'namespace':ns,'controller':TUNNEL_CONTROLLER.get(tname,'?'),'status':'DOWN','error':'wg show failed','rx_bytes':0,'tx_bytes':0}
            else:
                hs=info.get('last_handshake_sec',-1)
                info['status']='NO_HANDSHAKE' if hs<0 else ('STALE' if hs>180 else 'UP')
                info['rx_display']=_format_bytes(info['rx_bytes'])
                info['tx_display']=_format_bytes(info['tx_bytes'])
            uplink=ns.replace('ns_','')
            info['uplink']=uplink
            info['uplink_label']=UPLINK_LABELS.get(uplink,uplink)
            tunnels.append(info)
    return tunnels

def get_active_path():
    result={}
    try:
        out=subprocess.check_output(['ip','netns','exec','ns_vip','ip','route','show','default'],text=True,timeout=2).strip()
        result['ns_vip_default']=out
        m=re.search(r'dev\s+(\S+)',out); dev=m.group(1) if m else 'unknown'
        dm={'vip_fa':'fa','vip_fb':'fb','vip_sl_a':'sl_a','vip_sl_b':'sl_b','vip_cell_a':'cell_a','vip_cell_b':'cell_b'}
        result['active_from_route']=dm.get(dev,'unknown')
        result['has_src']='src 104.204.138.50' in out
    except:
        result['error']='Failed'
    return result

def get_namespace_health():
    health={}
    for ns in ['ns_fa','ns_fb','ns_sl_a','ns_sl_b','ns_cell_a','ns_cell_b','ns_vip']:
        info={'exists':False}
        try:
            subprocess.check_output(['ip','netns','exec',ns,'ip','link','show','lo'],text=True,timeout=2,stderr=subprocess.DEVNULL)
            info['exists']=True
            out=subprocess.check_output(['ip','netns','exec',ns,'ip','link','show'],text=True,timeout=2)
            info['ifaces_up']=out.count('state UP')
            try: info['ipv4_forward']=int(subprocess.check_output(['ip','netns','exec',ns,'sysctl','-n','net.ipv4.ip_forward'],text=True,timeout=1).strip())
            except: info['ipv4_forward']=0
            try: info['ipv6_forward']=int(subprocess.check_output(['ip','netns','exec',ns,'sysctl','-n','net.ipv6.conf.all.forwarding'],text=True,timeout=1).strip())
            except: info['ipv6_forward']=0
        except:
            pass
        health[ns]=info
    return health

# === Routes ===
@diag_bp.route('/')
def diag_index():
    return render_template('stats.html')

@diag_bp.route('/api/tunnels')
def diag_tunnels():
    return jsonify({'timestamp':time.time(),'tunnels':get_all_wg_diagnostics()})

@diag_bp.route('/api/path')
def diag_path():
    return jsonify(get_active_path())

@diag_bp.route('/api/namespaces')
def diag_namespaces():
    return jsonify(get_namespace_health())

@diag_bp.route('/api/throughput')
def diag_throughput():
    with _throughput_lock:
        recent = _throughput_samples[-30:] if _throughput_samples else []
    return jsonify({'samples': recent})

@diag_bp.route('/api/throughput/now')
def diag_throughput_now():
    s = _sample_throughput()
    return jsonify({'timestamp': time.time(), 'tunnels': s})
