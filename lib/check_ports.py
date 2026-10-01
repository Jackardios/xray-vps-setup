#!/usr/bin/env python3
"""Reject foreign listeners/container identities before changing a deployment."""
import json
from pathlib import Path
import re
import subprocess
import sys


def check(state):
    owned = set()
    for name in ['angie', 'xray', 'marzban', 'marzban-node']:
        result = subprocess.run(['docker', 'inspect', name], capture_output=True, text=True, timeout=15)
        if result.returncode:
            continue
        data = json.loads(result.stdout)[0]
        if data['Config'].get('Labels', {}).get('com.docker.compose.project') != 'xray-vps-setup':
            raise ValueError('Container name belongs to another deployment: ' + name)
        if data['State']['Running']:
            top = subprocess.check_output(['docker', 'top', name, '-eo', 'pid'], text=True, timeout=15)
            owned.update(int(line.strip()) for line in top.splitlines()[1:] if line.strip().isdigit())
    ports = [80, 443, 4123, 8443, 8444]
    if state['mode'] == 'marzban':
        ports.append(8000)
    if state['mode'] == 'node':
        ports += [62001, 62002]
    for port in ports:
        output = subprocess.check_output(['ss', '-H', '-ltnp', f'sport = :{port}'], text=True, timeout=10)
        for line in output.splitlines():
            pids = {int(p) for p in re.findall(r'pid=(\d+)', line)}
            if not pids or not pids <= owned:
                raise ValueError(f'Port {port} has a foreign/unknown listener; migrate it explicitly')


if __name__ == '__main__':
    try:
        check(json.loads(Path(sys.argv[1]).read_text()))
    except ValueError as error:
        raise SystemExit('ERROR: ' + str(error))
