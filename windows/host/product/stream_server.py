import asyncio
import datetime as dt
import hashlib
import time
from cryptography import x509
from input_server import run_session
from .process_guard import CaptureOwner
from .tls_listener import listen


class StreamServer:
    def __init__(self,identity,address,port,capture,bridge,notify):
        self.identity=identity;self.address=address;self.port=port;self.capture=capture;self.bridge=bridge;self.notify=notify
        self.stopped=asyncio.Event();self.ready=asyncio.Event();self.connected_id=None;self.session_task=None
        self.last_summary=None

    async def run(self):
        await listen(self.address,self.port,self.identity.tls_context(),self.session,self.stopped,self.ready)

    async def session(self,reader,writer):
        tls=writer.get_extra_info('ssl_object')
        if tls.selected_alpn_protocol()!='spatialpc/1':raise ValueError('Unpaired peer')
        fingerprint=hashlib.sha256(tls.getpeercert(binary_form=True)).hexdigest()
        device=self.identity.device_for(fingerprint)
        if device is None:raise ValueError('Revoked or unpaired peer')
        owner=CaptureOwner();self.connected_id=device['id'];self.session_task=asyncio.current_task()
        self.notify(dict(event='connecting',name=device['name']))
        started=False;failure=None
        def ready(caps):
            nonlocal started
            started=True
            self.notify(dict(event='connected',name=device['name'],width=caps['width'],height=caps['height']))
        try:
            peer=x509.load_der_x509_certificate(tls.getpeercert(binary_form=True))
            expires=min(peer.not_valid_after_utc,self.identity.server.not_valid_after_utc)
            remaining=max(0,(expires-dt.datetime.now(dt.timezone.utc)).total_seconds())
            if remaining<=0:raise ValueError('Pairing certificate expired')
            await run_session(reader,writer,{'clientSHA256':fingerprint},self.capture,self.bridge,
                self.identity.directory/'session',time.monotonic()+remaining,report=self.report,
                ready=ready,
                capture_owner=owner.assign,continuous=True)
        except (OSError,ValueError,EOFError,TimeoutError,asyncio.IncompleteReadError):
            if not started:failure='The desktop could not start. Check that a display is active, update your GPU driver, and use the latest Spatial PC on both devices.'
        finally:
            owner.close();self.connected_id=None;self.session_task=None
            event=dict(event='disconnected')
            if failure:event['message']=failure
            self.notify(event)

    def report(self,line,**ignored):
        # Bounded metadata is kept in memory for support, never sent as arbitrary
        # worker stdout (the UI pipe can contain a one-time setup code).
        if len(line)<=16384:self.last_summary=line
