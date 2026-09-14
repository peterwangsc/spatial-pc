"""Reproduce paused stdout cleanup with disposable non-capture child processes."""
import asyncio
import os
from pathlib import Path
import subprocess
import sys
import time
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'windows'/'host'))
from input_server import close_child


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


if __name__=='__main__':
    unittest.main()
