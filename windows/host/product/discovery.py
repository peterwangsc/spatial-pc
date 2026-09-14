import socket
from zeroconf import IPVersion, ServiceInfo
from zeroconf.asyncio import AsyncZeroconf


class Discovery:
    def __init__(self,identity,address,stream_port,pair_port):
        self.identity=identity;self.address=address;self.stream_port=stream_port;self.pair_port=pair_port
        self.zeroconf=None;self.info=None

    async def start(self):
        self.zeroconf=AsyncZeroconf(interfaces=[self.address],ip_version=IPVersion.V4Only)
        host_id=self.identity.state['hostId']
        self.info=ServiceInfo('_spatialpc._tcp.local.','Spatial PC '+host_id[:8]+'._spatialpc._tcp.local.',
            addresses=[socket.inet_aton(self.address)],port=self.stream_port,
            properties={'version':'1','hostId':host_id,'pairPort':str(self.pair_port),'pairing':'0'},
            server=self.identity.state['serverName']+'.')
        await self.zeroconf.async_register_service(self.info)

    async def pairing(self,enabled):
        if not self.info:return
        self.info=ServiceInfo(self.info.type,self.info.name,addresses=self.info.addresses,port=self.info.port,
            properties={'version':'1','hostId':self.identity.state['hostId'],'pairPort':str(self.pair_port),'pairing':'1' if enabled else '0'},server=self.info.server)
        await self.zeroconf.async_update_service(self.info)

    async def close(self):
        if self.zeroconf:
            try:await self.zeroconf.async_unregister_all_services()
            finally:await self.zeroconf.async_close();self.zeroconf=None
