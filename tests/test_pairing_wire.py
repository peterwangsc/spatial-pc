import asyncio
import hashlib
import hmac
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'windows'/'host'))
from product.pairing_wire import (PairingWindow, OpeningBudget, context, decode_code, encode_code,
    transcript, confirmation_key, proof, b64, unb64, strict_object, read_record, CLIENT_ID, SERVER_ID)
from product.pake import Pake
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec


def make_proof(challenge, pin, leaf=b'x'*32, name='Headset'):
    binding=context(leaf,bytes.fromhex(challenge['hostId']),unb64(challenge['windowId'],16),unb64(challenge['serverNonce'],32))
    client=Pake(0,pin,CLIENT_ID+binding,SERVER_ID+binding)
    try:
        key=ec.generate_private_key(ec.SECP256R1())
        point=key.public_key().public_bytes(serialization.Encoding.X962,serialization.PublicFormat.UncompressedPoint)
        data=transcript(binding,b'c'*32,point,name,client.message,unb64(challenge['serverMessage'],32))
        shared=client.finish(unb64(challenge['serverMessage'],32))
        try:confirm=confirmation_key(shared,data)
        finally:shared[:]=bytes(64)
        message=dict(version=2,type='proof',clientNonce=b64(b'c'*32),publicKey=b64(point),name=name,
            clientMessage=b64(client.message),proof=b64(proof(confirm,'client',data)),
            signature=b64(key.sign(b'client-key\0'+data,ec.ECDSA(hashes.SHA256()))))
        return message,confirm,data,key
    finally:client.close()


class PairingTests(unittest.TestCase):
    def window(self, now=None):
        clock=(lambda:now[0]) if now is not None else __import__('time').monotonic
        window=PairingWindow('01'*16,b'x'*32,clock)
        self.addCleanup(window.close)
        return window

    def test_four_ascii_digits_and_uniform_zero_padding(self):
        with patch('product.pairing_wire.secrets.randbelow', return_value=0):
            window=self.window();self.assertEqual(window.code(),'0000')
        self.assertEqual(decode_code('0042'),b'0042')
        self.assertEqual(encode_code(b'9999'),'9999')
        for bad in ('123456','123',' 0042','0042 ','00-42','００４２','abcd'):
            with self.assertRaises(ValueError):decode_code(bad)

    def test_fixed_vector_independent_hkdf_and_signature(self):
        v=json.loads((Path(__file__).resolve().parents[1]/'docs/pairing-v2-test-vector.json').read_text())
        data=transcript(bytes.fromhex(v['contextHex']),unb64(v['clientNonce']),unb64(v['publicKey']),v['name'],unb64(v['clientMessage']),unb64(v['serverMessage']))
        self.assertEqual(data.hex(),v['transcriptHex'])
        shared=bytes.fromhex(v['fixtureSharedKeyHex'])
        # Independent RFC5869 single-block extract/expand, not the production helper.
        prk=hmac.digest(hashlib.sha256(data).digest(),shared,'sha256')
        confirm=hmac.digest(prk,b'SpatialPC-Pair-v2/confirm\0'+b'\x01','sha256')
        self.assertEqual(confirm,confirmation_key(shared,data))
        self.assertEqual(confirm.hex(),v['confirmationKeyHex'])
        for role in ('client','server'):
            self.assertEqual(b64(proof(confirm,role,data)),v[role+'Proof'])
        key=ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(),unb64(v['publicKey']))
        key.verify(unb64(v['signature']),b'client-key\0'+data,ec.ECDSA(hashes.SHA256()))

    def test_reject_v1_duplicates_types_and_bounds(self):
        for payload in ('{"version":1}','{"version":2,"version":2}','{"version":true}',
                        '{"version":2,"x":[]}','{"version":2,"x":{}}','{"version":2,"x":NaN}'):
            with self.assertRaises(ValueError):strict_object(payload)
        async def framing():
            for header in (b'SPP1\0\0\0\x01x',b'SPP2\0\0\x40\x01'):
                reader=asyncio.StreamReader();reader.feed_data(header)
                with self.assertRaises(ValueError):await read_record(reader)
        asyncio.run(framing())

    def test_three_attempts_counted_before_output_even_abandoned(self):
        window=self.window()
        for count in range(1,4):
            _,attempt=window.challenge()
            self.assertEqual(window.attempts,count)
            self.assertFalse(window.is_open())
            with self.assertRaises(ValueError):window.challenge()
            self.assertEqual(window.attempts,count)
            window.release_attempt()
            self.assertIsNone(attempt.pake.handle)
        self.assertFalse(window.is_open());self.assertEqual(window.secret,bytes(4))
        with self.assertRaises(ValueError):window.challenge()

    def test_success_consumes_window_and_expiry_is_original(self):
        now=[0.0];window=self.window(now);pin=decode_code(window.code())
        challenge,attempt=window.challenge();message,confirm,data,_=make_proof(challenge,pin)
        now[0]=150
        _,_,server=window.accept(message,attempt)
        self.assertEqual(server,proof(confirm,'server',data))
        self.assertFalse(window.is_open());self.assertEqual(window.secret,bytes(4))
        self.assertTrue(window.can_commit(window.request_id));self.assertFalse(window.can_commit('other'))
        self.assertIsNone(attempt.pake.handle)
        with self.assertRaises(ValueError):window.accept(message,attempt)
        now[0]=180;self.assertFalse(window.can_commit(window.request_id))

    def test_wrong_pin_context_reflection_and_substitutions(self):
        for change in ('pin','leaf','name','key','nonce','signature','reflection','message','unknown'):
            with self.subTest(change=change):
                window=self.window();pin=decode_code(window.code());challenge,attempt=window.challenge()
                if change=='pin':pin=f'{(int(pin)+1)%10000:04d}'.encode()
                message,confirm,data,_=make_proof(challenge,pin,leaf=b'z'*32 if change=='leaf' else b'x'*32)
                if change=='name':message['name']='Other'
                if change=='key':message['publicKey']=b64(b'\x04'+bytes(64))
                if change=='nonce':message['clientNonce']=b64(bytes(32))
                if change=='signature':message['signature']=b64(b'bad')
                if change=='reflection':message['proof']=b64(proof(confirm,'server',data))
                if change=='message':message['clientMessage']=b64(b'\x02'+bytes(31))
                if change=='unknown':message['suite']='other'
                with self.assertRaises((ValueError,InvalidSignature)):window.accept(message,attempt)
                self.assertIsNone(attempt.pake.handle);self.assertIsNone(window.request_id)
                self.assertEqual(window.attempts,1)
                window.close()

    def test_expired_exchange_cannot_commit(self):
        now=[0.0];window=self.window(now);pin=decode_code(window.code());challenge,attempt=window.challenge()
        message,_,_,_=make_proof(challenge,pin);now[0]=180
        with self.assertRaises(ValueError):window.accept(message,attempt)
        window.release_attempt();self.assertFalse(window.is_open())

    def test_opening_budget_is_monotonic_and_not_peer_keyed(self):
        now=[0.0];budget=OpeningBudget(lambda:now[0])
        for _ in range(5):budget.reserve()
        with self.assertRaises(ValueError):budget.reserve()
        now[0]=599.99
        with self.assertRaises(ValueError):budget.reserve()
        now[0]=600;budget.reserve();self.assertEqual(len(budget.openings),1)
