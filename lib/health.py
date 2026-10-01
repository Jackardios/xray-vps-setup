#!/usr/bin/env python3
"""Bounded host-side TLS/HTTP checks through the actual Reality fallback."""
import json
import socket
import ssl
import sys
import time
from pathlib import Path


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
        probe(json.loads(Path(sys.argv[1]).read_text()))
    except RuntimeError as error:
        raise SystemExit('ERROR: ' + str(error))
