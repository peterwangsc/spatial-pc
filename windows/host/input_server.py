"""Opt-in full-duplex transport. Exactly one event-loop thread owns TLS."""
import asyncio
import hashlib
import json
import math
import os
import socket
import struct
import subprocess
import time
from input_protocol import CAPABILITY, EventQueue, Gate, decode, text_negotiated
from transport_metrics import MAX_MESSAGE, TransportStats


async def hello(reader):
    header = await reader.readexactly(8)
    length = struct.unpack('!I', header[4:])[0]
    if header[:4] != b'SPC1' or not 0 < length <= 4096:
        raise ValueError('Invalid capability header')
    value = json.loads(await reader.readexactly(length))
    if not isinstance(value, dict) or type(value.get('version')) is not int or value['version'] != 1:
        raise ValueError('Invalid capability version')
    return value


async def close_child(child, graceful=False, drain_stderr=True):
    if child is None:
        return
    if child.stdin:
        child.stdin.close()  # Native EOF handler releases held state independently.
    if not graceful and child.returncode is None:
        child.terminate()

    async def drain(reader):
        if reader:
            while await reader.read(65536):
                pass  # Discard pixels/metadata; unblock paused pipe transports.

    async def finished():
        # Process.wait can wait on pipe closure even after returncode is set.
        # Drain concurrently so canceled video reads cannot keep teardown stuck.
        await asyncio.gather(child.wait(), drain(child.stdout), drain(child.stderr if drain_stderr else None))

    try:
        await asyncio.wait_for(finished(), 3)
    except asyncio.TimeoutError:
        if child.returncode is None:
            child.kill()
        try:
            await asyncio.wait_for(finished(), 1)
        except asyncio.TimeoutError as error:
            # Stop this host rather than accept a new session with orphaned pipe
            # state. There is no unbounded second wait after kill.
            raise RuntimeError('Child cleanup deadline exceeded') from error


def session_timeout(deadline, continuous=False):
    if not math.isfinite(deadline):raise ValueError('Finite authorization deadline required')
    remaining=max(0,deadline-time.monotonic())
    return remaining if continuous else min(600,remaining)


async def read_input(reader, active, text_enabled):
    # Viewing without input may stay idle. A partial record may not hold a
    # session open; the separate lease also expires active control in two seconds.
    first=await asyncio.wait_for(reader.readexactly(1),2 if active else None)
    rest=await asyncio.wait_for(reader.readexactly(23),2)
    return decode(first+rest,text_enabled=text_enabled)


async def bounded_metadata(reader, destination):
    # Native stderr contains diagnostics only. Retain at most 256 KiB per child
    # even across an all-day session; a slow peer never grows an unbounded log.
    while chunk:=await reader.read(4096):
        if destination.tell()+len(chunk)>256*1024:
            destination.seek(0);destination.truncate()
        destination.write(chunk);destination.flush()


async def log_metadata(reader,path):
    with path.open('wb') as destination:
        await bounded_metadata(reader,destination)


async def run_session(reader, writer, policy, capture_path, bridge_path, directory, deadline, *, report=print, ready=None, capture_owner=None, continuous=False, encoder='mf'):
    capture = bridge = None
    gate = None
    completed = []
    tasks = []
    metadata_tasks=[];capture_log=bridge_log=None
    stats = TransportStats()
    flags = subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0
    try:
        if encoder not in ('mf','nvenc'):raise ValueError('Unsupported desktop encoder')
        session_timeout(deadline,continuous)
        if continuous and capture_owner is None:raise ValueError('Continuous capture requires process ownership')
        tls = writer.get_extra_info('ssl_object')
        certificate = tls.getpeercert(binary_form=True)
        if hashlib.sha256(certificate).hexdigest() != policy['clientSHA256'] or tls.selected_alpn_protocol() != 'spatialpc/1':
            raise ValueError('Unpaired peer')
        request = await asyncio.wait_for(hello(reader), 5)
        codecs = request.get('codecs')
        if not isinstance(codecs, list) or not all(isinstance(codec, str) for codec in codecs) or 'h264-annexb' not in codecs:
            raise ValueError('No common codec')
        offer = request.get('input')
        enabled = isinstance(offer, dict) and type(offer.get('version')) is int and offer['version'] == 1
        text_enabled = enabled and text_negotiated(offer)
        lifetime_args=['--until-owner-exits'] if continuous else []
        encoder_args=['--encoder','nvenc'] if encoder=='nvenc' else []
        capture = await asyncio.create_subprocess_exec(str(capture_path), '--stream', *encoder_args, *lifetime_args, stdout=asyncio.subprocess.PIPE,
                                                      stdin=asyncio.subprocess.PIPE if continuous else None,
                                                      stderr=asyncio.subprocess.PIPE, creationflags=flags, limit=65536)
        capture_log=asyncio.create_task(log_metadata(capture.stderr,directory.parent/'encoder.log'),name='capture-diagnostics')
        metadata_tasks.append(capture_log)
        if capture_owner:
            capture_owner(capture.pid)
        if continuous:
            capture.stdin.write(b'C') # Only after successful Job assignment.
            await asyncio.wait_for(capture.stdin.drain(),.5)
        capabilities = await asyncio.wait_for(hello(capture.stdout), 5)
        for field in ('width', 'height'):
            bound = request.get('max'+field.title())
            if type(bound) is not int or type(capabilities.get(field)) is not int or not 2 <= capabilities[field] <= bound:
                raise ValueError('Display exceeds client capability')
        if capabilities.get('hardwareEncoder') is not True:
            raise ValueError('Hardware encoder unavailable')
        if enabled:
            bridge = await asyncio.create_subprocess_exec(str(bridge_path), '--width', str(capabilities['width']),
                '--height', str(capabilities['height']), *(['--enable-text'] if text_enabled else []), *lifetime_args, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE, creationflags=flags, limit=4096)
            bridge_log=asyncio.create_task(log_metadata(bridge.stderr,directory.parent/'input-status.log'),name='input-diagnostics')
            metadata_tasks.append(bridge_log)
            native_ready = json.loads(await asyncio.wait_for(bridge.stdout.readline(), 3))
            if native_ready != dict(ready=True, width=capabilities['width'], height=capabilities['height']):
                raise ValueError('Native input bridge unavailable')
            bridge.stdin.transport.set_write_buffer_limits(high=24*8, low=24*2)
            capabilities['input'] = dict(CAPABILITY)
            if text_enabled:
                capabilities['input']['textVersion'] = 1
        payload = json.dumps(capabilities, separators=(',', ':')).encode()
        if len(payload)>4096:
            raise ValueError('Capability response exceeds bound')
        writer.write(b'SPC1'+struct.pack('!I', len(payload))+payload)
        await asyncio.wait_for(writer.drain(), 5)
        report('Authenticated session; input='+('negotiated' if enabled else 'view-only'), flush=True)
        if ready:
            ready(capabilities)

        async def video():
            next_report = time.perf_counter()+5
            while True:
                before = time.perf_counter()
                header = await capture.stdout.readexactly(16)
                size, pts, _ = struct.unpack('!IQI', header)
                if not 0 < size <= MAX_MESSAGE:
                    raise ValueError('Invalid video size')
                payload = await capture.stdout.readexactly(size)
                sending = time.perf_counter()
                writer.write(header)
                writer.write(payload)
                await asyncio.wait_for(writer.drain(), 5)
                sent = time.perf_counter()
                stats.frame(pts, size, (sending-before)*1000, (sent-sending)*1000)
                if sent >= next_report:
                    report('transport_summary='+json.dumps(stats.report()), flush=True)
                    next_report = sent+5

        async def watch_view_only():
            # Reverse traffic is forbidden without successful negotiation.
            if await reader.read(1):
                raise ValueError('Unnegotiated input')

        tasks.append(asyncio.create_task(video(), name='video'))
        if enabled:
            queue, gate = EventQueue(), Gate()

            async def receive():
                while True:
                    event = await read_input(reader,gate.active,text_enabled)
                    gate.accept(event)
                    queue.put(event)

            async def dispatch():
                while True:
                    event = await queue.get()
                    bridge.stdin.write(event.wire())
                    await asyncio.wait_for(bridge.stdin.drain(), .5)

            async def lease():
                while True:
                    await asyncio.sleep(.05)
                    if gate.expired():
                        raise TimeoutError('Input lease expired')

            tasks.extend(asyncio.create_task(job(),name=job.__name__) for job in (receive, dispatch, lease))
            tasks.append(asyncio.create_task(bridge.wait(),name='native-exit'))
        else:
            tasks.append(asyncio.create_task(watch_view_only()))
        done, _ = await asyncio.wait(tasks+metadata_tasks, timeout=session_timeout(deadline,continuous), return_when=asyncio.FIRST_COMPLETED)
        completed = sorted(task.get_name() for task in done)
        for task in done:
            task.result()
    finally:
        input_summary = dict(records=gate.accepted, leaseExpired=gate.expired(), completed=completed) if gate else None
        if bridge and bridge.stdin:
            bridge.stdin.close()  # Signal native release before any awaited cleanup.
        writer.transport.abort()  # Session EOF must not wait on a full capture pipe.
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        cleanup_failed = False
        try:
            await close_child(bridge, graceful=True,drain_stderr=bridge_log is None or bridge_log.done())
        except RuntimeError:
            cleanup_failed = True
        if input_summary is not None:
            input_summary['nativeExit'] = bridge.returncode
            report('input_summary='+json.dumps(input_summary), flush=True)
        try:
            await close_child(capture,drain_stderr=capture_log is None or capture_log.done())
        except RuntimeError:
            cleanup_failed = True
        for task in metadata_tasks:
            try:await asyncio.wait_for(asyncio.shield(task),1)
            except (Exception,asyncio.CancelledError):task.cancel();cleanup_failed=True
        await asyncio.gather(*metadata_tasks,return_exceptions=True)
        if stats.frames:
            report('transport_summary='+json.dumps(stats.report()), flush=True)
        if cleanup_failed:
            raise RuntimeError('Session child cleanup did not finish')


async def serve_async(directory, capture_path, bridge_path, bind, lifetime):
    from lab_server import context_for  # Development-only entry point; not in the consumer package.
    policy = json.loads((directory/'server-policy.json').read_text())
    context = context_for(directory)
    loop = asyncio.get_running_loop()
    deadline = time.monotonic()+lifetime
    with socket.socket() as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE if os.name == 'nt' else socket.SO_REUSEADDR, 1)
        listener.bind((bind, policy['port']))
        listener.listen(2)
        listener.setblocking(False)
        print('Input-capable lab host listening; authenticated opt-in control only', flush=True)
        while time.monotonic() < deadline:
            try:
                raw, _ = await asyncio.wait_for(loop.sock_accept(listener), 1)
            except asyncio.TimeoutError:
                continue
            writer = transport = None
            try:
                # Accept and handshake only one peer at a time. No task/thread
                # fan-out per connection and no shared concurrent SSL calls.
                reader = asyncio.StreamReader(limit=4096)
                protocol = asyncio.StreamReaderProtocol(reader)
                transport, _ = await loop.connect_accepted_socket(lambda: protocol, raw, ssl=context, ssl_handshake_timeout=5)
                writer = asyncio.StreamWriter(transport, protocol, reader, loop)
                await asyncio.wait_for(run_session(reader, writer, policy, capture_path, bridge_path, directory, deadline),
                                       max(.1, deadline-time.monotonic()))
            except (OSError, ValueError, EOFError, asyncio.IncompleteReadError, asyncio.TimeoutError):
                print('Session ended', flush=True)
            finally:
                if writer:
                    writer.close()
                    try:
                        await asyncio.wait_for(writer.wait_closed(), 2)
                    except (OSError, asyncio.TimeoutError):
                        transport.abort()
                elif transport:
                    transport.abort()
                else:
                    raw.close()


def serve_input(directory, capture_path, bridge_path, bind, lifetime):
    asyncio.run(serve_async(directory, capture_path, bridge_path, bind, lifetime))
