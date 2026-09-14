import asyncio
import base64
import json
from pathlib import Path
import sys
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'windows'/'host'))
from product.pairing_wire import PairingWindow,decode_code,encode_code,transcript,proof,b64,unb64,strict_object,read_record
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes,serialization
from cryptography.hazmat.primitives.asymmetric import ec

VECTOR=Path(__file__).resolve().parents[1]/'docs'/'pairing-v1-test-vector.json'


class PairingTests(unittest.TestCase):
    def test_shared_vector_and_role_certificate_binding(self):
        v=json.loads(VECTOR.read_text());secret=bytes.fromhex(v['secretHex'])
        self.assertEqual(encode_code(secret),v['code'])
        self.assertEqual(decode_code(' '+v['code'][:4].lower()+'-'+v['code'][4:]+' '),secret)
        data=transcript(bytes.fromhex(v['serverLeafSHA256']),bytes.fromhex(v['hostId']),unb64(v['windowId']),
            unb64(v['serverNonce']),unb64(v['clientNonce']),unb64(v['publicKey']),v['name'])
        self.assertEqual(data.hex(),v['transcriptHex'])
        self.assertEqual(b64(proof(secret,'client',data)),v['clientProof'])
        self.assertEqual(b64(proof(secret,'server',data)),v['serverProof'])
        self.assertNotEqual(proof(secret,'client',data),proof(secret,'server',data))
        self.assertNotEqual(proof(secret,'client',data),proof(secret,'client',data[:-1]+b'x'))
        key=ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(),unb64(v['publicKey']))
        key.verify(unb64(v['signature']),b'client-key\0'+data,ec.ECDSA(hashes.SHA256()))
        with self.assertRaises(InvalidSignature):key.verify(unb64(v['signature']),b'client-key\0'+data+b'x',ec.ECDSA(hashes.SHA256()))

    def test_canonical_code_and_message_bounds(self):
        good=encode_code(bytes(16))
        for bad in ('123456',good[:-1]+'B',good+'=',good[:4]+'\t'+good[4:],good[:-1]+'0'):
            with self.assertRaises(ValueError):decode_code(bad)
        for payload in ('{"version":1,"version":1}','{"version":true}','{"version":1,"x":[]}',
                        '{"version":1,"x":{}}','{"version":1,"x":NaN}'):
            with self.assertRaises(ValueError):strict_object(payload)
        async def oversized():
            reader=asyncio.StreamReader();reader.feed_data(b'SPP1\x00\x00\x40\x01')
            with self.assertRaises(ValueError):await read_record(reader)
        asyncio.run(oversized())

    def test_window_consumption_expiry_approval_and_replay(self):
        now=[0.0];window=PairingWindow('01'*16,b'x'*32,lambda:now[0]);secret=decode_code(window.code())
        challenge,nonce=window.challenge();key=ec.generate_private_key(ec.SECP256R1())
        point=key.public_key().public_bytes(serialization.Encoding.X962,serialization.PublicFormat.UncompressedPoint)
        data=transcript(b'x'*32,bytes.fromhex(challenge['hostId']),unb64(challenge['windowId']),nonce,b'c'*32,point,'Headset')
        message=dict(version=1,type='proof',clientNonce=b64(b'c'*32),publicKey=b64(point),name='Headset',
                     proof=b64(proof(secret,'client',data)),signature=b64(key.sign(b'client-key\0'+data,ec.ECDSA(hashes.SHA256()))))
        _,_,server_proof=window.accept(message,nonce)
        self.assertEqual(server_proof,proof(secret,'server',data))
        self.assertFalse(window.is_open());self.assertEqual(window.secret,bytes(16))
        self.assertTrue(window.can_commit(window.request_id));self.assertFalse(window.can_commit('other'))
        with self.assertRaises(ValueError):window.accept(message,nonce)
        now[0]=60;self.assertFalse(window.can_commit(window.request_id))
        window=PairingWindow('01'*16,b'x'*32,lambda:now[0]);now[0]+=180
        self.assertFalse(window.is_open())
        window=PairingWindow('01'*16,b'x'*32)
        for _ in range(5):window.failed_attempt()
        self.assertFalse(window.is_open());self.assertEqual(window.secret,bytes(16))

    def test_name_and_nonce_mismatch_rejected(self):
        window=PairingWindow('01'*16,b'x'*32);secret=decode_code(window.code());challenge,nonce=window.challenge()
        key=ec.generate_private_key(ec.SECP256R1());point=key.public_key().public_bytes(serialization.Encoding.X962,serialization.PublicFormat.UncompressedPoint)
        data=transcript(b'x'*32,bytes.fromhex(challenge['hostId']),unb64(challenge['windowId']),nonce,b'c'*32,point,'Headset')
        message=dict(version=1,type='proof',clientNonce=b64(b'c'*32),publicKey=b64(point),name='Headset',
                     proof=b64(proof(secret,'client',data)),signature=b64(key.sign(b'client-key\0'+data,ec.ECDSA(hashes.SHA256()))))
        with self.assertRaises(ValueError):window.accept(message,b'z'*32)
        message['name']='Headset\u202e'
        with self.assertRaises(ValueError):window.accept(message,nonce)
