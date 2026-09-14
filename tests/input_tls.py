"""Authenticated duplex tests with a no-capture/no-injection native fixture."""
import argparse
import asyncio
import hashlib
import json
import os
from pathlib import Path
import ssl
import struct
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
sys.path.insert(0,str(ROOT/'windows'/'host'))
from create_lab_pair import create_pair
from input_protocol import Event


async def default_view_only(directory, fixture, port):
    directory.mkdir()
    pair_dir=directory/'pair';create_pair(pair_dir,'127.0.0.1',port)
    pair=json.loads((pair_dir/'lab-pair.json').read_text())
    with (directory/'host.log').open('w') as log:
        host=await asyncio.create_subprocess_exec(sys.executable,str(ROOT/'windows/host/lab_server.py'),
            '--credentials',str(pair_dir),'--capture',str(fixture),'--bind','127.0.0.1','--lifetime','3',
            stdout=log,stderr=log,creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0)
        try:
            deadline=time.monotonic()+5
            while 'listening' not in (directory/'host.log').read_text():
                if time.monotonic()>deadline:raise RuntimeError('Default host not ready')
                await asyncio.sleep(.05)
            context=ssl.create_default_context(cafile=str(pair_dir/'root.pem'))
            context.minimum_version=ssl.TLSVersion.TLSv1_3;context.set_alpn_protocols(['spatialpc/1'])
            context.load_cert_chain(str(pair_dir/'client.pem'),str(pair_dir/'client-key.pem'))
            reader,writer=await asyncio.open_connection('127.0.0.1',port,ssl=context,server_hostname=pair['serverName'])
            payload=json.dumps(dict(version=1,codecs=['h264-annexb'],maxWidth=8192,maxHeight=8192,input={'version':1})).encode()
            writer.write(b'SPC1'+struct.pack('!I',len(payload))+payload);await writer.drain()
            header=await asyncio.wait_for(reader.readexactly(8),3)
            caps=json.loads(await reader.readexactly(struct.unpack('!I',header[4:])[0]));assert 'input' not in caps
            writer.write(Event(5,0,1,0,0,0).wire());await writer.drain()
            header=await reader.readexactly(16);await reader.readexactly(struct.unpack('!I',header[:4])[0])
            writer.close()
            try:await writer.wait_closed()
            except OSError:pass
            await asyncio.wait_for(host.wait(),6)
            assert not (directory/'input-status.log').exists()
        finally:
            if host.returncode is None:host.terminate();await host.wait()


async def run(directory, fixture, port):
    directory.mkdir(parents=True, exist_ok=False)
    pair_dir = directory/'pair'
    create_pair(pair_dir,'127.0.0.1',port)
    pair = json.loads((pair_dir/'lab-pair.json').read_text())
    flags = subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0
    with (directory/'host.log').open('w') as log:
        host = await asyncio.create_subprocess_exec(sys.executable,str(ROOT/'windows/host/lab_server.py'),
            '--credentials',str(pair_dir),'--capture',str(fixture),'--input-bridge',str(fixture),
            '--enable-input','--bind','127.0.0.1','--lifetime','35',stdout=log,stderr=log,creationflags=flags)
        try:
            deadline = time.monotonic()+10
            while 'listening' not in (directory/'host.log').read_text():
                if time.monotonic()>deadline or host.returncode is not None:
                    raise RuntimeError('Fixture host failed to listen')
                await asyncio.sleep(.05)

            def context(client=True,trusted=True):
                value=ssl.create_default_context(cafile=str(pair_dir/'root.pem') if trusted else None)
                value.minimum_version=ssl.TLSVersion.TLSv1_3
                value.set_alpn_protocols(['spatialpc/1'])
                if client:value.load_cert_chain(str(pair_dir/'client.pem'),str(pair_dir/'client-key.pem'))
                return value

            async def connect(client=True,trusted=True):
                return await asyncio.wait_for(asyncio.open_connection('127.0.0.1',port,ssl=context(client,trusted),server_hostname=pair['serverName']),5)

            async def close(writer):
                writer.close()
                try:await asyncio.wait_for(writer.wait_closed(),2)
                except (OSError,asyncio.TimeoutError):pass

            for client,trusted in [(False,True),(True,False)]:
                writer=None
                try:
                    reader,writer=await connect(client,trusted)
                    writer.write(b'SPC1'+struct.pack('!I',2)+b'{}')
                    await writer.drain()
                    assert not await asyncio.wait_for(reader.read(1),2)
                except (ssl.SSLError,ConnectionError):pass
                finally:
                    if writer:await close(writer)
            assert not (directory/'encoder.log').exists(), 'Capture fixture started before authentication'

            async def session(version=None,text_version=None):
                reader,writer=await connect()
                tls=writer.get_extra_info('ssl_object')
                assert tls.version()=='TLSv1.3' and tls.selected_alpn_protocol()=='spatialpc/1'
                assert hashlib.sha256(tls.getpeercert(binary_form=True)).hexdigest()==pair['serverSHA256']
                hello=dict(version=1,codecs=['h264-annexb'],maxWidth=8192,maxHeight=8192)
                if version is not None:hello['input']={'version':version}
                if version is not None and text_version is not None:hello['input']['textVersion']=text_version
                data=json.dumps(hello).encode();writer.write(b'SPC1'+struct.pack('!I',len(data))+data);await writer.drain()
                header=await asyncio.wait_for(reader.readexactly(8),5);assert header[:4]==b'SPC1'
                caps=json.loads(await reader.readexactly(struct.unpack('!I',header[4:])[0]))
                return reader,writer,caps

            async def frames(reader,count):
                last=-1
                for _ in range(count):
                    header=await asyncio.wait_for(reader.readexactly(16),4)
                    size,pts,_=struct.unpack('!IQI',header)
                    assert 0<size<=16*1024*1024 and pts>last
                    await reader.readexactly(size);last=pts

            async def released():
                deadline=time.monotonic()+4
                path=directory/'input-status.log'
                while time.monotonic()<deadline:
                    lines=path.read_text().split('\n')[:-1] if path.exists() else []
                    results=[json.loads(line.split('=',1)[1]) for line in lines if line.startswith('fixture_input_summary=')]
                    if results:return results[-1]
                    await asyncio.sleep(.05)
                raise AssertionError('Native fixture did not release and exit')

            for version in (None,99):
                reader,writer,caps=await session(version)
                assert 'input' not in caps
                await frames(reader,3);await close(writer)
                await asyncio.sleep(.1)

            for text_version in (None,True,1.0,'1',2):
                reader,writer,caps=await session(1,text_version)
                assert 'textVersion' not in caps['input']
                writer.write(Event(5,0,1,0,0,0).wire());await writer.drain()
                await frames(reader,2)
                writer.write(Event(8,0,2,0x41,0,0).wire());await writer.drain()
                try:
                    await frames(reader,100)
                    raise AssertionError('Unnegotiated text accepted')
                except (asyncio.IncompleteReadError,ConnectionError):pass
                await close(writer)
                rejected_text=await released();assert rejected_text['downs']==rejected_text['ups']==0

            reader,writer,caps=await session(1,1)
            assert caps['input']['textVersion']==1
            for event in [Event(5,0,1,0,0,0),Event(8,0,2,0xE9,0,0),Event(8,0,3,0x1F642,0,0)]:writer.write(event.wire())
            await writer.drain();await frames(reader,10)
            writer.write(Event(6,0,4,0,0,0).wire());await writer.drain();await frames(reader,2)
            await close(writer)
            text_release=await released();assert text_release['downs']==text_release['ups']==3

            reader,writer,caps=await session(1)
            assert caps['input']['wire']=='SPI1'
            # Two event-loop tasks own separate directions through asyncio, never
            # concurrent cross-thread calls on an SSL object.
            async def controls():
                for event in [Event(5,0,1,0,0,0),Event(2,1,2,1234,4567,1),Event(4,1,3,4,0,0)]:
                    writer.write(event.wire())
                await writer.drain()
                for sequence in range(4,7):
                    await asyncio.sleep(.3);writer.write(Event(7,0,sequence,0,0,0).wire());await writer.drain()
            await asyncio.gather(frames(reader,40),controls())
            await close(writer)
            release=await released();assert release['downs']==release['ups']==2

            reader,writer,_=await session(1)
            for event in [Event(5,0,1,0,0,0),Event(4,1,2,4,0,0)]:writer.write(event.wire())
            await writer.drain()
            admitted=time.monotonic()
            while 'fixture_control_active' not in (directory/'input-status.log').read_text():
                assert time.monotonic()-admitted<1, 'Input start did not reach native fixture promptly'
                await asyncio.sleep(.01)
            admitted=time.monotonic()
            try:
                await asyncio.wait_for(frames(reader,1000),4)  # Bound by time after native admission, not frame rate.
                raise AssertionError('Lease did not close session')
            except (asyncio.IncompleteReadError,ConnectionError):pass
            assert time.monotonic()-admitted<4
            await close(writer)
            lease=await released();assert lease['downs']==lease['ups']==1

            reader,writer,_=await session(1)
            writer.write(Event(5,0,1,0,0,0).wire());writer.write(Event(2,1,2,0,0,1).wire());await writer.drain()
            await frames(reader,3)
            writer.write(Event(7,0,2,0,0,0).wire());await writer.drain()  # Replayed sequence.
            try:
                await frames(reader,100)
                raise AssertionError('Replayed input accepted')
            except (asyncio.IncompleteReadError,ConnectionError):pass
            await close(writer)
            replay=await released();assert replay['downs']==replay['ups']==1
            await default_view_only(directory/'default-view-only',fixture,port+1)
            result=dict(fixtureOnly=True,desktopCapture=False,inputInjection=False,tls='TLSv1.3',
                        certificateNegatives=True,hostDefaultViewOnly=True,oldClientViewOnly=True,unsupportedVersionViewOnly=True,
                        duplexVideoFrames=40,disconnectRelease=release,leaseRelease=lease,replayRelease=replay,
                        textNegotiation=True,unnegotiatedTextRejected=True,textRelease=text_release)
            (directory/'result.json').write_text(json.dumps(result,indent=2)+'\n')
            print(json.dumps(result))
        finally:
            if host.returncode is None:host.terminate()
            await host.wait()


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--directory',type=Path,required=True)
    parser.add_argument('--fixture',type=Path,required=True)
    parser.add_argument('--port',type=int,default=47992)
    args=parser.parse_args()
    asyncio.run(run(args.directory.resolve(),args.fixture.resolve(),args.port))
