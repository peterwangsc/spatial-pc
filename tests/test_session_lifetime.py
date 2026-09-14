import asyncio
import io
import math
import os
from pathlib import Path
import struct
import json
import sys
import time
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'windows'/'host'))
from input_server import session_timeout,read_input,bounded_metadata
from input_protocol import Event


class LifetimeUnitTests(unittest.IsolatedAsyncioTestCase):
    def test_lab_retains_limit_and_product_uses_authorization_deadline(self):
        with patch('input_server.time.monotonic',return_value=100):
            self.assertEqual(session_timeout(1100),600)
            self.assertEqual(session_timeout(1100,True),1000)
            self.assertEqual(session_timeout(90,True),0)
            for invalid in (math.inf,-math.inf,math.nan):
                with self.assertRaises(ValueError):session_timeout(invalid,True)

    async def test_partial_record_times_out_even_without_control(self):
        reader=asyncio.StreamReader();reader.feed_data(b'S')
        before=time.monotonic()
        with self.assertRaises(TimeoutError):await read_input(reader,False,True)
        self.assertLess(time.monotonic()-before,3)

    async def test_active_input_without_heartbeat_times_out(self):
        with self.assertRaises(TimeoutError):await read_input(asyncio.StreamReader(),True,True)

    async def test_inactive_wait_accepts_fragmented_record(self):
        reader=asyncio.StreamReader();event=Event(5,0,1,0,0,0)
        task=asyncio.create_task(read_input(reader,False,True))
        await asyncio.sleep(.05);self.assertFalse(task.done())
        reader.feed_data(event.wire()[:1]);await asyncio.sleep(.05)
        reader.feed_data(event.wire()[1:]);self.assertEqual(await task,event)

    async def test_metadata_remains_bounded_and_retains_final_release(self):
        reader=asyncio.StreamReader();destination=io.BytesIO()
        reader.feed_data(b'x'*(1024*1024)+b'fixture released\n');reader.feed_eof()
        await bounded_metadata(reader,destination)
        self.assertLessEqual(len(destination.getvalue()),256*1024)
        self.assertTrue(destination.getvalue().endswith(b'fixture released\n'))


@unittest.skipUnless(os.name=='nt' and os.environ.get('SPATIAL_PC_LONG_IDLE')=='1',
                     'Explicit eleven-minute no-capture fixture run required')
class LongIdleTests(unittest.IsolatedAsyncioTestCase):
    async def test_idle_beyond_ten_minutes_then_input_and_revoke(self):
        # Reuse production DPAPI/TLS setup only; this executable has no DXGI or
        # SendInput imports and emits no frames in idle mode.
        from test_product_lifecycle import ProductLifecycle
        fixture=ProductLifecycle();writer=None
        with patch.dict(os.environ,{'SPATIAL_INPUT_FIXTURE_IDLE':'1'}):
            await fixture.asyncSetUp()
            try:
                reader,writer=await fixture.connect()
                value=json.dumps(dict(version=1,codecs=['h264-annexb'],maxWidth=8192,maxHeight=8192,
                                      input={'version':1,'textVersion':1})).encode()
                writer.write(b'SPC1'+struct.pack('!I',len(value))+value);await writer.drain()
                header=await asyncio.wait_for(reader.readexactly(8),5)
                caps=json.loads(await reader.readexactly(struct.unpack('!I',header[4:])[0]))
                self.assertEqual(caps['input']['textVersion'],1)
                started=time.monotonic();print('Long idle fixture started; no capture or injected input',flush=True)
                for _ in range(66):
                    await asyncio.sleep(10)
                    self.assertFalse(reader.at_eof());self.assertIsNotNone(fixture.worker.stream.connected_id)
                elapsed=time.monotonic()-started;self.assertGreaterEqual(elapsed,660)
                writer.write(Event(5,0,1,0,0,0).wire()+Event(4,1,2,4,0,0).wire());await writer.drain()
                deadline=time.monotonic()+2
                while 'fixture_control_active' not in (fixture.identity.directory/'input-status.log').read_text():
                    self.assertLess(time.monotonic(),deadline);await asyncio.sleep(.01)
                await fixture.worker.command(dict(command='revoke',deviceId=fixture.device['id']))
                self.assertEqual(await asyncio.wait_for(reader.read(),3),b'');await fixture.assert_release()
                rejected,rejected_writer=await fixture.connect()
                self.assertEqual(await asyncio.wait_for(rejected.read(),3),b'');await fixture.close(rejected_writer)
                print('Long idle fixture passed: '+json.dumps(dict(idleSeconds=round(elapsed,3),
                    nativeFixtureRelease=True,revokedReconnectRejected=True,realCapture=False,realInput=False)),flush=True)
            finally:
                if writer:await fixture.close(writer)
                await fixture.asyncTearDown()
