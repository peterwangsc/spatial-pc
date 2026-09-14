"""Explicit local approval, one-time enrollment, and no capture path."""
import asyncio
import base64
import time
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from .pairing_wire import PairingWindow, read_record, write_record, b64
from .tls_listener import listen


class PairingServer:
    def __init__(self, identity, address, port, stream_port, notify):
        self.identity=identity;self.address=address;self.port=port;self.stream_port=stream_port;self.notify=notify
        self.window=PairingWindow(identity.state['hostId'],identity.server.fingerprint(hashes.SHA256()))
        self.stopped=asyncio.Event();self.ready=asyncio.Event();self.approval=None;self.task=None

    async def run(self):
        listener=asyncio.create_task(listen(self.address,self.port,self.identity.tls_context(pairing=True),self.session,self.stopped,self.ready))
        timer=asyncio.create_task(asyncio.sleep(max(0,self.window.expires-time.monotonic())))
        stopper=asyncio.create_task(self.stopped.wait())
        try:
            done,_=await asyncio.wait([listener,timer,stopper],return_when=asyncio.FIRST_COMPLETED)
            for task in done:task.result()
        finally:
            self.window.close();self.stopped.set()
            if self.approval and not self.approval.done():self.approval.set_result(False)
            for task in (listener,timer,stopper):task.cancel()
            await asyncio.gather(listener,timer,stopper,return_exceptions=True)
            self.notify(dict(event='pairingClosed'))

    def stop(self):
        self.window.close();self.stopped.set()
        if self.approval and not self.approval.done():self.approval.set_result(False)

    def approve(self, request_id, accepted):
        if self.approval and not self.approval.done() and self.window.can_commit(request_id):
            self.approval.set_result(accepted is True)

    async def session(self, reader, writer):
        claimed=False
        try:
            tls=writer.get_extra_info('ssl_object')
            if tls.selected_alpn_protocol()!='spatialpc-pair/1':
                raise ValueError('Pairing protocol rejected')
            challenge,nonce=self.window.challenge()
            await write_record(writer,challenge)
            value=await read_record(reader)
            key,name,server_proof=self.window.accept(value,nonce)
            claimed=True
            self.approval=asyncio.get_running_loop().create_future()
            await write_record(writer,dict(version=1,type='pending',serverProof=b64(server_proof)))
            request_id=self.window.request_id
            self.notify(dict(event='approval',requestId=request_id,name=name,
                             expiresSeconds=max(0,int(self.window.approval_expires-time.monotonic()))))
            # Peer disappearance or any extra unrequested bytes cancels approval.
            disconnected=asyncio.create_task(reader.read(1))
            try:
                done,_=await asyncio.wait([self.approval,disconnected],
                    timeout=max(0,self.window.approval_expires-time.monotonic()),return_when=asyncio.FIRST_COMPLETED)
                if disconnected in done or self.approval not in done or not self.approval.result():
                    raise ValueError('Pairing was not approved')
                if self.stopped.is_set() or not self.window.can_commit(request_id):
                    raise ValueError('Pairing approval expired')
                device=self.identity.enroll(key,name,allowed=lambda:not self.stopped.is_set() and self.window.can_commit(request_id))
                # No awaits between the final expiry check and atomic persistence.
                await write_record(writer,dict(version=1,type='paired',hostId=self.identity.state['hostId'],
                    deviceId=device['id'],serverCertificate=b64(self.identity.server.public_bytes(serialization.Encoding.DER)),
                    clientCertificate=device['certificate'],caCertificate=b64(self.identity.ca.public_bytes(serialization.Encoding.DER)),
                    serverName=self.identity.state['serverName'],streamPort=self.stream_port))
                self.notify(dict(event='paired',deviceId=device['id']))
            finally:
                disconnected.cancel();await asyncio.gather(disconnected,return_exceptions=True)
        except (ValueError,InvalidSignature,TimeoutError,EOFError,OSError,asyncio.IncompleteReadError):
            if not claimed:
                self.window.failed_attempt()
            self.notify(dict(event='pairingAttemptFailed',attemptsRemaining=max(0,5-self.window.failures)))
        finally:
            if claimed or not self.window.is_open():
                self.stop()
