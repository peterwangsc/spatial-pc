"""Memory transports/fake media only. No desktop input, capture or vendor runtime."""
import asyncio
import json
from pathlib import Path
import struct
import sys
import time
import unittest
from unittest.mock import AsyncMock, patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'windows'/'host'))
from product import control_wire as wire
from product.focus_control import FocusControl, ControlSession
from product.focus import FocusController
from product.main import Worker
from test_focus_host import Deployment, Adapter


DEVICE = 'a'*32


def request(number, operation, **parameters):
    return dict(version=1, type='request', id=number, operation=operation, parameters=parameters)


class Writer:
    def __init__(self): self.records = []; self.block = None
    def write(self, frame):
        size = struct.unpack('>I', frame[:4])[0]
        assert size == len(frame)-4
        self.records.append(json.loads(frame[4:]))
    async def drain(self):
        if self.block: await self.block.wait()


class Identity:
    def __init__(self, grant=True):
        self.state = dict(devices=[dict(id=DEVICE, name='Public fixture', fingerprint='fixture', pairedAt='', allowFocusControl=grant)])
        self.commits = 0
    def device_for(self, fingerprint):
        return next((d for d in self.state['devices'] if d['fingerprint'] == fingerprint), None)
    def set_focus_allowed(self, device_id, value, allowed):
        if not allowed(): raise ValueError('Expired')
        self.state['devices'][0]['allowFocusControl'] = value; self.commits += 1
    def revoke(self, device_id): self.state['devices'] = [d for d in self.state['devices'] if d['id'] != device_id]


class FakeAdapter(Adapter):
    def __init__(self, config, session):
        super().__init__(config, session); self.config = config; self.session = session
    async def start(self, device):
        self.config['_authorize'](self.session)
        await super().start(device)


class WireTests(unittest.TestCase):
    def test_requests_roundtrip(self):
        for op, parameters in [('capabilities', {}), ('heartbeat', {}), ('focus.requestPermission', {}),
            ('focus.prepare', dict(intent='setup')), ('focus.stop', dict(sessionId=None, returnToDesktop=False))]:
            value = request(1, op, **parameters)
            self.assertEqual(wire.decode(json.dumps(value).encode(), 1), value)

    def test_strict_fields_ids_types_duplicates_numbers(self):
        value = request(1, 'heartbeat')
        mutations = [dict(value, id=True), dict(value, id=2), dict(value, id=0), dict(value, version=True),
            dict(value, extra=1), dict(value, parameters={'extra': 1}), dict(value, parameters=[]),
            request(1, 'focus.stop', sessionId='wrong', returnToDesktop=False),
            request(1, 'focus.stop', sessionId=None, returnToDesktop=1),
            request(1, 'focus.prepare', intent=[])]
        for bad in mutations:
            with self.subTest(bad=bad), self.assertRaises(ValueError): wire.decode(json.dumps(bad).encode(), 1)
        for raw in (b'{"id":1,"id":1}', json.dumps(value).replace('"id": 1','"id": 1.0').encode(),
                    b'{"x":NaN}', b'\xff', b'{"x":[[[[[[[[0]]]]]]]]}', b' ' * 8193):
            with self.subTest(raw=raw[:60]), self.assertRaises(ValueError): wire.decode(raw, 1)


class SessionTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.events = []
        self.identity = Identity()
        self.worker = Worker(self.identity, Path('capture.exe'), Path('input.exe'), self.events.append,
            discovery=False, focus_deployment=Deployment(), focus_factory=FakeAdapter)
        self.worker.address = '127.0.0.1'; self.worker.enabled = True
        self.worker.pause_desktop = AsyncMock()
        self.worker.start_desktop = AsyncMock()
        self.hub = FocusControl(self.worker); self.worker.control = self.hub
        self.reader = asyncio.StreamReader(); self.writer = Writer()
        self.session = ControlSession(self.hub, DEVICE, 'fixture', self.reader, self.writer,
                                      '127.0.0.2', '127.0.0.1', time.monotonic()+3600)
        self.hub.sessions.add(self.session)
        self.task = asyncio.create_task(self.session.run()); self.number = 0

    async def asyncTearDown(self):
        self.reader.feed_eof()
        await asyncio.wait_for(self.task, 2)
        self.assertIsNone(self.worker.focus.token)

    def send(self, operation, **parameters):
        self.number += 1; self.reader.feed_data(wire.encode(request(self.number, operation, **parameters)))
        return self.number

    async def until(self, predicate):
        async with asyncio.timeout(2):
            while not predicate(): await asyncio.sleep(.001)

    async def terminal(self, number):
        await self.until(lambda: any(r['id'] == number and r['type'] != 'progress' for r in self.writer.records))
        return next(r for r in self.writer.records if r['id'] == number and r['type'] != 'progress')

    async def prepare(self):
        result = await self.terminal(self.send('focus.prepare', intent='enter'))
        self.assertEqual(result['type'], 'result', result)
        return result['result']['sessionId']

    async def test_capabilities_exact_and_rate_limit(self):
        result = (await self.terminal(self.send('capabilities')))['result']
        self.assertFalse(result['consumerReady']); self.assertFalse(result['hardwareValidated'])
        self.assertEqual(result['systemTrust'], 'apple-qr-separate')
        self.assertEqual((await self.terminal(self.send('capabilities')))['code'], 'rateLimited')
        self.assertEqual((await self.terminal(self.send('heartbeat')))['type'],'result')
        self.assertTrue(self.session.live)

    async def test_prepare_stop_restores_listener_even_return_false(self):
        sid = await self.prepare()
        self.assertEqual(self.worker.media.mode, 'focus')
        self.assertEqual(self.worker.pause_desktop.await_count, 1)
        result = await self.terminal(self.send('focus.stop', sessionId=sid, returnToDesktop=False))
        self.assertTrue(result['result']['desktopAllowed'])
        self.worker.start_desktop.assert_awaited_once()
        self.assertEqual(self.worker.media.mode, 'idle')
        self.assertIn('focusControlStarted', [e['event'] for e in self.events])

    async def test_eof_restores_listener(self):
        await self.prepare(); self.reader.feed_eof(); await self.task
        self.worker.start_desktop.assert_awaited_once()
        self.assertEqual(self.worker.media.mode, 'idle')

    async def test_disable_suppresses_restoration(self):
        await self.prepare(); self.worker.enabled = False
        await self.terminal(self.send('focus.stop', sessionId=None, returnToDesktop=True))
        self.worker.start_desktop.assert_not_awaited()

    async def test_interface_loss_suppresses_restoration(self):
        await self.prepare()
        with patch('product.main.local_addresses', return_value={}):
            await self.terminal(self.send('focus.stop', sessionId=None, returnToDesktop=True))
        self.worker.start_desktop.assert_not_awaited(); self.assertFalse(self.worker.enabled)

    async def test_duplicate_prepare_preserves_first(self):
        sid = await self.prepare()
        response = await self.terminal(self.send('focus.prepare', intent='setup'))
        self.assertEqual(response['code'], 'busy'); self.assertEqual(self.worker.focus.session_id, sid)
        self.assertTrue(self.worker.focus_previous_enabled)
        self.assertEqual(self.worker.pause_desktop.await_count, 1)

    async def test_wrong_session_cannot_stop_owner(self):
        sid = await self.prepare()
        self.assertEqual((await self.terminal(self.send('focus.stop', sessionId='f'*32, returnToDesktop=True)))['code'], 'wrongOwner')
        self.assertEqual(self.worker.focus.session_id, sid)

    async def test_idempotent_old_stop_cannot_stop_new_session(self):
        old = await self.prepare()
        await self.terminal(self.send('focus.stop', sessionId=old, returnToDesktop=False))
        new = await self.prepare()
        await self.terminal(self.send('focus.stop', sessionId=old, returnToDesktop=False))
        self.assertEqual(self.worker.focus.session_id, new)

    async def test_stop_and_heartbeat_bypass_suspended_prepare(self):
        entered = asyncio.Event()
        async def pause(): entered.set(); await asyncio.Event().wait()
        self.worker.pause_desktop = pause
        pending = self.send('focus.prepare', intent='enter'); await entered.wait()
        self.assertEqual((await self.terminal(self.send('heartbeat')))['type'], 'result')
        stop = self.send('focus.stop', sessionId=None, returnToDesktop=False)
        self.assertEqual((await self.terminal(pending))['code'], 'canceled')
        self.assertTrue((await self.terminal(stop))['result']['stopped'])
        self.worker.start_desktop.assert_awaited_once()
        self.assertFalse(any(r['type'] == 'result' and r['id'] == pending for r in self.writer.records))

    async def test_eof_during_native_start_cancels_and_restores(self):
        entered = asyncio.Event()
        class Slow(FakeAdapter):
            async def start(self, device): entered.set(); await asyncio.Event().wait()
        self.worker.focus.factory = Slow
        self.send('focus.prepare', intent='enter'); await entered.wait()
        self.reader.feed_eof(); await self.task
        self.worker.start_desktop.assert_awaited_once()

    async def test_permission_real_decision_and_no_implicit_grant(self):
        self.identity.state['devices'][0]['allowFocusControl'] = False
        pending = self.send('focus.requestPermission')
        await self.until(lambda: self.hub.permission is not None)
        self.assertEqual(self.identity.commits, 0)
        self.assertFalse(any(r['id'] == pending and r['type'] == 'result' for r in self.writer.records))
        self.hub.permission_decision(self.hub.permission[2], True)
        result = await self.terminal(pending)
        self.assertEqual(result['result'], dict(granted=True, reason='none')); self.assertEqual(self.identity.commits, 1)
        self.worker.pause_desktop.assert_not_awaited()

    async def test_permission_cancel_rejects_late_approval(self):
        self.identity.state['devices'][0]['allowFocusControl'] = False
        pending = self.send('focus.requestPermission')
        await self.until(lambda: self.hub.permission is not None); approval = self.hub.permission[2]
        stop = self.send('focus.stop', sessionId=None, returnToDesktop=False)
        self.assertEqual((await self.terminal(pending))['result'], dict(granted=False, reason='canceled'))
        await self.terminal(stop); self.hub.permission_decision(approval, True)
        self.assertEqual(self.identity.commits, 0)

    async def test_permission_denial(self):
        self.identity.state['devices'][0]['allowFocusControl'] = False
        pending = self.send('focus.requestPermission'); await self.until(lambda: self.hub.permission is not None)
        self.hub.permission_decision(self.hub.permission[2], False)
        self.assertEqual((await self.terminal(pending))['result'], dict(granted=False, reason='denied'))

    async def test_ungranted_prepare_has_no_media_side_effect(self):
        self.identity.state['devices'][0]['allowFocusControl'] = False
        result = await self.terminal(self.send('focus.prepare', intent='enter'))
        self.assertEqual(result['code'], 'permissionRequired'); self.worker.pause_desktop.assert_not_awaited()

    async def test_revoke_active_owner_restores_other_device_availability(self):
        await self.prepare(); self.identity.revoke(DEVICE); self.hub.revoke(DEVICE); await self.task
        self.worker.start_desktop.assert_awaited_once(); self.assertTrue(self.worker.enabled)

    async def test_other_desktop_owner_busy_not_disconnected(self):
        token = self.worker.media.claim('desktop', 'b'*32)
        result = await self.terminal(self.send('focus.prepare', intent='enter'))
        self.assertEqual(result['code'], 'busy'); self.worker.pause_desktop.assert_not_awaited()
        self.worker.media.release(token)

    async def test_same_owner_desktop_waits_then_claims(self):
        token = self.worker.media.claim('desktop', DEVICE)
        pending = self.send('focus.prepare', intent='enter')
        await self.until(lambda: self.hub.owner is self.session)
        self.worker.pause_desktop.assert_not_awaited()
        self.worker.media.release(token)
        self.assertEqual((await self.terminal(pending))['type'], 'result')

    async def test_canceled_queued_success_becomes_one_canceled_terminal(self):
        self.writer.block = asyncio.Event()
        # Block writer drain on an earlier result, then enqueue endpoint success.
        self.send('heartbeat'); await self.until(lambda: len(self.writer.records) == 1)
        pending = self.send('focus.prepare', intent='enter')
        await self.until(lambda: self.session.session_id is not None and self.session.operation.done())
        stop = self.send('focus.stop', sessionId=None, returnToDesktop=False)
        await self.until(lambda: self.worker.media.mode == 'idle')
        self.writer.block.set()
        self.assertEqual((await self.terminal(pending))['code'], 'canceled'); await self.terminal(stop)
        self.assertEqual(sum(r['id'] == pending and r['type'] != 'progress' for r in self.writer.records), 1)

    async def test_prepare_budget_survives_socket_and_stop(self):
        for _ in range(3):
            await self.prepare(); await self.terminal(self.send('focus.stop', sessionId=None, returnToDesktop=False))
        self.assertEqual((await self.terminal(self.send('focus.prepare', intent='enter')))['code'], 'rateLimited')
        self.assertEqual(self.worker.pause_desktop.await_count, 3)
        self.assertEqual((await self.terminal(self.send('heartbeat')))['type'],'result')
        self.assertTrue(self.session.live)

    async def test_uncertain_cleanup_poison_prevents_restore(self):
        class Bad(FakeAdapter):
            async def stop(self): raise RuntimeError('fixture uncertain cleanup')
        self.worker.focus.factory = Bad
        await self.prepare()
        result = await self.terminal(self.send('focus.stop', sessionId=None, returnToDesktop=False))
        self.assertEqual(result['code'], 'cleanupFailed'); self.assertTrue(self.worker.media.failed)
        self.worker.start_desktop.assert_not_awaited()

    async def test_malformed_record_closes_and_cleans_owner(self):
        await self.prepare()
        self.reader.feed_data(wire.encode(request(self.number, 'heartbeat')))
        await self.task
        self.worker.start_desktop.assert_awaited_once()

    async def test_writer_overflow_closes_and_cleans_owner(self):
        await self.prepare()
        self.writer.block = asyncio.Event()
        for _ in range(20): self.send('heartbeat')
        done,_=await asyncio.wait([self.task],timeout=.5)
        self.assertIn(self.task,done,'overflow must close without the test canceling the reader')
        self.worker.start_desktop.assert_awaited_once()

    async def test_heartbeat_does_not_extend_setup_or_media_deadline(self):
        await self.prepare(); self.session.deadline=time.monotonic()+.02
        deadline=self.session.deadline
        await self.terminal(self.send('heartbeat'))
        self.assertEqual(self.session.deadline,deadline)
        await asyncio.wait_for(self.task,1)
        self.worker.start_desktop.assert_awaited_once()

    async def test_permission_expiry_does_not_persist(self):
        self.identity.state['devices'][0]['allowFocusControl']=False
        self.session.certificate_deadline=time.monotonic()+.025
        pending=self.send('focus.requestPermission')
        result=await self.terminal(pending)
        self.assertEqual(result['result'],dict(granted=False,reason='timeout'))
        self.assertEqual(self.identity.commits,0)

    async def test_idle_timeout_closes_and_restores(self):
        await self.prepare(); self.session.last_record=time.monotonic()-16
        await asyncio.wait_for(self.task,1)
        self.worker.start_desktop.assert_awaited_once()

    async def test_last_request_response_then_owned_cleanup(self):
        await self.consume_until_final_request()
        final=self.send('focus.prepare',intent='enter')
        self.assertEqual(final,4096)
        self.assertEqual((await self.terminal(final))['type'],'result')
        await asyncio.wait_for(self.task,2)
        self.worker.start_desktop.assert_awaited_once()

    async def consume_until_final_request(self):
        for index in range(4095):
            self.send('heartbeat')
            if index%8==7:await self.terminal(self.number)
        await self.terminal(self.number)

    async def final_pending_disconnect(self, permission=False, extra_input=False):
        await self.consume_until_final_request()
        if permission:
            self.identity.state['devices'][0]['allowFocusControl']=False
            self.send('focus.requestPermission')
            await self.until(lambda:self.hub.permission is not None)
            approval=self.hub.permission[2]
        else:
            entered=asyncio.Event()
            async def pause():entered.set();await asyncio.Event().wait()
            self.worker.pause_desktop=pause
            self.send('focus.prepare',intent='enter');await entered.wait()
        self.assertEqual(self.number,4096)
        if extra_input:self.reader.feed_data(b'X')
        else:self.reader.feed_eof()
        done,_=await asyncio.wait([self.task],timeout=.3)
        self.assertIn(self.task,done,'final-ID peer loss must cancel without a test-issued cancellation')
        self.assertFalse(any(r['id']==4096 and r['type']=='result' for r in self.writer.records))
        if permission:
            self.hub.permission_decision(approval,True)
            self.assertEqual(self.identity.commits,0)
            self.worker.pause_desktop.assert_not_awaited()
        else:self.worker.start_desktop.assert_awaited_once()

    async def test_final_id_eof_cancels_pending_prepare(self):
        await self.final_pending_disconnect()

    async def test_final_id_eof_cancels_pending_permission(self):
        await self.final_pending_disconnect(permission=True)

    async def test_final_id_extra_bytes_cancel_pending_prepare(self):
        await self.final_pending_disconnect(extra_input=True)

    async def test_final_response_drains_before_normal_close(self):
        await self.consume_until_final_request()
        self.writer.block=asyncio.Event()
        final=self.send('heartbeat');await self.terminal(final)
        self.assertFalse(self.session.final_response.is_set());self.assertFalse(self.task.done())
        self.writer.block.set()
        done,_=await asyncio.wait([self.task],timeout=.3)
        self.assertIn(self.task,done);self.assertTrue(self.session.final_response.is_set())

    async def completed_permission_then_prepare(self, cancel_prepare=False):
        self.writer.block=asyncio.Event()
        self.send('heartbeat');await self.until(lambda:len(self.writer.records)==1)
        permission=self.send('focus.requestPermission')
        await self.until(lambda:self.session.operation is not None and self.session.operation.done())
        prepare=self.send('focus.prepare',intent='enter')
        await self.until(lambda:self.session.session_id is not None and self.session.operation.done())
        if cancel_prepare:
            self.send('focus.stop',sessionId=None,returnToDesktop=False)
            await self.until(lambda:self.worker.media.mode=='idle')
        self.writer.block.set()
        self.assertEqual((await self.terminal(permission))['result'],dict(granted=True,reason='none'))
        response=await self.terminal(prepare)
        if cancel_prepare:self.assertEqual(response['code'],'canceled')
        else:self.assertEqual(response['type'],'result')

    async def test_new_operation_preserves_completed_permission_result(self):
        await self.completed_permission_then_prepare()

    async def test_cancel_new_prepare_preserves_completed_permission_result(self):
        await self.completed_permission_then_prepare(cancel_prepare=True)

    async def test_idle_stop_preserves_completed_permission_result(self):
        self.writer.block=asyncio.Event()
        self.send('heartbeat');await self.until(lambda:len(self.writer.records)==1)
        permission=self.send('focus.requestPermission')
        await self.until(lambda:self.session.operation is not None and self.session.operation.done())
        stop=self.send('focus.stop',sessionId=None,returnToDesktop=False)
        await self.until(lambda:self.session.operation is None)
        self.writer.block.set()
        self.assertEqual((await self.terminal(permission))['result'],dict(granted=True,reason='none'))
        await self.terminal(stop)

    async def test_changed_interface_does_not_restore_on_another_address(self):
        await self.prepare();self.worker.address='127.0.0.2'
        self.reader.feed_eof();await self.task
        self.worker.start_desktop.assert_not_awaited();self.assertFalse(self.worker.enabled)

    async def test_explicit_disable_uses_shared_cleanup_without_deadlock(self):
        await self.prepare()
        await asyncio.wait_for(self.worker.stop(),2)
        await self.task
        self.worker.start_desktop.assert_not_awaited();self.assertFalse(self.worker.enabled)

    async def test_restoration_listener_failure_has_no_recursive_close(self):
        await self.prepare()
        self.worker.start_desktop=Worker.start_desktop.__get__(self.worker)
        self.worker.start_task=AsyncMock(side_effect=OSError('fixture listener failure'))
        class FailedStream:
            def __init__(self,*args):self.stopped=asyncio.Event();self.ready=asyncio.Event()
            async def run(self):await asyncio.Event().wait()
        with patch('product.main.StreamServer',FailedStream):
            result=await self.terminal(self.send('focus.stop',sessionId=None,returnToDesktop=False))
        self.assertEqual(result['code'],'cleanupFailed');self.assertFalse(self.worker.enabled)

    async def test_apple_disconnect_cleanup_allows_fresh_explicit_prepare(self):
        first=await self.prepare()
        self.worker.focus.adapter.running=False
        await self.until(lambda:self.worker.media.mode=='idle' and self.session.cleanup_task.done())
        self.worker.start_desktop.assert_awaited_once()
        second=await self.prepare()
        self.assertNotEqual(first,second)


if __name__ == '__main__': unittest.main()
