
def select_best_path():
    """Switch service traffic to best available path"""
    paths = {
        'tmo_cA': 'wg-ca-cA',
        'fa': 'veth_fa',
        # Add more as configured
    }
    
    best_table = None
    best_rtt = float('inf')
    
    for table, iface in paths.items():
        # Get RTT from status
        # Pick lowest RTT with acceptable loss
        pass
    
    if best_table:
        os.system(f'ip rule del from 104.204.136.48/28 2>/dev/null')
        os.system(f'ip rule add from 104.204.136.48/28 lookup {best_table} priority 90')
