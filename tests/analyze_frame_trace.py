"""Analyze opt-in native timing metadata; no desktop pixels or network access."""
import argparse
import bisect
import json
from pathlib import Path


def distribution(values):
    ordered = sorted(values)
    if not ordered:
        return {'n': 0}
    return dict(n=len(ordered), p50=ordered[int(.50*(len(ordered)-1))],
                p95=ordered[int(.95*(len(ordered)-1))],
                p99=ordered[int(.99*(len(ordered)-1))], max=ordered[-1])


def analyze(trace):
    frequency = trace['qpc_frequency']
    events = trace['events']
    if type(frequency) is not int or frequency <= 0 or len(events) > 8192:
        raise ValueError('Invalid trace frequency or event count')
    samples, waits, returns = {}, [], []
    waiting = None
    previous_tick = -1
    for event in events:
        tick, pts, kind = event['ticks'], event['pts_100ns'], event['event']
        if type(tick) is not int or tick < previous_tick or type(pts) is not int:
            raise ValueError('Invalid event time or order')
        previous_tick = tick
        if kind == 'acquire_begin':
            if waiting is not None:
                raise ValueError('Overlapping capture waits')
            waiting = tick
        elif kind in ('acquire_return', 'acquire_timeout'):
            if waiting is not None:
                waits.append((waiting, tick))
            waiting = None
            returns.append(tick)
        if pts >= 0:
            frame = samples.setdefault(pts, {})
            if kind in frame:
                raise ValueError('Duplicate frame event')
            frame[kind] = tick
    frames = sorted((pts, frame) for pts, frame in samples.items() if 'write_enter' in frame)
    ages, submission_ages, next_gaps, next_offsets, return_offsets = [], [], [], [], []
    before_next = after_next = during_wait = encoded = 0
    wait_starts = [start for start, _ in waits]
    for index, (_, frame) in enumerate(frames):
        if 'encoded' not in frame:
            continue
        output = frame['encoded']
        encoded += 1
        scale = 1000/frequency
        submission_ages.append((output-frame['write_enter'])*scale)
        if 'acquired' in frame:
            ages.append((output-frame['acquired'])*scale)
        wait_index = bisect.bisect_right(wait_starts, output)-1
        if wait_index >= 0 and output < waits[wait_index][1]:
            during_wait += 1
        return_index = bisect.bisect_right(returns, output)-1
        if return_index >= 0:
            return_offsets.append((output-returns[return_index])*scale)
        if index+1 < len(frames):
            next_write = frames[index+1][1]['write_enter']
            next_gaps.append((next_write-frame['write_enter'])*scale)
            next_offsets.append((output-next_write)*scale)
            if output < next_write:
                before_next += 1
            else:
                after_next += 1
    return dict(boundary='Observed event ordering only; correlations do not prove encoder or driver causality',
                trace_omitted=trace.get('omitted', 0), submitted_frames=len(frames), encoded_frames=encoded,
                outputs_during_capture_wait=during_wait,
                outputs_before_next_write=before_next, outputs_at_or_after_next_write=after_next,
                acquire_to_encoded_ms=distribution(ages), write_enter_to_encoded_ms=distribution(submission_ages),
                next_write_gap_ms=distribution(next_gaps),
                output_minus_next_write_ms=distribution(next_offsets),
                output_after_latest_capture_return_ms=distribution(return_offsets))


def read_trace(path):
    if path.stat().st_size > 16*1024*1024:
        raise ValueError('Trace log exceeds 16 MiB input bound')
    records = [line.removeprefix('frame_trace=') for line in path.read_text().splitlines()
               if line.startswith('frame_trace=')]
    if len(records) != 1:
        raise ValueError('Expected one finalized frame trace')
    return json.loads(records[0])


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('log', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    report = json.dumps(analyze(read_trace(args.log)), indent=2)+'\n'
    if args.output:
        args.output.write_text(report)
    else:
        print(report, end='')
