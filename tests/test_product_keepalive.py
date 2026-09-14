import asyncio
import os
from pathlib import Path
import socket
import sys
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'windows'/'host'))
from product.tls_listener import configure_peer


@unittest.skipUnless(os.name=='nt','Windows socket-option acceptance')
class KeepaliveTests(unittest.IsolatedAsyncioTestCase):
    async def test_actual_ipv4_and_ipv6_peer_settings(self):
        for family,address in ((socket.AF_INET,'127.0.0.1'),(socket.AF_INET6,'::1')):
            with self.subTest(address=address),socket.socket(family) as listener,socket.socket(family) as client:
                listener.bind((address,0));listener.listen(1)
                client.connect(listener.getsockname())
                with listener.accept()[0] as peer:
                    configure_peer(peer)
                    for level,option,value in ((socket.SOL_SOCKET,socket.SO_KEEPALIVE,1),
                        (socket.IPPROTO_TCP,socket.TCP_KEEPIDLE,10),(socket.IPPROTO_TCP,socket.TCP_KEEPINTVL,2),
                        (socket.IPPROTO_TCP,socket.TCP_KEEPCNT,3),(socket.IPPROTO_TCP,socket.TCP_NODELAY,1)):
                        self.assertEqual(peer.getsockopt(level,option),value)

    async def test_healthy_idle_connection_survives_keepalive_window(self):
        ready=asyncio.Event();server_writer=None
        async def accepted(reader,writer):
            nonlocal server_writer
            server_writer=writer;configure_peer(writer.get_extra_info('socket'));ready.set()
        server=await asyncio.start_server(accepted,'127.0.0.1',0)
        reader,writer=await asyncio.open_connection('127.0.0.1',server.sockets[0].getsockname()[1])
        try:
            await asyncio.wait_for(ready.wait(),2);await asyncio.sleep(18)
            self.assertFalse(reader.at_eof());server_writer.write(b'alive');await server_writer.drain()
            self.assertEqual(await asyncio.wait_for(reader.readexactly(5),2),b'alive')
        finally:
            writer.close();await writer.wait_closed()
            if server_writer:server_writer.close();await server_writer.wait_closed()
            server.close();await server.wait_closed()
