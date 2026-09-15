"""Development-only Apple local session management; separate from SPP2 trust.

Apple StreamingSession protocol version 1 uses LITTLE endian framed JSON. No
credential bytes are sent through this TCP channel: QR presentation is private UI
IPC. System ClientID and SessionID are untrusted labels, never desktop identities.
"""
import asyncio
import json
import ipaddress
import re
import secrets
import socket
import struct
import time
from .focus import NativeFocus


def decode_message(payload):
    if not 1<=len(payload)<=8192:raise ValueError('Invalid Focus frame length')
    def unique(pairs):
        result={}
        for key,value in pairs:
            if key in result:raise ValueError('Duplicate Focus field')
            result[key]=value
        return result
    value=json.loads(payload.decode('utf-8'),object_pairs_hook=unique)
    if not isinstance(value,dict):raise ValueError('Invalid Focus message')
    common={'Event','SessionID'}
    fields={'RequestConnection':common|{'ProtocolVersion','ClientID','StreamingProvider','StreamingProviderVersion','UserInterfaceIdiom'},
            'RequestBarcodePresentation':common,'SessionStatusDidChange':common|{'Status'}}
    event=value.get('Event')
    if not isinstance(event,str) or event not in fields or set(value)-fields[event]:raise ValueError('Unknown Focus message/field')
    required=common|({'ProtocolVersion','ClientID'} if event=='RequestConnection' else {'Status'} if event=='SessionStatusDidChange' else set())
    if not required<=set(value):raise ValueError('Missing Focus field')
    for key,content in value.items():
        if not isinstance(content,str) or not re.fullmatch(r'[!-~]{1,256}',content):raise ValueError('Invalid Focus field')
    if event=='RequestConnection' and value['ProtocolVersion']!='1':raise ValueError('Unsupported Focus version')
    if event=='SessionStatusDidChange' and value['Status'] not in ('WAITING','CONNECTING','CONNECTED','PAUSED','DISCONNECTED'):
        raise ValueError('Invalid Focus status')
    return value


async def read_message(reader,timeout):
    async with asyncio.timeout(timeout):
        size=struct.unpack('<I',await reader.readexactly(4))[0]
        if not 1<=size<=8192:raise ValueError('Invalid Focus frame length')
        return decode_message(await reader.readexactly(size))


async def send_message(writer,event,session,**fields):
    payload=json.dumps(dict(Event=event,SessionID=session,**fields),separators=(',',':')).encode()
    if not 1<=len(payload)<=8192:raise ValueError('Invalid Focus response length')
    writer.write(struct.pack('<I',len(payload))+payload)
    await asyncio.wait_for(writer.drain(),2)


class LocalFocus:
    """One explicitly opened window, one connection, one owned native generation."""
    def __init__(self,config,session_id,native_factory=NativeFocus):
        self.config=config;self.session_id=session_id;self.factory=native_factory
        self.server=None;self.task=None;self.native=None;self.writer=None;self.expiry=None
        self.running=False;self.invalid=False;self.cleanup_failed=False
        self.receipt=None;self.receipt_id=None;self.deadline=0;self.session=None
        self.handler=None;self.pump=None;self.messages=None;self.read_timer=None
        self.cancel_sent=False;self.closing=False

    def cancel_handler(self):
        target=self.handler or self.task
        if target is not None and not self.cancel_sent and not self.closing:
            self.cancel_sent=True;target.cancel()

    async def start(self,_local_owner):
        address=self.config['_address']
        self.deadline=min(time.monotonic()+180,self.config.get('_setup_deadline',float('inf')),
                          self.config.get('_certificate_deadline',float('inf')))
        # Callback is synchronous: reserve before another accepted connection can run.
        self.server=await asyncio.start_server(self._accept,address,55000,limit=8192,
            backlog=1,start_serving=False)
        self.running=True
        try:
            if '_authorize' in self.config:self.config['_authorize'](self.session_id)
            await self.server.start_serving()
            self.expiry=asyncio.create_task(self._expire())
        except BaseException:
            await self.stop();raise

    async def _expire(self):
        await asyncio.sleep(max(0,self.deadline-time.monotonic()))
        if self.session is None or self.receipt is not None:
            self.invalid=True
            self.cancel_handler()
            self.running=False
            if self.server:self.server.close()

    def _accept(self,reader,writer):
        allowed_peer=self.config.get('_control_peer')
        peer=writer.get_extra_info('peername')
        if allowed_peer and (not peer or ipaddress.ip_address(peer[0].split('%')[0])!=ipaddress.ip_address(allowed_peer.split('%')[0])):
            writer.close();return
        if self.invalid or not self.running or self.task is not None or time.monotonic()>=self.deadline:
            writer.close();return
        self.writer=writer
        sock=writer.get_extra_info('socket')
        if sock:
            sock.setsockopt(socket.IPPROTO_TCP,socket.TCP_NODELAY,1)
            sock.setsockopt(socket.SOL_SOCKET,socket.SO_KEEPALIVE,1)
        self.task=asyncio.create_task(self._connection(reader,writer))
        if self.server:self.server.close() # One attempt; another local Start is required.

    def barcode_receipt(self,request_id,accepted):
        if not self.invalid and request_id==self.receipt_id and self.receipt and not self.receipt.done():
            self.receipt.set_result(accepted)

    def notify(self,value):self.config['_notify'](dict(value,generation=self.session_id))

    def progress(self,state):
        if '_progress' in self.config:self.config['_progress'](state)

    def remaining(self,limit):
        remaining=min(limit,self.deadline-time.monotonic())
        if remaining<=0:raise TimeoutError('Focus setup expired')
        return remaining

    async def _read_pump(self,reader):
        try:
            async with asyncio.timeout_at(self.deadline) as timer:
                self.read_timer=timer
                while not self.invalid:
                    # One reader remains active throughout vendor RPC/UI waits.
                    event=await read_message(reader,None)
                    if event['SessionID']!=self.session or event['Event']=='RequestConnection':raise ValueError('Focus session mismatch')
                    if event['Event']=='SessionStatusDidChange' and event['Status']=='DISCONNECTED':break
                    self.messages.put_nowait(event)
        except asyncio.CancelledError:return
        except (ValueError,OSError,TimeoutError,asyncio.IncompleteReadError,asyncio.QueueFull):pass
        self.invalid=True;self.running=False
        self.cancel_handler()

    async def _connection(self,reader,writer):
        self.handler=asyncio.current_task()
        try:
            request=await read_message(reader,min(5,max(.001,self.deadline-time.monotonic())))
            if request['Event']!='RequestConnection':raise ValueError('Expected Focus connection')
            self.session=request['SessionID']
            self.messages=asyncio.Queue(maxsize=8)
            self.pump=asyncio.create_task(self._read_pump(reader))
            self.native=self.factory(self.config,self.session_id)
            prepare_timeout=self.remaining(16)
            await asyncio.wait_for(self.native.start(request['ClientID']),prepare_timeout)
            if self.invalid:raise asyncio.CancelledError()
            # Force documented system QR, never reuse a claimed SPP2 identity.
            await send_message(writer,'AcknowledgeConnection',self.session,ServerID=self.session_id)
            paired=False;ready=False;presented=False
            hard_deadline=self.deadline
            while not self.invalid:
                deadline=hard_deadline if paired else self.deadline
                remaining=deadline-time.monotonic()
                if remaining<=0:raise TimeoutError('Focus session expired')
                event=await asyncio.wait_for(self.messages.get(),remaining)
                if event['Event']=='RequestBarcodePresentation':
                    if presented or ready:raise ValueError('Duplicate Focus barcode request')
                    self.receipt=asyncio.get_running_loop().create_future();self.receipt_id=secrets.token_hex(16)
                    pin,token=self.native.credentials
                    self.notify(dict(event='focusBarcode',requestId=self.receipt_id,token=token,digest=pin))
                    token=None
                    if not await asyncio.wait_for(self.receipt,self.remaining(15)):raise ValueError('Focus barcode not presented')
                    self.receipt=None;self.receipt_id=None
                    if self.invalid:raise asyncio.CancelledError()
                    presented=True
                    self.progress('qrPresented')
                    await send_message(writer,'AcknowledgeBarcodePresentation',self.session)
                elif event['Status']=='DISCONNECTED':break
                elif event['Status']=='WAITING':
                    if not presented or ready:raise ValueError('Unexpected Focus WAITING')
                    paired=True # Protocol progression only, not an SPP2 authentication claim.
                    self.notify(dict(event='focusBarcodeClosed'))
                    start_timeout=self.remaining(16)
                    self.progress('startingMedia')
                    hard_deadline=min(time.monotonic()+600,self.config.get('_certificate_deadline',float('inf')))
                    self.read_timer.reschedule(hard_deadline)
                    await asyncio.wait_for(self.native.start_media(),min(start_timeout,max(.001,hard_deadline-time.monotonic())))
                    if self.invalid:raise asyncio.CancelledError()
                    ready=True
                    await send_message(writer,'MediaStreamIsReady',self.session)
                    self.progress('mediaReady')
                elif not ready:raise ValueError('Focus status before readiness')
        except asyncio.CancelledError:pass
        except (ValueError,OSError,TimeoutError,asyncio.IncompleteReadError):
            self.notify(dict(event='focusEnded',reason='Immersive Mode ended. Pairing is unchanged.'))
        finally:
            self.closing=True
            self.invalid=True;self.running=False;self.notify(dict(event='focusBarcodeClosed'))
            if self.pump:
                self.pump.cancel();await asyncio.gather(self.pump,return_exceptions=True);self.pump=None
            writer.close()
            try:await asyncio.wait_for(writer.wait_closed(),1)
            except (OSError,TimeoutError):pass
            try:
                if self.native:await self.native.stop()
            except BaseException:
                self.cleanup_failed=True;raise
            finally:self.handler=None

    def alive(self):
        return (self.running and not self.invalid and (self.task is None or not self.task.done()) and
                (self.native is None or self.native.alive()))

    async def stop(self):
        if self.cleanup_failed:raise RuntimeError('Focus cleanup remains uncertain')
        self.invalid=True;self.running=False
        if self.server:self.server.close()
        if self.writer:self.writer.close()
        try:
            try:
                if self.expiry:self.expiry.cancel();await asyncio.gather(self.expiry,return_exceptions=True);self.expiry=None
                if self.task:
                    self.cancel_handler();await asyncio.gather(self.task,return_exceptions=True);self.task=None
                if self.server:await asyncio.wait_for(self.server.wait_closed(),2);self.server=None
            finally:
                self.notify(dict(event='focusBarcodeClosed'))
                self.receipt=None;self.receipt_id=None
                if self.native:await self.native.stop();self.native=None
        except BaseException:
            self.cleanup_failed=True;raise
