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
from product.pairing_wire import read_record,write_record,decode_code,unb64,b64,proof
from test_pairing_wire import make_proof
from cryptography import x509
from cryptography.hazmat.primitives import hashes,serialization
from cryptography.hazmat.primitives.asymmetric import ec


def free_port(address='127.0.0.1'):
    with socket.socket(socket.AF_INET6 if ':' in address else socket.AF_INET) as s:
        s.bind((address,0));return s.getsockname()[1]


@unittest.skipUnless(os.name=='nt','Windows protected identity integration')
class PairingIntegration(unittest.IsolatedAsyncioTestCase):
    ADDRESS='127.0.0.1'
    async def asyncSetUp(self):
        self.temp=tempfile.TemporaryDirectory();self.identity=Identity(Path(self.temp.name)/'identity')
        self.events=[];self.port=free_port(self.ADDRESS)
        self.server=PairingServer(self.identity,self.ADDRESS,self.port,47993,self.events.append)
        self.code=decode_code(self.server.window.code());self.task=asyncio.create_task(self.server.run())
        await asyncio.wait_for(self.server.ready.wait(),3)

    async def asyncTearDown(self):
        self.server.stop();await asyncio.wait_for(self.task,5);self.temp.cleanup()

    async def client(self,wrong_hash=False,port=None):
        context=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT);context.check_hostname=False;context.verify_mode=ssl.CERT_NONE
        context.minimum_version=context.maximum_version=ssl.TLSVersion.TLSv1_3;context.set_alpn_protocols(['spatialpc-pair/2'])
        reader,writer=await asyncio.open_connection(self.ADDRESS,port or self.port,ssl=context,server_hostname=self.identity.state['serverName'])
        tls=writer.get_extra_info('ssl_object');leaf=tls.getpeercert(binary_form=True)
        challenge=await read_record(reader)
        key=ec.generate_private_key(ec.SECP256R1());point=key.public_key().public_bytes(serialization.Encoding.X962,serialization.PublicFormat.UncompressedPoint)
        actual_hash=hashlib.sha256(leaf).digest()
        message,confirm,data,key=make_proof(challenge,self.code,b'x'*32 if wrong_hash else actual_hash,'Test headset')
        await write_record(writer,message)
        return reader,writer,key,(confirm,data),leaf

    async def close(self,writer):
        writer.close()
        try:await asyncio.wait_for(writer.wait_closed(),2)
        except OSError:pass

    async def test_explicit_approval_certificate_binding_and_reload(self):
        reader,writer,key,data,leaf=await self.client()
        try:
            pending=await read_record(reader)
            self.assertEqual(unb64(pending['serverProof']),proof(data[0],'server',data[1]))
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
        for _ in range(3):
            reader,writer,_,_,_=await self.client(wrong_hash=True)
            self.assertEqual(await asyncio.wait_for(reader.read(),2),b'')
            await self.close(writer)
        await asyncio.wait_for(self.task,3)
        self.assertFalse(self.server.window.is_open());self.assertEqual(self.identity.state['devices'],[])

    async def test_malformed_tls_handshakes_exhaust_window(self):
        for _ in range(3):
            reader,writer=await asyncio.open_connection(self.server.address,self.server.port)
            writer.write(b'not a TLS client hello\r\n');await writer.drain()
            try:await asyncio.wait_for(reader.read(),2)
            except OSError:pass
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

    async def test_explicit_denial_closes_and_consumes(self):
        reader,writer,_,_,_=await self.client();await read_record(reader)
        self.server.approve(self.server.window.request_id,False)
        self.assertEqual(await asyncio.wait_for(reader.read(),2),b'')
        await self.close(writer);await asyncio.wait_for(self.task,3)
        self.assertEqual(self.identity.state['devices'],[])

    async def test_disconnect_before_proof_still_spends_three_attempts(self):
        context=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT);context.check_hostname=False;context.verify_mode=ssl.CERT_NONE
        context.minimum_version=context.maximum_version=ssl.TLSVersion.TLSv1_3
        context.set_alpn_protocols(['spatialpc-pair/2'])
        for count in range(1,4):
            reader,writer=await asyncio.open_connection(self.ADDRESS,self.port,ssl=context,server_hostname='test')
            await read_record(reader)
            self.assertEqual(self.server.window.attempts,count)
            await self.close(writer)
        await asyncio.wait_for(self.task,3)
        self.assertEqual(self.identity.state['devices'],[])

    async def test_one_tls_and_pake_exchange_at_a_time(self):
        context=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT);context.check_hostname=False;context.verify_mode=ssl.CERT_NONE
        context.minimum_version=context.maximum_version=ssl.TLSVersion.TLSv1_3
        context.set_alpn_protocols(['spatialpc-pair/2'])
        first,writer=await asyncio.open_connection(self.ADDRESS,self.port,ssl=context,server_hostname='test')
        await read_record(first)
        second=asyncio.create_task(asyncio.open_connection(self.ADDRESS,self.port,ssl=context,server_hostname='test'))
        try:
            await asyncio.sleep(.1)
            self.assertFalse(second.done());self.assertEqual(self.server.window.attempts,1)
            await self.close(writer)
            reader,other=await asyncio.wait_for(second,3)
            try:
                await read_record(reader)
                self.assertEqual(self.server.window.attempts,2)
            finally:await self.close(other)
        finally:
            await self.close(writer)
            if not second.done():second.cancel()
            await asyncio.gather(second,return_exceptions=True)

    async def test_tls_terminating_relay_with_other_leaf_cannot_enroll(self):
        other_identity=Identity(Path(self.temp.name)/'proxy-identity')
        tasks=set()
        async def proxy(reader,writer):
            task=asyncio.current_task();tasks.add(task);upstream=None
            try:
                tls=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT);tls.check_hostname=False;tls.verify_mode=ssl.CERT_NONE
                tls.minimum_version=tls.maximum_version=ssl.TLSVersion.TLSv1_3;tls.set_alpn_protocols(['spatialpc-pair/2'])
                incoming,upstream=await asyncio.open_connection(self.ADDRESS,self.port,ssl=tls,server_hostname='test')
                await write_record(writer,await read_record(incoming))
                await write_record(upstream,await read_record(reader))
                # Authentication must fail before pending or credential output.
                result=await asyncio.wait_for(incoming.read(),2)
                self.assertEqual(result,b'')
            finally:
                if upstream:await self.close(upstream)
                await self.close(writer);tasks.discard(task)
        relay=await asyncio.start_server(proxy,self.ADDRESS,0,ssl=other_identity.tls_context(pairing=True))
        try:
            reader,writer,_,_,_=await self.client(port=relay.sockets[0].getsockname()[1])
            self.assertEqual(await asyncio.wait_for(reader.read(),3),b'')
            await self.close(writer)
            self.assertEqual(self.identity.state['devices'],[])
            self.assertFalse(any(e['event']=='approval' for e in self.events))
        finally:
            relay.close();await relay.wait_closed()
            if tasks:await asyncio.wait_for(asyncio.gather(*tasks),3)

    async def test_worker_opening_throttle_survives_disable_and_network(self):
        from product.main import Worker
        worker=Worker(self.identity,Path('unused-capture'),Path('unused-input'),lambda value:None,development=True,discovery=False)
        worker.pair_port=free_port(self.ADDRESS)
        try:
            for _ in range(5):
                await worker.command(dict(command='network',address=self.ADDRESS))
                worker.enabled=True # No stream/capture is needed to exercise pairing lifecycle.
                await worker.command(dict(command='pair'))
                await worker.command(dict(command='enable',value=False))
            await worker.command(dict(command='network',address=self.ADDRESS));worker.enabled=True
            with self.assertRaises(ValueError):await worker.command(dict(command='pair'))
            self.assertEqual(len(worker.opening_budget.openings),5)
        finally:await worker.stop()


@unittest.skipUnless(os.name=='nt' and socket.has_ipv6,'Windows IPv6 protected identity integration')
class PairingIPv6Integration(PairingIntegration):
    ADDRESS='::1'
