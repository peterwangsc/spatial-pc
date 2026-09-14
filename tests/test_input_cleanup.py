"""Reproduce paused stdout cleanup with disposable non-capture child processes."""
import asyncio
import io
import os
from pathlib import Path
import subprocess
import sys
import time
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'windows'/'host'))
from input_server import close_child,bounded_metadata


class InputCleanupTests(unittest.IsolatedAsyncioTestCase):
    async def flood(self, graceful):
        tail = 'sys.stdin.buffer.read()' if graceful else 'time.sleep(60)'
        child = await asyncio.create_subprocess_exec(sys.executable,'-c',
            'import sys,time;sys.stdout.buffer.write(b"x"*1048576);sys.stdout.flush();'+tail,
            stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.DEVNULL,
            limit=4096,creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0)
        try:
            await asyncio.sleep(.2)  # Fill stdout beyond its pause threshold.
            began=time.monotonic()
            await asyncio.wait_for(close_child(child,graceful=graceful),4.5)
            self.assertIsNotNone(child.returncode)
            self.assertLess(time.monotonic()-began,4.5)
            self.assertTrue(child.stdout.at_eof())
            if graceful:self.assertEqual(child.returncode,0)
        finally:
            if child.returncode is None:child.kill()
            child.stdin.close()

    async def test_terminated_full_stdout_drains_and_exits(self):
        await self.flood(False)

    async def test_graceful_full_stdout_drains_after_stdin_close(self):
        await self.flood(True)

    async def test_full_stdout_and_bounded_stderr_finish_together(self):
        child=await asyncio.create_subprocess_exec(sys.executable,'-c',
            'import sys;sys.stdout.buffer.write(b"x"*1048576);sys.stdout.flush();'
            'sys.stderr.buffer.write(b"m"*1048576);sys.stderr.flush();sys.stdin.buffer.read();'
            'sys.stderr.buffer.write(b"released\\n");sys.stderr.flush()',
            stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE,
            limit=4096,creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0)
        log=io.BytesIO();metadata=asyncio.create_task(bounded_metadata(child.stderr,log))
        try:
            await asyncio.sleep(.2)
            await asyncio.wait_for(close_child(child,graceful=True,drain_stderr=False),4.5)
            await asyncio.wait_for(metadata,1)
            self.assertEqual(child.returncode,0);self.assertLessEqual(len(log.getvalue()),256*1024)
            self.assertTrue(log.getvalue().endswith(b'released\n'))
        finally:
            if child.returncode is None:child.kill();await child.wait()
            child.stdin.close();metadata.cancel();await asyncio.gather(metadata,return_exceptions=True)


if __name__=='__main__':
    unittest.main()
