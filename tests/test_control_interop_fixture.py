"""New harness checks only: no listener, timer window, runtime, input or DPAPI."""
import asyncio
import base64
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import AsyncMock, patch
sys.path.insert(0, str(Path(__file__).resolve().parent/'support'))
from control_interop_fixture import Fixture, MemoryIdentity, decode_command
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from product.focus_control import ControlSession


def key_bytes(key):
    return key.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)


class Grammar(unittest.TestCase):
    def test_reject_unknown_duplicate_and_unbounded_commands(self):
        values = [b'{"version":1,"version":1,"type":"status"}', b' ' * 8193,
            b'{"version":true,"type":"status"}', b'{"version":1,"type":"startRuntime"}',
            b'{"version":1,"type":"arm","lifetimeSeconds":true}',
            b'{"version":1,"type":"arm","lifetimeSeconds":181}',
            b'{"version":1,"type":"arm","lifetimeSeconds":10,"address":"0.0.0.0"}',
            b'{"version":1,"type":"permission","requestId":"x","accepted":true}']
        for raw in values:
            with self.subTest(raw=raw[:100]), self.assertRaises(ValueError): decode_command(raw)

    def test_exact_supported_records(self):
        for value in [dict(version=1,type='status'),dict(version=1,type='close'),
                      dict(version=1,type='arm',lifetimeSeconds=180)]:
            self.assertEqual(decode_command(json.dumps(value).encode()),value)


class FixtureTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.output=[];self.fixture=Fixture(self.output.append)
        self.key=ec.generate_private_key(ec.SECP256R1())
        self.forbid=patch.object(self.fixture,'open_loopback',AsyncMock(side_effect=AssertionError('No listener allowed in these tests')))
        self.open=self.forbid.start()

    async def asyncTearDown(self):
        await self.fixture.close();self.forbid.stop()

    async def enroll(self):
        await self.fixture.command(dict(version=1,type='enroll',publicKey=base64.b64encode(key_bytes(self.key)).decode()))

    async def test_default_and_enrollment_do_not_arm_or_write_identity(self):
        self.assertIsNone(self.fixture.hub)
        await self.enroll()
        self.assertFalse(self.fixture.armed);self.assertIsNone(self.fixture.expiry)
        self.assertIsNone(self.fixture.hub.listener);self.open.assert_not_called()
        self.assertIsNone(self.fixture.identity.directory)
        self.assertFalse(self.fixture.identity.state['devices'][0]['allowFocusControl'])

    async def test_public_bundle_matches_only_client_public_key_and_pins(self):
        await self.enroll();bundle=self.output[-1]
        client=x509.load_der_x509_certificate(base64.b64decode(bundle['clientCertificate']))
        server=x509.load_der_x509_certificate(base64.b64decode(bundle['serverCertificate']))
        ca=x509.load_der_x509_certificate(base64.b64decode(bundle['caCertificate']))
        client.verify_directly_issued_by(ca);server.verify_directly_issued_by(ca)
        self.assertEqual(client.public_key().public_numbers(),self.key.public_key().public_numbers())
        self.assertEqual(server.fingerprint(hashes.SHA256()).hex(),bundle['serverSHA256'])
        self.assertEqual(client.fingerprint(hashes.SHA256()).hex(),bundle['clientSHA256'])
        self.assertNotIn('PRIVATE',json.dumps(bundle));self.assertNotIn('privateKey',bundle)
        self.assertFalse(bundle['systemEndpointUsable']);self.assertEqual(len(bundle['deviceId']),32)

    async def test_enrollment_one_use_and_only_p256(self):
        wrong=ec.generate_private_key(ec.SECP384R1())
        with self.assertRaises(ValueError):
            await self.fixture.command(dict(type='enroll',publicKey=base64.b64encode(key_bytes(wrong)).decode()))
        self.assertIsNone(self.fixture.identity)
        await self.enroll()
        with self.assertRaises(ValueError):await self.enroll()

    async def test_tls_context_uses_only_removed_encrypted_temp_server_key(self):
        await self.enroll()
        identity=self.fixture.identity
        context=identity.tls_context()
        self.assertEqual(context.num_tickets,0);self.assertIsNone(identity.directory)
        self.assertNotIn('serverKey',identity.state);self.assertNotIn('caKey',identity.state)
        with self.assertRaises(ValueError):identity.tls_context(pairing=True)
        self.open.assert_not_called()

    async def test_arm_requires_enrollment_and_cannot_rearm(self):
        with self.assertRaises(ValueError):await self.fixture.command(dict(type='arm',lifetimeSeconds=180))
        await self.enroll()
        self.open.side_effect=None
        # Exercise admission logic without opening a socket or starting a timer.
        with patch.object(self.fixture,'expire',AsyncMock()):
            await self.fixture.command(dict(type='arm',lifetimeSeconds=180))
            with self.assertRaises(ValueError):await self.fixture.command(dict(type='arm',lifetimeSeconds=180))
        self.open.assert_awaited_once()

    async def test_permission_uses_live_id_and_memory_only_grant(self):
        await self.enroll();self.fixture.armed=True
        device=self.fixture.identity.state['devices'][0]
        session=ControlSession(self.fixture.hub,device['id'],device['fingerprint'],None,None,'127.0.0.1','127.0.0.1',float('inf'))
        task=asyncio.create_task(self.fixture.hub.request_permission(session,0))
        async with asyncio.timeout(1):
            while self.fixture.hub.permission is None:await asyncio.sleep(0)
        pending=self.output[-1]
        with self.assertRaises(ValueError):await self.fixture.command(dict(type='permission',requestId='f'*32,accepted=True))
        await self.fixture.command(dict(type='permission',requestId=pending['requestId'],accepted=True))
        self.assertEqual(await task,dict(granted=True,reason='none'))
        self.assertTrue(self.fixture.identity.state['devices'][0]['allowFocusControl'])
        self.open.assert_not_called()

    async def test_fake_prepare_cleanup_never_creates_system_or_desktop_listener(self):
        await self.enroll();device=self.fixture.identity.state['devices'][0]
        session=ControlSession(self.fixture.hub,device['id'],device['fingerprint'],None,None,'127.0.0.1','127.0.0.1',float('inf'))
        self.fixture.hub.claim(session)
        value=await self.fixture.hub.prepare(session,0)
        self.assertEqual(value['endpoint']['port'],55000) # Synthetic result only.
        self.assertIsNone(self.fixture.hub.listener);self.open.assert_not_called()
        self.assertFalse(self.fixture.worker.desktop_listening)
        await self.fixture.hub.cleanup(session)
        self.assertTrue(self.fixture.worker.desktop_listening);self.assertEqual(self.fixture.worker.restorations,1)
        self.assertEqual(self.fixture.worker.media.mode,'idle')

    async def test_close_drops_identity_reference_and_rejects_reuse(self):
        await self.enroll();identity=self.fixture.identity
        await self.fixture.close()
        self.assertIsNone(self.fixture.identity);self.assertEqual(identity.state['devices'],[])
        self.assertTrue(self.fixture.done.is_set());self.assertEqual(self.output[-1]['type'],'closed')
        with self.assertRaises(ValueError):await self.enroll()


if __name__=='__main__':unittest.main()
