import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch
from host_perf import slice_types

spec = importlib.util.spec_from_file_location('lab_server', Path(__file__).resolve().parents[1]/'windows/host/lab_server.py')
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


class HostMetricsTests(unittest.TestCase):
    def test_recognizes_i_p_and_b_slice_headers_without_retaining_video(self):
        # first_mb=0, slice_type I=2, P=0, B=1; includes both Annex B prefix lengths.
        self.assertEqual(slice_types(b'\x00\x00\x00\x01\x65\xb0'), [2])
        self.assertEqual(slice_types(b'\x00\x00\x01\x41\xc0'), [0])
        self.assertEqual(slice_types(b'\x00\x00\x01\x41\xa0'), [1])
        self.assertEqual(slice_types(b'\x00\x00\x01\x67\xb0'), [])

    def test_transport_drift_uses_relative_pts_not_absolute_clock(self):
        with patch.object(server.time, 'perf_counter', side_effect=[100, 101, 101.15, 102]):
            stats = server.TransportStats()
            stats.frame(9_000_000_000, 10, 3, 2)
            stats.frame(9_001_000_000, 20, 4, 5)
            result = stats.report()
        self.assertEqual(result['frames'], 2)
        self.assertEqual(result['encodedBytes'], 30)
        self.assertAlmostEqual(result['metrics']['send_timeline_drift_ms']['max'], 50)

    def test_metadata_storage_remains_bounded(self):
        stats = server.TransportStats()
        for n in range(40000):
            stats.add('tls_send_ms', n)
        self.assertEqual(len(stats.series['tls_send_ms']), 36000)


if __name__ == '__main__':
    unittest.main()
