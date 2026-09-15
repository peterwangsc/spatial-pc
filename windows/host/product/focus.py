"""On-demand Focus lifecycle inside the existing host. No new network protocol.

Only verified local runtime inventory can instantiate the native adapter.
CloudXR credentials stay inside the private adapter/control owner, never status.
"""
import asyncio
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
from .process_guard import CaptureOwner
from input_server import close_child


class FocusDeployment:
    def __init__(self,root):
        self.root=Path(root).resolve()

    def load(self):
        path=self.root/'focus'/'deployment.json'
        if not path.is_file() or path.stat().st_size>32768:
            raise ValueError('Focus runtime is missing. Repair the Spatial PC installation.')
        def unique(pairs):
            result={}
            for k,v in pairs:
                if k in result:raise ValueError('Duplicate deployment key')
                result[k]=v
            return result
        data=json.loads(path.read_text(encoding='utf-8'),object_pairs_hook=unique)
        expected={'version','runtimeVersion','managerVersion','reviewed','mediaSecurity',
                  'manager','clientLibrary','manifest','scene','runtimeConfig','files'}
        if not isinstance(data,dict) or set(data)!=expected or type(data['version']) is not int or data['version']!=1:
            raise ValueError('Invalid Focus deployment')
        if (data['runtimeVersion']!='6.2.3' or data['managerVersion']!='6.1.0' or
            data['reviewed'] is not True or data['mediaSecurity']!='development-only-unencrypted'):
            raise ValueError('Focus dependency/security review is incomplete')
        files=data['files']
        if not isinstance(files,dict) or not 4<=len(files)<=256:raise ValueError('Invalid Focus inventory')
        resolved={}
        for name,digest in files.items():
            if (not isinstance(name,str) or not name or '\\' in name or ':' in name or
                Path(name).is_absolute() or '..' in Path(name).parts or
                not isinstance(digest,str) or not re.fullmatch('[0-9a-f]{64}',digest)):
                raise ValueError('Invalid Focus inventory path/hash')
            target=(self.root/'focus'/name).resolve()
            if not target.is_relative_to(self.root/'focus') or not target.is_file():
                raise ValueError('Missing Focus dependency')
            if target.stat().st_size>512*1024*1024:raise ValueError('Focus dependency exceeds bound')
            with target.open('rb') as stream:actual=hashlib.file_digest(stream,'sha256').hexdigest()
            if actual!=digest:raise ValueError('Focus dependency hash mismatch')
            resolved[name]=target
        result={}
        for field in ('manager','clientLibrary','manifest','scene','runtimeConfig'):
            if not isinstance(data[field],str) or data[field] not in resolved:raise ValueError('Missing selected Focus file')
            result[field]=str(resolved[data[field]])
        if (Path(result['manager']).name!='NvStreamManager.exe' or
            Path(result['clientLibrary']).name!='NvStreamManagerClient.dll' or
            Path(result['manifest']).name!='openxr_cloudxr.json'):
            raise ValueError('Unexpected Focus component')
        expected_manifest=Path(result['manager']).parent/'releases'/'6.2.3'/'openxr_cloudxr.json'
        if Path(result['manifest'])!=expected_manifest:raise ValueError('Runtime version layout mismatch')
        manifest=json.loads(Path(result['manifest']).read_text(encoding='utf-8'),object_pairs_hook=unique)
        library=manifest.get('runtime',{}).get('library_path')
        if not isinstance(library,str):raise ValueError('Invalid runtime manifest')
        runtime=(Path(result['manifest']).parent/library.replace('\\','/')).resolve()
        if runtime not in resolved.values():raise ValueError('Unreviewed runtime library')
        # Every file in the deployment is inventoried; no hidden DLL/config sibling.
        actual_files={p.resolve() for p in (self.root/'focus').rglob('*') if p.is_file() and p!=path}
        if actual_files!=set(resolved.values()):raise ValueError('Unexpected Focus deployment file')
        bridge=self.root/'native'/'focus_bridge.exe'
        if not bridge.is_file():raise ValueError('Focus bridge missing')
        result['bridge']=str(bridge)
        return result


class NativeFocus:
    def __init__(self,config,session_id):
        self.config=config;self.session_id=session_id;self.process=None;self.owner=None
        self.credentials=None;self.drain=None;self.cleanup_failed=False

    async def start(self,device_id):
        self.owner=CaptureOwner()
        try:
            self.process=await asyncio.create_subprocess_exec(self.config['bridge'],
                stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.DEVNULL,
                limit=8192,creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0)
            self.owner.assign(self.process.pid)
            # Helper blocks before loading vendor code until this message arrives.
            payload={k:self.config[k] for k in ('manager','clientLibrary','manifest','scene','runtimeConfig')}
            payload.update(command='prepare',sessionId=self.session_id,clientId=device_id)
            self.process.stdin.write(json.dumps(payload,separators=(',',':')).encode()+b'\n')
            await asyncio.wait_for(self.process.stdin.drain(),1)
            line=await asyncio.wait_for(self.process.stdout.readline(),15)
            if len(line)>8192:raise ValueError('Focus response exceeds bound')
            result=json.loads(line)
            if (not isinstance(result,dict) or set(result)!={'event','sessionId','fingerprint','token'} or
                result['event']!='prepared' or result['sessionId']!=self.session_id or
                not isinstance(result['fingerprint'],str) or not re.fullmatch('[0-9a-f]{64}',result['fingerprint']) or
                not isinstance(result['token'],str) or not 1<=len(result['token'])<=4096 or
                any(ord(c)<33 or ord(c)>126 for c in result['token'])):
                raise ValueError('Focus trust response invalid')
            self.credentials=(result['fingerprint'],result['token'])
        except BaseException:
            await self.stop();raise

    async def start_media(self):
        if not self.alive() or self.credentials is None:raise ValueError('Focus is not prepared')
        self.process.stdin.write(b'{"command":"startMedia"}\n')
        await asyncio.wait_for(self.process.stdin.drain(),1)
        line=await asyncio.wait_for(self.process.stdout.readline(),15)
        if len(line)>8192:raise ValueError('Focus response exceeds bound')
        if json.loads(line)!={'event':'ready','sessionId':self.session_id}:raise ValueError('Focus readiness invalid')
        self.credentials=None
        self.drain=asyncio.create_task(self._discard())

    async def _discard(self):
        while await self.process.stdout.read(4096):pass

    def alive(self):return self.process is not None and self.process.returncode is None

    async def stop(self):
        if self.cleanup_failed:raise RuntimeError('Focus cleanup remains uncertain')
        self.credentials=None
        process=self.process
        try:
            if self.drain:
                self.drain.cancel();await asyncio.gather(self.drain,return_exceptions=True);self.drain=None
            if process:
                await close_child(process,graceful=True)
                if process.returncode!=0:raise RuntimeError('Focus helper did not confirm orderly shutdown')
        except BaseException:
            self.cleanup_failed=True;raise
        finally:
            if self.owner:self.owner.close();self.owner=None
            if self.drain:
                self.drain.cancel();await asyncio.gather(self.drain,return_exceptions=True);self.drain=None
            # Close unread pipes even when the helper failed before readiness.
            if process and process._transport:process._transport.close()
            self.process=None


class FocusController:
    def __init__(self,media,deployment,notify,factory=NativeFocus):
        self.media=media;self.deployment=deployment;self.notify=notify;self.factory=factory
        self.state='idle';self.adapter=None;self.token=None;self.session_id=None;self.device_id=None
        self._configured=None;self.starting_task=None;self.generation=0

    def capability(self):
        if self._configured is None:
            try:self.deployment.load();self._configured=True
            except (OSError,ValueError,KeyError,TypeError):self._configured=False
        return dict(compiled=True,hardwareValidated=False,runtimeConfigured=self._configured,
                    configured=self._configured,state=self.state,
                    available=self._configured and self.media.mode=='idle' and not self.media.failed,
                    mediaSecurity='development-only-unencrypted',remoteControl=False,
                    pairing='apple-system-qr-separate-from-spp2')

    async def start(self,device_id,prepare,context=None):
        config=self.deployment.load() # Fail before changing normal desktop availability.
        if context:config.update(context)
        token=self.media.claim('focus',device_id)
        self.generation+=1;generation=self.generation;self.starting_task=asyncio.current_task()
        self.token=token;self.device_id=device_id;self.session_id=secrets.token_hex(16);self.state='starting'
        self.notify()
        try:
            await asyncio.wait_for(prepare(),5)
            if self.generation!=generation:raise asyncio.CancelledError()
            self.adapter=self.factory(config,self.session_id)
            await asyncio.wait_for(self.adapter.start(device_id),16)
            if self.generation!=generation:raise asyncio.CancelledError()
            self.state='ready';self.notify()
        except BaseException:
            await self.stop();raise
        finally:self.starting_task=None

    async def stop(self):
        self.generation+=1
        starting=self.starting_task
        if starting is not None and starting is not asyncio.current_task():
            starting.cancel()
            await asyncio.gather(starting,return_exceptions=True)
            if self.media.failed:raise RuntimeError('Focus startup cleanup failed')
            return
        if self.token is None:return
        self.state='stopping';self.notify();clean=False
        try:
            if self.adapter:await asyncio.wait_for(self.adapter.stop(),11)
            clean=True
        finally:
            self.adapter=None;self.device_id=None;self.session_id=None
            self.media.release(self.token,clean);self.token=None
            self.state='idle' if clean else 'failed';self.notify()

    async def health(self):
        if self.state=='ready' and (self.adapter is None or not self.adapter.alive()):
            await self.stop();raise OSError('Focus process exited')
