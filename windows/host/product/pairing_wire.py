"""SPP1 enrollment primitives. Never log secrets, proofs or wire payloads."""
import asyncio
import base64
import hashlib
import hmac
import json
import secrets
import struct
import time
import unicodedata
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

MAX_RECORD = 16384
DOMAIN = b'SpatialPC-Pair-v1\0'


def encode_code(secret):
    if len(secret) != 16:
        raise ValueError('Invalid pairing secret')
    return base64.b32encode(secret).decode('ascii').rstrip('=')


def decode_code(value):
    if not isinstance(value, str) or len(value) > 80 or not value.isascii():
        raise ValueError('Invalid pairing code')
    normalized = ''.join(c for c in value if c not in ' -').upper()
    if len(normalized) != 26 or any(c not in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567' for c in normalized):
        raise ValueError('Invalid pairing code')
    result = base64.b32decode(normalized+'======')
    if encode_code(result) != normalized:
        raise ValueError('Noncanonical pairing code')
    return result


def b64(value):
    return base64.b64encode(value).decode('ascii')


def unb64(value, size=None, maximum=2048):
    if not isinstance(value, str) or len(value) > maximum*2:
        raise ValueError('Invalid pairing field')
    try:
        result = base64.b64decode(value, validate=True)
    except (ValueError, UnicodeError) as error:
        raise ValueError('Invalid pairing field') from error
    if len(result) > maximum or (size is not None and len(result) != size) or b64(result) != value:
        raise ValueError('Invalid pairing field')
    return result


def name_bytes(name):
    if not isinstance(name, str) or any(unicodedata.category(c).startswith('C') for c in name):
        raise ValueError('Invalid device name')
    encoded = name.encode('utf-8')
    if not 1 <= len(encoded) <= 64:
        raise ValueError('Invalid device name')
    return encoded


def transcript(server_hash, host_id, window_id, server_nonce, client_nonce, public_point, name):
    parts = [(server_hash,32),(host_id,16),(window_id,16),(server_nonce,32),(client_nonce,32),(public_point,65)]
    if any(not isinstance(value, bytes) or len(value) != size for value, size in parts):
        raise ValueError('Invalid pairing transcript')
    encoded_name = name_bytes(name)
    return DOMAIN+b''.join(value for value, _ in parts)+struct.pack('!H',len(encoded_name))+encoded_name


def proof(secret, role, value):
    if role not in ('client', 'server') or len(secret) != 16:
        raise ValueError('Invalid pairing proof role')
    return hmac.digest(secret, role.encode('ascii')+b'\0'+value, 'sha256')


def strict_object(payload):
    def pairs(items):
        result = {}
        for key,value in items:
            if key in result:
                raise ValueError('Duplicate pairing field')
            result[key]=value
        return result
    try:
        value=json.loads(payload,object_pairs_hook=pairs)
    except (UnicodeError,RecursionError,json.JSONDecodeError) as error:
        raise ValueError('Invalid pairing JSON') from error
    if not isinstance(value,dict) or len(value)>16 or any(type(v) not in (str,int) for v in value.values()):
        raise ValueError('Invalid pairing message shape')
    if type(value.get('version')) is not int or value['version']!=1:
        raise ValueError('Unsupported pairing version')
    return value


async def read_record(reader, timeout=5):
    async def read():
        header=await reader.readexactly(8)
        size=struct.unpack('!I',header[4:])[0]
        if header[:4]!=b'SPP1' or not 0<size<=MAX_RECORD:
            raise ValueError('Invalid pairing framing')
        return strict_object(await reader.readexactly(size))
    return await asyncio.wait_for(read(),timeout)


async def write_record(writer, value):
    payload=json.dumps(value,separators=(',',':'),ensure_ascii=False).encode('utf-8')
    if not 0<len(payload)<=MAX_RECORD:
        raise ValueError('Invalid pairing response size')
    writer.write(b'SPP1'+struct.pack('!I',len(payload))+payload)
    await asyncio.wait_for(writer.drain(),5)


class PairingWindow:
    def __init__(self, host_id, server_hash, clock=time.monotonic):
        self.host_id=bytes.fromhex(host_id)
        self.server_hash=server_hash
        self.window_id=secrets.token_bytes(16)
        self.secret=bytearray(secrets.token_bytes(16))
        self.clock=clock
        self.expires=clock()+180
        self.failures=0
        self.phase='open'
        self.request_id=None

    def code(self):
        if not self.is_open():
            raise ValueError('Pairing window closed')
        return encode_code(self.secret)

    def is_open(self):
        return self.phase=='open' and self.clock()<self.expires and self.failures<5

    def challenge(self):
        if not self.is_open():
            raise ValueError('Pairing window closed')
        nonce=secrets.token_bytes(32)
        return dict(version=1,type='challenge',hostId=self.host_id.hex(),windowId=b64(self.window_id),serverNonce=b64(nonce)),nonce

    def failed_attempt(self):
        self.failures+=1
        if self.failures>=5:
            self.close()

    def accept(self, value, server_nonce):
        if not self.is_open():
            raise ValueError('Pairing window closed')
        expected={'version','type','clientNonce','publicKey','name','proof','signature'}
        if set(value)!=expected or type(value['version']) is not int or value['version']!=1 or value['type']!='proof':
            raise ValueError('Invalid pairing proof message')
        nonce,point=unb64(value['clientNonce'],32),unb64(value['publicKey'],65)
        if point[0]!=4:
            raise ValueError('Invalid device key encoding')
        data=transcript(self.server_hash,self.host_id,self.window_id,server_nonce,nonce,point,value['name'])
        if not hmac.compare_digest(unb64(value['proof'],32),proof(self.secret,'client',data)):
            raise ValueError('Pairing proof rejected')
        key=ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(),point)
        key.verify(unb64(value['signature'],maximum=80),b'client-key\0'+data,ec.ECDSA(hashes.SHA256()))
        server_proof=proof(self.secret,'server',data)
        self.phase='pending'
        self.request_id=secrets.token_hex(16)
        # Approval is separately bounded, and never extends the original window.
        self.approval_expires=min(self.expires,self.clock()+60)
        self.secret[:]=b'\0'*len(self.secret)
        return key,value['name'],server_proof

    def can_commit(self, request_id):
        return self.phase=='pending' and request_id==self.request_id and self.clock()<self.approval_expires

    def close(self):
        self.phase='closed'
        self.secret[:]=b'\0'*len(self.secret)
