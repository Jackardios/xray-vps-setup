#!/usr/bin/env python3
"""Pure configuration/state operations shared by the installer and its tests."""
import argparse
import copy
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import subprocess
import tempfile
import uuid

TAGS = {'grpc': 'VLESS GRPC REALITY', 'vision': 'VLESS TCP VISION REALITY'}
PORTS = {'grpc': 8443, 'vision': 8444}
RESERVED_PORTS = {80, 443, 4123, 8443, 8444, 8000, 40000, 62001, 62002}
IMAGES = {'xray': 'ghcr.io/xtls/xray-core:26.3.27',
          'angie': 'docker.angie.software/angie:1.12.2-minimal',
          'marzban': 'gozargah/marzban:v0.8.4', 'node': 'gozargah/marzban-node:v0.5.2'}


def atomic_write(path, content, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def save_json(path, value):
    atomic_write(path, json.dumps(value, indent=2) + '\n')


def domain(value):
    value = value.strip().rstrip('.').lower().encode('idna').decode('ascii')
    if len(value) > 253 or '.' not in value:
        raise ValueError('Use a fully qualified domain name')
    labels = value.split('.')
    if not all(re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', label) for label in labels):
        raise ValueError('Invalid domain name')
    return value


def ssh_port(value):
    if not re.fullmatch(r'[0-9]{1,5}', str(value)):
        raise ValueError('SSH port must contain decimal digits only')
    port = int(value)
    if not 1 <= port <= 65535 or port in RESERVED_PORTS:
        raise ValueError('Invalid or reserved SSH port')
    return port


def validate_state(state):
    if state.get('schema') != 1 or state.get('mode') not in ('xray', 'marzban', 'node'):
        raise ValueError('Unsupported state schema or install mode')
    names = state.get('names', {})
    if not names.get('grpc') or state.get('domain') != names['grpc'][0]:
        raise ValueError('The main domain must be the first gRPC name')
    all_names = names.get('grpc', []) + names.get('vision', [])
    if len(all_names) > 5 or len(set(all_names)) != len(all_names):
        raise ValueError('Duplicate domains or more than five SNI names')
    if any(domain(name) != name for name in all_names):
        raise ValueError('Domains must be canonical')
    ingress, egress = state.get('ingress', ''), state.get('egress', '')
    if bool(ingress) != bool(egress):
        raise ValueError('Split-IP requires both addresses')
    if ingress:
        if state['mode'] == 'node' or state['mode'] == 'marzban':
            raise ValueError('Split-IP is supported only for standalone; shared panel config must be portable')
        for address in (ingress, egress):
            if ipaddress.ip_address(address).version != 4:
                raise ValueError('Split-IP requires IPv4')
        if ingress == egress:
            raise ValueError('Ingress and egress must differ')
    if state.get('ssh'):
        ssh_port(state['ssh']['port'])
        if not re.fullmatch(r'[a-z][a-z0-9_-]{0,31}', state['ssh']['user']):
            raise ValueError('Invalid SSH username')
    if state['mode'] != 'node':
        keys = state['keys']
        for name in ('private', 'public'):
            if not isinstance(keys.get(name), str) or not re.fullmatch(r'[A-Za-z0-9_-]{43}', keys[name]):
                raise ValueError('Invalid Reality key')
        uuid.UUID(keys['uuid'])
        if not re.fullmatch(r'[a-f0-9]{12}', keys['service']):
            raise ValueError('Invalid gRPC service name')
        if len(keys['short_ids']) != 3 or not all(re.fullmatch(r'(?:[a-f0-9]{2}){1,8}', v) for v in keys['short_ids']):
            raise ValueError('Short IDs must be nonempty even-length hex strings')
    if state['mode'] == 'marzban':
        admin = state['admin']
        if not re.fullmatch(r'[a-z][a-z0-9_]{2,31}', admin['user']) or len(admin['password']) < 12:
            raise ValueError('Invalid panel credentials')
        # Reject values that could be interpreted by dotenv or interpolated by Compose.
        if not re.fullmatch(r'[A-Za-z0-9_-]+', admin['password']):
            raise ValueError('Panel password contains unsupported dotenv characters')
        for field in ('path', 'subscription_path'):
            if not re.fullmatch(r'[a-zA-Z0-9_-]{1,64}', admin[field]):
                raise ValueError('Invalid panel path')
    if state['mode'] == 'node':
        domain(state['panel_domain'])
        address = state['node_address']
        try:
            ipaddress.ip_address(address)
        except ValueError:
            domain(address)
        if not state.get('management_sources'):
            raise ValueError('Explicit panel management source addresses are required')
        for address in state['management_sources']:
            ipaddress.ip_network(address, strict=False)
    return state


def new_state(mode, main, names, xray=None):
    state = {'schema': 1, 'mode': mode, 'domain': domain(main), 'names': names,
             'ingress': '', 'egress': '', 'warp': False, 'ssh': None, 'block_happ': False}
    if mode != 'node':
        result = subprocess.run([str(xray), 'x25519'], check=True, capture_output=True, text=True, timeout=10)
        keys = {line.split(':', 1)[0].strip(): line.split(':', 1)[1].strip()
                for line in result.stdout.splitlines() if ':' in line}
        public = keys.get('Password (PublicKey)') or keys.get('Password') or keys.get('Public key')
        state['keys'] = {'private': keys.get('PrivateKey') or keys.get('Private key'), 'public': public,
                         'uuid': str(uuid.uuid4()), 'short_ids': [secrets.token_hex(n) for n in (8, 4, 2)],
                         'service': secrets.token_hex(6)}
    if mode == 'marzban':
        state['admin'] = {'user': 'admin_' + secrets.token_hex(3), 'password': secrets.token_hex(16),
                          'path': secrets.token_hex(8), 'subscription_path': secrets.token_hex(8)}
    state['socks'] = {'user': secrets.token_hex(4), 'password': secrets.token_hex(16)}
    return state


def dotenv(path):
    values = {}
    for line in Path(path).read_text().splitlines():
        if not line.strip() or line.lstrip().startswith('#') or '=' not in line:
            continue
        name, value = line.split('=', 1)
        parsed = shlex.split(value.strip(), comments=True)
        values[name.strip()] = parsed[0] if parsed else ''
    return values


def import_legacy(root):
    root = Path(root)
    panel = root / 'marzban/xray_config.json'
    standalone = root / 'xray/config.json'
    mode = 'marzban' if panel.exists() else 'xray'
    path = panel if panel.exists() else standalone
    if not path.exists():
        raise ValueError('Legacy node/unknown install requires manual migration; existing files were not changed')
    cfg = json.loads(path.read_text())
    inbounds = {i['tag']: i for i in cfg['inbounds'] if i.get('tag') in TAGS.values()}
    if TAGS['grpc'] not in inbounds:
        raise ValueError('Unsupported legacy Xray layout')
    grpc = inbounds[TAGS['grpc']]
    reality = grpc['streamSettings']['realitySettings']
    names = {transport: inbounds.get(tag, {}).get('streamSettings', {}).get('realitySettings', {}).get('serverNames', [])
             for transport, tag in TAGS.items()}
    main = names['grpc'][0]
    keys = {'private': reality['privateKey'], 'public': reality['publicKey'],
            'short_ids': reality['shortIds'], 'service': grpc['streamSettings']['grpcSettings']['serviceName'],
            'uuid': grpc['settings']['clients'][0]['id'] if grpc['settings'].get('clients') else str(uuid.uuid4())}
    state = {'schema': 1, 'mode': mode, 'domain': domain(main), 'names': names, 'keys': keys,
             'ssh': None, 'warp': False, 'ingress': '', 'egress': '', 'block_happ': False,
             'socks': {'user': secrets.token_hex(4), 'password': secrets.token_hex(16)}}
    for inbound in inbounds.values():
        other = inbound['streamSettings']['realitySettings']
        if other['privateKey'] != keys['private'] or other['shortIds'] != keys['short_ids']:
            raise ValueError('Legacy transports have different keys; refusing to rotate them')
    direct = next(o for o in cfg['outbounds'] if o.get('tag') == 'direct')
    if direct.get('sendThrough'):
        if mode == 'marzban':
            raise ValueError('Legacy split-IP panel needs a separate migration before adding portable nodes')
        state['egress'] = direct['sendThrough']
        text = (root / 'angie.conf').read_text()
        match = re.search(r'listen\s+(\d+\.\d+\.\d+\.\d+):443;', text)
        if not match:
            raise ValueError('Cannot safely infer legacy ingress IP')
        state['ingress'] = match[1]
    if mode == 'marzban':
        env = dotenv(root / 'marzban/.env')
        state['admin'] = {'user': env['SUDO_USERNAME'], 'password': env['SUDO_PASSWORD'],
                          'path': env['DASHBOARD_PATH'].strip('/'), 'subscription_path': env['XRAY_SUBSCRIPTION_PATH']}
    legacy_warp = any(o.get('tag') == 'warp' for o in cfg['outbounds'])
    if legacy_warp and mode == 'marzban':
        raise ValueError('Legacy panel WARP is host-specific; migrate its routing before portable node support')
    state['warp'] = legacy_warp
    return validate_state(state)


def render(text, values):
    return re.sub(r'\$([A-Z][A-Z0-9_]*)', lambda m: str(values[m[1]]) if m[1] in values else m[0], text)


def server_config(template, state, existing=None):
    keys = state['keys']
    values = {'XRAY_UUID': keys['uuid'], 'VLESS_DOMAIN': state['domain'], 'XRAY_PIK': keys['private'],
              'XRAY_PBK': keys['public'], 'XRAY_SID': keys['short_ids'][0], 'XRAY_SID2': keys['short_ids'][1],
              'XRAY_SID3': keys['short_ids'][2], 'XRAY_SERVICE_NAME': keys['service']}
    default = json.loads(render(template, values))
    cfg = copy.deepcopy(existing or default)
    if existing:
        # Only the two owned inbounds are reconciled; unrelated inbounds/rules survive.
        by_tag = {i['tag']: i for i in default['inbounds']}
        found = {i.get('tag') for i in cfg.get('inbounds', [])}
        for tag, inbound in by_tag.items():
            if tag not in found:
                cfg.setdefault('inbounds', []).append(inbound)
    kept = []
    for inbound in cfg['inbounds']:
        transport = next((t for t, tag in TAGS.items() if inbound.get('tag') == tag), None)
        if not transport:
            kept.append(inbound)
            continue
        stream = inbound.get('streamSettings', {})
        reality = stream.get('realitySettings', {})
        if (stream.get('security') != 'reality' or
                stream.get('network') not in ({'grpc'} if transport == 'grpc' else {'tcp', 'raw'}) or
                reality.get('dest', reality.get('target')) != '127.0.0.1:4123' or reality.get('xver') != 1 or
                reality.get('privateKey') != keys['private'] or reality.get('publicKey') != keys['public'] or
                reality.get('shortIds') != keys['short_ids']):
            raise ValueError('Owned inbound differs from saved identity/transport contract: ' + TAGS[transport])
        if transport == 'grpc' and stream.get('grpcSettings', {}).get('serviceName') != keys['service']:
            raise ValueError('gRPC serviceName differs from saved state')
        names = state['names'][transport]
        if not names and state['mode'] == 'xray':
            continue
        inbound['listen'] = '127.0.0.1'
        inbound['port'] = PORTS[transport]
        reality = inbound['streamSettings']['realitySettings']
        # A panel shares these names with its nodes: keep names added through its API.
        reality['serverNames'] = list(dict.fromkeys(names + (reality.get('serverNames', []) if state['mode'] == 'marzban' and existing else [])))
        if state['mode'] == 'marzban' and not reality['serverNames']:
            # Xray requires nonempty serverNames. No public SNI maps to this placeholder.
            reality['serverNames'] = ['reserved-vision.invalid']
        if state['mode'] == 'marzban':
            inbound['settings']['clients'] = []
        kept.append(inbound)
    cfg['inbounds'] = kept
    cfg['log'] = {'loglevel': 'warning'}
    for outbound in cfg['outbounds']:
        if outbound.get('tag') == 'direct':
            if state['egress']:
                outbound['sendThrough'] = state['egress']
            else:
                outbound.pop('sendThrough', None)
    # Existing WARP/custom routing is preserved on repair; fresh WARP changes are explicit.
    return cfg


def panel_contract(config, required):
    config = copy.deepcopy(config)
    for outbound in config.get('outbounds', []):
        if outbound.get('sendThrough') or outbound.get('tag') == 'warp':
            raise ValueError('Panel has host-specific sendThrough/WARP; use a portable panel config before attaching a node')
    by_tag = {i.get('tag'): i for i in config.get('inbounds', [])}
    if TAGS['grpc'] not in by_tag:
        raise ValueError('Panel is incompatible: expected installer gRPC inbound')
    grpc = by_tag[TAGS['grpc']]
    if required.get('vision') and TAGS['vision'] not in by_tag:
        vision = copy.deepcopy(grpc)
        vision['tag'], vision['port'] = TAGS['vision'], PORTS['vision']
        vision['streamSettings']['network'] = 'tcp'
        vision['streamSettings'].pop('grpcSettings', None)
        vision['settings']['clients'] = []
        vision['streamSettings']['realitySettings']['serverNames'] = []
        config['inbounds'].append(vision)
        by_tag[TAGS['vision']] = vision
    for transport, names in required.items():
        if not names:
            continue
        inbound = by_tag[TAGS[transport]]
        stream = inbound.get('streamSettings', {})
        reality = stream.get('realitySettings', {})
        if (inbound.get('listen') != '127.0.0.1' or inbound.get('port') != PORTS[transport] or
                stream.get('security') != 'reality' or stream.get('network') not in ({'grpc'} if transport == 'grpc' else {'tcp', 'raw'}) or
                reality.get('dest', reality.get('target')) != '127.0.0.1:4123' or reality.get('xver') != 1 or
                not reality.get('privateKey') or not reality.get('shortIds')):
            raise ValueError('Panel inbound is incompatible with the local SNI router: ' + TAGS[transport])
        if transport == 'grpc' and not stream.get('grpcSettings', {}).get('serviceName'):
            raise ValueError('Panel gRPC serviceName is empty')
        reality['serverNames'] = list(dict.fromkeys(reality.get('serverNames', []) + names))
    return config


def update_hosts(hosts, names, prefix=None):
    hosts = copy.deepcopy(hosts)
    for transport, entries in names.items():
        tag = TAGS[transport]
        values = hosts.setdefault(tag, [])
        owner_prefix = f'{prefix or "Local"} [{transport}] #'
        expected_remarks = {owner_prefix + str(n) for n in range(1, len(entries)+1)}
        values[:] = [h for h in values if not (h.get('remark', '').startswith(owner_prefix) and h['remark'] not in expected_remarks)]
        if not entries:
            if prefix is None:
                for host in hosts.get(TAGS[transport], []):
                    if host.get('sni') in (None, '', 'reserved-vision.invalid'):
                        host['is_disabled'] = True
            continue
        if prefix is None:
            default = next((h for h in values if not h.get('remark', '').startswith('Node ') and
                            (h.get('address') in ('{SERVER_IP}', None, '') or h.get('sni') in (None, '', 'reserved-vision.invalid'))), None)
            if default:
                default.update(address=entries[0], sni=entries[0], port=443, fingerprint='firefox', is_disabled=False,
                               remark=owner_prefix+'1')
        for number, name in enumerate(entries, 1):
            remark = f'{prefix or "Local"} [{transport}] #{number}'
            match = next((h for h in values if h.get('remark') == remark or
                          (prefix is None and h.get('sni') == name)), None)
            if match:
                match.update(address=name, sni=name, port=443, fingerprint='firefox', is_disabled=False)
            else:
                values.append({'remark': remark, 'address': name, 'sni': name, 'port': 443,
                               'fingerprint': 'firefox', 'security': 'inbound_default', 'is_disabled': False,
                               'host': None, 'path': None, 'alpn': ''})
    return hosts


def check_dns(state, local, records):
    local = set(local)
    expected = {state['ingress']} if state['ingress'] else local
    for name in state['names']['grpc'] + state['names']['vision']:
        addresses = set(records[name])
        if not any(ipaddress.ip_address(a).version == 4 for a in addresses):
            raise ValueError(f'{name}: no A record')
        if state['ingress'] and any(ipaddress.ip_address(a).version == 6 for a in addresses):
            raise ValueError(f'{name}: remove AAAA records in IPv4 split-IP mode')
        if not addresses <= expected:
            raise ValueError(f'{name}: all DNS addresses must point to local listeners; unexpected {sorted(addresses - expected)}')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['validate', 'import', 'export', 'port', 'domain', 'render-server'])
    parser.add_argument('arguments', nargs='*')
    args = parser.parse_args()
    if args.command == 'domain':
        print(domain(args.arguments[0]))
    elif args.command == 'port':
        print(ssh_port(args.arguments[0]))
    elif args.command == 'import':
        save_json(args.arguments[1], import_legacy(args.arguments[0]))
    elif args.command == 'validate':
        validate_state(json.loads(Path(args.arguments[0]).read_text()))
    elif args.command == 'render-server':
        state = validate_state(json.loads(Path(args.arguments[0]).read_text()))
        existing = json.loads(Path(args.arguments[3]).read_text()) if len(args.arguments) > 3 else None
        save_json(args.arguments[2], server_config(Path(args.arguments[1]).read_text(), state, existing))
    elif args.command == 'export':
        state = validate_state(json.loads(Path(args.arguments[0]).read_text()))
        values = {'INSTALL_MODE': state['mode'], 'VLESS_DOMAIN': state['domain'],
                  'VLESS_SNI_GRPC': ','.join(state['names']['grpc']), 'VLESS_SNI_VISION': ','.join(state['names']['vision']),
                  'VLESS_SNI_EXTRA': ' '.join((state['names']['grpc'] + state['names']['vision'])[1:]),
                  'LISTEN_ADDR': state['ingress'] or '0.0.0.0', 'INGRESS_IP': state['ingress'], 'EGRESS_IP': state['egress'],
                  'CONFIGURE_WARP': 'y' if state['warp'] else 'n', 'HAPP_BLOCK': 'if ($http_user_agent ~* "Happ") { return 403; }' if state['block_happ'] else ''}
        for key, field in [('MARZBAN_USER','user'), ('MARZBAN_PASS','password'), ('MARZBAN_PATH','path'), ('MARZBAN_SUB_PATH','subscription_path')]:
            values[key] = state.get('admin', {}).get(field, '')
        for key, value in values.items():
            print('export ' + key + '=' + shlex.quote(value))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError) as error:
        raise SystemExit('ERROR: ' + str(error))
