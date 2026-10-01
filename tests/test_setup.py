import copy
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading
import urllib.parse
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'lib'))
import setup_config as cfg
import panel_api as api
import configure
import health
import ssh_policy

TEMPLATE=(ROOT/'templates_for_script/xray').read_text()
BINARY=os.environ.get('XRAY_TEST_BINARY')
BASH=os.environ.get('BASH_TEST_BINARY','bash')


def state(mode='xray'):
    with patch('setup_config.subprocess.run') as run:
        run.return_value.stdout='PrivateKey: '+'A'*43+'\nPassword (PublicKey): '+'B'*43+'\n'
        return cfg.new_state(mode,'main.example.com',{'grpc':['main.example.com'],'vision':['vision.example.com']},'/fixture/xray')


class ConfigurationTests(unittest.TestCase):
    def test_domains(self):
        self.assertEqual(cfg.domain('Пример.РФ.'),'xn--e1afmkfd.xn--p1ai')
        self.assertEqual(cfg.domain('MAIN.Example.COM'),'main.example.com')
        for invalid in ['','localhost','../etc/passwd','x;include evil;.com','bad*.example.com','a'*64+'.com','a..com','-foo.com','foo-.com']:
            with self.subTest(invalid=invalid), self.assertRaises((ValueError,UnicodeError)):
                cfg.domain(invalid)

    def test_ports(self):
        for invalid in ['0','-1','65536','2222+1','22;reboot','0x16','80','443','4123','8443','8444','8000','40000','62001','62002','1'*6]:
            with self.subTest(port=invalid),self.assertRaises(ValueError): cfg.ssh_port(invalid)
        self.assertEqual(cfg.ssh_port('022'),22)
        self.assertEqual(cfg.ssh_port('2222'),2222)

    def test_private_atomic_permissions(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'secret';p.write_text('old');p.chmod(0o600)
            old=os.umask(0o022)
            try: cfg.atomic_write(p,'new')
            finally: os.umask(old)
            self.assertEqual(p.read_text(),'new');self.assertEqual(stat.S_IMODE(p.stat().st_mode),0o600)
            with patch('setup_config.os.replace',side_effect=OSError('injected')),self.assertRaises(OSError): cfg.atomic_write(p,'broken')
            self.assertEqual(p.read_text(),'new');self.assertEqual(list(Path(d).iterdir()),[p])

    def test_empty_credentials_rejected(self):
        for field in ['private','public','service']:
            s=state();s['keys'][field]=''
            with self.subTest(field=field),self.assertRaises(ValueError): cfg.validate_state(s)
        s=state();s['keys']['short_ids']=['','','']
        with self.assertRaises(ValueError): cfg.validate_state(s)

    def test_generation_failure_aborts(self):
        with patch('setup_config.subprocess.run',side_effect=subprocess.CalledProcessError(1,['xray'])):
            with self.assertRaises(subprocess.CalledProcessError): cfg.new_state('xray','main.example.com',{'grpc':['main.example.com'],'vision':[]},'/xray')

    def test_repair_identity_custom_config_and_panel_clients(self):
        s=state('marzban');original=cfg.server_config(TEMPLATE,s)
        original['custom']={'keep':True}
        original['inbounds'][0]['settings']['clients']=[{'id':'legacy-hidden-user'}]
        original['inbounds'][0]['streamSettings']['realitySettings']['serverNames'].append('node.example.com')
        repaired=cfg.server_config(TEMPLATE,s,original)
        self.assertEqual(repaired['custom'],{'keep':True})
        self.assertIn('node.example.com',repaired['inbounds'][0]['streamSettings']['realitySettings']['serverNames'])
        self.assertEqual(repaired['inbounds'][0]['settings']['clients'],[])
        self.assertEqual(repaired['inbounds'][0]['streamSettings']['realitySettings']['privateKey'],s['keys']['private'])
        self.assertEqual(original['inbounds'][0]['settings']['clients'],[{'id':'legacy-hidden-user'}])

    def test_drift_rejected(self):
        s=state();original=cfg.server_config(TEMPLATE,s)
        original['inbounds'][0]['streamSettings']['realitySettings']['privateKey']='C'*43
        with self.assertRaises(ValueError): cfg.server_config(TEMPLATE,s,original)

    def test_panel_vision_contract_repair(self):
        s=state('marzban');core=cfg.server_config(TEMPLATE,s)
        core['inbounds']=[core['inbounds'][0]]
        updated=cfg.panel_contract(core,{'grpc':['node.example.com'],'vision':['node-vision.example.com']})
        self.assertEqual(len(updated['inbounds']),2)
        self.assertEqual(updated['inbounds'][1]['settings']['clients'],[])
        self.assertEqual(updated['inbounds'][1]['streamSettings']['network'],'tcp')
        self.assertIn('node-vision.example.com',updated['inbounds'][1]['streamSettings']['realitySettings']['serverNames'])
        self.assertEqual(len(core['inbounds']),1)

    def test_foreign_panel_bindings_rejected(self):
        for value in ['bind','warp','port','target']:
            core=cfg.server_config(TEMPLATE,state('marzban'))
            if value=='bind': core['outbounds'][0]['sendThrough']='192.0.2.10'
            if value=='warp': core['outbounds'].append({'tag':'warp'})
            if value=='port': core['inbounds'][0]['port']=4444
            if value=='target': core['inbounds'][0]['streamSettings']['realitySettings']['dest']='foreign:443'
            with self.subTest(value=value),self.assertRaises(ValueError): cfg.panel_contract(core,{'grpc':['node.example.com'],'vision':[]})

    def test_hosts_firefox_idempotence_and_other_profiles(self):
        hosts={cfg.TAGS['grpc']:[{'remark':'default','address':'{SERVER_IP}','sni':'','fingerprint':''},
                                 {'remark':'custom','address':'custom.example.com','sni':'custom.example.com'}]}
        names={'grpc':['main.example.com','extra.example.com'],'vision':[]}
        first=cfg.update_hosts(hosts,names);second=cfg.update_hosts(first,names)
        self.assertEqual(first,second)
        self.assertEqual(first[cfg.TAGS['grpc']][0]['fingerprint'],'firefox')
        self.assertEqual(first[cfg.TAGS['grpc']][1]['address'],'custom.example.com')
        node=cfg.update_hosts(first,names,'Node one');self.assertEqual(node,cfg.update_hosts(node,names,'Node one'))

    def test_reconfigure_hosts_preserves_node_and_removes_stale_local(self):
        node={'remark':'Node remote [vision] #1','address':'remote.example.com','sni':'remote.example.com'}
        hosts={cfg.TAGS['vision']:[node,{'remark':'default','address':'{SERVER_IP}','sni':'reserved-vision.invalid','is_disabled':True}]}
        enabled=cfg.update_hosts(hosts,{'vision':['vision.example.com']})
        self.assertEqual(enabled[cfg.TAGS['vision']][0],node)
        self.assertFalse(enabled[cfg.TAGS['vision']][1]['is_disabled'])
        removed=cfg.update_hosts(enabled,{'vision':[]})
        self.assertEqual(removed[cfg.TAGS['vision']],[node])

    def test_connection_name_renames_owned_profiles_without_duplicates(self):
        names={'grpc':['main.example.com','extra.example.com'],'vision':[]}
        hosts=cfg.update_hosts({},names)
        remote={'remark':'Node remote [grpc] #1','address':'remote.example.com','sni':'remote.example.com'}
        hosts[cfg.TAGS['grpc']].append(remote)
        renamed=cfg.update_hosts(hosts,names,connection_name='Мой VPN')
        self.assertEqual([h['remark'] for h in renamed[cfg.TAGS['grpc']]],
                         ['Мой VPN [grpc] #1','Мой VPN [grpc] #2',remote['remark']])
        changed=cfg.update_hosts(renamed,{'grpc':['main.example.com'],'vision':[]},
                                 connection_name='Новый VPN',previous_name='Мой VPN')
        self.assertEqual([h['remark'] for h in changed[cfg.TAGS['grpc']]],['Новый VPN [grpc] #1',remote['remark']])
        self.assertEqual(changed, cfg.update_hosts(changed,{'grpc':['main.example.com'],'vision':[]},connection_name='Новый VPN'))
        self.assertEqual(changed[cfg.TAGS['grpc']][1],remote)

    def test_reconfigure_keeps_saved_connection_name_on_empty_answer(self):
        with tempfile.TemporaryDirectory() as d:
            previous=Path(d)/'previous.json';output=Path(d)/'state.json'
            s=state();s['connection_name']='Мой VPN';cfg.save_json(previous,s)
            with patch('builtins.input',side_effect=['']*6):
                configure.configure(output,'/unused',previous)
            self.assertEqual(json.loads(output.read_text())['connection_name'],'Мой VPN')

    def test_connection_name_braces_are_literal_in_panel_templates(self):
        hosts=cfg.update_hosts({}, {'grpc':['main.example.com']}, connection_name='VPN {home}')
        remark=hosts[cfg.TAGS['grpc']][0]['remark']
        self.assertEqual(remark.format_map({}), 'VPN {home} [grpc] #1')
        self.assertEqual(hosts,cfg.update_hosts(hosts,{'grpc':['main.example.com']},connection_name='VPN {home}'))

    def test_egress_change_requires_new_ssh_confirmation(self):
        for old,new in [('', '192.0.2.2'), ('192.0.2.3','192.0.2.2'), ('192.0.2.2','192.0.2.2'), ('192.0.2.2','')]:
            with self.subTest(old=old,new=new),tempfile.TemporaryDirectory() as d:
                s=state();s.update(egress=old,ingress='192.0.2.1' if old else '',ssh_confirmed=True,
                                  ssh={'user':'operator','port':22,'public_key':'ssh-ed25519 fixture','password':'fixture'})
                p=Path(d);cfg.save_json(p/'old.json',s)
                answers=['','','', 'y' if new else 'n']+(['192.0.2.1',new] if new else [])+['n','n']
                with patch('builtins.input',side_effect=answers): configure.configure(p/'new.json','/unused',p/'old.json')
                self.assertEqual(json.loads((p/'new.json').read_text())['ssh_confirmed'],old==new)

    def test_dns_all_records_and_split_ipv6(self):
        s=state();s['names']['vision']=[]
        cfg.check_dns(s,['192.0.2.1','2001:db8::1'],{'main.example.com':['192.0.2.1','2001:db8::1']})
        for addresses in [[],['192.0.2.1','192.0.2.2'],['192.0.2.1','2001:db8::2']]:
            with self.subTest(addresses=addresses),self.assertRaises(ValueError): cfg.check_dns(s,['192.0.2.1'],{'main.example.com':addresses})
        s['ingress'],s['egress']='192.0.2.1','192.0.2.2'
        with self.assertRaises(ValueError): cfg.check_dns(s,['192.0.2.1','2001:db8::1'],{'main.example.com':['192.0.2.1','2001:db8::1']})

    def test_legacy_preserves_secrets_and_paths(self):
        s=state('marzban');core=cfg.server_config(TEMPLATE,s)
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);(p/'marzban').mkdir();(p/'marzban/xray_config.json').write_text(json.dumps(core))
            a=s['admin'];(p/'marzban/.env').write_text(f'SUDO_USERNAME="{a["user"]}"\nSUDO_PASSWORD="{a["password"]}"\nDASHBOARD_PATH="/{a["path"]}/"\nXRAY_SUBSCRIPTION_PATH="{a["subscription_path"]}"\n')
            imported=cfg.import_legacy(p)
            self.assertEqual(imported['admin'],s['admin'])
            for field in ['private','public','short_ids','service']: self.assertEqual(imported['keys'][field],s['keys'][field])


class HttpClientTests(unittest.TestCase):
    def test_real_curl_authentication_and_http_json_failures(self):
        received=[]
        class Handler(BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def do_POST(self):
                received.append(urllib.parse.parse_qs(self.rfile.read(int(self.headers['Content-Length'])).decode()))
                self.send_response(200);self.end_headers();self.wfile.write(b'{"access_token":"fixture-token"}')
            def do_GET(self):
                received.append(self.headers.get('Authorization'))
                self.send_response(403 if self.path=='/forbidden' else 200);self.end_headers()
                self.wfile.write(b'not-json' if self.path=='/invalid' else b'{"ok":true}')
        server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        try:
            client=api.Client('http://127.0.0.1:'+str(server.server_port))
            password=r'fixture\password&plus+'
            client.authenticate('operator',password)
            self.assertEqual(received[0]['password'],[password])
            self.assertEqual(client.request('GET','/ok'),{'ok':True})
            self.assertEqual(received[1],'Bearer fixture-token')
            with self.assertRaisesRegex(api.ApiError,'HTTP 403'): client.request('GET','/forbidden')
            with self.assertRaisesRegex(api.ApiError,'invalid JSON'): client.request('GET','/invalid')
        finally:
            server.shutdown();server.server_close();thread.join(timeout=2)


class FakeClient:
    shared={}
    failures={}
    calls=[]
    def __init__(self,*args): pass
    def request(self,method,path,body=None,**kwargs):
        self.calls.append((method,path))
        if self.failures.get((method,path)):
            self.failures[(method,path)]-=1
            raise api.ApiError('injected HTTP 500')
        if method=='GET':
            if path=='/api/nodes': return copy.deepcopy(self.shared['nodes'])
            if path.startswith('/api/node/'):
                return next(copy.deepcopy(n) for n in self.shared['nodes'] if str(n['id'])==path.rsplit('/',1)[1])
            return copy.deepcopy(self.shared[path])
        if method=='PUT':
            self.shared[path]=copy.deepcopy(body)
            if path=='/api/core/config':
                for inbound in body['inbounds']: self.shared['/api/hosts'].setdefault(inbound['tag'],[])
            return copy.deepcopy(body)
        if method=='POST' and path=='/api/node':
            node=dict(body,id=1,status='connected');self.shared['nodes'].append(node);return node
        if method=='POST': return {}
        if method=='DELETE':
            if not any(str(n['id'])==path.rsplit('/',1)[1] for n in self.shared['nodes']) and 404 not in kwargs.get('accepted',(200,)):
                raise api.ApiError('HTTP 404')
            self.shared['nodes']=[n for n in self.shared['nodes'] if str(n['id'])!=path.rsplit('/',1)[1]];return {}
        raise AssertionError((method,path))


class ApiTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.path=Path(self.tmp.name)/'transaction.json'
        core=cfg.server_config(TEMPLATE,state('marzban'));core['inbounds']=[core['inbounds'][0]]
        hosts={cfg.TAGS['grpc']:[]};names={'grpc':['node.example.com'],'vision':['vision.node.example.com']}
        self.journal={'base':'https://example.invalid','token':'fixture','before_core':core,'desired_core':cfg.panel_contract(core,names),
                      'before_hosts':hosts,'desired_hosts':cfg.update_hosts(hosts,names,'Node test'),'operations':[],'status':'prepared',
                      'node':{'name':'test','address':'node.example.com','port':62001,'api_port':62002,'add_as_new_host':False}}
        cfg.save_json(self.path,self.journal)
        FakeClient.shared={'/api/core/config':copy.deepcopy(core),'/api/hosts':copy.deepcopy(hosts),'nodes':[]}
        FakeClient.failures={};FakeClient.calls=[]
        self.patch=patch('panel_api.Client',FakeClient);self.patch.start();self.addCleanup(self.patch.stop)

    def test_apply_readback_new_vision_and_rollback(self):
        api.apply(self.path);self.assertEqual(json.loads(self.path.read_text())['status'],'applied')
        self.assertEqual(len(FakeClient.shared['nodes']),1)
        api.rollback(self.path)
        self.assertEqual(FakeClient.shared['/api/core/config'],self.journal['before_core'])
        self.assertEqual(FakeClient.shared['nodes'],[])

    def test_put_failure_restores_core(self):
        FakeClient.failures[('PUT','/api/hosts')]=1
        with self.assertRaises(api.ApiError): api.apply(self.path)
        self.assertEqual(FakeClient.shared['/api/core/config'],self.journal['before_core'])
        self.assertEqual(json.loads(self.path.read_text())['status'],'rolled_back')

    def test_auto_created_marzban_host_does_not_abort_transaction(self):
        original=FakeClient.request
        def request(client,method,path,*args,**kwargs):
            result=original(client,method,path,*args,**kwargs)
            if method=='PUT' and path=='/api/core/config' and cfg.TAGS['vision'] not in self.journal['before_hosts']:
                FakeClient.shared['/api/hosts'].setdefault(cfg.TAGS['vision'],[])
                if any(i['tag']==cfg.TAGS['vision'] for i in FakeClient.shared[path]['inbounds']):
                    FakeClient.shared['/api/hosts'][cfg.TAGS['vision']]=[copy.deepcopy(api.DEFAULT_HOST)]
            return result
        with patch.object(FakeClient,'request',request): api.apply(self.path)
        self.assertEqual(json.loads(self.path.read_text())['status'],'applied')
        self.assertEqual(FakeClient.shared['/api/hosts'],self.journal['desired_hosts'])

    def test_new_host_concurrent_edits_are_still_rejected(self):
        for change in ['remark','address','extra']:
            current=copy.deepcopy(self.journal['before_hosts'])
            current[cfg.TAGS['vision']]=[copy.deepcopy(api.DEFAULT_HOST)]
            if change=='extra': current[cfg.TAGS['vision']].append(copy.deepcopy(api.DEFAULT_HOST))
            else: current[cfg.TAGS['vision']][0][change]='custom'
            with self.subTest(change=change),self.assertRaises(api.ApiError): api.check_hosts_after_core(self.journal,current)

    def test_concurrent_core_not_overwritten(self):
        FakeClient.shared['/api/core/config']['external']='edit'
        with self.assertRaises(api.ApiError): api.apply(self.path)
        self.assertEqual(FakeClient.shared['/api/core/config']['external'],'edit')
        self.assertEqual(json.loads(self.path.read_text())['status'],'rollback_failed')

    def test_concurrent_edit_after_apply_not_erased(self):
        api.apply(self.path);FakeClient.shared['/api/core/config']['external']='after'
        with self.assertRaises(api.ApiError): api.rollback(self.path)
        self.assertEqual(FakeClient.shared['/api/core/config']['external'],'after')

    def test_retry_partial_rollback_accepts_already_deleted_node(self):
        api.apply(self.path)
        FakeClient.shared['/api/core/config']['external']='concurrent'
        with self.assertRaises(api.ApiError): api.rollback(self.path)
        self.assertEqual(FakeClient.shared['nodes'],[])
        del FakeClient.shared['/api/core/config']['external']
        api.rollback(self.path)
        self.assertEqual(json.loads(self.path.read_text())['status'],'rolled_back')

    def test_interrupted_node_creation_stays_pending_for_manual_recovery(self):
        original=FakeClient.request
        def interrupt(client,method,path,*args,**kwargs):
            if method=='POST' and path=='/api/node': raise KeyboardInterrupt()
            return original(client,method,path,*args,**kwargs)
        with patch.object(FakeClient,'request',interrupt),self.assertRaises(api.ApiError): api.apply(self.path)
        journal=json.loads(self.path.read_text())
        self.assertTrue(journal['node_creation_pending'])
        self.assertEqual(journal['status'],'rollback_failed')
        self.assertEqual(FakeClient.shared['/api/core/config'],self.journal['before_core'])

    def test_existing_node_is_reused_not_deleted(self):
        FakeClient.shared['nodes']=[dict(self.journal['node'],id=9,status='connected')]
        api.apply(self.path);api.rollback(self.path)
        self.assertEqual(FakeClient.shared['nodes'][0]['id'],9)

    def test_identity_conflict_aborts_and_compensates(self):
        FakeClient.shared['nodes']=[dict(self.journal['node'],address='elsewhere.example.com',id=9,status='connected')]
        with self.assertRaises(api.ApiError): api.apply(self.path)
        self.assertEqual(FakeClient.shared['nodes'][0]['address'],'elsewhere.example.com')
        self.assertEqual(FakeClient.shared['/api/core/config'],self.journal['before_core'])


class ShellTests(unittest.TestCase):
    def run_shell(self,body,stdin=''):
        return subprocess.run([BASH,'-c','source "'+str(ROOT/'vps-setup.sh')+'"\n'+body],input=stdin,text=True,capture_output=True,timeout=15)

    def test_library_source_has_no_system_side_effects(self):
        result=self.run_shell('echo sourced')
        self.assertEqual(result.returncode,0,result.stderr);self.assertEqual(result.stdout,'sourced\n')

    def test_download_failure_is_not_success_even_with_partial_file(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'partial';p.write_text('partial')
            result=self.run_shell('curl() { return 22; }; if download https://example.invalid '+str(p)+'; then echo WRONG; else echo rejected; fi')
            self.assertEqual(result.stdout,'rejected\n')

    def test_missing_template_does_not_touch_active_config(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'active';p.write_text('active')
            result=self.run_shell('RUN_DIR='+d+'; fetch missing > '+d+'/staged')
            self.assertNotEqual(result.returncode,0);self.assertEqual(p.read_text(),'active')

    def test_help_needs_no_linux_or_root(self):
        result=subprocess.run([BASH,str(ROOT/'vps-setup.sh'),'--help'],capture_output=True,text=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stderr)

    def test_rollback_failure_is_recorded_and_data_preserved(self):
        for fails in [False, True]:
            with self.subTest(fails=fails), tempfile.TemporaryDirectory() as d:
                p=Path(d)
                for directory in ['etc/ssh/sshd_config.d','etc/systemd/system/ssh.socket.d','install','backup','release']:
                    (p/directory).mkdir(parents=True)
                (p/'backup/ipv4').write_text('fixture')
                (p/'backup/docker-compose.yml').write_text('previous-compose')
                (p/'install/database').write_text('keep-data')
                cfg.save_json(p/'release/deployment.json',{'status':'activating'})
                # Relocate every system path in a temporary copy; never mutate the host.
                script=p/'installer.sh'
                script.write_text((ROOT/'vps-setup.sh').read_text().replace('/etc/',str(p/'etc')+'/'))
                body=f'''source "{script}"
LIB="{ROOT}/lib"; INSTALL_ROOT="{p}/install"; BACKUP_DIR="{p}/backup"; RELEASE_DIR="{p}/release"; OLD_CURRENT=''
docker() {{ return 0; }}
systemctl() {{ return 0; }}
iptables-restore() {{ cat >/dev/null; return {1 if fails else 0}; }}
set +e
rollback_system
exit $?'''
                result=subprocess.run([BASH,'-c',body],text=True,capture_output=True,timeout=15)
                self.assertEqual(result.returncode,1 if fails else 0,result.stderr)
                self.assertEqual(json.loads((p/'release/deployment.json').read_text())['status'],'rollback_failed' if fails else 'rolled_back')
                self.assertEqual((p/'install/docker-compose.yml').read_text(),'previous-compose')
                self.assertEqual((p/'install/database').read_text(),'keep-data')

    def test_ssh_runtime_directory_exists_before_config_inspection(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);cfg.save_json(p/'state.json',{'ssh':{'user':'operator','port':2222,'public_key':'invalid-fixture','password':'fixture'}})
            script=p/'ssh.sh'
            script.write_text((ROOT/'lib/ssh.sh').read_text().replace('/run/sshd',str(p/'run/sshd')).replace('/etc/ssh/',str(p/'etc/ssh')+'/'))
            body=f'''RUN_DIR="{p}"; STATE_FILE="{p}/state.json"; LIB="{ROOT}/lib"
source "{script}"
sshd() {{ [[ -d "{p}/run/sshd" ]] || return 99; echo inspected > "{p}/inspection"; echo 'port 22'; }}
ss() {{ return 0; }}
ssh-keygen() {{ return 1; }}
prepare_ssh'''
            result=self.run_shell(body)
            self.assertNotEqual(result.returncode,0)
            self.assertTrue((p/'inspection').exists(),'sshd was called without its runtime directory')

    def test_ssh_confirmation_error_and_signals_stop_after_rollback(self):
        source=(ROOT/'lib/confirm-access.sh').read_text()
        start=source.index('rollback() {');end=source.index("printf 'Port %s",start)
        for trigger,status in [('false',1),('kill -s INT $$',130),('kill -s TERM $$',143)]:
            with self.subTest(trigger=trigger),tempfile.TemporaryDirectory() as d:
                p=Path(d);script=p/'rollback.sh'
                script.write_text('#!/bin/sh\necho restored >> "'+str(p/'restored')+'"\n');script.chmod(0o700)
                body='RUN_DIR="'+d+'"; unit=fixture\nsystemctl() { return 0; }\n'+source[start:end]+trigger+'\necho SHOULD_NOT_CONTINUE\n'
                result=self.run_shell(body)
                self.assertEqual(result.returncode,status,result.stderr)
                self.assertNotIn('SHOULD_NOT_CONTINUE',result.stdout)
                self.assertEqual((p/'restored').read_text(),'restored\n')

    def test_complete_ssh_confirmation_with_relocated_system_files(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);install=p/'install';(install/'lib').mkdir(parents=True);(install/'current').mkdir()
            (p/'etc/ssh/sshd_config.d').mkdir(parents=True)
            (p/'etc/ssh/sshd_config').write_text('Include '+str(p/'etc/ssh/sshd_config.d/*.conf')+'\n')
            (p/'etc/ssh/sshd_config.d/00-xray-vps-setup.conf').write_text('Port 22\n')
            (install/'ssh-transition.env').write_text(f'INSTALL_ROOT="{install}"\nINSTALL_MODE=xray\nINGRESS_IP=""\nEGRESS_IP=""\nSSH_NEW_PORT=22\nSSH_USER=operator\nSSH_OLD_PORTS=(22)\n')
            cfg.save_json(install/'current/state.json',{'ssh_confirmed':False})
            for name in ['ssh.sh','firewall.sh','confirm-access.sh']:
                source=(ROOT/'lib'/name).read_text().replace('/etc/',str(p/'etc')+'/').replace('/opt/xray-vps-setup',str(install))
                if name=='confirm-access.sh': source='\n'.join(line for line in source.splitlines() if not line.startswith('[[ $EUID'))+'\n'
                (install/'lib'/name).write_text(source)
            for name in ['ssh_policy.py','setup_config.py']: (install/'lib'/name).write_text((ROOT/'lib'/name).read_text())
            body=f'''export SUDO_USER=operator SSH_CONNECTION='192.0.2.4 12345 192.0.2.1 22'
systemctl() {{ echo "$*" >> "{p}/systemctl"; }}
systemd-run() {{ :; }}
flock() {{ :; }}
sshd() {{ if [[ "$1" == -T ]]; then printf 'passwordauthentication no\nkbdinteractiveauthentication no\npermitrootlogin no\npubkeyauthentication yes\nauthenticationmethods any\n'; fi; }}
ss() {{ echo listener; }}
iptables-save() {{ echo fixture; }}
iptables-restore() {{ cat >/dev/null; }}
iptables() {{ if [[ "$*" == *' -C '* ]]; then return 1; fi; }}
source "{install}/lib/confirm-access.sh"'''
            result=self.run_shell(body)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertTrue(json.loads((install/'current/state.json').read_text())['ssh_confirmed'])
            self.assertIn('restart ssh.socket ssh.service',(p/'systemctl').read_text())
            self.assertEqual(list(install.glob('ssh-confirm.*')),[])

    def test_checkpoint_replaces_stale_link_after_interruption(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)
            for directory in ['etc','install/backups','release','previous']:(p/directory).mkdir(parents=True)
            (p/'install/.last-transaction-next').symlink_to(p/'previous')
            script=p/'installer.sh';script.write_text((ROOT/'vps-setup.sh').read_text().replace('/etc/',str(p/'etc')+'/'))
            body=f'''source "{script}"
LIB="{ROOT}/lib"; INSTALL_ROOT="{p}/install"; RELEASE_DIR="{p}/release"; OLD_CURRENT="{p}/previous"
iptables-save() {{ echo fixture; }}
ip6tables-save() {{ echo fixture; }}
mv() {{ python3 -c 'import os,sys;os.replace(sys.argv[1],sys.argv[2])' "${{@: -2}}"; }}
checkpoint'''
            result=self.run_shell(body)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual((p/'install/last-transaction').resolve(),(p/'release').resolve())
            metadata=json.loads((p/'release/deployment.json').read_text())
            self.assertEqual(metadata['previous'],str(p/'previous'))
            self.assertTrue(Path(metadata['backup'],'ipv4').exists())

    def test_recover_attempts_local_restore_when_api_authentication_fails(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);(p/'backups/fixture').mkdir(parents=True);(p/'release').mkdir()
            cfg.save_json(p/'release/deployment.json',{'status':'activating','backup':str(p/'backups/fixture'),'previous':''})
            cfg.save_json(p/'release/api-transaction.json',{'status':'applied'})
            (p/'last-transaction').symlink_to(p/'release')
            body=f'''ACTION=recover
preflight() {{ INSTALL_ROOT="{p}"; }}
python3() {{ if [[ "$*" == *'panel_api.py recover'* ]]; then return 1; fi; command python3 "$@"; }}
rollback_system() {{ echo attempted > "{p}/local-restore"; return 1; }}
main'''
            result=self.run_shell(body)
            self.assertNotEqual(result.returncode,0)
            self.assertTrue((p/'local-restore').exists())
            self.assertNotIn('recovery completed',result.stdout)

    def test_repeated_ssh_preparation_does_not_duplicate_listeners(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);(p/'home/operator').mkdir(parents=True)
            cfg.save_json(p/'state.json',{'ssh':{'user':'operator','port':22,'public_key':'fixture-public-key','password':'fixture'}})
            source=(ROOT/'lib/ssh.sh').read_text().replace('/run/sshd',str(p/'run/sshd')).replace('/etc/',str(p/'etc')+'/').replace('/home/',str(p/'home')+'/')
            script=p/'ssh.sh';script.write_text(source)
            body=f'''source "{script}"
RUN_DIR="{p}"; STATE_FILE="{p}/state.json"; LIB="{ROOT}/lib"; INSTALL_ROOT="{p}"; INSTALL_MODE=xray; INGRESS_IP=''; EGRESS_IP=''
id() {{ if [[ "$1" == -gn ]]; then echo fixture; fi; }}
usermod() {{ :; }}
chown() {{ :; }}
ssh-keygen() {{ :; }}
getent() {{ echo 'operator:x:1:1:fixture:{p}/home/operator:/bin/bash'; }}
install() {{ if [[ "$*" == *' -o '* ]]; then mkdir -p "${{!#}}"; else command install "$@"; fi; }}
sshd() {{ if [[ "$1" == -T ]]; then printf 'port 22\nport 22\n'; fi; }}
systemctl() {{ :; }}
ss() {{ echo listener; }}
prepare_ssh
prepare_ssh'''
            result=self.run_shell(body)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual((p/'etc/ssh/sshd_config.d/00-xray-vps-setup.conf').read_text(),'Port 22\n')
            socket_config=(p/'etc/systemd/system/ssh.socket.d/zz-xray-vps-setup.conf').read_text()
            self.assertEqual(socket_config.count('ListenStream=0.0.0.0:22'),1)
            self.assertNotIn('ListenStream=22',socket_config)
            self.assertIn('BindIPv6Only=ipv6-only',socket_config)
            self.assertEqual((p/'home/operator/.ssh/authorized_keys').read_text(),'fixture-public-key\n')

    def test_node_firewall_is_ordered_private_and_repeatable(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);s=state('node');s.update(panel_domain='panel.example.com',node_address='node.example.com',management_sources=['192.0.2.7/32','2001:db8::7/128'])
            cfg.save_json(p/'state.json',s)
            body=f'''RUN_DIR={d}; STATE_FILE={p}/state.json; INSTALL_MODE=node; INGRESS_IP=''; EGRESS_IP=''; SSH_NEW_PORT=2222; SSH_OLD_PORTS=(22); SSH_CONFIRMED=n
source "{ROOT}/lib/firewall.sh"
iptables() {{ if [[ "$*" == *' -C '* ]]; then return 1; fi; echo "$*" >> "{p}/commands"; }}
iptables-restore() {{ cat >> "{p}/rules"; }}
apply_family iptables iptables-restore 4
apply_family iptables iptables-restore 4
'''
            result=self.run_shell(body);self.assertEqual(result.returncode,0,result.stderr)
            rules=(p/'rules').read_text();self.assertIn('-F XRAY_SETUP',rules)
            self.assertLess(rules.index('-s 192.0.2.7/32'),rules.index('--dports 62001,62002 -j REJECT'))
            self.assertIn('--dport 22 -j ACCEPT',rules);self.assertIn('--dport 2222 -j ACCEPT',rules)
            self.assertNotIn('2001:db8',rules);self.assertNotIn('-P INPUT',rules)
            self.assertIn('-I INPUT 1 -j XRAY_SETUP',(p/'commands').read_text())

    def test_ssh_ports_include_socket_and_running_daemon(self):
        result=self.run_shell(f'''source "{ROOT}/lib/ssh.sh"
sshd() {{ echo 'port 22'; }}
ss() {{ echo 'LISTEN 0 128 0.0.0.0:2022 0.0.0.0:* users:(("sshd",pid=1,fd=3))'; }}
systemctl() {{ if [[ "$1" == show ]]; then echo '0.0.0.0:2222 (Stream) [::]:2222 (Stream)'; fi; }}
existing_ssh_ports''')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout,'22\n2022\n2222\n')

    def test_ipv6_listener_cannot_satisfy_ssh_readiness(self):
        result=self.run_shell(f'''source "{ROOT}/lib/ssh.sh"
SSH_NEW_PORT=22
ss() {{ if [[ "$1" != -4 ]]; then echo listener; fi; }}
if check_ssh_listener; then echo wrong; else echo rejected; fi''')
        self.assertEqual(result.stdout,'rejected\n',result.stderr)

    def test_ssh_restart_uses_one_socket_service_transaction(self):
        result=self.run_shell(f'''source "{ROOT}/lib/ssh.sh"
systemctl() {{ echo "$*"; if [[ "$1" == is-active ]]; then return 1; fi; }}
restart_ssh''')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('restart ssh.socket ssh.service\n',result.stdout)

    def test_confirmation_rollback_restarts_ssh_despite_firewall_failure(self):
        source=(ROOT/'lib/confirm-access.sh').read_text()
        start=source.index('cat > "$RUN_DIR/rollback.sh"');end=source.index('chmod 0700',start)
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);(p/'lib').mkdir();(p/'etc/ssh/sshd_config.d').mkdir(parents=True)
            for name in ['state.json','ssh.conf','ipv4']: (p/name).write_text('fixture')
            (p/'lib/ssh.sh').write_text('restart_ssh() { echo restarted; }\n')
            generator=source[start:end].replace('/etc/',str(p/'etc')+'/')
            body=f'''RUN_DIR="{p}"; STATE_FILE="{p}/restored.json"; INSTALL_ROOT="{p}"
{generator}
iptables-restore() {{ cat >/dev/null; return 1; }}
systemctl() {{ echo "$*"; }}
source "$RUN_DIR/rollback.sh"'''
            result=self.run_shell(body)
            self.assertEqual(result.returncode,1,result.stderr)
            self.assertIn('restarted\n',result.stdout)
            self.assertIn('enable xray-setup-firewall.service',result.stdout)
            self.assertEqual((p/'restored.json').read_text(),'fixture')

    def test_failed_confirmation_rollback_keeps_timer_armed(self):
        source=(ROOT/'lib/confirm-access.sh').read_text()
        start=source.index('rollback() {');end=source.index("printf 'Port %s",start)
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);script=p/'rollback.sh';script.write_text('#!/bin/sh\nexit 1\n');script.chmod(0o700)
            result=self.run_shell(f'RUN_DIR="{p}"; unit=fixture\nsystemctl() {{ echo "$*"; }}\n'+source[start:end]+'false')
            self.assertEqual(result.returncode,1)
            self.assertNotIn('stop fixture.timer',result.stdout)
            self.assertIn('timer and recovery files retained',result.stderr)

    def test_firewall_check_detects_bypass_and_missing_ssh_allow(self):
        for fault in ['', 'bypass', 'missing-ssh']:
            with self.subTest(fault=fault):
                result=self.run_shell(f'''source "{ROOT}/lib/firewall.sh"
INSTALL_MODE=xray; INGRESS_IP=''; EGRESS_IP=''; SSH_NEW_PORT=22
iptables() {{
 if [[ "$*" == *' -S INPUT'* ]]; then
   [[ '{fault}' != bypass ]] || echo '-A INPUT -j ACCEPT'
   echo '-A INPUT -j XRAY_SETUP'
 elif [[ '{fault}' == missing-ssh && "$*" == *'--dport 22 -j ACCEPT'* ]]; then return 1
 elif [[ "$*" != *' -C '* ]]; then echo MUTATION; return 1
 fi
}}
ip6tables() {{ iptables "$@"; }}
check_firewall''')
                self.assertEqual(result.returncode,0 if not fault else 1,result.stderr)
                self.assertNotIn('MUTATION',result.stdout)


class SshPolicyTests(unittest.TestCase):
    def test_match_auth_overrides_in_nested_includes_are_rejected(self):
        for directive in ['PasswordAuthentication yes','PermitRootLogin prohibit-password',
                          'KbdInteractiveAuthentication=yes','ChallengeResponseAuthentication yes']:
            with self.subTest(directive=directive),tempfile.TemporaryDirectory() as d:
                p=Path(d);(p/'included').write_text('Match User root\n'+directive+'\n')
                (p/'config').write_text('PasswordAuthentication no\nInclude '+str(p/'included')+'\n')
                with self.assertRaises(ValueError): ssh_policy.check(p/'config')

    def test_safe_match_settings_and_recursive_include(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'config';p.write_text('Match User root\nPermitRootLogin no\nX11Forwarding no\n')
            ssh_policy.check(p)
            p.write_text('Include '+str(p)+'\n')
            with self.assertRaises(ValueError): ssh_policy.check(p)


class RuntimeHealthTests(unittest.TestCase):
    def test_stopped_restarting_and_paused_containers_are_rejected(self):
        for mode in ['xray','marzban','node']:
            for fault in ['', 'Running','Restarting','Paused']:
                names=['angie','marzban-node' if mode=='node' else mode]
                containers=[{'Name':name,'State':{'Running':True,'Restarting':False,'Paused':False}} for name in names]
                if fault: containers[1]['State'][fault]=fault!='Running'
                with self.subTest(mode=mode,fault=fault),patch('health.subprocess.run') as run:
                    run.return_value.stdout=json.dumps(containers)
                    if fault:
                        with self.assertRaises(RuntimeError): health.check_containers({'mode':mode})
                    else: health.check_containers({'mode':mode})
                    self.assertEqual(run.call_args.args[0],['docker','inspect',*names])


@unittest.skipUnless(BINARY,'Set XRAY_TEST_BINARY for actual Xray config acceptance')
class NativeTests(unittest.TestCase):
    def test_node_contract_added_vision_is_accepted_by_xray(self):
        s=cfg.new_state('marzban','main.example.com',{'grpc':['main.example.com'],'vision':[]},BINARY)
        core=cfg.server_config(TEMPLATE,s);core['inbounds']=[core['inbounds'][0]]
        core=cfg.panel_contract(core,{'grpc':['node.example.com'],'vision':['vision.node.example.com']})
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'config.json';cfg.save_json(p,core)
            result=subprocess.run([BINARY,'run','-test','-config',str(p)],capture_output=True,text=True,timeout=20)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)

    def test_transport_matrix_and_empty_panel_vision(self):
        for mode in ['xray','marzban']:
            for vision in [[],['vision.example.com']]:
                s=cfg.new_state(mode,'main.example.com',{'grpc':['main.example.com'],'vision':vision},BINARY)
                cfg.validate_state(s)
                with tempfile.TemporaryDirectory() as d:
                    p=Path(d)/'config.json';cfg.save_json(p,cfg.server_config(TEMPLATE,s))
                    result=subprocess.run([BINARY,'run','-test','-config',str(p)],capture_output=True,text=True,timeout=20)
                    self.assertEqual(result.returncode,0,result.stdout+result.stderr)


if __name__=='__main__': unittest.main()
