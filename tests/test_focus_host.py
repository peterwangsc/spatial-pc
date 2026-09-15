"""No GPU, network listener, vendor runtime, real identity or input injection."""
import asyncio
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import AsyncMock,patch,Mock
import datetime as dt
import subprocess
import time
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'windows'/'host'))
from product.focus import FocusController,FocusDeployment
from product.media_owner import MediaOwner
from product.main import Worker
from product.stream_server import StreamServer
from product.focus import NativeFocus
from input_server import run_session


class Deployment:
    def load(self):return {}


class Adapter:
    def __init__(self,config,session):self.running=False;self.stopped=False
    async def start(self,device):self.running=True
    async def stop(self):self.running=False;self.stopped=True
    def alive(self):return self.running


class FocusTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.media=MediaOwner();self.events=[]
        self.focus=FocusController(self.media,Deployment(),lambda:self.events.append(self.focus.state),Adapter)

    async def test_start_stop_claim_before_prepare_and_no_credentials_in_status(self):
        async def prepare():self.assertEqual(self.media.mode,'focus')
        await self.focus.start('a'*32,prepare)
        self.assertEqual(self.focus.state,'ready');self.assertEqual(self.media.device_id,'a'*32)
        self.assertNotIn('token',json.dumps(self.focus.capability()))
        self.assertFalse(self.focus.capability()['remoteControl'])
        await self.focus.stop();self.assertEqual(self.media.mode,'idle')
        self.assertEqual(self.events,['starting','ready','stopping','idle'])

    async def test_active_desktop_refuses_focus_without_prepare(self):
        token=self.media.claim('desktop','b'*32);prepare=AsyncMock()
        with self.assertRaises(ValueError):await self.focus.start('a'*32,prepare)
        prepare.assert_not_awaited();self.assertEqual(self.media.mode,'desktop');self.media.release(token)

    async def test_focus_refuses_desktop_and_second_owner(self):
        await self.focus.start('a'*32,AsyncMock())
        for mode in ('desktop','focus'):
            with self.assertRaises(ValueError):self.media.claim(mode,'b'*32)
        await self.focus.stop()

    async def test_prepare_failure_cleans_claim(self):
        with self.assertRaises(OSError):await self.focus.start('a'*32,AsyncMock(side_effect=OSError()))
        self.assertEqual(self.media.mode,'idle');self.assertIsNone(self.focus.adapter)

    async def test_start_failure_cleans_adapter(self):
        class Bad(Adapter):
            async def start(self,device):raise OSError()
        self.focus.factory=Bad
        with self.assertRaises(OSError):await self.focus.start('a'*32,AsyncMock())
        self.assertEqual(self.media.mode,'idle')

    async def test_canceled_start_cleans_adapter(self):
        reached=asyncio.Event()
        class Slow(Adapter):
            async def start(self,device):reached.set();await asyncio.Event().wait()
        self.focus.factory=Slow
        task=asyncio.create_task(self.focus.start('a'*32,AsyncMock()));await reached.wait()
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):await task
        self.assertEqual(self.media.mode,'idle')

    async def test_failed_cleanup_poisoned_no_new_mode(self):
        class Bad(Adapter):
            async def stop(self):raise RuntimeError('uncertain cleanup')
        self.focus.factory=Bad;await self.focus.start('a'*32,AsyncMock())
        with self.assertRaises(RuntimeError):await self.focus.stop()
        self.assertTrue(self.media.failed);self.assertEqual(self.focus.state,'failed')
        with self.assertRaises(ValueError):self.media.claim('desktop','a'*32)

    async def test_unexpected_exit_releases_without_restart(self):
        await self.focus.start('a'*32,AsyncMock());self.focus.adapter.running=False
        with self.assertRaises(OSError):await self.focus.health()
        self.assertEqual(self.media.mode,'idle');self.assertIsNone(self.focus.adapter)

    async def test_stop_idempotent(self):
        await self.focus.stop();await self.focus.start('a'*32,AsyncMock());await self.focus.stop();await self.focus.stop()
        self.assertEqual(self.media.mode,'idle')


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        self.names=['NvStreamManager.exe','NvStreamManagerClient.dll','releases/6.2.3/openxr_cloudxr.json','releases/6.2.3/cloudxr.dll','scene.exe','runtime.yaml']
        files={}
        for name in self.names:
            path=self.root/'focus'/name;path.parent.mkdir(parents=True,exist_ok=True)
            payload=b'NOT EXECUTABLE'
            if name.endswith('.json'):payload=json.dumps({'runtime':{'library_path':'cloudxr.dll'}}).encode()
            path.write_bytes(payload);files[name]=hashlib.sha256(payload).hexdigest()
        (self.root/'native').mkdir();(self.root/'native'/'focus_bridge.exe').write_bytes(b'NOT EXECUTABLE')
        self.data=dict(version=1,runtimeVersion='6.2.3',managerVersion='6.1.0',reviewed=True,
            mediaSecurity='development-only-unencrypted',manager=self.names[0],clientLibrary=self.names[1],manifest=self.names[2],scene=self.names[4],runtimeConfig=self.names[5],files=files)
        self.save();self.deployment=FocusDeployment(self.root)
    def save(self): (self.root/'focus'/'deployment.json').write_text(json.dumps(self.data))
    def tearDown(self):self.temp.cleanup()
    def test_matching_inventory_loads_paths_without_execution(self):self.assertEqual(Path(self.deployment.load()['scene']).name,'scene.exe')
    def test_ordinary_product_loads_reviewed_inventory_without_flags(self):
        self.assertEqual(Path(FocusDeployment(self.root).load()['scene']).name,'scene.exe')
    def test_unreviewed_or_wrong_version_or_security_fail_closed(self):
        for key,value in [('reviewed',False),('runtimeVersion','6.2.1'),('mediaSecurity','encrypted'),('version',True)]:
            old=self.data[key];self.data[key]=value;self.save()
            with self.assertRaises(ValueError):self.deployment.load()
            self.data[key]=old
    def test_modified_dependency_rejected(self):
        (self.root/'focus'/self.names[0]).write_bytes(b'changed')
        with self.assertRaises(ValueError):self.deployment.load()
    def test_extra_dll_rejected(self):
        (self.root/'focus'/'unexpected.dll').write_bytes(b'new')
        with self.assertRaises(ValueError):self.deployment.load()
    def test_path_escape_rejected(self):
        self.data['files']['../outside']='0'*64;self.save()
        with self.assertRaises(ValueError):self.deployment.load()
    def test_duplicate_keys_rejected(self):
        p=self.root/'focus'/'deployment.json';p.write_text(p.read_text()[:-1]+',"version":1}')
        with self.assertRaises(ValueError):self.deployment.load()
    def test_missing_artifacts_capability_false(self):
        (self.root/'focus'/'deployment.json').unlink()
        controller=FocusController(MediaOwner(),self.deployment,lambda:None,Adapter)
        self.assertFalse(controller.capability()['configured']);self.assertFalse(controller.capability()['available'])


class FakeIdentity:
    def __init__(self):self.state={'devices':[{'id':'a'*32,'name':'fixture','pairedAt':'today'}]}
    def revoke(self,device):self.state['devices']=[d for d in self.state['devices'] if d['id']!=device]


class WorkerTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();root=Path(self.temp.name)
        self.events=[];self.worker=Worker(FakeIdentity(),root/'capture.exe',root/'input.exe',self.events.append,
            development=True,discovery=False,focus_deployment=Deployment(),focus_factory=Adapter)
        self.worker.enabled=True
        self.worker.address='127.0.0.1'
        self.worker.pause_desktop=AsyncMock();self.worker.start_desktop=AsyncMock()
    async def asyncTearDown(self):await self.worker.stop();self.temp.cleanup()
    async def test_start_stop_local_owner_resume(self):
        await self.worker.command({'command':'startFocus'})
        self.worker.pause_desktop.assert_awaited_once();await self.worker.command({'command':'stopFocus'})
        self.worker.start_desktop.assert_awaited_once()
    async def test_missing_network_start_refused(self):
        self.worker.address=None
        with self.assertRaises(ValueError):await self.worker.command({'command':'startFocus'})
        self.worker.pause_desktop.assert_not_awaited()

    async def test_disabled_access_rejects_local_immersive_without_mutation(self):
        self.worker.enabled=False
        before=json.dumps(self.worker.identity.state)
        with self.assertRaises(ValueError):await self.worker.command({'command':'startFocus'})
        self.assertFalse(self.worker.enabled);self.worker.start_desktop.assert_not_awaited()
        self.worker.pause_desktop.assert_not_awaited()
        self.assertIsNone(self.worker.focus.adapter);self.assertIsNone(self.worker.focus.token)
        self.assertIsNone(self.worker.control.listener);self.assertEqual(self.worker.media.mode,'idle')
        self.assertEqual(before,json.dumps(self.worker.identity.state))

    async def test_focus_failure_from_disabled_returns_disabled(self):
        self.worker.enabled=False
        class Bad(Adapter):
            async def start(self,device):raise OSError('fixture')
        self.worker.focus.factory=Bad
        with self.assertRaises(ValueError):await self.worker.command({'command':'startFocus'})
        self.assertIsNone(self.worker.focus.adapter)
        self.assertFalse(self.worker.enabled);self.worker.start_desktop.assert_not_awaited()

    async def test_repeated_start_preserves_first_focus_from_enabled(self):
        for previous in (True,):
            self.worker.enabled=previous
            self.worker.start_desktop.reset_mock();self.worker.pause_desktop.reset_mock()
            await self.worker.command({'command':'startFocus'})
            owner=self.worker.focus.token;adapter=self.worker.focus.adapter
            generation=self.worker.focus.generation
            with self.assertRaises(ValueError):await self.worker.command({'command':'startFocus'})
            self.assertIs(self.worker.focus.token,owner)
            self.assertIs(self.worker.focus.adapter,adapter)
            self.assertEqual(self.worker.focus.generation,generation)
            self.assertTrue(adapter.running);self.assertTrue(self.worker.enabled)
            self.assertIs(self.worker.focus_previous_enabled,previous)
            self.assertEqual(self.worker.media.mode,'focus')
            self.worker.pause_desktop.assert_awaited_once()
            self.worker.start_desktop.assert_not_awaited()
            await self.worker.command({'command':'stopFocus'})
            self.assertEqual(self.worker.start_desktop.await_count,int(previous))
            self.assertEqual(self.worker.enabled,previous)

    async def test_focus_child_exit_does_not_enable_previous_disabled_desktop(self):
        await self.worker.command({'command':'startFocus'})
        self.worker.enabled=False
        self.worker.focus.adapter.running=False
        await self.worker.health()
        self.assertFalse(self.worker.enabled);self.worker.start_desktop.assert_not_awaited()
    async def test_revoke_owner_releases_focus(self):
        await self.worker.command({'command':'startFocus'})
        await self.worker.command({'command':'revoke','deviceId':'a'*32})
        self.assertEqual(self.worker.media.mode,'idle');self.assertEqual(self.worker.identity.state['devices'],[])
    async def test_disable_cleans_focus_no_desktop_resume(self):
        await self.worker.command({'command':'startFocus'})
        await self.worker.command({'command':'enable','value':False})
        self.assertFalse(self.worker.enabled);self.worker.start_desktop.assert_not_awaited()
    async def test_encoder_while_focus_refused(self):
        await self.worker.command({'command':'startFocus'})
        with self.assertRaises(ValueError):await self.worker.command({'command':'desktopEncoder','value':'nvenc'})
        self.assertEqual(self.worker.encoder,'mf')
    async def test_missing_optional_encoder_does_not_change_default(self):
        with self.assertRaises(ValueError):await self.worker.command({'command':'desktopEncoder','value':'nvenc'})
        self.assertEqual(self.worker.encoder,'mf')
    async def test_existing_pair_untouched_by_modes(self):
        before=json.dumps(self.worker.identity.state)
        await self.worker.command({'command':'startFocus'});await self.worker.command({'command':'stopFocus'})
        self.assertEqual(json.dumps(self.worker.identity.state),before)

    async def test_normal_product_has_focus_control_without_starting_it(self):
        worker=Worker(FakeIdentity(),Path('native/capture.exe'),Path('native/input.exe'),lambda x:None)
        self.assertFalse(worker.development);self.assertEqual(worker.stream_port,47991);self.assertEqual(worker.pair_port,47990)
        self.assertIsNotNone(worker.control);self.assertIsNone(worker.control.listener)
        self.assertFalse(worker.enabled);self.assertIsNone(worker.focus.adapter)
        self.assertIsNone(worker.stream);self.assertIsNone(worker.pair)
        self.assertEqual(worker.identity.state['devices'][0]['id'],'a'*32)


class DesktopAdapterTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tls=Mock();self.tls.selected_alpn_protocol.return_value='spatialpc/1';self.tls.getpeercert.return_value=b'public fixture'
        self.writer=Mock();self.writer.get_extra_info.return_value=self.tls
        self.fingerprint=hashlib.sha256(b'public fixture').hexdigest()
    async def test_mf_default_and_explicit_nvenc_arguments_only(self):
        for backend,extra in [('mf',()),('nvenc',('--encoder','nvenc'))]:
            with patch('input_server.hello',AsyncMock(return_value={'codecs':['h264-annexb']})),patch('input_server.asyncio.create_subprocess_exec',AsyncMock(side_effect=OSError('No child launched'))) as spawn:
                with self.assertRaises(OSError):await run_session(None,self.writer,{'clientSHA256':self.fingerprint},Path('capture'),Path('input'),Path('.'),time.monotonic()+10,encoder=backend)
                self.assertEqual(spawn.call_args.args,('capture','--stream',*extra))
    async def test_invalid_encoder_never_spawns(self):
        with patch('input_server.asyncio.create_subprocess_exec',AsyncMock()) as spawn:
            with self.assertRaises(ValueError):await run_session(None,self.writer,{},Path('capture'),Path('input'),Path('.'),time.monotonic()+10,encoder='other')
            spawn.assert_not_awaited()
    async def test_stream_refuses_existing_focus_before_native_owner(self):
        media=MediaOwner();token=media.claim('focus','a'*32);identity=Mock();identity.device_for.return_value={'id':'a'*32,'name':'fixture'}
        server=StreamServer(identity,'127.0.0.1',1,Path('capture'),Path('input'),lambda x:None,media)
        with patch('product.stream_server.CaptureOwner') as owner:
            with self.assertRaises(ValueError):await server.session(None,self.writer)
            owner.assert_not_called()
        media.release(token)
    async def test_stream_cleanup_failure_poisoned(self):
        media=MediaOwner();identity=Mock();identity.device_for.return_value={'id':'a'*32,'name':'fixture'};identity.directory=Path('.')
        peer=Mock();peer.not_valid_after_utc=dt.datetime.now(dt.timezone.utc)+dt.timedelta(days=1);identity.server=peer
        server=StreamServer(identity,'127.0.0.1',1,Path('capture'),Path('input'),lambda x:None,media)
        with patch('product.stream_server.CaptureOwner'),patch('product.stream_server.x509.load_der_x509_certificate',return_value=peer),patch('product.stream_server.run_session',AsyncMock(side_effect=RuntimeError('cleanup'))):
            with self.assertRaises(RuntimeError):await server.session(None,self.writer)
        self.assertTrue(media.failed)
    async def test_native_cleanup_failure_stays_failed_after_second_stop(self):
        adapter=NativeFocus({},'a'*32);adapter.process=Mock(returncode=72);adapter.process._transport=Mock()
        with patch('product.focus.close_child',AsyncMock()):
            with self.assertRaises(RuntimeError):await adapter.stop()
            with self.assertRaises(RuntimeError):await adapter.stop()


class NativeBridgeAdmission(unittest.TestCase):
    def test_eof_and_invalid_commands_exit_before_vendor_load(self):
        exe=Path(__file__).resolve().parents[1]/'.local'/'focus_bridge.exe'
        if not exe.is_file():self.skipTest('Build Focus bridge first')
        for data,code in [(b'',0),(b'{}\n',1),(b'x'*8194+b'\n',1)]:
            result=subprocess.run([str(exe)],input=data,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=5,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
            self.assertEqual(result.returncode,code);self.assertEqual(result.stdout,b'');self.assertEqual(result.stderr,b'')


if __name__=='__main__':unittest.main()
