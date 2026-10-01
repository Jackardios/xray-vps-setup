#!/usr/bin/env python3
"""Checked panel requests, read-back verification and compensating transactions."""
import getpass
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import urllib.parse
from setup_config import panel_contract, save_json, update_hosts


class ApiError(RuntimeError):
    pass


# Marzban v0.8.4 creates this host when a newly added inbound is first read.
DEFAULT_HOST = {'remark': '🚀 Marz ({USERNAME}) [{PROTOCOL} - {TRANSPORT}]', 'address': '{SERVER_IP}',
                'port': None, 'sni': None, 'host': None, 'path': None, 'security': 'inbound_default',
                'alpn': '', 'fingerprint': '', 'allowinsecure': None, 'is_disabled': False,
                'mux_enable': False, 'fragment_setting': None, 'noise_setting': None,
                'random_user_agent': False, 'use_sni_as_host': False}


def check_hosts_after_core(journal, current):
    old = journal['before_hosts']
    new_tags = ({i['tag'] for i in journal['desired_core']['inbounds']} -
                {i['tag'] for i in journal['before_core']['inbounds']})
    if any(current.get(k) != v for k, v in old.items()):
        raise ApiError('Hosts changed concurrently after core update')
    for tag, hosts in current.items():
        if tag not in old and hosts and (tag not in new_tags or hosts != [DEFAULT_HOST]):
            raise ApiError('Hosts changed concurrently after core update')


class Client:
    def __init__(self, base, token=''):
        self.base, self.token = base, token

    def request(self, method, path, body=None, form=False, accepted=(200,)):
        # Credentials live in private files, never in curl's command-line arguments.
        with tempfile.TemporaryDirectory(prefix='xray-api-') as directory:
            headers = Path(directory) / 'headers'
            headers.write_text(('Authorization: Bearer ' + self.token + '\n' if self.token else '') +
                               ('Content-Type: application/x-www-form-urlencoded\n' if form else 'Content-Type: application/json\n'))
            headers.chmod(0o600)
            command = ['curl', '--silent', '--show-error', '--connect-timeout', '5', '--max-time', '20',
                       '--max-filesize', '4194304', '--request', method, '--header', '@' + str(headers),
                       '--write-out', '\n%{http_code}', self.base + path]
            if body is not None:
                payload = Path(directory) / 'body'
                payload.write_text(urllib.parse.urlencode(body) if form else json.dumps(body))
                payload.chmod(0o600)
                command += ['--data-binary', '@' + str(payload)]
            result = subprocess.run(command, capture_output=True, text=True, timeout=25)
        if result.returncode:
            raise ApiError(f'{method} {path}: network request failed (curl {result.returncode})')
        text, code = result.stdout.rsplit('\n', 1)
        if int(code) not in accepted:
            # Do not dump server responses: they can contain credentials or config keys.
            raise ApiError(f'{method} {path}: HTTP {code}')
        try:
            return json.loads(text) if text else None
        except json.JSONDecodeError as error:
            raise ApiError(f'{method} {path}: invalid JSON') from error

    def authenticate(self, user, password):
        token = self.request('POST', '/api/admin/token', {'username': user, 'password': password}, form=True)
        self.token = token.get('access_token', '')
        if not self.token:
            raise ApiError('Panel did not return an access token')


def contains(actual, desired):
    if isinstance(desired, dict):
        return isinstance(actual, dict) and all(k in actual and contains(actual[k], v) for k, v in desired.items())
    if isinstance(desired, list):
        return isinstance(actual, list) and len(actual) == len(desired) and all(contains(a, b) for a, b in zip(actual, desired))
    return actual == desired


def put_checked(client, path, before, desired):
    if client.request('GET', path) != before:
        raise ApiError('Panel changed concurrently; refusing to overwrite ' + path)
    client.request('PUT', path, desired)
    after = client.request('GET', path)
    if not contains(after, desired):
        raise ApiError('Panel read-back does not match ' + path)
    return after


def prepare(state, journal_path, cert_path, previous_path=''):
    client = Client('https://' + state['panel_domain'])
    client.authenticate(state['panel_user'], getpass.getpass('Panel admin password: '))
    before_core = client.request('GET', '/api/core/config')
    desired_core = panel_contract(before_core, state['names'])
    before_hosts = client.request('GET', '/api/hosts')
    previous = json.loads(Path(previous_path).read_text()) if previous_path else {}
    desired_hosts = update_hosts(before_hosts, state['names'], 'Node ' + state['node_name'],
                                 state.get('connection_name'), previous.get('connection_name'))
    cert = client.request('GET', '/api/node/settings')['certificate']
    if '-----BEGIN CERTIFICATE-----' not in cert:
        raise ApiError('Panel returned an invalid client certificate')
    Path(cert_path).write_text(cert)
    Path(cert_path).chmod(0o600)
    journal = {'base': client.base, 'token': client.token, 'before_core': before_core, 'desired_core': desired_core,
               'before_hosts': before_hosts, 'desired_hosts': desired_hosts, 'operations': [], 'status': 'prepared',
               'node': {'name': state['node_name'], 'address': state['node_address'], 'port': 62001,
                        'api_port': 62002, 'add_as_new_host': False}}
    save_json(journal_path, journal)


def rollback(journal_path):
    journal = json.loads(Path(journal_path).read_text())
    if journal['status'] in ('rolled_back', 'committed'):
        return
    client = Client(journal['base'], journal['token'])
    errors = []
    for field, path in [('hosts', '/api/hosts'), ('core', '/api/core/config')]:
        if field not in journal['operations']:
            continue
        try:
            current = client.request('GET', path)
            # If a request failed after applying its body, desired still identifies our write.
            if current == journal['desired_' + field]:
                client.request('PUT', path, journal['before_' + field])
                if not contains(client.request('GET', path), journal['before_' + field]):
                    raise ApiError('Rollback read-back mismatch')
            elif current != journal['before_' + field]:
                raise ApiError('Concurrent changes detected; manual recovery required')
        except (ApiError, subprocess.TimeoutExpired) as error:
            errors.append(str(error))
    if journal.get('created_node_id') is not None:
        try:
            client.request('DELETE', '/api/node/' + str(journal['created_node_id']), accepted=(200, 404))
        except (ApiError, subprocess.TimeoutExpired) as error:
            errors.append(str(error))
    if journal.get('node_creation_pending'):
        errors.append('Node creation was interrupted; inspect the panel before recovery')
    if journal.get('ambiguous_node_id') is not None:
        errors.append('POST outcome was ambiguous; inspect node ' + str(journal['ambiguous_node_id']) + ' manually')
    journal['status'] = 'rollback_failed' if errors else 'rolled_back'
    if not errors:
        journal['token'] = ''
    save_json(journal_path, journal)
    if errors:
        raise ApiError('API rollback incomplete: ' + '; '.join(errors))


def apply(journal_path):
    journal = json.loads(Path(journal_path).read_text())
    client = Client(journal['base'], journal['token'])
    if journal['status'] != 'prepared':
        raise ApiError('Transaction is not prepared')
    try:
        for field, path in [('core', '/api/core/config'), ('hosts', '/api/hosts')]:
            if field == 'hosts':
                current = client.request('GET', path)
                check_hosts_after_core(journal, current)
                journal['before_hosts'] = current
            # Write intent before the HTTP mutation, so interrupted requests can be reconciled.
            journal['operations'].append(field)
            save_json(journal_path, journal)
            after = put_checked(client, path, journal['before_' + field], journal['desired_' + field])
            journal['desired_' + field] = after
            save_json(journal_path, journal)
        nodes = client.request('GET', '/api/nodes')
        matches = [n for n in nodes if n['name'] == journal['node']['name'] or n['address'] == journal['node']['address']]
        if matches:
            if len(matches) != 1 or any(matches[0].get(k) != journal['node'][k] for k in ('name', 'address', 'port', 'api_port')):
                raise ApiError('Existing node identity differs; refusing to overwrite it')
            node_id = matches[0]['id']
            if matches[0].get('status') == 'disabled':
                raise ApiError('Existing node is disabled; enable it explicitly in the panel')
            client.request('POST', f'/api/node/{node_id}/reconnect')
        else:
            journal['node_creation_pending'] = True
            save_json(journal_path, journal)
            try:
                node = client.request('POST', '/api/node', journal['node'])
            except (ApiError, subprocess.TimeoutExpired):
                # POST may have succeeded even if the response was lost. Never blindly retry it.
                nodes = client.request('GET', '/api/nodes')
                matches = [n for n in nodes if all(n.get(k) == journal['node'][k] for k in ('name', 'address', 'port', 'api_port'))]
                if len(matches) != 1:
                    raise ApiError('Node creation outcome is unknown; check panel nodes before retrying')
                node = matches[0]
                journal['ambiguous_node_id'] = node['id']
            node_id = node['id']
            if not journal.get('ambiguous_node_id'):
                journal['created_node_id'] = node_id
            journal.pop('node_creation_pending', None)
            save_json(journal_path, journal)
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            node = client.request('GET', f'/api/node/{node_id}')
            if node['status'] == 'connected':
                journal['status'] = 'applied'
                save_json(journal_path, journal)
                return
            time.sleep(2)
        raise ApiError('Panel could not connect to node; check explicit source ACL and node address')
    except BaseException:
        rollback(journal_path)
        raise


def local_hosts(state, previous_path=''):
    client = Client('http://127.0.0.1:8000')
    deadline = time.monotonic() + 90
    while True:
        try:
            client.authenticate(state['admin']['user'], state['admin']['password'])
            break
        except (ApiError, subprocess.TimeoutExpired):
            if time.monotonic() >= deadline:
                raise ApiError('Cannot authenticate local panel; existing DB credentials must match saved state')
            time.sleep(2)
    before = client.request('GET', '/api/hosts')
    previous = json.loads(Path(previous_path).read_text()) if previous_path else {}
    put_checked(client, '/api/hosts', before, update_hosts(before, state['names'],
                connection_name=state.get('connection_name'), previous_name=previous.get('connection_name')))


if __name__ == '__main__':
    # Let the transaction handler compensate a graceful interruption.
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    try:
        command = sys.argv[1]
        if command == 'prepare':
            prepare(json.loads(Path(sys.argv[2]).read_text()), sys.argv[3], sys.argv[4], sys.argv[5] if len(sys.argv) > 5 else '')
        elif command == 'recover':
            journal=json.loads(Path(sys.argv[2]).read_text())
            client=Client(journal['base'])
            client.authenticate(input('Panel sudo admin username: '), getpass.getpass('Panel admin password: '))
            journal['token']=client.token
            if journal.get('ambiguous_node_id') is not None or journal.get('node_creation_pending'):
                print('Node creation was interrupted. Inspect panel nodes; recovery will keep any unconfirmed creation.')
                if input('Confirm keeping this node in the panel [y/N]: ').strip().lower() != 'y':
                    raise ApiError('Inspect/delete the ambiguous node manually before recovery')
                journal.pop('ambiguous_node_id', None)
                journal.pop('node_creation_pending', None)
            save_json(sys.argv[2],journal)
            rollback(sys.argv[2])
        elif command == 'apply':
            apply(sys.argv[2])
        elif command == 'rollback':
            rollback(sys.argv[2])
        elif command == 'commit':
            journal = json.loads(Path(sys.argv[2]).read_text())
            journal['status'], journal['token'] = 'committed', ''
            save_json(sys.argv[2], journal)
        elif command == 'local-hosts':
            local_hosts(json.loads(Path(sys.argv[2]).read_text()), sys.argv[3] if len(sys.argv) > 3 else '')
        else:
            raise ValueError('Unknown API operation')
    except (ApiError, ValueError, KeyError, subprocess.TimeoutExpired, KeyboardInterrupt) as error:
        raise SystemExit('ERROR: ' + (str(error) or 'API operation interrupted'))
