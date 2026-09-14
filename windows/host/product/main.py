"""Windows Forms child backend. Bounded local stdio IPC, never an HTTP control API."""
import argparse
import asyncio
import ipaddress
import json
import os
from pathlib import Path
import queue
import sys
import threading
import time
from .identity import Identity
from .pairing_server import PairingServer
from .stream_server import StreamServer
from .discovery import Discovery
from .network import local_addresses,normalize


class Worker:
    def __init__(self,identity,capture,bridge,notify,development=False,discovery=True):
        self.identity=identity;self.capture=capture;self.bridge=bridge;self.notify=notify;self.development=development
        self.stream_port=47993 if development else 47991;self.pair_port=47992 if development else 47990
        self.discovery_enabled=discovery;self.discovery=None;self.stream=None;self.stream_task=None
        self.pair=None;self.pair_task=None;self.address=None;self.enabled=False;self.connected=''
        self.message='Select a Private network and enable access when you are ready.'

    def status(self):
        self.notify(dict(event='status',enabled=self.enabled,connected=self.connected,message=self.message,
            needsNetwork=self.address is None,preferredAddress=self.identity.state.get('bindAddress'),
            devices=[{k:d[k] for k in ('id','name','pairedAt')} for d in self.identity.state['devices']]))

    def event(self,value):
        kind=value['event']
        if kind in ('connecting','connected'):
            self.connected=value['name']
            self.message=('Connecting securely…' if kind=='connecting' else
                          str(value['width'])+' × '+str(value['height'])+' · one physical display · encrypted LAN connection')
            self.status()
        elif kind=='disconnected':
            self.connected='';self.message=value.get('message','The device disconnected. You can reconnect from Vision Pro.');self.status()
        else:
            self.notify(value)
            if kind=='paired':self.status()

    async def start_task(self,task,ready):
        waiting=asyncio.create_task(ready.wait())
        try:
            done,_=await asyncio.wait([task,waiting],timeout=5,return_when=asyncio.FIRST_COMPLETED)
            if task in done:task.result();raise OSError('Listener stopped')
            if waiting not in done:raise TimeoutError('Listener did not start')
        finally:
            waiting.cancel();await asyncio.gather(waiting,return_exceptions=True)

    async def stop_pairing(self):
        pair,task=self.pair,self.pair_task;self.pair=self.pair_task=None
        if pair:pair.stop()
        if task:
            task.cancel();await asyncio.gather(task,return_exceptions=True)
        if self.discovery:await self.discovery.pairing(False)

    async def stop(self):
        self.enabled=False
        await self.stop_pairing()
        task=self.stream_task;self.stream_task=None
        if self.stream:self.stream.stopped.set()
        if task:
            task.cancel()
            result=await asyncio.gather(task,return_exceptions=True)
            if result and isinstance(result[0],RuntimeError):
                raise RuntimeError('Native process cleanup failed; quit Spatial PC')
        self.stream=None
        if self.discovery:
            await self.discovery.close();self.discovery=None
        self.connected='';self.message='Access is disabled. No desktop is being shared.';self.status()

    async def start(self):
        if not self.address:raise ValueError('Select a Private network first.')
        if not self.capture.is_file() or not self.bridge.is_file():raise ValueError('Repair the Spatial PC installation: a host component is missing.')
        await self.stop()
        self.stream=StreamServer(self.identity,self.address,self.stream_port,self.capture,self.bridge,self.event)
        self.stream_task=asyncio.create_task(self.stream.run())
        try:
            await self.start_task(self.stream_task,self.stream.ready)
            if self.discovery_enabled:
                self.discovery=Discovery(self.identity,self.address,self.stream_port,self.pair_port)
                await self.discovery.start()
            self.enabled=True
            self.message='Ready on '+self.address+'. Pair a device or reconnect from Vision Pro.'
            self.status()
        except BaseException:
            await self.stop();raise

    async def command(self,value):
        if not isinstance(value,dict) or len(value)>3:raise ValueError('Invalid local command')
        command=value.get('command')
        expected={'status':{'command'},'enable':{'command','value'},'network':{'command','address'},
                  'pair':{'command'},'cancelPairing':{'command'},'approve':{'command','requestId','accepted'},
                  'revoke':{'command','deviceId'},'shutdown':{'command'}}
        if command not in expected or set(value)!=expected[command]:raise ValueError('Invalid local command')
        if command=='status':self.status()
        elif command=='enable':
            if type(value['value']) is not bool:raise ValueError('Invalid access preference')
            if value['value']:await self.start()
            else:await self.stop()
        elif command=='network':
            if self.enabled:raise ValueError('Disable access before changing networks.')
            address=value['address']
            if not isinstance(address,str):raise ValueError('Invalid network address')
            address=normalize(address);ip=ipaddress.ip_address(address)
            local=local_addresses()
            if address not in local or ip.is_unspecified or ip.is_multicast or (ip.is_loopback and not self.development):
                raise ValueError('Choose an address on this PC.')
            self.identity.configure(bindAddress=address);self.address=address;self.status()
        elif command=='pair':
            if not self.enabled:raise ValueError('Enable access before pairing.')
            if len(self.identity.state['devices'])>=10:raise ValueError('Revoke a device before pairing another.')
            await self.stop_pairing()
            self.pair=PairingServer(self.identity,self.address,self.pair_port,self.stream_port,self.event)
            self.pair_task=asyncio.create_task(self.pair.run())
            try:
                await self.start_task(self.pair_task,self.pair.ready)
                if self.discovery:await self.discovery.pairing(True)
                code=self.pair.window.code()
                self.notify(dict(event='pairingCode',code='-'.join(code[i:i+4] for i in range(0,len(code),4)),
                    expiresSeconds=max(0,int(self.pair.window.expires-time.monotonic()))))
            except BaseException:
                await self.stop_pairing();raise
        elif command=='cancelPairing':await self.stop_pairing()
        elif command=='approve':
            if type(value['accepted']) is not bool or not isinstance(value['requestId'],str):raise ValueError('Invalid local approval')
            if self.pair:self.pair.approve(value['requestId'],value['accepted'])
        elif command=='revoke':
            if not isinstance(value['deviceId'],str) or len(value['deviceId'])!=32:raise ValueError('Invalid device')
            self.identity.revoke(value['deviceId'])
            if self.stream and self.stream.connected_id==value['deviceId']:
                await self.start() # Cancellation releases this device before accepting another.
            self.status()
        elif command=='shutdown':await self.stop()

    async def health(self):
        if self.stream_task and self.stream_task.done():
            task=self.stream_task
            await self.stop()
            try:task.result()
            except BaseException:pass
            self.notify(dict(event='error',message='Desktop sharing stopped. Check the display and network, then enable access again.'))
        if self.pair_task and self.pair_task.done():
            await self.stop_pairing()
        if self.enabled and self.address not in local_addresses():
            await self.stop();self.address=None
            self.notify(dict(event='error',message='The network changed. Select a Private network and enable access again.'))


async def run(development):
    loop=asyncio.get_running_loop();commands=asyncio.Queue(maxsize=16);stop=asyncio.Event();output=queue.Queue(maxsize=32)
    def halt():loop.call_soon_threadsafe(stop.set)
    def notify(value):
        try:output.put_nowait(json.dumps(value,separators=(',',':'),ensure_ascii=True))
        except queue.Full:halt()
    def output_loop():
        try:
            while True:
                item=output.get()
                if item is None:return
                sys.stdout.write(item+'\n');sys.stdout.flush()
        except (OSError,ValueError):halt()
    def enqueue(value):
        try:commands.put_nowait(value)
        except asyncio.QueueFull:stop.set()
    def input_loop():
        try:
            while True:
                line=sys.stdin.buffer.readline(8193)
                if not line or len(line)>8192:halt();return
                value=json.loads(line)
                loop.call_soon_threadsafe(enqueue,value)
        except (OSError,ValueError,UnicodeError):halt()
    threading.Thread(target=output_loop,daemon=True).start()
    threading.Thread(target=input_loop,daemon=True).start()
    root=Path(os.environ['LOCALAPPDATA'])/('SpatialPC-Development' if development else 'SpatialPC')
    app=Path(__file__).resolve().parents[2]
    worker=None
    try:
        identity=Identity(root)
        worker=Worker(identity,app/'native'/'capture.exe',app/'native'/'input_bridge.exe',notify,development)
        worker.status()
        while not stop.is_set():
            try:value=await asyncio.wait_for(commands.get(),.5)
            except asyncio.TimeoutError:await worker.health();continue
            try:
                await worker.command(value)
                if value.get('command')=='shutdown':break
            except (ValueError,OSError,TimeoutError):
                notify(dict(event='error',message='The operation could not finish. Check your Private network and installation, then try again.'))
    except Exception:
        notify(dict(event='error',message='Spatial PC could not open its protected identity. Your pairing has not been reset. Repair the installation or contact support.'))
    finally:
        if worker:await worker.stop()
        await asyncio.sleep(.05)


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--development',action='store_true')
    args=parser.parse_args()
    asyncio.run(run(args.development))
