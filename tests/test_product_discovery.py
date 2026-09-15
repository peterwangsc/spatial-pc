import asyncio
import ipaddress
import os
from pathlib import Path
import secrets
import sys
from types import SimpleNamespace
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'windows'/'host'))
from product.discovery import Discovery,close_discovery
from product.network import local_addresses,normalize
from zeroconf import IPVersion
from zeroconf.asyncio import AsyncZeroconf,AsyncServiceInfo


class DiscoveryTests(unittest.IsolatedAsyncioTestCase):
    async def test_loopback_resolves_distinct_pair_and_stream_ports(self):
        await self.check_services('127.0.0.1',IPVersion.V4Only)

    @unittest.skipUnless(os.environ.get('SPATIAL_PC_TEST_IPV6'),'Explicit assigned-interface IPv6 discovery window required')
    async def test_assigned_ipv6_interface_resolves_aaaa_and_pair_port(self):
        address=normalize(os.environ['SPATIAL_PC_TEST_IPV6'])
        self.assertIn(address,local_addresses());self.assertEqual(ipaddress.ip_address(address).version,6)
        await self.check_services(address,IPVersion.V6Only)

    async def check_services(self,address,version):
        host=secrets.token_hex(16)
        identity=SimpleNamespace(state={'hostId':host,'serverName':'spatialpc-'+host+'.local'})
        discovery=Discovery(identity,address,47993,47992)
        browser=AsyncZeroconf(interfaces=[address],ip_version=version)
        try:
            await discovery.start()
            stream=AsyncServiceInfo('_spatialpc._tcp.local.',discovery.info.name)
            self.assertTrue(await stream.async_request(browser.zeroconf,2500))
            self.assertEqual(stream.port,47993);self.assertEqual(stream.properties[b'pairing'],b'0')
            self.assertEqual(stream.properties[b'version'],b'1')
            self.assertEqual(stream.properties[b'pairingVersion'],b'2')
            self.assertIn(ipaddress.ip_address(address).packed,stream.addresses_by_version(version))
            self.assertIsNone(discovery.pair_info)
            await discovery.pairing(True)
            pair=AsyncServiceInfo('_spatialpc-pair._tcp.local.',discovery.pair_info.name)
            self.assertTrue(await pair.async_request(browser.zeroconf,2500))
            self.assertEqual(pair.port,47992);self.assertEqual(pair.server,stream.server)
            self.assertIn(ipaddress.ip_address(address).packed,pair.addresses_by_version(version))
            self.assertEqual(pair.properties[b'hostId'],host.encode())
            self.assertEqual(pair.properties[b'pairingVersion'],b'2')
            await discovery.pairing(False)
            self.assertIsNone(discovery.pair_info)
            # Observe the real goodbye, then query with a fresh cache object.
            await asyncio.sleep(.2)
            absent=AsyncServiceInfo(pair.type,pair.name)
            self.assertFalse(await absent.async_request(browser.zeroconf,600))
        finally:
            transports={wrapped.transport for instance in (discovery.zeroconf,browser) if instance
                        for wrapped in (*instance.zeroconf.engine.senders,*instance.zeroconf.engine.readers)}
            sockets=[transport.get_extra_info('socket') for transport in transports]
            await discovery.close();await close_discovery(browser)
            self.assertTrue(sockets)
            self.assertTrue(all(sock.fileno()==-1 for sock in sockets),'Discovery socket leaked at close')
