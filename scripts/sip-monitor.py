#!/usr/bin/env python3
"""
PathSteer SIP Monitor
Sniffs SIP traffic inside ns_vip, parses INVITE/BYE/REGISTER/200OK
Writes call state to /run/pathsteer/sip.json
"""
import subprocess
import re
import json
import time
import os
import threading

SIP_FILE = '/run/pathsteer/sip.json'
calls = {}  # call-id -> call info
registrations = {}  # user -> registration info
lock = threading.Lock()

def write_state():
    with lock:
        state = {
            'active_calls': len([c for c in calls.values() if c['state'] == 'active']),
            'total_calls': len(calls),
            'registrations': len(registrations),
            'calls': list(calls.values())[-10:],  # last 10
            'regs': list(registrations.values())[-5:],
            'updated': time.time()
        }
    try:
        with open(SIP_FILE + '.tmp', 'w') as f:
            json.dump(state, f)
        os.rename(SIP_FILE + '.tmp', SIP_FILE)
    except:
        pass

def parse_sip(packet_lines):
    """Parse a SIP message from tcpdump output"""
    text = '\n'.join(packet_lines)
    
    # Extract method
    method = None
    m = re.search(r'^(INVITE|BYE|REGISTER|ACK|CANCEL|OPTIONS|INFO|UPDATE|REFER) ', text, re.M)
    if m:
        method = m.group(1)
    
    # Check for response
    status = None
    m = re.search(r'^SIP/2\.0 (\d{3})', text, re.M)
    if m:
        status = int(m.group(1))
    
    # Call-ID
    call_id = None
    m = re.search(r'Call-ID:\s*(.+)', text, re.I)
    if m:
        call_id = m.group(1).strip()
    
    # From
    from_uri = None
    m = re.search(r'From:\s*<?sip:([^>;@]+)@?([^>;]*)', text, re.I)
    if m:
        from_uri = m.group(1)
    
    # To
    to_uri = None
    m = re.search(r'To:\s*<?sip:([^>;@]+)@?([^>;]*)', text, re.I)
    if m:
        to_uri = m.group(1)
    
    # Contact (for REGISTER)
    contact = None
    m = re.search(r'Contact:\s*<?sip:([^>;]+)', text, re.I)
    if m:
        contact = m.group(1)
    
    return method, status, call_id, from_uri, to_uri, contact

def process_sip(method, status, call_id, from_uri, to_uri, contact):
    if not call_id:
        return
    
    with lock:
        now = time.time()
        
        if method == 'INVITE':
            calls[call_id] = {
                'call_id': call_id[:30],
                'calling': from_uri or '?',
                'called': to_uri or '?',
                'state': 'ringing',
                'start': now,
                'updated': now
            }
        elif method == 'BYE':
            if call_id in calls:
                calls[call_id]['state'] = 'ended'
                calls[call_id]['updated'] = now
        elif method == 'CANCEL':
            if call_id in calls:
                calls[call_id]['state'] = 'cancelled'
                calls[call_id]['updated'] = now
        elif method == 'REGISTER':
            if from_uri:
                registrations[from_uri] = {
                    'user': from_uri,
                    'contact': contact or '?',
                    'updated': now
                }
        
        # 200 OK to INVITE = call active
        if status == 200 and call_id in calls and calls[call_id]['state'] == 'ringing':
            calls[call_id]['state'] = 'active'
            calls[call_id]['updated'] = now
    
    write_state()

def run_capture():
    """Run tcpdump inside ns_vip capturing SIP"""
    cmd = [
        'ip', 'netns', 'exec', 'ns_vip',
        'tcpdump', '-i', 'any', '-l', '-A',
        '-s', '0', 'udp port 5060 or tcp port 5060',
    ]
    
    print("SIP Monitor starting capture in ns_vip...")
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    
    sip_buffer = []
    in_sip = False
    
    for line in proc.stdout:
        line = line.rstrip()
        
        # Start of SIP message
        if any(m in line for m in ['INVITE sip:', 'BYE sip:', 'REGISTER sip:', 'SIP/2.0 ', 'ACK sip:', 'CANCEL sip:']):
            if sip_buffer:
                method, status, call_id, from_uri, to_uri, contact = parse_sip(sip_buffer)
                if method or status:
                    process_sip(method, status, call_id, from_uri, to_uri, contact)
            sip_buffer = [line]
            in_sip = True
        elif in_sip:
            if line == '' or line.startswith('    '):
                if sip_buffer:
                    method, status, call_id, from_uri, to_uri, contact = parse_sip(sip_buffer)
                    if method or status:
                        process_sip(method, status, call_id, from_uri, to_uri, contact)
                    sip_buffer = []
                    in_sip = False
            else:
                sip_buffer.append(line)

# Periodic state writer (even if no SIP traffic)
def periodic_writer():
    while True:
        write_state()
        # Clean up old ended calls (>60s)
        with lock:
            old = [k for k, v in calls.items() if v['state'] in ('ended', 'cancelled') and time.time() - v['updated'] > 60]
            for k in old:
                del calls[k]
        time.sleep(5)

if __name__ == '__main__':
    os.makedirs('/run/pathsteer', exist_ok=True)
    write_state()
    t = threading.Thread(target=periodic_writer, daemon=True)
    t.start()
    run_capture()
