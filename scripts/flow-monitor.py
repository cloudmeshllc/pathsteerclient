#!/usr/bin/env python3
"""
PathSteer Flow Monitor
Tracks ALL active sessions through ns_vip:
- SIP (unencrypted): full call details, called/calling, Call-ID
- WebRTC/SRTP: UDP flow tracking, packet rates
- HTTPS/WebSocket: TCP session tracking
- Any persistent flow

Writes to /run/pathsteer/flows.json
"""
import subprocess
import re
import json
import time
import os
import threading
from collections import defaultdict

FLOW_FILE = '/run/pathsteer/flows.json'
SIP_FILE = '/run/pathsteer/sip.json'

lock = threading.Lock()

# SIP calls (unencrypted only)
sip_calls = {}
sip_regs = {}

# All flows: keyed by (proto, src_ip, src_port, dst_ip, dst_port)
flows = {}
failover_count = 0
prev_active = None

# Known service signatures
SERVICES = {
    (443, 'tcp'): 'HTTPS/WSS',
    (5060, 'udp'): 'SIP',
    (5060, 'tcp'): 'SIP-TCP',
    (5061, 'tcp'): 'SIP-TLS',
    (8443, 'tcp'): 'WebRTC-Sig',
}

def identify_service(dst_port, proto, dst_ip):
    """Identify the service based on port and destination"""
    key = (dst_port, proto)
    if key in SERVICES:
        return SERVICES[key]
    # RTP is even UDP ports in 16384-32767 range
    if proto == 'udp' and 16384 <= dst_port <= 32767 and dst_port % 2 == 0:
        return 'RTP/SRTP'
    # RTCP is odd port right after RTP
    if proto == 'udp' and 16384 <= dst_port <= 32767 and dst_port % 2 == 1:
        return 'RTCP'
    # High UDP could be STUN/TURN/WebRTC
    if proto == 'udp' and dst_port > 10000:
        return 'UDP-Media'
    # AWS ranges
    if dst_ip.startswith('52.') or dst_ip.startswith('54.') or dst_ip.startswith('3.'):
        return f'AWS:{dst_port}'
    # Webex
    if dst_ip.startswith('170.') or dst_ip.startswith('173.'):
        return f'Webex:{dst_port}'
    return f'{proto.upper()}:{dst_port}'

def flow_key(proto, src_ip, src_port, dst_ip, dst_port):
    # Normalize: always use the lower IP as first
    if src_ip < dst_ip:
        return f"{proto}|{src_ip}:{src_port}|{dst_ip}:{dst_port}"
    else:
        return f"{proto}|{dst_ip}:{dst_port}|{src_ip}:{src_port}"

def update_flow(proto, src_ip, src_port, dst_ip, dst_port, pkt_len):
    key = flow_key(proto, src_ip, src_port, dst_ip, dst_port)
    now = time.time()
    with lock:
        if key not in flows:
            service = identify_service(dst_port, proto, dst_ip)
            flows[key] = {
                'proto': proto,
                'src': f"{src_ip}:{src_port}",
                'dst': f"{dst_ip}:{dst_port}",
                'service': service,
                'packets': 0,
                'bytes': 0,
                'start': now,
                'last_seen': now,
                'failovers_survived': 0,
                'active': True
            }
        f = flows[key]
        f['packets'] += 1
        f['bytes'] += pkt_len
        f['last_seen'] = now
        f['active'] = True

def parse_sip_payload(text):
    """Parse SIP from packet payload"""
    method = None
    m = re.search(r'^(INVITE|BYE|REGISTER|ACK|CANCEL) ', text, re.M)
    if m:
        method = m.group(1)
    status = None
    m = re.search(r'^SIP/2\.0 (\d{3})', text, re.M)
    if m:
        status = int(m.group(1))
    call_id = None
    m = re.search(r'Call-ID:\s*(.+)', text, re.I)
    if m:
        call_id = m.group(1).strip()
    from_uri = None
    m = re.search(r'From:.*?sip:([^>;@\s]+)', text, re.I)
    if m:
        from_uri = m.group(1)
    to_uri = None
    m = re.search(r'To:.*?sip:([^>;@\s]+)', text, re.I)
    if m:
        to_uri = m.group(1)
    return method, status, call_id, from_uri, to_uri

def process_sip(method, status, call_id, from_uri, to_uri):
    if not call_id:
        return
    now = time.time()
    with lock:
        if method == 'INVITE':
            sip_calls[call_id] = {
                'call_id': call_id[:40],
                'calling': from_uri or '?',
                'called': to_uri or '?',
                'state': 'ringing',
                'start': now,
                'updated': now,
                'failovers_survived': 0
            }
        elif method == 'BYE':
            if call_id in sip_calls:
                sip_calls[call_id]['state'] = 'ended'
                sip_calls[call_id]['updated'] = now
        elif method == 'CANCEL':
            if call_id in sip_calls:
                sip_calls[call_id]['state'] = 'cancelled'
                sip_calls[call_id]['updated'] = now
        elif method == 'REGISTER':
            if from_uri:
                sip_regs[from_uri] = {'user': from_uri, 'updated': now}
        if status == 200 and call_id in sip_calls and sip_calls[call_id]['state'] == 'ringing':
            sip_calls[call_id]['state'] = 'active'
            sip_calls[call_id]['updated'] = now

def mark_failover():
    """Called when active uplink changes - increment survived count on all active flows"""
    global failover_count
    with lock:
        failover_count += 1
        for f in flows.values():
            if f['active'] and time.time() - f['last_seen'] < 10:
                f['failovers_survived'] += 1
        for c in sip_calls.values():
            if c['state'] == 'active':
                c['failovers_survived'] += 1

def check_failover():
    """Monitor active uplink for changes"""
    global prev_active
    try:
        with open('/run/pathsteer/status.json', 'r') as f:
            data = json.load(f)
        active = data.get('active_uplink', '')
        if prev_active and active != prev_active:
            mark_failover()
        prev_active = active
    except:
        pass

def write_state():
    now = time.time()
    with lock:
        # Mark stale flows inactive
        for f in flows.values():
            if now - f['last_seen'] > 30:
                f['active'] = False
        
        active_flows = [f for f in flows.values() if f['active']]
        active_flows.sort(key=lambda x: x['last_seen'], reverse=True)
        
        active_calls = [c for c in sip_calls.values() if c['state'] == 'active']
        recent_calls = sorted(sip_calls.values(), key=lambda x: x['updated'], reverse=True)[:10]
        
        state = {
            'active_flows': len(active_flows),
            'total_flows': len(flows),
            'active_sip_calls': len(active_calls),
            'registrations': len(sip_regs),
            'failover_count': failover_count,
            'flows': active_flows[:20],
            'sip_calls': recent_calls,
            'sip_regs': list(sip_regs.values()),
            'updated': now
        }
    
    try:
        with open(FLOW_FILE + '.tmp', 'w') as f:
            json.dump(state, f)
        os.rename(FLOW_FILE + '.tmp', FLOW_FILE)
        # Also write SIP-specific file for backward compat
        with open(SIP_FILE + '.tmp', 'w') as f:
            json.dump({'active_calls': len(active_calls), 'calls': recent_calls, 'regs': list(sip_regs.values())}, f)
        os.rename(SIP_FILE + '.tmp', SIP_FILE)
    except:
        pass

def run_capture():
    """Run tcpdump inside ns_vip capturing all traffic"""
    cmd = [
        'ip', 'netns', 'exec', 'ns_vip',
        'tcpdump', '-i', 'any', '-l', '-n', '-q',
        '-s', '1500',
        'not', 'host', '10.201.10.1', 'and', 'not', 'host', '10.201.10.5',
        'and', 'not', 'host', '10.201.10.9', 'and', 'not', 'host', '10.201.10.13',
        'and', 'not', 'host', '10.201.10.17', 'and', 'not', 'host', '10.201.10.21',
        'and', 'not', 'host', '10.201.10.25',
        'and', 'not', 'icmp',
    ]
    
    print("Flow Monitor starting capture in ns_vip...")
    print("Filtering out veth management traffic and ICMP")
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    
    for line in proc.stdout:
        line = line.rstrip()
        # Parse tcpdump -q output: timestamp IP src.port > dst.port: proto, length N
        # TCP: 11:33:56.283713 IP 104.204.136.50.49654 > 192.73.248.83.443: tcp 0
        # UDP: 11:33:58.015510 IP 104.204.136.50.41641 > 176.58.93.248.3478: UDP, length 40
        
        m = re.match(r'[\d:.]+\s+IP\s+(\d+\.\d+\.\d+\.\d+)\.(\d+)\s+>\s+(\d+\.\d+\.\d+\.\d+)\.(\d+):\s+(tcp|UDP)', line)
        if m:
            src_ip, src_port, dst_ip, dst_port = m.group(1), int(m.group(2)), m.group(3), int(m.group(4))
            proto = 'tcp' if m.group(5) == 'tcp' else 'udp'
            pkt_len = 0
            lm = re.search(r'length (\d+)', line)
            if lm:
                pkt_len = int(lm.group(1))
            update_flow(proto, src_ip, src_port, dst_ip, dst_port, pkt_len)

def run_sip_capture():
    """Separate capture for SIP payload parsing"""
    cmd = [
        'ip', 'netns', 'exec', 'ns_vip',
        'tcpdump', '-i', 'any', '-l', '-A', '-s', '0',
        'udp port 5060 or tcp port 5060',
    ]
    print("SIP deep capture starting...")
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    
    sip_buffer = []
    for line in proc.stdout:
        line = line.rstrip()
        if any(m in line for m in ['INVITE sip:', 'BYE sip:', 'REGISTER sip:', 'SIP/2.0 ', 'CANCEL sip:']):
            if sip_buffer:
                method, status, call_id, from_uri, to_uri = parse_sip_payload('\n'.join(sip_buffer))
                if method or status:
                    process_sip(method, status, call_id, from_uri, to_uri)
            sip_buffer = [line]
        elif sip_buffer:
            if line == '':
                method, status, call_id, from_uri, to_uri = parse_sip_payload('\n'.join(sip_buffer))
                if method or status:
                    process_sip(method, status, call_id, from_uri, to_uri)
                sip_buffer = []
            else:
                sip_buffer.append(line)

def periodic():
    while True:
        check_failover()
        write_state()
        # Cleanup old flows
        with lock:
            old = [k for k, v in flows.items() if not v['active'] and time.time() - v['last_seen'] > 300]
            for k in old:
                del flows[k]
            old_calls = [k for k, v in sip_calls.items() if v['state'] in ('ended', 'cancelled') and time.time() - v['updated'] > 120]
            for k in old_calls:
                del sip_calls[k]
        time.sleep(2)

if __name__ == '__main__':
    os.makedirs('/run/pathsteer', exist_ok=True)
    write_state()
    
    # Periodic writer + failover checker
    threading.Thread(target=periodic, daemon=True).start()
    
    # SIP deep parser (separate tcpdump for payload)
    threading.Thread(target=run_sip_capture, daemon=True).start()
    
    # Main flow tracker
    run_capture()
