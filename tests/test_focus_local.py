"""Public in-memory protocol fixtures: no sockets, GPU, vendor code or real QR."""
import asyncio
import json
import struct
import time
import unittest
from unittest.mock import AsyncMock
from product.focus_local import LocalFocus,decode_message,read_message
from product.focus import FocusController
from product.media_owner import MediaOwner


def frame(event,session='public-session',**fields):
    data=json.dumps(dict(Event=event,SessionID=session,**fields)).encode()
    return struct.pack('<I',len(data))+data


REQUEST=frame('RequestConnection',ClientID='PUBLIC-CLIENT',ProtocolVersion='1',StreamingProvider='CloudXR')
BARCODE=frame('RequestBarcodePresentation')
WAITING=frame('SessionStatusDidChange',Status='WAITING')
DISCONNECTED=frame('SessionStatusDidChange',Status='DISCONNECTED')


class Writer:
    def __init__(self):self.data=bytearray();self.closed=False
    def write(self,data):self.data.extend(data)
    async def drain(self):pass
    def close(self):self.closed=True
    async def wait_closed(self):pass
    def get_extra_info(self,_):return None


class Native:
    def __init__(self,config,session):self.credentials=('a'*64,'PUBLIC-FIXTURE-TOKEN');self.client=None;self.starts=0;self.stopped=False
    async def start(self,client):self.client=client
    async def start_media(self):self.starts+=1
    async def stop(self):self.stopped=True
    def alive(self):return not self.stopped


class Wire(unittest.IsolatedAsyncioTestCase):
    def test_duplicate_unknown_version_types_rejected(self):
        for data in [b'{"Event":"RequestConnection","Event":"RequestConnection"}',
                     b'{"Event":"RequestConnection","SessionID":"x","ClientID":"y","ProtocolVersion":1}',
                     b'{"Event":"RequestConnection","SessionID":"x","ClientID":"y","ProtocolVersion":"2"}',
                     b'{"Event":"RequestBarcodePresentation","SessionID":"x","extra":true}',
                     b'{"Event":"SessionStatusDidChange","SessionID":"x","Status":"other"}',b'[]',b'\xff']:
            with self.subTest(data=data):
                with self.assertRaises((ValueError,UnicodeError)):decode_message(data)

    async def test_length_checked_before_payload_allocation(self):
        for size in (0,8193,0xffffffff):
            reader=asyncio.StreamReader();reader.feed_data(struct.pack('<I',size))
            with self.assertRaises(ValueError):await read_message(reader,.1)

    async def test_fragment_deadline(self):
        reader=asyncio.StreamReader();reader.feed_data(REQUEST[:8])
        with self.assertRaises(TimeoutError):await read_message(reader,.01)

    async def test_little_endian_request(self):
        reader=asyncio.StreamReader();reader.feed_data(REQUEST)
        self.assertEqual((await read_message(reader,.1))['ClientID'],'PUBLIC-CLIENT')


class Sessions(unittest.IsolatedAsyncioTestCase):
    async def test_control_peer_restriction_rejects_other_source_before_native(self):
        self.focus.config['_control_peer']='192.0.2.23'
        self.writer.get_extra_info=lambda key:('192.0.2.24',50000) if key=='peername' else None
        self.focus._accept(asyncio.StreamReader(),self.writer)
        self.assertTrue(self.writer.closed);self.assertIsNone(self.focus.task);self.assertIsNone(self.focus.native)

    async def test_progress_is_metadata_only_and_media_timer_starts_at_waiting(self):
        phases=[]
        self.focus.config['_progress']=phases.append
        await self.run_messages(REQUEST+BARCODE+WAITING+DISCONNECTED)
        self.assertEqual(phases,['qrPresented','startingMedia','mediaReady'])
        self.assertNotIn('PUBLIC-FIXTURE-TOKEN',str(phases))

    async def test_expired_setup_never_calls_native_start(self):
        self.focus.deadline=time.monotonic()-.01
        await self.run_messages(REQUEST)
        self.assertTrue(self.focus.native is None or self.focus.native.client is None)

    def setUp(self):
        self.events=[]
        def notify(value):
            self.events.append(value)
            if value['event']=='focusBarcode':self.focus.barcode_receipt(value['requestId'],True)
        self.focus=LocalFocus({'_notify':notify},'b'*32,Native)
        self.focus.running=True;self.focus.deadline=time.monotonic()+5
        self.writer=Writer()

    async def asyncTearDown(self):await self.focus.stop()

    async def run_messages(self,data):
        reader=asyncio.StreamReader()
        task=asyncio.create_task(self.focus._connection(reader,self.writer))
        while data and not task.done():
            size=struct.unpack('<I',data[:4])[0];one=data[:4+size];data=data[4+size:]
            before=len(self.writer.data);reader.feed_data(one)
            for _ in range(100):
                if task.done() or len(self.writer.data)>before:break
                await asyncio.sleep(0)
        reader.feed_eof()
        await asyncio.wait_for(task,1)

    async def test_system_client_used_and_only_waiting_starts_media(self):
        await self.run_messages(REQUEST+BARCODE+WAITING+DISCONNECTED)
        self.assertEqual(self.focus.native.client,'PUBLIC-CLIENT');self.assertEqual(self.focus.native.starts,1)
        self.assertNotIn(b'PUBLIC-FIXTURE-TOKEN',self.writer.data)
        self.assertNotIn(b'CertificateFingerprint',self.writer.data) # Force documented QR.
        self.assertIn(b'MediaStreamIsReady',self.writer.data)
        self.assertTrue(self.writer.closed);self.assertFalse(self.focus.alive())
        native=self.focus.native;await self.focus.stop();self.assertTrue(native.stopped)

    async def test_eof_before_waiting_does_not_start_media(self):
        await self.run_messages(REQUEST+BARCODE)
        self.assertEqual(self.focus.native.starts,0)

    async def test_waiting_without_qr_refused(self):
        await self.run_messages(REQUEST+WAITING)
        self.assertEqual(self.focus.native.starts,0);self.assertNotIn(b'MediaStreamIsReady',self.writer.data)

    async def test_duplicate_waiting_never_starts_second_runtime(self):
        await self.run_messages(REQUEST+BARCODE+WAITING+WAITING)
        self.assertEqual(self.focus.native.starts,1)

    async def test_wrong_session_does_not_start_media(self):
        await self.run_messages(REQUEST+frame('RequestBarcodePresentation',session='other'))
        self.assertEqual(self.focus.native.starts,0)

    async def test_stale_ui_receipt_cannot_complete_current_request(self):
        self.focus.receipt=asyncio.get_running_loop().create_future();self.focus.receipt_id='current'
        self.focus.barcode_receipt('other',True);self.assertFalse(self.focus.receipt.done())
        self.focus.invalid=True;self.focus.barcode_receipt('current',True);self.assertFalse(self.focus.receipt.done())

    async def test_additional_connection_rejected_without_child(self):
        self.focus.task=asyncio.create_task(asyncio.sleep(1))
        self.focus._accept(asyncio.StreamReader(),self.writer)
        self.assertTrue(self.writer.closed);self.assertIsNone(self.focus.native)

    async def test_native_cleanup_uncertainty_remains_terminal(self):
        native=Native({},'');native.stop=AsyncMock(side_effect=RuntimeError('fixture'))
        self.focus.native=native
        with self.assertRaises(RuntimeError):await self.focus.stop()
        with self.assertRaises(RuntimeError):await self.focus.stop()
        native.stop=AsyncMock();self.focus.cleanup_failed=False

    async def test_cancel_pending_barcode_invalidates_and_closes(self):
        self.focus.config['_notify']=self.events.append
        reader=asyncio.StreamReader();reader.feed_data(REQUEST+BARCODE)
        self.focus.task=asyncio.create_task(self.focus._connection(reader,self.writer))
        for _ in range(30):
            if self.focus.receipt:break
            await asyncio.sleep(0)
        native=self.focus.native
        self.assertIsNotNone(self.focus.receipt)
        await self.focus.stop()
        self.assertTrue(native.stopped);self.assertTrue(self.writer.closed)

    async def test_disconnect_and_eof_cancel_each_inflight_phase(self):
        for phase in ('prepare','barcode','media'):
            for terminal in ('disconnect','eof'):
                with self.subTest(phase=phase,terminal=terminal):
                    reached=asyncio.Event()
                    class Suspended(Native):
                        async def pause(self):
                            reached.set()
                            try:await asyncio.Event().wait()
                            except asyncio.CancelledError:pass # Deliberately late native completion.
                        async def start(self,client):
                            self.client=client
                            if phase=='prepare':await self.pause()
                        async def start_media(self):
                            if phase=='media':await self.pause()
                    events=[]
                    def notify(value):
                        events.append(value)
                        if value['event']=='focusBarcode':
                            if phase=='barcode':reached.set()
                            else:focus.barcode_receipt(value['requestId'],True)
                    focus=LocalFocus({'_notify':notify},'c'*32,Suspended)
                    focus.running=True;focus.deadline=time.monotonic()+5
                    reader=asyncio.StreamReader();writer=Writer()
                    focus.task=asyncio.create_task(focus._connection(reader,writer))
                    async def response(marker):
                        async with asyncio.timeout(1):
                            while marker not in writer.data:await asyncio.sleep(0)
                    reader.feed_data(REQUEST)
                    if phase!='prepare':
                        await response(b'AcknowledgeConnection');reader.feed_data(BARCODE)
                    if phase=='media':
                        await response(b'AcknowledgeBarcodePresentation');reader.feed_data(WAITING)
                    await asyncio.wait_for(reached.wait(),1)
                    if terminal=='eof':reader.feed_eof()
                    else:reader.feed_data(DISCONNECTED)
                    await asyncio.wait_for(focus.task,1)
                    self.assertTrue(focus.invalid);self.assertTrue(writer.closed);self.assertTrue(focus.native.stopped)
                    self.assertNotIn(b'MediaStreamIsReady',writer.data)
                    if phase=='prepare':self.assertNotIn(b'AcknowledgeConnection',writer.data)
                    if phase=='barcode':self.assertNotIn(b'AcknowledgeBarcodePresentation',writer.data)
                    await focus.stop()

    async def test_bounded_backlog_cancels_suspended_prepare(self):
        reached=asyncio.Event()
        class Suspended(Native):
            async def start(self,client):reached.set();await asyncio.Event().wait()
        self.focus.factory=Suspended
        reader=asyncio.StreamReader();self.focus.task=asyncio.create_task(self.focus._connection(reader,self.writer))
        reader.feed_data(REQUEST);await asyncio.wait_for(reached.wait(),1)
        reader.feed_data(BARCODE*9)
        await asyncio.wait_for(self.focus.task,1)
        self.assertTrue(self.focus.invalid);self.assertTrue(self.focus.native.stopped)
        self.assertNotIn(b'AcknowledgeConnection',self.writer.data)

    async def test_health_stop_does_not_interrupt_terminal_native_cleanup(self):
        closing=asyncio.Event();finish=asyncio.Event();calls=[]
        class SlowStop(Native):
            async def stop(self):
                if self.stopped:return
                calls.append('stop');closing.set();await finish.wait();self.stopped=True
        self.focus.factory=SlowStop
        reader=asyncio.StreamReader();self.focus.task=asyncio.create_task(self.focus._connection(reader,self.writer))
        reader.feed_data(REQUEST)
        async with asyncio.timeout(1):
            while b'AcknowledgeConnection' not in self.writer.data:await asyncio.sleep(0)
        reader.feed_eof();await asyncio.wait_for(closing.wait(),1)
        cleanup=asyncio.create_task(self.focus.stop());await asyncio.sleep(0);finish.set()
        await asyncio.wait_for(cleanup,1)
        self.assertEqual(calls,['stop']);self.assertFalse(self.focus.cleanup_failed)


class Generation(unittest.IsolatedAsyncioTestCase):
    async def test_late_prepare_after_stop_cannot_create_adapter(self):
        reached=asyncio.Event();created=[]
        class Deployment:
            def load(self):return {}
        async def prepare():
            reached.set()
            try:await asyncio.Event().wait()
            except asyncio.CancelledError:pass # Deliberately late completion.
        focus=FocusController(MediaOwner(),Deployment(),lambda:None,lambda *args:created.append(args))
        task=asyncio.create_task(focus.start(None,prepare));await reached.wait()
        await focus.stop()
        self.assertTrue(task.cancelled());self.assertEqual(created,[]);self.assertEqual(focus.media.mode,'idle')
