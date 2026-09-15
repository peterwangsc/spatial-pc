"""SPP2 enrollment: pinned SPAKE2, transcript binding, bounded local approval."""
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
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from collections import deque
from .pake import Pake, library

MAX_RECORD = 16384
DOMAIN = b'SpatialPC-Pair-v2\0'
CLIENT_ID = b'SpatialPC-Pair-v2/client\0'
SERVER_ID = b'SpatialPC-Pair-v2/server\0'
CONFIRM_INFO = b'SpatialPC-Pair-v2/confirm\0'
MAX_ATTEMPTS = 3


def encode_code(secret):
    if len(secret) != 4 or any(c < 48 or c > 57 for c in secret):
        raise ValueError('Expected four ASCII digits')
    return bytes(secret).decode('ascii')


def decode_code(value):
    if not isinstance(value, str) or len(value) != 4 or any(c not in '0123456789' for c in value):
        raise ValueError('Expected four ASCII digits')
    return value.encode('ascii')


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


def context(server_hash, host_id, window_id, server_nonce):
    parts = [(server_hash,32),(host_id,16),(window_id,16),(server_nonce,32)]
    if any(not isinstance(value, bytes) or len(value) != size for value, size in parts):
        raise ValueError('Invalid pairing context')
    return b''.join(value for value, _ in parts)


def transcript(binding, client_nonce, public_point, name, client_message, server_message):
    parts = [(binding,96),(client_nonce,32),(public_point,65),(client_message,32),(server_message,32)]
    if any(not isinstance(value, bytes) or len(value) != size for value, size in parts):
        raise ValueError('Invalid pairing transcript')
    encoded_name = name_bytes(name)
    return DOMAIN+binding+client_nonce+public_point+struct.pack('!H',len(encoded_name))+encoded_name+client_message+server_message


def confirmation_key(shared, data):
    if len(shared) != 64:
        raise ValueError('Invalid PAKE output')
    return HKDF(algorithm=hashes.SHA256(),length=32,salt=hashlib.sha256(data).digest(),info=CONFIRM_INFO).derive(shared)


def proof(key, role, value):
    if role not in ('client', 'server') or len(key) != 32:
        raise ValueError('Invalid confirmation role/key')
    return hmac.digest(key, role.encode('ascii')+b'\0'+value, 'sha256')


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
    if type(value.get('version')) is not int or value['version']!=2:
        raise ValueError('Unsupported pairing version')
    return value


async def read_record(reader, timeout=5):
    async def read():
        header=await reader.readexactly(8)
        size=struct.unpack('!I',header[4:])[0]
        if header[:4]!=b'SPP2' or not 0<size<=MAX_RECORD:
            raise ValueError('Invalid pairing framing')
        return strict_object(await reader.readexactly(size))
    return await asyncio.wait_for(read(),timeout)


async def write_record(writer, value):
    payload=json.dumps(value,separators=(',',':'),ensure_ascii=False).encode('utf-8')
    if not 0<len(payload)<=MAX_RECORD:
        raise ValueError('Invalid pairing response size')
    writer.write(b'SPP2'+struct.pack('!I',len(payload))+payload)
    await asyncio.wait_for(writer.drain(),5)


class PairingRateLimited(ValueError):
    pass


class OpeningBudget:
    """Per-worker monotonic throttle; remote reconnect cannot reset it."""
    def __init__(self, clock=time.monotonic):
        self.clock=clock
        self.openings=deque()

    def reserve(self):
        now=self.clock()
        while self.openings and now-self.openings[0]>=600:
            self.openings.popleft()
        if len(self.openings)>=5:
            raise PairingRateLimited('Pairing opened too often. Wait up to ten minutes and try again.')
        self.openings.append(now)


class PairingAttempt:
    def __init__(self, pin, binding):
        self.binding=binding
        self.pake=Pake(1,pin,SERVER_ID+binding,CLIENT_ID+binding)
        self.message=self.pake.message

    def close(self):
        self.pake.close()


class PairingWindow:
    def __init__(self, host_id, server_hash, clock=time.monotonic):
        library() # Fail closed before displaying a code if the native package is missing.
        self.host_id=bytes.fromhex(host_id)
        self.server_hash=server_hash
        self.window_id=secrets.token_bytes(16)
        self.secret=bytearray(f'{secrets.randbelow(10000):04d}'.encode('ascii'))
        self.clock=clock
        self.expires=clock()+180
        self.attempts=0
        self.phase='open'
        self.request_id=None
        self.active=None

    def code(self):
        if not self.is_open():
            raise ValueError('Pairing window closed')
        return encode_code(self.secret)

    def is_open(self):
        return self.phase=='open' and self.clock()<self.expires and self.attempts<MAX_ATTEMPTS

    def challenge(self):
        if not self.is_open():
            raise ValueError('Pairing window closed or busy')
        self.attempts+=1 # Reserve BEFORE any password-dependent message, never refund.
        self.phase='exchanging'
        nonce=secrets.token_bytes(32)
        try:
            binding=context(self.server_hash,self.host_id,self.window_id,nonce)
            self.active=PairingAttempt(self.secret,binding)
            return dict(version=2,type='challenge',hostId=self.host_id.hex(),windowId=b64(self.window_id),
                        serverNonce=b64(nonce),serverMessage=b64(self.active.message)),self.active
        except BaseException:
            self.release_attempt()
            raise

    def failed_handshake(self):
        # No PAKE data was sent, but bound resource-consuming malformed TLS/ALPN too.
        if self.phase=='open':
            self.attempts+=1
            if self.attempts>=MAX_ATTEMPTS:
                self.close()

    def release_attempt(self):
        if self.active:
            self.active.close()
            self.active=None
        if self.phase=='exchanging':
            self.phase='open'
            if not self.is_open():
                self.close()

    def accept(self, value, attempt):
        if self.phase!='exchanging' or attempt is not self.active or self.clock()>=self.expires:
            raise ValueError('Pairing exchange closed')
        try:
            expected={'version','type','clientNonce','publicKey','name','clientMessage','proof','signature'}
            if set(value)!=expected or type(value['version']) is not int or value['version']!=2 or value['type']!='proof':
                raise ValueError('Invalid pairing proof message')
            nonce,point,message=unb64(value['clientNonce'],32),unb64(value['publicKey'],65),unb64(value['clientMessage'],32)
            if point[0]!=4:
                raise ValueError('Invalid device key encoding')
            data=transcript(attempt.binding,nonce,point,value['name'],message,attempt.message)
            shared=attempt.pake.finish(message)
            try:
                confirm=confirmation_key(shared,data)
            finally:
                shared[:]=b'\0'*len(shared)
            if not hmac.compare_digest(unb64(value['proof'],32),proof(confirm,'client',data)):
                raise ValueError('Pairing proof rejected')
            key=ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(),point)
            key.verify(unb64(value['signature'],maximum=80),b'client-key\0'+data,ec.ECDSA(hashes.SHA256()))
            server_proof=proof(confirm,'server',data)
            self.phase='pending'
            self.request_id=secrets.token_hex(16)
            self.approval_expires=min(self.expires,self.clock()+60)
            self.secret[:]=b'\0'*len(self.secret)
            return key,value['name'],server_proof
        finally:
            self.release_attempt() # Terminal even if parsing or point validation fails.

    def can_commit(self, request_id):
        return self.phase=='pending' and request_id==self.request_id and self.clock()<self.approval_expires

    def close(self):
        self.phase='closed'
        self.release_attempt()
        self.secret[:]=b'\0'*len(self.secret)
