import asyncio
from pathlib import Path
import secrets
import sys
from types import SimpleNamespace
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'windows'/'host'))
from product.discovery import Discovery
from zeroconf import IPVersion
from zeroconf.asyncio import AsyncZeroconf,AsyncServiceInfo


class DiscoveryTests(unittest.IsolatedAsyncioTestCase):
    async def test_loopback_resolves_distinct_pair_and_stream_ports(self):
        host=secrets.token_hex(16)
        identity=SimpleNamespace(state={'hostId':host,'serverName':'spatialpc-'+host+'.local'})
        discovery=Discovery(identity,'127.0.0.1',47993,47992)
        browser=AsyncZeroconf(interfaces=['127.0.0.1'],ip_version=IPVersion.V4Only)
        try:
            await discovery.start()
            stream=AsyncServiceInfo('_spatialpc._tcp.local.',discovery.info.name)
            self.assertTrue(await stream.async_request(browser.zeroconf,2500))
            self.assertEqual(stream.port,47993);self.assertEqual(stream.properties[b'pairing'],b'0')
            self.assertIsNone(discovery.pair_info)
            await discovery.pairing(True)
            pair=AsyncServiceInfo('_spatialpc-pair._tcp.local.',discovery.pair_info.name)
            self.assertTrue(await pair.async_request(browser.zeroconf,2500))
            self.assertEqual(pair.port,47992);self.assertEqual(pair.server,stream.server)
            self.assertEqual(pair.properties[b'hostId'],host.encode())
            await discovery.pairing(False)
            self.assertIsNone(discovery.pair_info)
            # Observe the real goodbye, then query with a fresh cache object.
            await asyncio.sleep(.2)
            absent=AsyncServiceInfo(pair.type,pair.name)
            self.assertFalse(await absent.async_request(browser.zeroconf,600))
        finally:
            await discovery.close();await browser.async_close()
