"""Opt-in authenticated Focus orchestration; Apple QR/media trust is separate.

All state belongs to one asyncio loop. No reconnect, capture, or runtime starts
are caused by opening this listener. Runtime ownership uses the existing host.
"""
import asyncio
from collections import deque
import datetime as dt
import hashlib
import secrets
import socket
import time
from cryptography import x509
from . import control_wire as wire
from .network import socket_address


class ControlError(Exception):
    def __init__(self, code):
        self.code = code


class FocusControl:
    def __init__(self, worker):
        self.worker = worker
        self.owner = None
        self.sessions = set()
        self.clients = set()
        self.tasks = set()
        self.listener = None
        self.accept_task = None
        self.attempts = deque()
        self.permission = None
        self.closing = False

    def device(self, session):
        return self.worker.identity.device_for(session.fingerprint)

    def allowed(self, session):
        device = self.device(session)
        return bool(device and device.get('allowFocusControl') is True)

    def claim(self, session):
        if self.owner is not None:
            raise ControlError('busy')
        self.owner = session

    def budget(self, session):
        now = time.monotonic()
        while self.attempts and self.attempts[0][0] <= now-600:
            self.attempts.popleft()
        if len(self.attempts) >= 10 or sum(t > now-180 and d == session.device_id for t, d in self.attempts) >= 3:
            raise ControlError('rateLimited')
        self.attempts.append((now, session.device_id))

    def capabilities(self, session):
        worker = self.worker
        configured = worker.focus.capability()['runtimeConfigured']
        return dict(focusCompiled=True, runtimeConfigured=configured, hardwareValidated=False,
            consumerReady=False, focusAllowed=self.allowed(session), accessEnabled=worker.enabled,
            available=bool(configured and worker.enabled and self.allowed(session) and
                           self.owner is None and worker.media.mode == 'idle' and not worker.media.failed),
            mediaMode=worker.media.mode, content='plain-scene-development', systemTrust='apple-qr-separate',
            systemTrustPersistence='unverified', mediaSecurity='development-only',
            setupWindowSeconds=180, sessionLimitSeconds=600)

    async def request_permission(self, session, generation):
        if self.allowed(session):
            return dict(granted=True, reason='none')
        request_id = secrets.token_hex(16)
        future = asyncio.get_running_loop().create_future()
        self.permission = (session, generation, request_id, future)
        device = self.device(session)
        if device is None:
            raise ControlError('canceled')
        self.worker.notify(dict(event='focusPermission', requestId=request_id,
                                name=device['name'], expiresSeconds=60))
        try:
            try:
                accepted = await asyncio.wait_for(future, min(60, session.certificate_deadline-time.monotonic()))
            except TimeoutError:
                return dict(granted=False, reason='timeout')
            session.check(generation)
            if accepted:
                self.worker.identity.set_focus_allowed(session.device_id, True,
                    allowed=lambda: session.valid(generation) and self.device(session) is not None)
            return dict(granted=accepted, reason='none' if accepted else 'denied')
        finally:
            self.permission = None
            self.worker.notify(dict(event='focusPermissionClosed', requestId=request_id))

    def permission_decision(self, request_id, accepted):
        pending = self.permission
        if pending and pending[2] == request_id and pending[0].valid(pending[1]) and not pending[3].done():
            pending[3].set_result(accepted)

    async def prepare(self, session, generation):
        worker = self.worker
        deadline = min(time.monotonic()+180, session.certificate_deadline)
        session.deadline = deadline
        session.progress('waitingForDesktop')
        wait_until = min(time.monotonic()+8, deadline)
        while worker.media.mode == 'desktop':
            if worker.media.device_id != session.device_id:
                raise ControlError('busy')
            session.check(generation)
            if time.monotonic() >= wait_until:
                raise ControlError('desktopStopTimeout')
            await asyncio.sleep(.025)
        session.check(generation)
        if worker.media.mode != 'idle' or worker.media.failed:
            raise ControlError('busy')
        previous = worker.enabled
        async def pause():
            # FocusController has atomically claimed media before invoking us.
            session.check(generation)
            worker.focus_previous_enabled = previous
            session.prepared = True
            await worker.pause_desktop()
            session.check(generation)
        def progress(state):
            if session.valid(generation):
                if state == 'startingMedia':
                    session.deadline = min(time.monotonic()+600, session.certificate_deadline)
                session.progress(state)
        def authorize(session_id):
            session.check(generation)
            session.session_id = session_id
            worker.notify(dict(event='focusControlStarted', generation=session_id))
        context = {'_address': session.local_address, '_notify': worker.notify,
                   '_control_peer': session.peer_address, '_setup_deadline': deadline,
                   '_certificate_deadline': session.certificate_deadline, '_progress': progress,
                   '_authorize': authorize}
        try:
            await worker.focus.start(session.device_id, pause, context)
        except ValueError as error:
            raise ControlError('busy') from error
        session.check(generation)
        session.session_id = worker.focus.session_id
        # Authorizes exactly this generation in the local wizard before Apple QR.
        session.progress('waitingForSystem')
        return dict(sessionId=session.session_id, endpoint=dict(address=session.local_address.split('%')[0], port=55000),
                    setupRemainingSeconds=max(0, int(deadline-time.monotonic())))

    async def cleanup(self, session):
        if self.owner is not session:
            return
        try:
            # A permission-only request must never stop a locally started Focus.
            if session.prepared or self.worker.focus.device_id == session.device_id:
                await self.worker.focus.stop()
                if self.worker.address != session.local_address:
                    self.worker.focus_previous_enabled = None
                    self.worker.enabled = False
                await self.worker.restore_focus_access()
                self.worker.notify(dict(event='focusControlClosed', generation=session.session_id))
        finally:
            self.owner = None

    async def start(self):
        if self.accept_task:
            return
        self.closing = False
        address = self.worker.address
        context = self.worker.identity.tls_context()
        context.set_alpn_protocols([wire.ALPN])
        family, bound_address = socket_address(address, wire.PORT)
        listener = socket.socket(family, socket.SOCK_STREAM)
        try:
            if hasattr(socket, 'SO_EXCLUSIVEADDRUSE'):
                listener.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
            if family == socket.AF_INET6:
                listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            listener.bind(bound_address); listener.listen(2); listener.setblocking(False)
            self.listener = listener
            self.accept_task = asyncio.create_task(self._accept(context))
        except BaseException:
            listener.close(); raise

    async def _accept(self, context):
        loop = asyncio.get_running_loop()
        while True:
            sock, _ = await loop.sock_accept(self.listener)
            if len(self.tasks) >= 2 or self.closing:
                sock.close(); continue
            task = asyncio.create_task(self._serve(sock, context))
            self.tasks.add(task); task.add_done_callback(self.tasks.discard)

    async def _serve(self, sock, context):
        writer = None
        session = None
        try:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            reader = asyncio.StreamReader(limit=16384)
            protocol = asyncio.StreamReaderProtocol(reader)
            transport, _ = await asyncio.get_running_loop().connect_accepted_socket(
                lambda: protocol, sock, ssl=context, ssl_handshake_timeout=5)
            writer = asyncio.StreamWriter(transport, protocol, reader, asyncio.get_running_loop())
            tls = writer.get_extra_info('ssl_object')
            if tls.selected_alpn_protocol() != wire.ALPN or tls.session_reused:
                return
            certificate = tls.getpeercert(binary_form=True)
            fingerprint = hashlib.sha256(certificate).hexdigest()
            device = self.worker.identity.device_for(fingerprint)
            if device is None or device['id'] in self.clients:
                return
            peer_cert = x509.load_der_x509_certificate(certificate)
            expires = min(peer_cert.not_valid_after_utc, self.worker.identity.server.not_valid_after_utc)
            remaining = (expires-dt.datetime.now(dt.timezone.utc)).total_seconds()
            if remaining <= 0:
                return
            session = ControlSession(self, device['id'], fingerprint, reader, writer,
                writer.get_extra_info('peername')[0], self.worker.address, time.monotonic()+remaining)
            self.clients.add(device['id']); self.sessions.add(session)
            await session.run()
        except (OSError, ValueError, TimeoutError, asyncio.IncompleteReadError):
            pass
        finally:
            if session:
                self.clients.discard(session.device_id); self.sessions.discard(session)
            if writer:
                writer.transport.abort()
                try: await asyncio.wait_for(writer.wait_closed(), 2)
                except (OSError, TimeoutError): pass
            else:
                sock.close()

    async def close(self):
        self.closing = True
        if self.accept_task:
            self.accept_task.cancel()
            await asyncio.gather(self.accept_task, return_exceptions=True)
            self.accept_task = None
        if self.listener:
            self.listener.close(); self.listener = None
        for session in tuple(self.sessions): session.disconnect()
        if self.tasks:
            await asyncio.gather(*tuple(self.tasks), return_exceptions=True)

    def revoke(self, device_id):
        for session in tuple(self.sessions):
            if session.device_id == device_id: session.disconnect()


class ControlSession:
    def __init__(self, hub, device_id, fingerprint, reader, writer, peer_address, local_address, certificate_deadline):
        self.hub = hub; self.device_id = device_id; self.fingerprint = fingerprint
        self.reader = reader; self.writer = writer; self.peer_address = peer_address; self.local_address = local_address
        self.certificate_deadline = certificate_deadline
        self.generation = 0; self.live = True; self.prepared = False
        self.session_id = None; self.last_session_id = None; self.origin = None
        self.operation = None; self.cleanup_task = None; self.runner = None
        self.deadline = certificate_deadline; self.last_record = time.monotonic(); self.last_caps = -float('inf')
        self.outgoing = asyncio.Queue(maxsize=16); self.stops = set()
        self.cleanup_failed = False; self.final_response = asyncio.Event()

    def valid(self, generation):
        return self.live and generation == self.generation and self.cleanup_task is None and self.hub.device(self) is not None and time.monotonic() < min(self.certificate_deadline, self.deadline, self.last_record+15)

    def check(self, generation):
        if not self.valid(generation): raise ControlError('canceled')
        if not self.hub.worker.enabled: raise ControlError('accessDisabled')
        if self.hub.worker.address != self.local_address: raise ControlError('interfaceChanged')

    def emit(self, value, generation=None, stale=None):
        if not self.live: return
        try: self.outgoing.put_nowait((dict(version=1, **value), generation, stale))
        except asyncio.QueueFull: self.disconnect()

    def result(self, request_id, result, generation=None, stale=None):
        self.emit(dict(type='result', id=request_id, result=result), generation, stale)

    def error(self, request_id, code):
        self.emit(dict(type='error', id=request_id, code=code))

    def progress(self, state):
        if self.origin is not None:
            self.emit(dict(type='progress', id=self.origin, sessionId=self.session_id, state=state), self.generation)

    async def _write(self):
        try:
            while True:
                value, generation, stale = await self.outgoing.get()
                if generation is not None and generation != self.generation:
                    if stale == 'permission':
                        value = dict(version=1, type='result', id=value['id'], result=dict(granted=False, reason='canceled'))
                    elif stale == 'prepare':
                        value = dict(version=1, type='error', id=value['id'], code='canceled')
                    else: continue
                self.writer.write(wire.encode(value))
                await asyncio.wait_for(self.writer.drain(), 2)
                if value['id'] == 4096 and value['type'] != 'progress': self.final_response.set()
        except (OSError, TimeoutError, ValueError): self.disconnect()

    def disconnect(self):
        if not self.live:return
        self.live = False
        self.begin_cleanup()
        if self.runner and self.runner is not asyncio.current_task(): self.runner.cancel()

    def begin_cleanup(self):
        if self.cleanup_task is None:
            self.generation += 1  # Invalidate success and side effects before ANY await.
            if self.operation and self.operation is not asyncio.current_task() and not self.operation.done(): self.operation.cancel()
            self.cleanup_task = asyncio.create_task(self._cleanup())
        return self.cleanup_task

    async def _cleanup(self):
        try:
            self.progress('stopping')
            async with asyncio.timeout(11):
                if self.operation: await asyncio.gather(self.operation, return_exceptions=True)
                await self.hub.cleanup(self)
        except (Exception, asyncio.CancelledError):
            self.cleanup_failed = True
            self.hub.worker.media.failed = True
            self.hub.worker.media.mode = 'failed'
            self.hub.worker.enabled = False
            # Keep the owner reserved after uncertain cleanup.
            self.hub.owner = self
        finally:
            self.progress('failed' if self.cleanup_failed else 'stopped')
            self.last_session_id = self.session_id or self.last_session_id
            self.session_id = None; self.prepared = False
            self.deadline = self.certificate_deadline

    async def _stop(self, request_id, parameters, cleanup):
        requested = parameters['sessionId']
        if requested is not None and requested not in (self.session_id, self.last_session_id):
            self.error(request_id, 'wrongOwner'); return
        if cleanup is None and requested is not None and requested == self.last_session_id and requested != self.session_id:
            self.result(request_id, dict(stopped=True, desktopAllowed=bool(self.hub.worker.enabled and not self.hub.worker.media.failed)))
            return
        await cleanup
        if self.cleanup_failed:
            self.error(request_id, 'cleanupFailed')
        else:
            self.result(request_id, dict(stopped=True, desktopAllowed=bool(self.hub.worker.enabled and not self.hub.worker.media.failed)))
            if self.cleanup_task is cleanup:
                self.cleanup_task = None; self.operation = None; self.origin = None

    async def _operation(self, request_id, operation, generation):
        try:
            self.check(generation)
            if operation == 'focus.requestPermission':
                self.progress('awaitingPermission')
                result = await self.hub.request_permission(self, generation)
                self.result(request_id, result, generation, 'permission')
            else:
                if not self.hub.allowed(self): raise ControlError('permissionRequired')
                if not self.hub.worker.focus.capability()['runtimeConfigured']: raise ControlError('unsupported')
                self.hub.budget(self)
                result = await self.hub.prepare(self, generation)
                self.result(request_id, result, generation, 'prepare')
        except asyncio.CancelledError:
            if operation == 'focus.requestPermission': self.result(request_id, dict(granted=False, reason='canceled'))
            else: self.error(request_id, 'canceled')
        except ControlError as error:
            self.error(request_id, error.code)
            self.begin_cleanup()
        except TimeoutError:
            self.error(request_id, 'setupTimeout'); self.begin_cleanup()
        except (OSError, ValueError, RuntimeError):
            self.error(request_id, 'runtimeStartFailed'); self.begin_cleanup()
        finally:
            if operation == 'focus.requestPermission' and self.cleanup_task is None and self.hub.owner is self:
                self.hub.owner = None

    async def _watch(self):
        while True:
            await asyncio.sleep(.1)
            if (time.monotonic() >= min(self.last_record+15, self.deadline) or self.hub.device(self) is None
                or not self.hub.worker.enabled or self.hub.worker.address != self.local_address
                or ((self.session_id or self.prepared) and not self.hub.allowed(self))):
                self.disconnect(); return
            if self.session_id and self.hub.worker.focus.adapter and not self.hub.worker.focus.adapter.alive():
                self.begin_cleanup()

    async def run(self):
        self.runner = asyncio.current_task()
        writing = asyncio.create_task(self._write()); watching = asyncio.create_task(self._watch())
        try:
            for request_id in range(1, 4097):
                request = await wire.read(self.reader, request_id)
                self.last_record = time.monotonic()
                if self.cleanup_task and self.cleanup_task.done() and not self.cleanup_failed and not self.stops:
                    self.cleanup_task = None; self.operation = None; self.origin = None
                operation = request['operation']
                if operation == 'heartbeat':
                    self.result(request_id, dict(idleRemainingSeconds=15, sessionRemainingSeconds=max(0, int(self.deadline-time.monotonic())) if self.session_id or self.prepared else 0))
                elif operation == 'capabilities':
                    if time.monotonic()-self.last_caps < 1: self.error(request_id, 'rateLimited')
                    else:
                        self.last_caps = time.monotonic(); self.result(request_id, self.hub.capabilities(self))
                elif operation == 'focus.stop':
                    if len(self.stops) >= 8: raise ValueError('Control dispatch limit')
                    # Invalidate synchronously here, not after task scheduling.
                    target = request['parameters']['sessionId']
                    cleanup = self.begin_cleanup() if target is None or target == self.session_id else None
                    task = asyncio.create_task(self._stop(request_id, request['parameters'], cleanup))
                    self.stops.add(task); task.add_done_callback(self.stops.discard)
                elif operation in ('focus.requestPermission', 'focus.prepare'):
                    if self.cleanup_task is not None or (self.operation and not self.operation.done()):
                        self.error(request_id, 'busy')
                    else:
                        try:
                            self.hub.claim(self)
                            self.generation += 1; self.origin = request_id
                            self.operation = asyncio.create_task(self._operation(request_id, operation, self.generation))
                        except ControlError as error: self.error(request_id, error.code)
                else: self.error(request_id, 'unsupported')
                if request_id == 4096:
                    await asyncio.wait_for(self.final_response.wait(), 71)
        except (asyncio.CancelledError, ValueError, OSError, TimeoutError, asyncio.IncompleteReadError):
            pass
        finally:
            self.live = False
            await self.begin_cleanup()
            for task in (writing, watching, *tuple(self.stops)): task.cancel()
            await asyncio.gather(writing, watching, *tuple(self.stops), return_exceptions=True)
