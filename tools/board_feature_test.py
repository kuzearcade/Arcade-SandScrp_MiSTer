#!/usr/bin/env python3
"""Drive the core's OSD options from the host and judge each one by its effect.

The MiSTer's native `screenshot` captures the core's video WITHOUT the OSD
overlay, so the menus cannot be read back and blind key-navigation of them is
unverifiable. What can be driven exactly is the saved settings file:
`/media/fat/config/<setname>.CFG` is the 128-bit OSD status word, 16 bytes
little-endian, and the core reads it when the .mra is loaded. DIP switches are
the same idea in `/media/fat/config/dips/<mra name>.dip`, 8 bytes, the
<switches> block.

So each test writes the bits, loads the core, captures frames, and checks the
picture actually changed the way the option promises.
"""
import os, subprocess, sys, tempfile, time

HOST = os.getenv('MISTER_HOST', '192.168.1.138')
MRA  = '/media/fat/_Arcade/Sand Scorpion.mra'
SET  = 'sandscrp'
ASK  = os.getenv('SSH_ASKPASS')

def ssh(cmd, timeout=300):
    env = dict(os.environ, SSH_ASKPASS=ASK, SSH_ASKPASS_REQUIRE='force', DISPLAY=':0')
    r = subprocess.run(['setsid', '-w', 'ssh', '-o', 'PreferredAuthentications=password',
                        '-o', 'PubkeyAuthentication=no', '-o', 'StrictHostKeyChecking=no',
                        f'root@{HOST}', cmd], capture_output=True, text=True, env=env, timeout=timeout)
    return '\n'.join(l for l in r.stdout.splitlines() if 'post-quantum' not in l and not l.startswith('**'))

def scp_to(local, remote):
    env = dict(os.environ, SSH_ASKPASS=ASK, SSH_ASKPASS_REQUIRE='force', DISPLAY=':0')
    subprocess.run(['setsid', '-w', 'scp', '-o', 'PreferredAuthentications=password',
                    '-o', 'PubkeyAuthentication=no', '-o', 'StrictHostKeyChecking=no',
                    local, f'root@{HOST}:{remote}'], capture_output=True, env=env, timeout=300)

def status_bytes(bits):
    """bits: {bit_index: value} or {(hi,lo): value} -> 16 little-endian bytes."""
    v = 0
    for k, val in bits.items():
        if isinstance(k, tuple):
            hi, lo = k
            v |= (val & ((1 << (hi - lo + 1)) - 1)) << lo
        else:
            v |= (val & 1) << k
    return v.to_bytes(16, 'little')

def write_cfg(bits):
    data = status_bytes(bits)
    with tempfile.NamedTemporaryFile(delete=False) as f:
        f.write(data); tmp = f.name
    scp_to(tmp, f'/media/fat/config/{SET}.CFG')
    os.unlink(tmp)
    return data.hex()

def write_dip(dsw1, dsw2, byte2=0x00):
    with tempfile.NamedTemporaryFile(delete=False) as f:
        f.write(bytes([dsw1, dsw2, byte2, 0, 0, 0, 0, 0])); tmp = f.name
    scp_to(tmp, '/media/fat/config/dips/Sand Scorpion.dip')
    os.unlink(tmp)

def clear_dip():
    ssh('rm -f "/media/fat/config/dips/Sand Scorpion.dip"')

def load(settle=50):
    ssh(f'rm -rf /media/fat/screenshots/{SET}; echo "load_core {MRA}" > /dev/MiSTer_cmd; sleep {settle}', timeout=settle + 120)

def shots(n=1, gap=6):
    ssh(f'for i in $(seq {n}); do timeout 10 sh -c "echo screenshot > /dev/MiSTer_cmd"; sleep {gap}; done',
        timeout=n * (gap + 12) + 60)
    return ssh(f'ls /media/fat/screenshots/{SET}/ 2>/dev/null').split()

def fetch(dest):
    os.makedirs(dest, exist_ok=True)
    env = dict(os.environ, SSH_ASKPASS=ASK, SSH_ASKPASS_REQUIRE='force', DISPLAY=':0')
    subprocess.run(['setsid', '-w', 'scp', '-o', 'PreferredAuthentications=password',
                    '-o', 'PubkeyAuthentication=no', '-o', 'StrictHostKeyChecking=no',
                    f'root@{HOST}:/media/fat/screenshots/{SET}/*.png', dest],
                   capture_output=True, env=env, timeout=300)
    return sorted(os.path.join(dest, f) for f in os.listdir(dest) if f.endswith('.png'))

def keys(*k):
    ssh('python3 /media/fat/mister_keys.py ' + ' '.join(k), timeout=180)
