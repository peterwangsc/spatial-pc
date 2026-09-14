"""Kill only native capture if its owning backend disappears. Input gets EOF."""
import ctypes
from ctypes import wintypes
import os


class BasicLimits(ctypes.Structure):
    _fields_=[('process_time',ctypes.c_int64),('job_time',ctypes.c_int64),('flags',wintypes.DWORD),
              ('minimum_working_set',ctypes.c_size_t),('maximum_working_set',ctypes.c_size_t),
              ('active_processes',wintypes.DWORD),('affinity',ctypes.c_size_t),('priority',wintypes.DWORD),('scheduling',wintypes.DWORD)]


class ExtendedLimits(ctypes.Structure):
    _fields_=[('basic',BasicLimits),('io',ctypes.c_uint64*6),('process_memory',ctypes.c_size_t),
              ('job_memory',ctypes.c_size_t),('peak_process_memory',ctypes.c_size_t),('peak_job_memory',ctypes.c_size_t)]


class CaptureOwner:
    def __init__(self):
        self.handle=None
        if os.name!='nt':return
        self.kernel=ctypes.WinDLL('kernel32',use_last_error=True)
        self.kernel.CreateJobObjectW.argtypes=[ctypes.c_void_p,wintypes.LPCWSTR]
        self.kernel.CreateJobObjectW.restype=wintypes.HANDLE
        self.kernel.CloseHandle.argtypes=[wintypes.HANDLE]
        self.kernel.SetInformationJobObject.argtypes=[wintypes.HANDLE,ctypes.c_int,ctypes.c_void_p,wintypes.DWORD]
        self.kernel.AssignProcessToJobObject.argtypes=[wintypes.HANDLE,wintypes.HANDLE]
        self.kernel.OpenProcess.argtypes=[wintypes.DWORD,wintypes.BOOL,wintypes.DWORD]
        self.kernel.OpenProcess.restype=wintypes.HANDLE
        self.handle=self.kernel.CreateJobObjectW(None,None)
        limits=ExtendedLimits();limits.basic.flags=0x2000
        if not self.handle or not self.kernel.SetInformationJobObject(self.handle,9,ctypes.byref(limits),ctypes.sizeof(limits)):
            self.close();raise OSError('Capture ownership unavailable')

    def assign(self,pid):
        if not self.handle:return
        process=self.kernel.OpenProcess(0x100|0x1,False,pid)
        try:
            if not process or not self.kernel.AssignProcessToJobObject(self.handle,process):
                raise OSError('Capture ownership unavailable')
        finally:
            if process:self.kernel.CloseHandle(process)

    def close(self):
        if self.handle:self.kernel.CloseHandle(self.handle);self.handle=None
