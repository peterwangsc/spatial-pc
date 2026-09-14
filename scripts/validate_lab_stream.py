import ssl,socket,json,struct,hashlib,subprocess
from pathlib import Path
import argparse
parser=argparse.ArgumentParser(description='Validate TLS rejection and live native hardware decoding; no pixel files are written.')
parser.add_argument('--pair-directory',type=Path,required=True)
parser.add_argument('--decoder',type=Path,required=True)
parser.add_argument('--frames',type=int,default=120,help='Frames to decode (1-36000); no image retention')
args=parser.parse_args()
if not 1<=args.frames<=36000:parser.error('--frames must be between 1 and 36000')
root=args.pair_directory;pair=json.loads((root/'lab-pair.json').read_text())
def exact(s,n):
 b=bytearray()
 while len(b)<n:
  c=s.recv(n-len(b))
  if not c:raise EOFError()
  b.extend(c)
 return bytes(b)
def context(client=True,trusted=True):
 c=ssl.create_default_context(cafile=str(root/'root.pem') if trusted else None)
 c.minimum_version=ssl.TLSVersion.TLSv1_3;c.set_alpn_protocols(['spatialpc/1'])
 if client:c.load_cert_chain(str(root/'client.pem'),str(root/'client-key.pem'))
 return c
def connect(c):
 return c.wrap_socket(socket.create_connection((pair['host'],pair['port']),timeout=10),server_hostname=pair['serverName'])
hello=json.dumps(dict(version=1,codecs=['h264-annexb'],maxWidth=8192,maxHeight=8192)).encode()
for label,c in [('missing-client-certificate',context(False)),('untrusted-host',context(trusted=False))]:
 try:
  with connect(c) as s:
   # Send an otherwise valid hello so malformed application input cannot mask
   # an authentication failure. TLS 1.3 rejection may surface as EOF or reset.
   s.sendall(b'SPC1'+struct.pack('!I',len(hello))+hello)
   if s.recv(1):raise AssertionError(label+' unexpectedly accepted')
 except (ssl.SSLError,ConnectionResetError,BrokenPipeError):pass
 print(label+' rejected',flush=True)
with connect(context()) as s:
 assert hashlib.sha256(s.getpeercert(binary_form=True)).hexdigest()==pair['serverSHA256']
 print('tls='+s.version()+' alpn='+str(s.selected_alpn_protocol()),flush=True)
 s.sendall(b'SPC1'+struct.pack('!I',len(hello))+hello)
 header=exact(s,8);assert header[:4]==b'SPC1'
 count=struct.unpack('!I',header[4:])[0];assert count<=4096
 body=exact(s,count);print('server='+body.decode(),flush=True)
 p=subprocess.Popen([str(args.decoder.resolve()),str(args.frames)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 try:
  p.stdin.write(header+body)
  for i in range(args.frames):
   frame=exact(s,16);n=struct.unpack('!I',frame[:4])[0];assert 0<n<=16777216
   p.stdin.write(frame+exact(s,n));p.stdin.flush()
  p.stdin.close();p.wait(timeout=30)
  print(p.stdout.read().decode());print(p.stderr.read().decode()[-1500:]);assert p.returncode==0
 finally:
  if p.poll() is None:p.kill();p.wait()
