import os
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'windows'/'host'))
from product.identity import Identity
from product.windows_security import dpapi
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec


@unittest.skipUnless(os.name=='nt','Windows DPAPI integration')
class IdentityTests(unittest.TestCase):
    def test_protected_identity_reload_revoke_and_no_plaintext_key_files(self):
        with tempfile.TemporaryDirectory() as root:
            identity=Identity(Path(root)/'state')
            self.assertNotIn(b'PRIVATE KEY',identity.path.read_bytes())
            self.assertFalse(identity.state['accessEnabled'])
            device=identity.enroll(ec.generate_private_key(ec.SECP256R1()).public_key(),'Test headset')
            again=Identity(identity.directory)
            self.assertEqual(identity.server.fingerprint(hashes.SHA256()),again.server.fingerprint(hashes.SHA256()))
            self.assertEqual(again.device_for(device['fingerprint'])['id'],device['id'])
            self.assertEqual(again.tls_context().num_tickets,0)
            self.assertEqual([p.name for p in identity.directory.iterdir()],['identity.dat'])
            again.revoke(device['id']);self.assertIsNone(Identity(identity.directory).device_for(device['fingerprint']))

    def test_dpapi_tamper_and_failed_write_keep_identity(self):
        with tempfile.TemporaryDirectory() as root:
            identity=Identity(Path(root)/'state');original=identity.path.read_bytes()
            altered=bytearray(original);altered[-1]^=1
            with self.assertRaises(OSError):dpapi(bytes(altered),decrypt=True)
            def fail(*args,**kwargs):raise OSError('Test storage failure')
            identity.protect=fail
            with self.assertRaises(OSError):identity.configure(accessEnabled=True)
            self.assertEqual(identity.path.read_bytes(),original)
            self.assertFalse(identity.state['accessEnabled'])
