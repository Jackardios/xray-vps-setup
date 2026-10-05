import copy
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import stat
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from test_setup import ROOT, TEMPLATE, BINARY, state
import setup_config as cfg
import configure
import proxy_check


def proxy(protocol='socks', udp=False):
    return dict(protocol=protocol, address='proxy.example.com', port=1080,
                user='operator', password='secret:$"\\password', udp=udp)


class ProxyTests(unittest.TestCase):
    def test_invalid_settings_and_incompatible_modes(self):
        mutations=[{'protocol':'https'},{'address':'https://proxy.example.com'},{'port':True},
                   {'port':0},{'port':65536},{'user':'user:pass'},{'password':'line\nbreak'},
                   {'user':'','password':'secret'},{'udp':'yes'},
                   {'protocol':'http','udp':True},{'user':'ю'*128}]
        for change in mutations:
            s=state();s['egress_proxy']=dict(proxy(),**change)
            with self.subTest(change=change),self.assertRaises(ValueError): cfg.validate_state(s)
        for mode in ['node','warp']:
            s=state();s['egress_proxy']=proxy()
            if mode=='node': s['mode']='node'
            else: s['warp']=True
            with self.subTest(mode=mode),self.assertRaises(ValueError): cfg.validate_state(s)

    def test_proxy_wins_over_custom_direct_rules_without_changing_api(self):
        s=state();original=cfg.server_config(TEMPLATE,s)
        original['routing']['rules'].insert(0,{'inboundTag':['api'],'outboundTag':'api'})
        original['routing']['rules'].append({'domain':['example.com'],'outboundTag':'direct'})
        s['egress_proxy']=proxy();s['egress_proxy_previous_dns']=copy.deepcopy(original['dns']);s['egress_proxy_previous_domain_strategy']=original['routing'].get('domainStrategy')
        rendered=cfg.server_config(TEMPLATE,s,original)
        rules=rendered['routing']['rules']
        position=next(i for i,r in enumerate(rules) if r.get('outboundTag')==cfg.PROXY_TAG)
        self.assertLess(position,next(i for i,r in enumerate(rules) if r.get('outboundTag')=='direct'))
        self.assertTrue(all('api' not in r.get('inboundTag',[]) for r in rules[:position+1]))
        self.assertEqual(rules[position+1:],original['routing']['rules'])
        self.assertEqual(rendered,cfg.server_config(TEMPLATE,s,rendered))
        self.assertEqual(original['dns']['servers'],['1.1.1.1','8.8.8.8'])
        self.assertEqual(rendered['dns']['servers'],['https://1.1.1.1/dns-query'])
        self.assertIn('dns-aux',rules[position]['inboundTag'])
        self.assertEqual(rendered['routing']['domainStrategy'],'IPOnDemand')
        self.assertTrue(any(r.get('ruleTag')==cfg.PROXY_UDP_RULE for r in rules[:position]))
        self.assertTrue(any(r.get('ip')==['geoip:private'] for r in rules[:position]))
        self.assertEqual(rules[0]['outboundTag'], cfg.PROXY_DNS_TAG)
        self.assertEqual(rules[0]['port'], '53')

    def test_disable_restores_dns_and_unrelated_rules(self):
        for strategy in ['IPIfNonMatch','AsIs',None]:
            with self.subTest(strategy=strategy):
                s=state();original=cfg.server_config(TEMPLATE,s)
                original['dns']['servers']=['https://dns.example.com/query']
                if strategy is None: original['routing'].pop('domainStrategy')
                else: original['routing']['domainStrategy']=strategy
                s['egress_proxy']=proxy()
                s['egress_proxy_previous_dns']=copy.deepcopy(original['dns'])
                s['egress_proxy_previous_domain_strategy']=strategy
                enabled=cfg.server_config(TEMPLATE,s,original)
                s['egress_proxy']=None
                self.assertEqual(cfg.server_config(TEMPLATE,s,enabled),original)

    def test_udp_and_split_ip_and_panel_portability(self):
        for mode in ['xray','marzban']:
            s=state(mode);s['egress_proxy']=proxy(udp=True)
            if mode=='xray': s.update(ingress='192.0.2.1',egress='192.0.2.2')
            cfg.validate_state(s)
            rendered=cfg.server_config(TEMPLATE,s)
            self.assertFalse(any(r.get('ruleTag')==cfg.PROXY_UDP_RULE for r in rendered['routing']['rules']))
            outbound=next(o for o in rendered['outbounds'] if o['tag']==cfg.PROXY_TAG)
            if mode=='xray':
                self.assertEqual(outbound['sendThrough'],'192.0.2.2')
                self.assertNotIn('streamSettings',outbound)
            else: cfg.panel_contract(rendered,{'grpc':['node.example.com'],'vision':[]})

    def test_saved_proxy_credentials_keep_on_blank_and_can_disable(self):
        s=state();s['egress_proxy']=proxy()
        with patch('builtins.input',side_effect=['']*7),patch('getpass.getpass',return_value=''):
            configure.configure_proxy(s)
        self.assertEqual(s['egress_proxy'],proxy())
        with patch('builtins.input',return_value='n'): configure.configure_proxy(s)
        self.assertIsNone(s['egress_proxy'])

    def test_render_cli_persists_snapshot_and_removes_it_on_disable(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);s=state();s['egress_proxy']=proxy();cfg.save_json(p/'state',s)
            args=['python3',str(ROOT/'lib/setup_config.py'),'render-server',str(p/'state'),
                  str(ROOT/'templates_for_script/xray'),str(p/'config')]
            subprocess.run(args,check=True,capture_output=True)
            saved=json.loads((p/'state').read_text())
            self.assertEqual(saved['egress_proxy_previous_dns'],json.loads(TEMPLATE)['dns'])
            cfg.save_json(p/'old',json.loads((p/'config').read_text()))
            saved['egress_proxy']=None;cfg.save_json(p/'state',saved)
            subprocess.run(args+[str(p/'old')],check=True,capture_output=True)
            self.assertEqual(json.loads((p/'config').read_text())['dns'],json.loads(TEMPLATE)['dns'])
            self.assertNotIn('egress_proxy_previous_dns',json.loads((p/'state').read_text()))
            self.assertNotIn('egress_proxy_previous_domain_strategy',json.loads((p/'state').read_text()))

    def test_probe_credentials_are_private_and_not_in_arguments(self):
        s=state();s['egress_proxy']=proxy();s['egress']='192.0.2.2'
        def run(args,**kwargs):
            self.assertEqual(args[:3],['curl','--disable','--config'])
            self.assertNotIn(s['egress_proxy']['password'],' '.join(args))
            p=Path(args[3]);self.assertEqual(stat.S_IMODE(p.stat().st_mode),0o600)
            content=p.read_text();self.assertIn('socks5h://proxy.example.com:1080',content)
            self.assertIn('noproxy = ""',content);self.assertIn('interface = "192.0.2.2"',content)
            return subprocess.CompletedProcess(args,0,'ip=192.0.2.15\n')
        with patch('proxy_check.subprocess.run',side_effect=run): proxy_check.check(s)
        with patch('proxy_check.subprocess.run',side_effect=subprocess.CalledProcessError(7,['curl'])),self.assertRaises(subprocess.CalledProcessError): proxy_check.check(s)
        with patch('proxy_check.subprocess.run') as run:
            proxy_check.check(state());run.assert_not_called()

    def test_real_curl_reads_escaped_proxy_credentials(self):
        received=[]
        class Handler(BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def do_CONNECT(self):
                received.append((self.path,self.headers.get('Proxy-Authorization')))
                self.send_response(403);self.end_headers();self.close_connection=True
        server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        try:
            s=state();s['egress_proxy']=proxy('http')
            s['egress_proxy'].update(address='127.0.0.1',port=server.server_port)
            with self.assertRaises(subprocess.CalledProcessError): proxy_check.check(s)
            expected=base64.b64encode(('operator:'+s['egress_proxy']['password']).encode()).decode()
            self.assertEqual(received,[('www.cloudflare.com:443','Basic '+expected)])
        finally:
            server.shutdown();server.server_close();thread.join(timeout=2)

    def test_check_detects_routing_dns_and_credentials_drift(self):
        s=state();original=cfg.server_config(TEMPLATE,s)
        s['egress_proxy']=proxy();s['egress_proxy_previous_dns']=copy.deepcopy(original['dns']);s['egress_proxy_previous_domain_strategy']=original['routing'].get('domainStrategy')
        rendered=cfg.server_config(TEMPLATE,s,original)
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/'config.json';cfg.save_json(path,rendered)
            proxy_check.check_config(s,path)
            mutations=[lambda c:c['routing']['rules'].reverse(),
                       lambda c:c['dns'].update(servers=['8.8.8.8']),
                       lambda c:c['routing'].update(domainStrategy='AsIs'),
                       lambda c:next(o for o in c['outbounds'] if o['tag']==cfg.PROXY_TAG)['settings']['servers'][0].update(port=9999),
                       lambda c:c['routing']['rules'].clear()]
            for mutation in mutations:
                changed=copy.deepcopy(rendered);mutation(changed);cfg.save_json(path,changed)
                with self.assertRaises(ValueError): proxy_check.check_config(s,path)
            s['egress_proxy']=None;cfg.save_json(path,rendered)
            with self.assertRaises(ValueError): proxy_check.check_config(s,path)
            cfg.save_json(path,original);proxy_check.check_config(s,path)

    @unittest.skipUnless(BINARY,'Set XRAY_TEST_BINARY for native checks')
    def test_real_xray_ip_blocks_and_dns_use_proxy(self):
        received=[];requested=threading.Event()
        class Handler(BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def do_CONNECT(self):
                received.append(self.path);requested.set()
                self.send_response(403);self.end_headers();self.close_connection=True
        upstream=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        thread=threading.Thread(target=upstream.serve_forever,daemon=True);thread.start()
        try:
            # The old strategy is a positive control: it forwards this private
            # hostname before performing its IP check. IPOnDemand must block it.
            for strategy,hostname,expected_proxy in [('IPOnDemand','blocked.fixture.invalid',False),
                                                     ('IPIfNonMatch','blocked.fixture.invalid',True),
                                                     ('IPOnDemand','dns.fixture.invalid',True)]:
                requested.clear()
                s=state();s['egress_proxy']=proxy('http')
                s['egress_proxy'].update(address='127.0.0.1',port=upstream.server_port)
                config=cfg.server_config(TEMPLATE,s)
                config['dns']['hosts']={'blocked.fixture.invalid':'127.0.0.1'}
                config['routing']['domainStrategy']=strategy
                with socket.socket() as port_socket:
                    port_socket.bind(('127.0.0.1',0));port=port_socket.getsockname()[1]
                config['inbounds']=[{'tag':cfg.TAGS['grpc'],'listen':'127.0.0.1','port':port,
                                     'protocol':'socks','settings':{'auth':'noauth','udp':False}}]
                with tempfile.TemporaryDirectory() as d:
                    path=Path(d)/'config.json';cfg.save_json(path,config)
                    with open(Path(d)/'xray.log','w') as log:
                        process=subprocess.Popen([BINARY,'run','-config',str(path)],stdout=log,stderr=log)
                        try:
                            deadline=time.monotonic()+5
                            while True:
                                self.assertIsNone(process.poll())
                                try: connection=socket.create_connection(('127.0.0.1',port),.2);break
                                except OSError:
                                    if time.monotonic()>deadline: self.fail('Xray listener not ready')
                                    time.sleep(.05)
                            with connection:
                                connection.settimeout(2);connection.sendall(b'\x05\x01\x00')
                                self.assertEqual(connection.recv(2),b'\x05\x00')
                                host=hostname.encode()
                                connection.sendall(b'\x05\x01\x00\x03'+bytes([len(host)])+host+b'\x01\xbb')
                                try:
                                    while connection.recv(1024): pass
                                except OSError: pass
                            self.assertEqual(requested.wait(.2),expected_proxy)
                        finally:
                            process.terminate();process.wait(timeout=5)
            self.assertEqual(received.count('blocked.fixture.invalid:443'),1)
            self.assertIn('1.1.1.1:443',received)  # Built-in DoH went through the proxy.
        finally:
            upstream.shutdown();upstream.server_close();thread.join(timeout=2)

    @unittest.skipUnless(BINARY,'Set XRAY_TEST_BINARY for native checks')
    def test_real_xray_tcp_only_proxy_blocks_udp_without_direct_fallback(self):
        # A direct positive control proves the UDP fixture works before testing
        # that the TCP-only proxy policy drops the same packet.
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as target:
            target.bind(('127.0.0.1', 0))
            target.settimeout(.5)
            destination = target.getsockname()[1]
            for protocol in [None, 'socks', 'http']:
                with self.subTest(protocol=protocol), tempfile.TemporaryDirectory() as directory:
                    s = state()
                    if protocol:
                        s['egress_proxy'] = proxy(protocol)
                        s['egress_proxy'].update(address='127.0.0.1', port=1)
                    config = cfg.server_config(TEMPLATE, s)
                    config['dns']['hosts'] = {'dns.fixture.invalid': ['203.0.113.9', '2001:db8::9']}
                    # Loopback is only allowed for this disposable fixture.
                    config['routing']['rules'] = [r for r in config['routing']['rules']
                                                  if r.get('ip') != ['geoip:private']]
                    with socket.socket() as listener:
                        listener.bind(('127.0.0.1', 0))
                        port = listener.getsockname()[1]
                    config['inbounds'] = [{'tag': cfg.TAGS['grpc'], 'listen': '127.0.0.1',
                                           'port': port, 'protocol': 'socks',
                                           'settings': {'auth': 'noauth', 'udp': True}}]
                    path = Path(directory) / 'config.json'
                    cfg.save_json(path, config)
                    with open(Path(directory) / 'xray.log', 'w') as log:
                        process = subprocess.Popen([BINARY, 'run', '-config', str(path)], stdout=log, stderr=log)
                        try:
                            deadline = time.monotonic() + 5
                            while True:
                                self.assertIsNone(process.poll())
                                try:
                                    connection = socket.create_connection(('127.0.0.1', port), .2)
                                    break
                                except OSError:
                                    if time.monotonic() > deadline:
                                        self.fail('Xray listener not ready')
                                    time.sleep(.05)
                            with connection, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
                                connection.settimeout(2)
                                stream = connection.makefile('rb')
                                try:
                                    connection.sendall(b'\x05\x01\x00')
                                    self.assertEqual(stream.read(2), b'\x05\x00')
                                    connection.sendall(b'\x05\x03\x00\x01' + b'\x00' * 6)
                                    reply = stream.read(10)
                                    self.assertEqual(reply[:4], b'\x05\x00\x00\x01')
                                    relay = (socket.inet_ntoa(reply[4:8]), int.from_bytes(reply[8:10], 'big'))
                                    packet = b'\x00\x00\x00\x01\x7f\x00\x00\x01' + destination.to_bytes(2, 'big') + b'udp-audit'
                                    client.sendto(packet, relay)
                                    if protocol:
                                        with self.assertRaises(socket.timeout):
                                            target.recvfrom(1024)
                                        # A private resolver address also works: only
                                        # DNS is intercepted; no private service is dialed.
                                        name = b'\x03dns\x07fixture\x07invalid\x00'
                                        dns_header = b'\x12\x34\x01\x00\x00\x01' + b'\x00' * 6
                                        dns_destination = b'\x00\x00\x00\x01\xc0\xa8\x01\x01\x00\x35'
                                        # Separate flow: Xray SOCKS UDP dispatch keeps
                                        # the outbound chosen for the first destination.
                                        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as dns_client:
                                            dns_client.settimeout(2)
                                            for query_type in [1, 28, 16]:
                                                query = dns_header + name + query_type.to_bytes(2, 'big') + b'\x00\x01'
                                                dns_client.sendto(dns_destination + query, relay)
                                                response = dns_client.recvfrom(1024)[0][10:]
                                                self.assertEqual(response[:2], b'\x12\x34')
                                                self.assertEqual(response[3] & 15, 5 if query_type == 16 else 0)
                                                if query_type == 1:
                                                    self.assertEqual(response[6:8], b'\x00\x01')
                                                    self.assertIn(socket.inet_aton('203.0.113.9'), response)
                                                if query_type == 28:
                                                    # Production intentionally uses IPv4;
                                                    # AAAA gets a prompt empty answer, not a timeout.
                                                    self.assertEqual(response[6:8], b'\x00\x00')
                                        with socket.create_connection(('127.0.0.1', port), 2) as dns_tcp:
                                            dns_tcp.settimeout(2)
                                            with dns_tcp.makefile('rb') as reader:
                                                dns_tcp.sendall(b'\x05\x01\x00')
                                                self.assertEqual(reader.read(2), b'\x05\x00')
                                                dns_tcp.sendall(b'\x05\x01\x00\x01\xc0\xa8\x01\x01\x00\x35')
                                                self.assertEqual(reader.read(10)[:2], b'\x05\x00')
                                                query = dns_header + name + b'\x00\x01\x00\x01'
                                                dns_tcp.sendall(len(query).to_bytes(2, 'big') + query)
                                                response = reader.read(int.from_bytes(reader.read(2), 'big'))
                                                self.assertEqual(response[3] & 15, 0)
                                                self.assertIn(socket.inet_aton('203.0.113.9'), response)
                                    else:
                                        self.assertEqual(target.recvfrom(1024)[0], b'udp-audit')
                                finally:
                                    stream.close()
                        finally:
                            process.terminate()
                            process.wait(timeout=5)

    @unittest.skipUnless(BINARY,'Set XRAY_TEST_BINARY for native checks')
    def test_real_xray_accepts_authenticated_socks_and_http(self):
        for protocol in ['socks','http']:
            for udp in ([False,True] if protocol=='socks' else [False]):
                s=state();s['egress_proxy']=proxy(protocol,udp)
                with self.subTest(protocol=protocol,udp=udp),tempfile.TemporaryDirectory() as d:
                    p=Path(d)/'config.json';cfg.save_json(p,cfg.server_config(TEMPLATE,s))
                    result=subprocess.run([BINARY,'run','-test','-config',str(p)],capture_output=True,text=True,timeout=15)
                    self.assertEqual(result.returncode,0,result.stdout+result.stderr)
