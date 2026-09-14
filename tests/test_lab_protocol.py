import importlib.util
import io
import json
import struct
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('lab_server',Path(__file__).resolve().parents[1]/'windows/host/lab_server.py')
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

class LabProtocolTests(unittest.TestCase):
    def message(self, value):
        data = json.dumps(value).encode()
        return io.BytesIO(b'SPC1'+struct.pack('!I',len(data))+data)

    def test_current_version(self):
        _, value = server.read_hello(self.message(dict(version=1,codecs=['h264-annexb'])))
        self.assertEqual(value['codecs'],['h264-annexb'])

    def test_rejects_versions_and_non_objects(self):
        for value in [dict(version=2), dict(version=True), dict(version='1'), [], None]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                server.read_hello(self.message(value))

    def test_rejects_oversize_and_empty_before_reading_body(self):
        for count in [0,4097,0xffffffff]:
            with self.subTest(count=count), self.assertRaises(ValueError):
                server.read_hello(io.BytesIO(b'SPC1'+struct.pack('!I',count)))

    def test_rejects_truncated_and_wrong_magic(self):
        with self.assertRaises(EOFError): server.read_hello(io.BytesIO(b'SPC1'))
        with self.assertRaises(ValueError): server.read_hello(io.BytesIO(b'NOPE\x00\x00\x00\x01'))
        with self.assertRaises(EOFError): server.read_hello(io.BytesIO(b'SPC1\x00\x00\x00\x02{'))

if __name__ == '__main__': unittest.main()
