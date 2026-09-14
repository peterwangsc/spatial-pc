import asyncio
import json
import os
from pathlib import Path
import ssl
import socket
import struct
import sys
import tempfile
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'windows'/'host'))
from product.identity import Identity
from product.main import Worker
from input_protocol import Event
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from test_pairing_integration import free_port

FIXTURE=Path(os.environ.get('SPATIAL_PC_INPUT_FIXTURE',Path(__file__).resolve().parents[1]/'.local'/'input_fixture.exe'))


@unittest.skipUnless(os.name=='nt' and FIXTURE.is_file(),'Build windows/host/test_input.cmd first on Windows')
class ProductLifecycle(unittest.IsolatedAsyncioTestCase):
    ADDRESS='127.0.0.1'
    async def asyncSetUp(self):
        self.temp=tempfile.TemporaryDirectory();self.identity=Identity(Path(self.temp.name)/'state')
        self.events=[];self.worker=Worker(self.identity,FIXTURE,FIXTURE,self.events.append,development=True,discovery=False)
        self.worker.stream_port=free_port(self.ADDRESS);self.worker.pair_port=free_port(self.ADDRESS)
        self.key=ec.generate_private_key(ec.SECP256R1());self.device=self.identity.enroll(self.key.public_key(),'Lifecycle fixture')
        root=Path(self.temp.name)
        (root/'client.pem').write_bytes(__import__('base64').b64decode(self.device['certificate']))
        (root/'client-key.pem').write_bytes(self.key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))
        # SSL load_cert_chain needs PEM; the store intentionally carries public DER.
        from cryptography import x509
        (root/'client.pem').write_bytes(x509.load_der_x509_certificate((root/'client.pem').read_bytes()).public_bytes(serialization.Encoding.PEM))
        self.context=ssl.create_default_context(cadata=self.identity.state['caCertificate'])
        self.context.minimum_version=self.context.maximum_version=ssl.TLSVersion.TLSv1_3
        self.context.set_alpn_protocols(['spatialpc/1']);self.context.load_cert_chain(root/'client.pem',root/'client-key.pem')
        await self.worker.command(dict(command='network',address=self.ADDRESS))
        await self.worker.command(dict(command='enable',value=True))

    async def asyncTearDown(self):
        await self.worker.stop();self.temp.cleanup()

    async def connect(self):
        return await asyncio.open_connection(self.ADDRESS,self.worker.stream_port,ssl=self.context,server_hostname=self.identity.state['serverName'])

    async def streaming(self):
        reader,writer=await self.connect()
        hello=json.dumps(dict(version=1,codecs=['h264-annexb'],maxWidth=8192,maxHeight=8192,input={'version':1,'textVersion':1})).encode()
        writer.write(b'SPC1'+struct.pack('!I',len(hello))+hello);await writer.drain()
        header=await asyncio.wait_for(reader.readexactly(8),3)
        caps=json.loads(await reader.readexactly(struct.unpack('!I',header[4:])[0]))
        self.assertEqual(caps['input']['textVersion'],1)
        writer.write(Event(5,0,1,0,0,0).wire()+Event(4,1,2,4,0,0).wire());await writer.drain()
        deadline=asyncio.get_running_loop().time()+2
        while 'fixture_control_active' not in (self.identity.directory/'input-status.log').read_text():
            self.assertLess(asyncio.get_running_loop().time(),deadline);await asyncio.sleep(.01)
        return reader,writer

    async def assert_release(self):
        lines=(self.identity.directory/'input-status.log').read_text().splitlines()
        summary=json.loads(next(line.split('=',1)[1] for line in lines if line.startswith('fixture_input_summary=')))
        self.assertEqual(summary['downs'],1);self.assertEqual(summary['ups'],1)

    async def close(self,writer):
        writer.close()
        try:await writer.wait_closed()
        except OSError:pass

    async def test_disable_releases_input_and_closes_listener(self):
        reader,writer=await self.streaming()
        await self.worker.command(dict(command='enable',value=False))
        await asyncio.wait_for(reader.read(),2);await self.close(writer);await self.assert_release()
        self.assertFalse(self.worker.enabled)
        with self.assertRaises(OSError):await self.connect()

    async def test_revoke_active_device_releases_and_rejects_reconnect_before_capture(self):
        reader,writer=await self.streaming()
        await self.worker.command(dict(command='revoke',deviceId=self.device['id']))
        await asyncio.wait_for(reader.read(),2);await self.close(writer);await self.assert_release()
        before=(self.identity.directory/'encoder.log').stat().st_mtime_ns
        reader,writer=await self.connect()
        self.assertEqual(await asyncio.wait_for(reader.read(),2),b'');await self.close(writer)
        self.assertEqual((self.identity.directory/'encoder.log').stat().st_mtime_ns,before)
        self.assertIsNone(Identity(self.identity.directory).device_for(self.device['fingerprint']))

    async def test_shutdown_closes_pairing_and_active_stream(self):
        reader,writer=await self.streaming()
        await self.worker.command(dict(command='pair'))
        self.assertTrue(self.worker.pair.window.is_open())
        await self.worker.command(dict(command='shutdown'))
        await asyncio.wait_for(reader.read(),2);await self.close(writer);await self.assert_release()
        self.assertIsNone(self.worker.pair);self.assertFalse(self.worker.enabled)

    async def test_network_selection_rejects_wildcard_remote_and_invalid_scopes(self):
        await self.worker.stop()
        for address in ('0.0.0.0','::','ff02::fb','::ffff:127.0.0.1','fe80::1',
                        'fe80::1%invalid','fe80::1%4294967296','2001:db8::1','192.0.2.1'):
            with self.subTest(address=address),self.assertRaises(ValueError):
                await self.worker.command(dict(command='network',address=address))
        self.assertEqual(self.worker.address,self.ADDRESS)


@unittest.skipUnless(os.name=='nt' and socket.has_ipv6 and FIXTURE.is_file(),'Windows IPv6 native fixture required')
class ProductIPv6Lifecycle(ProductLifecycle):
    ADDRESS='::1'
