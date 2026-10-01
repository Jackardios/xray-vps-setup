"""Local real-Xray transport test. Requires XRAY_TEST_BINARY and openssl.
Private routing exceptions exist only inside this disposable test fixture.
"""
import pathlib,subprocess,socket,ssl,threading,time,json,copy,tempfile,os,sys
ROOT=pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'lib'))
from setup_config import new_state,server_config,render
B=pathlib.Path(os.environ['XRAY_TEST_BINARY']).resolve()
workspace=tempfile.TemporaryDirectory(prefix='xray-transport-test-')
P=pathlib.Path(workspace.name); processes=[]; logs=[]
state=new_state('xray','main.example.com',{'grpc':['main.example.com'],'vision':['vision.example.com']},B)
(P/'xray.json').write_text(json.dumps(server_config((ROOT/'templates_for_script/xray').read_text(),state)))
k=state['keys']
values={'VLESS_DOMAIN':state['domain'],'XRAY_UUID':k['uuid'],'XRAY_PBK':k['public'],'XRAY_SID':k['short_ids'][0],
        'XRAY_SERVICE_NAME':k['service'],'CLIENT_SOCKS_PORT':10808,'CLIENT_SOCKS_USER':'audituser','CLIENT_SOCKS_PASS':'auditpassword'}
(P/'xray_full_client.json').write_text(render((ROOT/'templates_for_script/xray_full_client').read_text(),values))
def freeport():
 with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(P/'fixture.key'),'-out',str(P/'fixture.crt'),'-days','1','-subj','/CN=main.example.com'],capture_output=True,check=True,timeout=20)
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(P/'fixture.crt',P/'fixture.key');ctx.set_alpn_protocols(['h2','http/1.1']);ctx.minimum_version=ssl.TLSVersion.TLSv1_3
stop=threading.Event(); tls=socket.socket();tls.bind(('127.0.0.1',0));tls.listen();tls.settimeout(.2);tp=tls.getsockname()[1]
def decoy_one(raw):
 try:
  raw.settimeout(5);line=b''
  while not line.endswith(b'\r\n'):line+=raw.recv(1)
  assert line.startswith(b'PROXY ')
  with ctx.wrap_socket(raw,server_side=True) as s:
   try:s.recv(4096)
   except (TimeoutError,ssl.SSLError):pass
 except Exception:raw.close()
def decoy():
 while not stop.is_set():
  try:s,_=tls.accept();threading.Thread(target=decoy_one,args=(s,),daemon=True).start()
  except socket.timeout:pass
threading.Thread(target=decoy,daemon=True).start()
up=socket.socket();up.bind(('127.0.0.1',0));up.listen();up.settimeout(.2);up_port=up.getsockname()[1]
def upstream():
 while not stop.is_set():
  try:
   s,_=up.accept();s.settimeout(5)
   with s:
    s.recv(4096);body=b'audit-tunnel-ok';s.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: '+str(len(body)).encode()+b'\r\nConnection: close\r\n\r\n'+body)
  except socket.timeout:pass
threading.Thread(target=upstream,daemon=True).start()
def start(config,name):
 file=P/(name+'.json');file.write_text(json.dumps(config));log=open(P/(name+'.log'),'w');logs.append(log)
 p=subprocess.Popen([str(B),'run','-config',str(file)],stdout=log,stderr=log);processes.append(p);return p
def waitport(port,p):
 deadline=time.monotonic()+5
 while time.monotonic()<deadline:
  if p.poll() is not None:raise RuntimeError('Xray exited '+str(p.returncode))
  try:
   with socket.create_connection(('127.0.0.1',port),.2):return
  except OSError:time.sleep(.1)
 raise RuntimeError('listener not ready')
def recv(s,n):
 data=b''
 while len(data)<n:
  b=s.recv(n-len(data))
  if not b:raise RuntimeError('unexpected EOF '+repr(data))
  data+=b
 return data
results=[]
try:
 for transport in ['grpc','tcp']:
  server=json.loads((P/'xray.json').read_text());inbound=copy.deepcopy(server['inbounds'][0 if transport=='grpc' else 1]);port=freeport();inbound['port']=port;inbound['streamSettings']['realitySettings']['dest']=f'127.0.0.1:{tp}';server['inbounds']=[inbound];server['log']['loglevel']='warning'
  # Exception only for local echo fixture; production's private-IP block stays tested elsewhere.
  server['routing']['rules'].insert(0,{'ip':['127.0.0.1'],'port':str(up_port),'outboundTag':'direct'})
  sp=start(server,'e2e-server-'+transport);waitport(port,sp)
  client=json.loads((P/'xray_full_client.json').read_text());cp=freeport();client['inbounds'][0]['port']=cp;out=client['outbounds'][0];out['settings']['vnext'][0]['address']='127.0.0.1';out['settings']['vnext'][0]['port']=port;out['streamSettings']['network']=transport
  if transport=='tcp':
   out['streamSettings'].pop('grpcSettings',None);out['settings']['vnext'][0]['users'][0]['flow']='xtls-rprx-vision'
   out['streamSettings']['realitySettings']['serverName']='vision.example.com'
  # Remove private routing on client for the isolated loopback fixture only.
  client['routing']['rules']=[]
  cproc=start(client,'e2e-client-'+transport);waitport(cp,cproc)
  with socket.create_connection(('127.0.0.1',cp),5) as s:
   s.settimeout(10);s.sendall(b'\x05\x01\x02');assert recv(s,2)==b'\x05\x02'
   user=b'audituser';pw=b'auditpassword';s.sendall(b'\x01'+bytes([len(user)])+user+bytes([len(pw)])+pw);assert recv(s,2)==b'\x01\x00'
   s.sendall(b'\x05\x01\x00\x01\x7f\x00\x00\x01'+up_port.to_bytes(2,'big'));response=recv(s,10);assert response[1]==0,response
   s.sendall(b'GET / HTTP/1.1\r\nHost: fixture\r\nConnection: close\r\n\r\n');data=b''
   while True:
    b=s.recv(4096)
    if not b:break
    data+=b
   assert b'audit-tunnel-ok' in data,data
   results.append({'transport':transport,'authenticated_tunnel':'PASS'})
  with socket.create_connection(('127.0.0.1',cp),5) as s:
   s.settimeout(3);s.sendall(b'\x05\x01\x00');assert recv(s,2)==b'\x05\xff';results[-1]['no_auth_rejected']='PASS'
  cproc.terminate();sp.terminate();cproc.wait(timeout=5);sp.wait(timeout=5)
 print(json.dumps(results,indent=2));(P/'e2e-results.json').write_text(json.dumps(results,indent=2))
finally:
 stop.set();tls.close();up.close()
 for p in processes:
  if p.poll() is None:p.terminate()
 for p in processes:
  try:p.wait(timeout=5)
  except subprocess.TimeoutExpired:p.kill();p.wait()
 for l in logs:l.close()
 workspace.cleanup()
