#!/usr/bin/env python3
"""Probe the optional upstream without exposing credentials in process arguments."""
import ipaddress
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile

from setup_config import configure_proxy


def check_config(state, path):
    """Detect drift in managed routing, DNS and upstream credentials."""
    config = json.loads(Path(path).read_text())
    expected = copy.deepcopy(config)
    configure_proxy(expected, state)
    if expected != config:
        raise ValueError('Managed egress proxy configuration has drifted')


def check(state):
    proxy = state.get('egress_proxy')
    if not proxy:
        return
    host = proxy['address']
    if ':' in host:
        host = '[' + host + ']'
    scheme = 'socks5h' if proxy['protocol'] == 'socks' else 'http'
    def quoted(value):
        return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'
    lines = ['proxy = ' + quoted(f"{scheme}://{host}:{proxy['port']}"), 'noproxy = ""',
             'url = "https://www.cloudflare.com/cdn-cgi/trace"',
             'connect-timeout = 10', 'max-time = 30', 'max-filesize = 65536', 'silent', 'show-error', 'fail']
    if proxy['user']:
        lines.append('proxy-user = ' + quoted(proxy['user'] + ':' + proxy['password']))
    if state.get('egress'):
        lines.append('interface = ' + quoted(state['egress']))
    with tempfile.TemporaryDirectory(prefix='xray-egress-') as directory:
        path = Path(directory) / 'curl.conf'
        path.touch(mode=0o600)
        path.write_text('\n'.join(lines) + '\n')
        result = subprocess.run(['curl', '--disable', '--config', str(path)], capture_output=True, text=True, check=True, timeout=35)
    fields = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
    ipaddress.ip_address(fields.get('ip', ''))


if __name__ == '__main__':
    try:
        state = json.loads(Path(sys.argv[1]).read_text())
        if len(sys.argv) > 2:
            check_config(state, sys.argv[2])
        check(state)
    except (OSError, ValueError, subprocess.SubprocessError):
        raise SystemExit('ERROR: External proxy configuration or HTTPS probe failed; refusing to activate or report success')
