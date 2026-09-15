"""Owned, single-use C PAKE handle. No Python group arithmetic or network I/O."""
import ctypes
from functools import lru_cache
from pathlib import Path

BYTE = ctypes.c_ubyte
PTR = ctypes.POINTER(BYTE)


def library_path():
    # Package layout is app/host/product. Source checkout is windows/host/product.
    root = Path(__file__).resolve().parents[2]
    if root.name == 'windows':
        return root.parent / '.local' / 'spatial_pake.dll'
    return root / 'native' / 'spatial_pake.dll'


@lru_cache(maxsize=1)
def library():
    # Absolute path, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | SYSTEM32. No PATH lookup.
    dll = ctypes.CDLL(str(library_path()), winmode=0x100 | 0x800)
    dll.spatial_pake_create.argtypes = [ctypes.c_int, PTR, ctypes.c_size_t,
        PTR, ctypes.c_size_t, PTR, ctypes.c_size_t, PTR, ctypes.c_size_t]
    dll.spatial_pake_create.restype = ctypes.c_void_p
    dll.spatial_pake_finish.argtypes = [ctypes.c_void_p, PTR, ctypes.c_size_t, PTR, ctypes.c_size_t]
    dll.spatial_pake_finish.restype = ctypes.c_int
    dll.spatial_pake_destroy.argtypes = [ctypes.c_void_p]
    dll.spatial_pake_destroy.restype = None
    dll.spatial_pake_cleanse.argtypes = [PTR, ctypes.c_size_t]
    dll.spatial_pake_cleanse.restype = None
    return dll


def buffer(value):
    return (BYTE * len(value)).from_buffer_copy(value)


class Pake:
    def __init__(self, role, pin, local_name, peer_name):
        self.handle = None
        self.dll = library()
        secret = buffer(pin)
        message = (BYTE * 32)()
        try:
            self.handle = self.dll.spatial_pake_create(role, secret, len(pin),
                buffer(local_name), len(local_name), buffer(peer_name), len(peer_name), message, 32)
            if not self.handle:
                raise ValueError('PAKE initialization failed')
            self.message = bytes(message)
        finally:
            self.dll.spatial_pake_cleanse(secret, len(secret))

    def finish(self, peer_message):
        key = (BYTE * 64)()
        try:
            if not self.handle or not self.dll.spatial_pake_finish(
                    self.handle, buffer(peer_message), len(peer_message), key, 64):
                raise ValueError('PAKE exchange rejected')
            return bytearray(key)
        finally:
            self.dll.spatial_pake_cleanse(key, 64)
            self.close()

    def close(self):
        if self.handle:
            self.dll.spatial_pake_destroy(self.handle)
            self.handle = None

    def __del__(self):
        self.close()
