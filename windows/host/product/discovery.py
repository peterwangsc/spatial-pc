import ipaddress
import asyncio
from zeroconf import IPVersion, ServiceInfo
from zeroconf.asyncio import AsyncZeroconf
from .network import local_addresses


async def close_discovery(zeroconf):
    # zeroconf 0.151.3 owns these transports. Preserve their handles before its
    # engine shuts down; no sockets outside this discovery instance are touched.
    transports={wrapped.transport for wrapped in
                (*zeroconf.zeroconf.engine.senders,*zeroconf.zeroconf.engine.readers)}
    try:
        await zeroconf.async_close() # Sends service goodbyes first.
    finally:
        transports.update(wrapped.transport for wrapped in
                          (*zeroconf.zeroconf.engine.senders,*zeroconf.zeroconf.engine.readers))
        # CPython 3.14.7 Proactor close() can leave an outstanding UDP write
        # stranded: _loop_writing returns on _conn_lost before finishing close.
        # The public abort API completes socket cleanup even in that state.
        for transport in transports:transport.abort()
        await asyncio.sleep(0)


class Discovery:
    def __init__(self,identity,address,stream_port,pair_port):
        self.identity=identity;self.address=address;self.stream_port=stream_port;self.pair_port=pair_port
        self.zeroconf=None;self.info=None;self.pair_info=None
        ip=ipaddress.ip_address(address)
        self.version=IPVersion.V4Only if ip.version==4 else IPVersion.V6Only
        self.packed=[ip.packed];self.interface_index=local_addresses().get(address)

    async def start(self):
        self.zeroconf=AsyncZeroconf(interfaces=[self.address],ip_version=self.version)
        host_id=self.identity.state['hostId']
        self.info=ServiceInfo('_spatialpc._tcp.local.','Spatial PC '+host_id[:8]+'._spatialpc._tcp.local.',
            addresses=self.packed,port=self.stream_port,interface_index=self.interface_index,
            properties={'version':'1','hostId':host_id,'pairPort':str(self.pair_port),'pairing':'0'},
            server=self.identity.state['serverName']+'.')
        broadcast=await self.zeroconf.async_register_service(self.info)
        await broadcast

    async def pairing(self,enabled):
        if not self.info:return
        if enabled and self.pair_info is None:
            self.pair_info=ServiceInfo('_spatialpc-pair._tcp.local.',
                self.info.name.replace('._spatialpc._tcp.local.','._spatialpc-pair._tcp.local.'),
                addresses=self.packed,port=self.pair_port,interface_index=self.interface_index,
                properties={'version':'1','hostId':self.identity.state['hostId']},server=self.info.server)
            try:
                broadcast=await self.zeroconf.async_register_service(self.pair_info)
                await broadcast
            except BaseException:self.pair_info=None;raise
        elif not enabled and self.pair_info is not None:
            info=self.pair_info;self.pair_info=None
            broadcast=await self.zeroconf.async_unregister_service(info)
            await broadcast
        self.info=ServiceInfo(self.info.type,self.info.name,addresses=self.packed,port=self.info.port,interface_index=self.interface_index,
            properties={'version':'1','hostId':self.identity.state['hostId'],'pairPort':str(self.pair_port),'pairing':'1' if enabled else '0'},server=self.info.server)
        broadcast=await self.zeroconf.async_update_service(self.info)
        await broadcast

    async def close(self):
        if self.zeroconf:
            try:await close_discovery(self.zeroconf)
            finally:
                self.zeroconf=None;self.info=None;self.pair_info=None
