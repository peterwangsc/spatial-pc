"""Metadata-only native pipe stall test; no visible workload or retained frames."""
import argparse
import json
import os
import struct
import subprocess
import threading
import time
from pathlib import Path
from host_perf import exact


def run(executable, directory, stall):
    path = directory / f'backpressure-{stall}.log'
    with path.open('w') as log:
        child = subprocess.Popen([str(executable), '--stream', '--seconds', '8'], stdout=subprocess.PIPE,
                                 stderr=log, creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
        watchdog = threading.Timer(15, child.kill)
        watchdog.start()
        frames = 0
        previous = -1
        try:
            header = exact(child.stdout, 8)
            assert header[:4] == b'SPC1'
            size = struct.unpack('!I', header[4:])[0]
            assert 0 < size <= 4096
            exact(child.stdout, size)
            time.sleep(stall)
            while True:
                size, pts, _ = struct.unpack('!IQI', exact(child.stdout, 16))
                assert 0 < size <= 16*1024*1024
                assert pts > previous, 'Reordered or duplicate sample timestamp'
                previous = pts
                exact(child.stdout, size)
                frames += 1
        except EOFError:
            pass
        finally:
            child.wait(timeout=5)
            watchdog.cancel()
    reports = [json.loads(line.split('=', 1)[1]) for line in path.read_text().splitlines() if line.startswith('perf_summary=')]
    peak = max((r['peak_pending'] for r in reports), default=None)
    assert peak is None or peak <= 4
    # Sink-writer throttling may block WriteSample before the explicit capacity
    # guard runs. The transport owner enforces socket/session deadlines. Here we
    # assert bounded retention and complete ordered recovery, not a native timeout.
    assert child.returncode == 0 and frames > 0 and reports
    assert reports[-1]['inputs'] == reports[-1]['outputs'] == frames
    assert reports[-1]['pending'] == 0
    result = {'stall_s': stall, 'frames': frames, 'exit': child.returncode, 'peak_pending': peak}
    print(json.dumps(result))
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--capture', type=Path, required=True)
    parser.add_argument('--directory', type=Path, required=True)
    args = parser.parse_args()
    results = [run(args.capture.resolve(), args.directory, stall) for stall in (.5, 6.5)]
    (args.directory/'backpressure.json').write_text(json.dumps(results, indent=2))
