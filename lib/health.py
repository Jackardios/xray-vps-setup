#!/usr/bin/env python3
"""Bounded host-side TLS/HTTP checks through the actual Reality fallback."""
import json
import socket
import ssl
import subprocess
import sys
import time
from pathlib import Path


def check_containers(state):
    names = ['angie', 'marzban-node' if state['mode'] == 'node' else state['mode']]
    result = subprocess.run(['docker', 'inspect', *names], capture_output=True, text=True, check=True, timeout=15)
    containers = json.loads(result.stdout)
    if len(containers) != len(names):
        raise RuntimeError('Expected containers are missing')
    for container in containers:
        status = container['State']
        if not status['Running'] or status.get('Restarting') or status.get('Paused'):
            raise RuntimeError('Container is not running normally: ' + container['Name'])


def probe(state, timeout=180):
    deadline = time.monotonic() + timeout
    pending = set(state['names']['grpc'] + state['names']['vision'])
    context = ssl.create_default_context()
    while pending and time.monotonic() < deadline:
        for name in list(pending):
            try:
                with socket.create_connection((state['ingress'] or '127.0.0.1', 443), timeout=3) as connection:
                    connection.settimeout(3)
                    with context.wrap_socket(connection, server_hostname=name) as tls:
                        tls.sendall(f'GET / HTTP/1.1\r\nHost: {name}\r\nConnection: close\r\n\r\n'.encode())
                        status = tls.recv(512).split(b'\r\n')[0]
                        if not status.startswith(b'HTTP/1.1 200'):
                            raise ValueError('Decoy did not return HTTP 200')
                pending.remove(name)
            except (OSError, ValueError):
                pass
        if pending:
            time.sleep(2)
    if pending:
        raise RuntimeError('TLS/HTTP readiness failed for: ' + ', '.join(sorted(pending)))



if __name__ == '__main__':
    try:
        state = json.loads(Path(sys.argv[1]).read_text())
        if '--runtime' in sys.argv[2:]:
            check_containers(state)
        probe(state)
    except (RuntimeError, subprocess.SubprocessError) as error:
        raise SystemExit('ERROR: ' + str(error))
