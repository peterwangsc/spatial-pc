"""Disposable, operator-armed control interoperability fixture.

Never uses DPAPI, a real paired identity, Worker, LocalFocus, capture or input.
Only an explicit stdin arm record can open an ephemeral loopback TLS listener.
The client creates its own P256 private key; only SPKI and public certificates
cross this bounded stdin/stdout interface. Stdout must be piped, not logged.
"""
import asyncio
import base64
import copy
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import secrets
import socket
import sys
import tempfile

HOST_ROOT = Path(os.environ.get('SPATIAL_PC_FIXTURE_HOST_ROOT',
                               Path(__file__).resolve().parents[2]/'windows'/'host')).resolve()
sys.path.insert(0, str(HOST_ROOT))
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID
from product.identity import Identity, issue_certificate
from product.focus import FocusController
from product.media_owner import MediaOwner
from product.focus_control import FocusControl
from product import control_wire


def b64(value): return base64.b64encode(value).decode('ascii')


def decode_command(raw):
    if not 1 <= len(raw) <= 8192: raise ValueError('Fixture command length')
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result: raise ValueError('Duplicate fixture field')
            result[key] = value
        return result
    value = json.loads(raw.decode('utf-8'), object_pairs_hook=unique)
    if not isinstance(value, dict) or type(value.get('version')) is not int or value['version'] != 1:
        raise ValueError('Fixture command version')
    kind = value.get('type')
    fields = {'enroll': {'publicKey'}, 'arm': {'lifetimeSeconds'},
              'permission': {'requestId', 'accepted'}, 'status': set(), 'close': set()}
    if not isinstance(kind, str) or kind not in fields or set(value) != {'version', 'type'} | fields[kind]:
        raise ValueError('Fixture command schema')
    if kind == 'enroll' and (not isinstance(value['publicKey'], str) or len(value['publicKey']) > 256):
        raise ValueError('Fixture public key')
    if kind == 'arm' and (type(value['lifetimeSeconds']) is not int or not 10 <= value['lifetimeSeconds'] <= 180):
        raise ValueError('Fixture lifetime')
    if kind == 'permission' and (not isinstance(value['requestId'], str) or len(value['requestId']) != 32 or type(value['accepted']) is not bool):
        raise ValueError('Fixture permission')
    return value


class MemoryIdentity(Identity):
    """Only public fixture identity; inherited persistence is replaced in memory."""
    def __init__(self, public_key):
        self.ca_key = ec.generate_private_key(ec.SECP256R1())
        self.server_key = ec.generate_private_key(ec.SECP256R1())
        host_id = secrets.token_hex(16)
        name = 'spatialpc-fixture-'+host_id+'.local'
        issuer = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'Spatial PC disposable fixture')])
        self.ca = issue_certificate(self.ca_key.public_key(), 'Spatial PC disposable fixture', issuer, self.ca_key, 1)
        self.server = issue_certificate(self.server_key.public_key(), 'Spatial PC disposable server', issuer,
                                        self.ca_key, 1, ExtendedKeyUsageOID.SERVER_AUTH, name)
        device_id = secrets.token_hex(16)
        client = issue_certificate(public_key, 'Spatial PC disposable client', issuer, self.ca_key, 1,
                                   ExtendedKeyUsageOID.CLIENT_AUTH)
        self.state = dict(version=1, hostId=host_id, serverName=name,
            caCertificate=self.ca.public_bytes(serialization.Encoding.PEM).decode('ascii'),
            serverCertificate=self.server.public_bytes(serialization.Encoding.PEM).decode('ascii'),
            devices=[dict(id=device_id, name='Public interoperability fixture', pairedAt=dt.datetime.now(dt.timezone.utc).isoformat(),
                certificate=b64(client.public_bytes(serialization.Encoding.DER)),
                fingerprint=client.fingerprint(hashes.SHA256()).hex(), allowFocusControl=False)])
        self.directory = None

    def save(self, state): self.state = copy.deepcopy(state)

    def tls_context(self, pairing=False):
        if pairing: raise ValueError('No pairing listener in this fixture')
        # SSLContext takes file paths. The inherited loader writes only a
        # password-encrypted server key; its temporary directory is removed
        # before returning. No client private key is accepted or generated.
        with tempfile.TemporaryDirectory(prefix='spatialpc-control-fixture-') as directory:
            self.directory = Path(directory)
            try: return super().tls_context()
            finally: self.directory = None

    def public_bundle(self):
        device = self.state['devices'][0]
        return dict(version=1, type='enrolled', fixtureOnly=True, hostId=self.state['hostId'], deviceId=device['id'],
            serverName=self.state['serverName'], caCertificate=b64(self.ca.public_bytes(serialization.Encoding.DER)),
            serverCertificate=b64(self.server.public_bytes(serialization.Encoding.DER)), clientCertificate=device['certificate'],
            serverSHA256=self.server.fingerprint(hashes.SHA256()).hex(), clientSHA256=device['fingerprint'],
            alpn=control_wire.ALPN, keyRetention='client-memory-only', systemEndpointUsable=False)


class FixtureDeployment:
    def load(self): return {}


class FakeMedia:
    def __init__(self, config, session): self.config = config; self.session = session; self.running = False
    async def start(self, _device):
        self.config['_authorize'](self.session)
        self.running = True
    async def stop(self): self.running = False
    def alive(self): return self.running


class FixtureWorker:
    def __init__(self, identity, notify):
        self.identity = identity; self.notify = notify; self.media = MediaOwner()
        self.address = '127.0.0.1'; self.enabled = True; self.focus_previous_enabled = None
        self.desktop_listening = True  # Model only: no desktop socket exists.
        self.restorations = 0
        self.focus = FocusController(self.media, FixtureDeployment(), lambda: None, FakeMedia)

    async def pause_desktop(self): self.desktop_listening = False

    async def restore_focus_access(self):
        previous = self.focus_previous_enabled; self.focus_previous_enabled = None
        if previous and self.enabled and not self.media.failed:
            self.desktop_listening = True; self.restorations += 1


class Fixture:
    def __init__(self, emit):
        self.emit = emit; self.identity = None; self.worker = None; self.hub = None
        self.armed = False; self.closed = False; self.port = None; self.expiry = None
        self.done = asyncio.Event()

    def notify(self, value):
        # No generic forwarding of arbitrary product IPC or QR credential data.
        if value['event'] == 'focusPermission':
            self.emit(dict(version=1, type='permissionPending', requestId=value['requestId'], expiresSeconds=value['expiresSeconds']))
        elif value['event'] == 'focusPermissionClosed':
            self.emit(dict(version=1, type='permissionClosed', requestId=value['requestId']))

    async def command(self, value):
        if self.closed: raise ValueError('Fixture closed')
        kind = value['type']
        if kind == 'enroll':
            if self.identity is not None: raise ValueError('Fixture enrollment is single use')
            raw = base64.b64decode(value['publicKey'], validate=True)
            public = serialization.load_der_public_key(raw)
            if not isinstance(public, ec.EllipticCurvePublicKey) or not isinstance(public.curve, ec.SECP256R1):
                raise ValueError('Expected P256 SPKI')
            self.identity = MemoryIdentity(public)
            self.worker = FixtureWorker(self.identity, self.notify); self.hub = FocusControl(self.worker)
            self.emit(self.identity.public_bundle())
        elif kind == 'arm':
            if self.identity is None or self.armed: raise ValueError('Enroll once before arming once')
            self.armed = True
            await self.open_loopback()
            self.expiry = asyncio.create_task(self.expire(value['lifetimeSeconds']))
            self.emit(dict(version=1, type='ready', fixtureOnly=True, address='127.0.0.1', port=self.port,
                lifetimeSeconds=value['lifetimeSeconds'], pid=os.getpid(), systemEndpointUsable=False,
                controlSourceSHA256=hashlib.sha256((HOST_ROOT/'product/focus_control.py').read_bytes().replace(b'\r\n',b'\n')).hexdigest()))
        elif kind == 'permission':
            if not self.armed or self.hub.permission is None or self.hub.permission[2] != value['requestId']:
                raise ValueError('No matching live permission request')
            self.hub.permission_decision(value['requestId'], value['accepted'])
        elif kind == 'status':
            self.emit(dict(version=1, type='status', enrolled=self.identity is not None, armed=self.armed,
                port=self.port, sessions=len(self.hub.sessions) if self.hub else 0,
                mediaMode=self.worker.media.mode if self.worker else 'idle',
                restorations=self.worker.restorations if self.worker else 0))
        elif kind == 'close': await self.close()

    async def open_loopback(self):
        context = self.identity.tls_context(); context.set_alpn_protocols([control_wire.ALPN])
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            if hasattr(socket, 'SO_EXCLUSIVEADDRUSE'): listener.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
            listener.bind(('127.0.0.1', 0)); listener.listen(2); listener.setblocking(False)
            self.port = listener.getsockname()[1]
            self.hub.listener = listener
            self.hub.accept_task = asyncio.create_task(self.hub._accept(context))
        except BaseException:
            listener.close(); raise

    async def expire(self, seconds):
        await asyncio.sleep(seconds)
        await self.close()

    async def close(self):
        if self.closed: return
        self.closed = True
        try:
            if self.expiry and self.expiry is not asyncio.current_task():
                self.expiry.cancel(); await asyncio.gather(self.expiry, return_exceptions=True)
            if self.hub: await self.hub.close()
            if self.identity: self.identity.state['devices'].clear()
            self.emit(dict(version=1, type='closed', fixtureOnly=True, listeners=0, devices=0))
        finally:
            self.identity = None; self.worker = None; self.hub = None
            self.done.set()


async def main():
    import queue
    import threading
    loop = asyncio.get_running_loop()
    incoming = asyncio.Queue(maxsize=8); outgoing = queue.Queue(maxsize=16)
    def fail(): loop.call_soon_threadsafe(fixture.done.set)
    def emit(value):
        try: outgoing.put_nowait(json.dumps(value, separators=(',', ':'))+'\n')
        except queue.Full: fail()
    fixture = Fixture(emit)
    def deliver(value):
        try: incoming.put_nowait(value)
        except asyncio.QueueFull: fixture.done.set()
    def read_input():
        try:
            while True:
                raw = sys.stdin.buffer.readline(8194)
                if not raw: fail(); return
                value = decode_command(raw)
                loop.call_soon_threadsafe(deliver, value)
        except Exception: fail()
    def write_output():
        try:
            while True:
                value = outgoing.get()
                if value is None: return
                sys.stdout.write(value); sys.stdout.flush()
        except (OSError, ValueError): fail()
    threading.Thread(target=read_input, daemon=True).start()
    output_thread = threading.Thread(target=write_output, daemon=True); output_thread.start()
    emit(dict(version=1, type='waiting', fixtureOnly=True, listenerStarted=False))
    try:
        while not fixture.done.is_set():
            try: value = await asyncio.wait_for(incoming.get(), .1)
            except TimeoutError: continue
            await fixture.command(value)
    except Exception:
        emit(dict(version=1, type='failed', reason='fixture-command-or-lifecycle-error'))
    finally:
        await fixture.close()
        try: outgoing.put_nowait(None)
        except queue.Full: pass
        # Bounded flush. A blocked operator pipe must not retain a listener.
        output_thread.join(timeout=1)


if __name__ == '__main__': asyncio.run(main())
