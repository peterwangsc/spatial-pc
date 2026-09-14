import unittest
from analyze_frame_trace import analyze


def fixture(outputs):
    events = []
    for index, output in enumerate(outputs):
        pts = index*400000
        for kind, tick in [('acquired', 1+index*40), ('write_enter', 2+index*40), ('encoded', output)]:
            events.append(dict(event=kind, ticks=tick, pts_100ns=pts))
    for kind, tick in [('acquire_begin', 10), ('acquire_return', 40)]:
        events.append(dict(event=kind, ticks=tick, pts_100ns=-1))
    return dict(qpc_frequency=1000, omitted=0, events=sorted(events, key=lambda event:event['ticks']))


class TraceAnalysisTests(unittest.TestCase):
    def test_output_independent_of_next_input(self):
        result = analyze(fixture([15, 45, 85]))
        self.assertEqual(result['outputs_before_next_write'], 2)
        self.assertEqual(result['outputs_at_or_after_next_write'], 0)
        self.assertEqual(result['outputs_during_capture_wait'], 1)

    def test_next_input_aligned_output(self):
        result = analyze(fixture([43, 83, 85]))
        self.assertEqual(result['outputs_before_next_write'], 0)
        self.assertEqual(result['outputs_at_or_after_next_write'], 2)
        self.assertEqual(result['outputs_during_capture_wait'], 0)
        self.assertEqual(result['output_minus_next_write_ms']['p95'], 1)

    def test_reject_nonmonotonic_trace(self):
        trace = fixture([15, 45, 85])
        trace['events'].reverse()
        with self.assertRaises(ValueError):
            analyze(trace)

    def test_partial_final_frame_is_not_a_decoded_sample(self):
        trace = fixture([15, 45, 85])
        trace['events'] = [event for event in trace['events'] if event['ticks'] != 85]
        trace['omitted'] = 20
        result = analyze(trace)
        self.assertEqual(result['encoded_frames'], 2)
        self.assertEqual(result['submitted_frames'], 3)
        self.assertEqual(result['trace_omitted'], 20)


if __name__ == '__main__':
    unittest.main()
