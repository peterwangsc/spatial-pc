"""Ephemeral loopback TLS only; disposable identities and no media operations."""
import asyncio
import hashlib
from pathlib import Path
import ssl
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'windows'/'host'))
from cryptography.hazmat.primitives.asymmetric import ec
from product.identity import Identity, private_pem
from product import control_wire as wire
from product.focus_control import FocusControl
from product.main import Worker
from test_focus_control import request
from test_focus_host import Deployment, Adapter


class ControlTLS(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.identity = Identity(root/'identity', protect=lambda data, **ignored: data,
            secure_directory=lambda path: path.mkdir(parents=True, exist_ok=True))
        self.worker = Worker(self.identity, root/'capture.exe', root/'input.exe', lambda _: None,
            discovery=False, focus_deployment=Deployment(), focus_factory=Adapter)
        self.worker.enabled = True; self.worker.address = '127.0.0.1'
        self.hub = FocusControl(self.worker); self.worker.control = self.hub
        self.key = ec.generate_private_key(ec.SECP256R1())
        self.device = self.identity.enroll(self.key.public_key(), 'Public TLS fixture')
        self.clients = []
        with patch.object(wire, 'PORT', 0): await self.hub.start()
        self.port = self.hub.listener.getsockname()[1]

    async def asyncTearDown(self):
        for _, writer in self.clients:
            writer.close()
            try: await writer.wait_closed()
            except (OSError, ssl.SSLError): pass
        await self.hub.close()
        self.assertIsNone(self.worker.focus.token)
        self.temp.cleanup()

    def context(self, alpn=wire.ALPN, certificate=True):
        context = ssl.create_default_context(cadata=self.identity.state['caCertificate'])
        context.minimum_version = context.maximum_version = ssl.TLSVersion.TLSv1_3
        context.set_alpn_protocols([alpn])
        if certificate:
            import base64
            from cryptography import x509
            from cryptography.hazmat.primitives.serialization import Encoding
            root = Path(self.temp.name)
            cert = x509.load_der_x509_certificate(base64.b64decode(self.device['certificate']))
            (root/'client.pem').write_bytes(cert.public_bytes(Encoding.PEM))
            (root/'client.key').write_text(private_pem(self.key), encoding='ascii')
            context.load_cert_chain(root/'client.pem', root/'client.key')
        return context

    async def connect(self, **options):
        pair = await asyncio.wait_for(asyncio.open_connection('127.0.0.1', self.port,
            ssl=self.context(**options), server_hostname=self.identity.state['serverName']), 2)
        self.clients.append(pair)
        return pair

    async def eof(self, reader):
        try: self.assertEqual(await asyncio.wait_for(reader.read(1), 2), b'')
        except (ConnectionResetError, ssl.SSLError): pass

    async def test_actual_mtls_alpn_and_capabilities_no_media(self):
        import json
        import struct
        reader, writer = await self.connect()
        self.assertEqual(writer.get_extra_info('ssl_object').version(), 'TLSv1.3')
        self.assertEqual(writer.get_extra_info('ssl_object').selected_alpn_protocol(), wire.ALPN)
        self.assertEqual(hashlib.sha256(writer.get_extra_info('ssl_object').getpeercert(binary_form=True)).hexdigest(),
                         self.identity.server.fingerprint(__import__('cryptography.hazmat.primitives.hashes', fromlist=['SHA256']).SHA256()).hex())
        writer.write(wire.encode(request(1, 'capabilities'))); await writer.drain()
        size = struct.unpack('>I', await reader.readexactly(4))[0]
        result = json.loads(await reader.readexactly(size))
        self.assertFalse(result['result']['focusAllowed']); self.assertFalse(result['result']['consumerReady'])
        self.assertEqual(self.worker.media.mode, 'idle')

    async def test_wrong_alpn_rejected_before_control(self):
        reader, _ = await self.connect(alpn='spatialpc/1'); await self.eof(reader)
        self.assertFalse(self.hub.sessions)

    async def test_unenrolled_certificate_rejected(self):
        context = self.context()
        self.identity.revoke(self.device['id'])
        pair = await asyncio.open_connection('127.0.0.1', self.port, ssl=context,
                                             server_hostname=self.identity.state['serverName'])
        self.clients.append(pair); await self.eof(pair[0]); self.assertFalse(self.hub.sessions)

    async def test_missing_client_certificate_rejected(self):
        try:
            reader, _ = await self.connect(certificate=False)
            await self.eof(reader)
        except (ConnectionResetError, ssl.SSLError): pass
        self.assertFalse(self.hub.sessions)

    async def test_duplicate_device_connection_rejected(self):
        await self.connect()
        async with asyncio.timeout(2):
            while not self.hub.sessions: await asyncio.sleep(.001)
        reader, _ = await self.connect(); await self.eof(reader)
        self.assertEqual(len(self.hub.sessions), 1)

    async def test_two_total_connections_including_handshakes(self):
        for _ in range(2): self.clients.append(await asyncio.open_connection('127.0.0.1', self.port))
        async with asyncio.timeout(2):
            while len(self.hub.tasks) != 2: await asyncio.sleep(.001)
        pair = await asyncio.open_connection('127.0.0.1', self.port); self.clients.append(pair)
        await self.eof(pair[0]); self.assertEqual(len(self.hub.tasks), 2)

    async def test_revoke_connected_certificate_closes_control(self):
        reader, _ = await self.connect()
        async with asyncio.timeout(2):
            while not self.hub.sessions: await asyncio.sleep(.001)
        self.identity.revoke(self.device['id']); self.hub.revoke(self.device['id'])
        await self.eof(reader)


if __name__ == '__main__': unittest.main()
