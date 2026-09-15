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
    def test_focus_grant_is_explicit_atomic_and_preserves_identity(self):
        with tempfile.TemporaryDirectory() as root:
            identity=Identity(Path(root)/'state')
            device=identity.enroll(ec.generate_private_key(ec.SECP256R1()).public_key(),'Public fixture')
            before=identity.server.fingerprint(hashes.SHA256())
            self.assertNotIn('allowFocusControl',device)
            with self.assertRaises(ValueError):identity.set_focus_allowed(device['id'],True,allowed=lambda:False)
            self.assertNotIn('allowFocusControl',identity.device_for(device['fingerprint']))
            identity.set_focus_allowed(device['id'],True,allowed=lambda:True)
            saved=Identity(identity.directory)
            self.assertTrue(saved.device_for(device['fingerprint'])['allowFocusControl'])
            self.assertEqual(before,saved.server.fingerprint(hashes.SHA256()))
            saved.set_focus_allowed(device['id'],False)
            self.assertFalse(Identity(identity.directory).device_for(device['fingerprint'])['allowFocusControl'])
            saved.revoke(device['id'])
            with self.assertRaises(ValueError):saved.set_focus_allowed(device['id'],True)

    def test_protected_identity_reload_revoke_and_no_plaintext_key_files(self):
        with tempfile.TemporaryDirectory() as root:
            identity=Identity(Path(root)/'state')
            self.assertNotIn(b'PRIVATE KEY',identity.path.read_bytes())
            self.assertFalse(identity.state['accessEnabled'])
            self.assertLess((identity.server.not_valid_after_utc-identity.server.not_valid_before_utc).total_seconds(),366*86400)
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
