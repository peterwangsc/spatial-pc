"""One connection/handshake at a time, with explicit cancellation and bounds."""
import asyncio
import os
import socket
from .network import socket_address


async def listen(address, port, context, session, stopped, ready=None, handshake_failed=None):
    loop=asyncio.get_running_loop()
    family,endpoint=socket_address(address,port)
    with socket.socket(family) as listener:
        listener.setsockopt(socket.SOL_SOCKET,socket.SO_EXCLUSIVEADDRUSE if os.name=='nt' else socket.SO_REUSEADDR,1)
        if family==socket.AF_INET6:listener.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,1)
        listener.bind(endpoint);listener.listen(2);listener.setblocking(False)
        if ready:
            ready.set()
        while not stopped.is_set():
            try:
                raw,_=await asyncio.wait_for(loop.sock_accept(listener),.25)
            except asyncio.TimeoutError:
                continue
            transport=writer=None
            try:
                reader=asyncio.StreamReader(limit=16384)
                protocol=asyncio.StreamReaderProtocol(reader)
                transport,_=await loop.connect_accepted_socket(lambda:protocol,raw,ssl=context,ssl_handshake_timeout=5)
                writer=asyncio.StreamWriter(transport,protocol,reader,loop)
                await session(reader,writer)
            except (OSError,ValueError,EOFError,asyncio.IncompleteReadError,asyncio.TimeoutError):
                if writer is None and handshake_failed:handshake_failed()
                # Static UI state only; never retain peer payloads.
            finally:
                if writer:
                    writer.transport.abort()
                    try:
                        await asyncio.wait_for(writer.wait_closed(),2)
                    except (OSError,asyncio.TimeoutError):
                        pass
                elif transport:
                    transport.abort()
                else:
                    raw.close()
