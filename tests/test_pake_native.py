"""Shared PAKE ownership/negative checks; no sockets, UI or stored identities.

Run with SPATIAL_PAKE_LIBRARY pointing to the locally built wrapper library.
Only fixed public fixture PINs are used. Secret results are never printed.
"""
import ctypes
import os
import unittest

LIB = ctypes.CDLL(os.environ['SPATIAL_PAKE_LIBRARY'])
BYTES = ctypes.POINTER(ctypes.c_ubyte)
LIB.spatial_pake_create.argtypes = [ctypes.c_int, BYTES, ctypes.c_size_t,
    BYTES, ctypes.c_size_t, BYTES, ctypes.c_size_t, BYTES, ctypes.c_size_t]
LIB.spatial_pake_create.restype = ctypes.c_void_p
LIB.spatial_pake_finish.argtypes = [ctypes.c_void_p, BYTES, ctypes.c_size_t, BYTES, ctypes.c_size_t]
LIB.spatial_pake_finish.restype = ctypes.c_int
LIB.spatial_pake_destroy.argtypes = [ctypes.c_void_p]
LIB.spatial_pake_cleanse.argtypes = [BYTES, ctypes.c_size_t]

def buffer(value):
    return (ctypes.c_ubyte * len(value)).from_buffer_copy(value)

class NativePAKETests(unittest.TestCase):
    def new(self, role, pin=b'0042', names=(b'client-context', b'host-context')):
        message = (ctypes.c_ubyte * 32)()
        local, peer = names if role == 0 else names[::-1]
        state = LIB.spatial_pake_create(role, buffer(pin), len(pin), buffer(local), len(local),
            buffer(peer), len(peer), message, len(message))
        if state:
            self.addCleanup(LIB.spatial_pake_destroy, state)
        return state, message

    def finish(self, state, message):
        key = (ctypes.c_ubyte * 64)()
        self.addCleanup(LIB.spatial_pake_cleanse, key, len(key))
        result = LIB.spatial_pake_finish(state, message, len(message), key, len(key))
        return result, key

    def test_matching_leading_zero_pin_and_single_use(self):
        a, am = self.new(0)
        b, bm = self.new(1)
        self.assertTrue(a and b)
        ar, ak = self.finish(a, bm)
        br, bk = self.finish(b, am)
        self.assertEqual((ar, br), (1, 1))
        self.assertEqual(bytes(ak), bytes(bk))
        self.assertEqual(self.finish(a, bm)[0], 0)

    def test_wrong_pin_does_not_agree(self):
        a, am = self.new(0)
        b, bm = self.new(1, b'0043')
        ar, ak = self.finish(a, bm)
        br, bk = self.finish(b, am)
        self.assertEqual((ar, br), (1, 1))
        self.assertNotEqual(bytes(ak), bytes(bk))

    def test_context_and_role_binding(self):
        for role, names in [(1, (b'changed-client', b'host-context')),
                            (0, (b'client-context', b'host-context'))]:
            a, am = self.new(0)
            b, bm = self.new(role, names=names)
            ar, ak = self.finish(a, bm)
            br, bk = self.finish(b, am)
            self.assertFalse(ar and br and bytes(ak) == bytes(bk))

    def test_invalid_pins_and_role(self):
        for pin in [b'', b'042', b'00042', b'00a2', b' 042', '００４２'.encode()]:
            self.assertFalse(self.new(0, pin)[0])
        self.assertFalse(self.new(2)[0])

    def test_failed_finish_consumes_attempt(self):
        a, _ = self.new(0)
        self.assertEqual(self.finish(a, buffer(b'short'))[0], 0)
        _, bm = self.new(1)
        self.assertEqual(self.finish(a, bm)[0], 0)

    def test_invalid_point_cannot_agree(self):
        a, _ = self.new(0)
        # y=2 has no valid recovered x; rejected by the upstream primitive.
        self.assertEqual(self.finish(a, buffer(b'\x02' + bytes(31)))[0], 0)

if __name__ == '__main__':
    unittest.main()
