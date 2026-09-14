"""Real Windows process ownership without capturing pixels or injecting input."""
import ctypes
from ctypes import wintypes
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

HOST=Path(__file__).resolve().parents[1]/'windows'/'host'
FIXTURE=Path(os.environ.get('SPATIAL_PC_INPUT_FIXTURE',HOST.parents[1]/'.local'/'input_fixture.exe'))


@unittest.skipUnless(os.name=='nt' and FIXTURE.is_file(),'Windows native fixture required')
class CrashTests(unittest.TestCase):
    def test_killed_backend_kills_owned_capture_and_input_releases_on_eof(self):
        with tempfile.TemporaryDirectory() as root:
            script=Path(root)/'owner.py';log=Path(root)/'input.log'
            script.write_text('''import subprocess,sys,time
sys.path.insert(0,sys.argv[1])
from product.process_guard import CaptureOwner
from input_protocol import Event
owner=CaptureOwner()
capture=subprocess.Popen([sys.executable,'-I','-c','import time;time.sleep(30)'],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
owner.assign(capture.pid)
with open(sys.argv[3],'wb',buffering=0) as log:
    bridge=subprocess.Popen([sys.argv[2]],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log)
    bridge.stdout.readline()
    bridge.stdin.write(Event(5,0,1,0,0,0).wire()+Event(4,1,2,4,0,0).wire());bridge.stdin.flush()
    print(capture.pid,bridge.pid,flush=True)
    time.sleep(30)
''')
            parent=subprocess.Popen([sys.executable,'-I','-B',str(script),str(HOST),str(FIXTURE),str(log)],stdout=subprocess.PIPE,text=True)
            handles=[]
            kernel=ctypes.WinDLL('kernel32',use_last_error=True)
            kernel.OpenProcess.argtypes=[wintypes.DWORD,wintypes.BOOL,wintypes.DWORD];kernel.OpenProcess.restype=wintypes.HANDLE
            kernel.WaitForSingleObject.argtypes=[wintypes.HANDLE,wintypes.DWORD]
            kernel.CloseHandle.argtypes=[wintypes.HANDLE]
            try:
                pids=[int(p) for p in parent.stdout.readline().split()];self.assertEqual(len(pids),2)
                handles=[kernel.OpenProcess(0x100000,False,pid) for pid in pids];self.assertTrue(all(handles))
                deadline=time.monotonic()+1
                while 'fixture_control_active' not in log.read_text() and time.monotonic()<deadline:time.sleep(.01)
                self.assertIn('fixture_control_active',log.read_text())
                parent.kill();parent.wait(timeout=3)
                for handle in handles:self.assertEqual(kernel.WaitForSingleObject(handle,3000),0)
                self.assertIn('"downs":1,"ups":1',log.read_text())
            finally:
                if parent.poll() is None:parent.kill();parent.wait(timeout=3)
                parent.stdout.close()
                for handle in handles:
                    if handle:kernel.CloseHandle(handle)
