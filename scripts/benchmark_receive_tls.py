#!/usr/bin/env python3
"""Synthetic TLS receive check; requires development-only cryptography and swiftc."""
from pathlib import Path
import datetime, ipaddress, json, socket, ssl, struct, subprocess, tempfile, threading
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID
root=Path(__file__).resolve().parents[1]
frames=1000
with tempfile.TemporaryDirectory(prefix='spatialpc-network-fixture-') as temp:
    folder=Path(temp)
    key=ec.generate_private_key(ec.SECP256R1())
    name=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'Spatial PC disposable loopback fixture')])
    now=datetime.datetime.now(datetime.timezone.utc)
    ca=(x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
        .serial_number(x509.random_serial_number()).not_valid_before(now-datetime.timedelta(minutes=5))
        .not_valid_after(now+datetime.timedelta(days=1)).add_extension(x509.BasicConstraints(ca=True,path_length=0),critical=True)
        .add_extension(x509.KeyUsage(False,False,False,False,False,True,True,False,False),critical=True)
        .sign(key,hashes.SHA256()))
    leaf_key=ec.generate_private_key(ec.SECP256R1())
    leaf=(x509.CertificateBuilder().subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'localhost')]))
        .issuer_name(name).public_key(leaf_key.public_key()).serial_number(x509.random_serial_number())
        .not_valid_before(now-datetime.timedelta(minutes=5)).not_valid_after(now+datetime.timedelta(hours=1))
        .add_extension(x509.BasicConstraints(ca=False,path_length=None),critical=True)
        .add_extension(x509.KeyUsage(True,False,False,False,False,False,False,False,False),critical=True)
        .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]),critical=False)
        .add_extension(x509.SubjectAlternativeName([x509.DNSName('localhost'),x509.IPAddress(ipaddress.ip_address('127.0.0.1'))]),critical=False)
        .sign(key,hashes.SHA256()))
    (folder/'cert.pem').write_bytes(leaf.public_bytes(serialization.Encoding.PEM)+ca.public_bytes(serialization.Encoding.PEM))
    (folder/'cert.der').write_bytes(ca.public_bytes(serialization.Encoding.DER))
    key=leaf_key
    (folder/'key.pem').write_bytes(key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))
    (folder/'key.pem').chmod(0o600)
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version=ssl.TLSVersion.TLSv1_3
    context.set_alpn_protocols(['spatialpc-network-bench/1'])
    context.load_cert_chain(folder/'cert.pem',folder/'key.pem')
    binary=folder/'probe'
    subprocess.run(['swiftc','-O',str(root/'visionos/SpatialPC/Streaming/StreamWire.swift'),str(root/'visionos/SpatialPC/Streaming/ExactStreamReader.swift'),str(root/'scripts/ReceiveTLSProbe.swift'),'-o',str(binary)],check=True)
    results=[]
    for mode in ['baseline','candidate','candidate','baseline']:
        errors=[]
        with socket.socket() as listener:
            listener.bind(('127.0.0.1',0)); listener.listen(1); listener.settimeout(20)
            port=listener.getsockname()[1]
            def serve():
                try:
                    raw,_=listener.accept(); raw.settimeout(20)
                    raw.setsockopt(socket.IPPROTO_TCP,socket.TCP_NODELAY,1) # Match the Windows host.
                    with context.wrap_socket(raw,server_side=True) as stream:
                        if stream.selected_alpn_protocol()!='spatialpc-network-bench/1':raise ValueError('ALPN')
                        for index in range(frames):
                            payload=struct.pack('!Q',index)+bytes([0xA5])*(65536-8)
                            stream.sendall(struct.pack('!I',len(payload)))
                            # Separate TLS writes also exercise record fragmentation.
                            for offset in range(0,len(payload),16384):stream.sendall(payload[offset:offset+16384])
                except Exception as error:errors.append(type(error).__name__)
            thread=threading.Thread(target=serve,daemon=True);thread.start()
            try:
                completed=subprocess.run([str(binary),str(port),str(folder/'cert.der'),mode,str(frames)],capture_output=True,text=True,timeout=30)
            except subprocess.TimeoutExpired as error:
                raise RuntimeError(f'Client timeout; server={errors}; stages={error.stderr!r}') from error
            thread.join(timeout=21)
            if completed.returncode or thread.is_alive() or errors:
                raise RuntimeError(f'Fixture failed: client={completed.returncode}, server={errors}; {completed.stderr[-2000:]}')
            results.append(json.loads(completed.stdout))
    print(json.dumps({'fixtureClosed':True,'retainedPayloads':False,'runs':results},indent=2))
