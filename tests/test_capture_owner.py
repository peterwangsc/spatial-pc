"""Owner pipe checks never authorize real desktop capture."""
import asyncio
import os
from pathlib import Path
import subprocess
import unittest

ROOT=Path(__file__).resolve().parents[1]
CAPTURE=ROOT/'.local'/'capture_probe.exe'
FIXTURE=Path(os.environ.get('SPATIAL_PC_INPUT_FIXTURE',ROOT/'.local'/'input_fixture.exe'))


@unittest.skipUnless(os.name=='nt' and CAPTURE.is_file() and FIXTURE.is_file(),'Build native host and fixtures first')
class CaptureOwnerTests(unittest.IsolatedAsyncioTestCase):
    async def test_real_capture_refuses_eof_before_owner_assignment(self):
        child=await asyncio.create_subprocess_exec(str(CAPTURE),'--stream','--until-owner-exits',
            stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE,
            creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            child.stdin.close() # Never sends the byte that authorizes DXGI initialization.
            output,error=await asyncio.wait_for(child.communicate(),3)
            self.assertEqual(child.returncode,1);self.assertEqual(output,b'')
            self.assertIn(b'Capture owner ended',error);self.assertNotIn(b'capture_adapter=',error)
        finally:
            if child.returncode is None:child.kill();await child.wait()

    async def test_idle_fixture_waits_for_assignment_and_exits_on_owner_eof(self):
        environment=dict(os.environ,SPATIAL_INPUT_FIXTURE_IDLE='1')
        child=await asyncio.create_subprocess_exec(str(FIXTURE),'--stream','--until-owner-exits',
            stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE,
            env=environment,creationflags=subprocess.CREATE_NO_WINDOW)
        pending=asyncio.create_task(child.stdout.readexactly(8))
        try:
            await asyncio.sleep(.1);self.assertFalse(pending.done())
            child.stdin.write(b'C');await child.stdin.drain()
            header=await asyncio.wait_for(pending,2);self.assertEqual(header[:4],b'SPC1')
            await child.stdout.readexactly(int.from_bytes(header[4:],'big'))
            child.stdin.close()
            self.assertEqual(await asyncio.wait_for(child.wait(),2),0)
            self.assertEqual(await child.stdout.read(),b'')
        finally:
            pending.cancel();await asyncio.gather(pending,return_exceptions=True)
            if child.returncode is None:child.kill();await child.wait()
            await child.stderr.read()
