import asyncio
import base64
import hashlib
import os
from pathlib import Path
import socket
import ssl
import sys
import tempfile
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'windows'/'host'))
from product.identity import Identity
from product.pairing_server import PairingServer
from product.pairing_wire import read_record,write_record,decode_code,transcript,unb64,b64,proof
from cryptography import x509
from cryptography.hazmat.primitives import hashes,serialization
from cryptography.hazmat.primitives.asymmetric import ec


def free_port():
    with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]


@unittest.skipUnless(os.name=='nt','Windows protected identity integration')
class PairingIntegration(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp=tempfile.TemporaryDirectory();self.identity=Identity(Path(self.temp.name)/'identity')
        self.events=[];self.port=free_port()
        self.server=PairingServer(self.identity,'127.0.0.1',self.port,47993,self.events.append)
        self.code=decode_code(self.server.window.code());self.task=asyncio.create_task(self.server.run())
        await asyncio.wait_for(self.server.ready.wait(),3)

    async def asyncTearDown(self):
        self.server.stop();await asyncio.wait_for(self.task,5);self.temp.cleanup()

    async def client(self,wrong_hash=False):
        context=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT);context.check_hostname=False;context.verify_mode=ssl.CERT_NONE
        context.minimum_version=context.maximum_version=ssl.TLSVersion.TLSv1_3;context.set_alpn_protocols(['spatialpc-pair/1'])
        reader,writer=await asyncio.open_connection('127.0.0.1',self.port,ssl=context,server_hostname=self.identity.state['serverName'])
        tls=writer.get_extra_info('ssl_object');leaf=tls.getpeercert(binary_form=True)
        challenge=await read_record(reader)
        key=ec.generate_private_key(ec.SECP256R1());point=key.public_key().public_bytes(serialization.Encoding.X962,serialization.PublicFormat.UncompressedPoint)
        actual_hash=hashlib.sha256(leaf).digest()
        data=transcript(b'x'*32 if wrong_hash else actual_hash,bytes.fromhex(challenge['hostId']),unb64(challenge['windowId']),unb64(challenge['serverNonce']),b'c'*32,point,'Test headset')
        await write_record(writer,dict(version=1,type='proof',clientNonce=b64(b'c'*32),publicKey=b64(point),name='Test headset',
            proof=b64(proof(self.code,'client',data)),signature=b64(key.sign(b'client-key\0'+data,ec.ECDSA(hashes.SHA256())))))
        return reader,writer,key,data,leaf

    async def close(self,writer):
        writer.close()
        try:await asyncio.wait_for(writer.wait_closed(),2)
        except OSError:pass

    async def test_explicit_approval_certificate_binding_and_reload(self):
        reader,writer,key,data,leaf=await self.client()
        try:
            pending=await read_record(reader)
            self.assertEqual(unb64(pending['serverProof']),proof(self.code,'server',data))
            self.assertEqual(self.identity.state['devices'],[])
            approval=next(item for item in self.events if item['event']=='approval')
            self.server.approve(approval['requestId'],True)
            response=await read_record(reader,timeout=3)
            self.assertEqual(unb64(response['serverCertificate']),leaf)
            certificate=x509.load_der_x509_certificate(unb64(response['clientCertificate']))
            certificate.verify_directly_issued_by(self.identity.ca)
            self.assertEqual(certificate.public_key().public_numbers(),key.public_key().public_numbers())
            self.assertEqual(response['hostId'],self.identity.state['hostId'])
            reloaded=Identity(self.identity.directory)
            self.assertIsNotNone(reloaded.device_for(certificate.fingerprint(hashes.SHA256()).hex()))
            self.assertEqual(len(reloaded.state['devices']),1)
        finally:await self.close(writer)

    async def test_changed_tls_certificate_binding_and_attempt_limit(self):
        for _ in range(5):
            reader,writer,_,_,_=await self.client(wrong_hash=True)
            self.assertEqual(await asyncio.wait_for(reader.read(),2),b'')
            await self.close(writer)
        await asyncio.wait_for(self.task,3)
        self.assertFalse(self.server.window.is_open());self.assertEqual(self.identity.state['devices'],[])

    async def test_disconnect_after_proof_cancels_approval_and_consumes_code(self):
        reader,writer,_,_,_=await self.client();await read_record(reader)
        request_id=self.server.window.request_id
        await self.close(writer);await asyncio.wait_for(self.task,3)
        self.server.approve(request_id,True)
        self.assertEqual(self.identity.state['devices'],[])
        self.assertFalse(self.server.window.can_commit(request_id))

    async def test_expired_commit_and_explicit_denial_issue_no_certificate(self):
        reader,writer,_,_,_=await self.client();await read_record(reader)
        self.server.window.approval_expires=self.server.window.clock()-1
        self.server.approve(self.server.window.request_id,True)
        self.server.stop()
        self.assertEqual(await asyncio.wait_for(reader.read(),2),b'')
        await self.close(writer)
        self.assertEqual(self.identity.state['devices'],[])
