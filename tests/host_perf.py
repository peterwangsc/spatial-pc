"""Metadata-only local pipe benchmark. Requires a coordinated visible workload window."""
import argparse
import json
import os
import struct
import subprocess
import threading
import time
from pathlib import Path


def exact(stream, count):
    data = bytearray()
    while len(data) < count:
        part = stream.read(count - len(data))
        if not part:
            raise EOFError()
        data.extend(part)
    return bytes(data)


def percentiles(values):
    values = sorted(values)
    if not values:
        return {}
    return {"n": len(values), **{name: values[int(q * (len(values) - 1))]
            for name, q in (("p50", .5), ("p95", .95), ("p99", .99))}}


def slice_types(data):
    """Read only slice-header types from Annex B; no video retained."""
    types = []
    for nal in data.split(b'\x00\x00\x01')[1:]:
        if not nal or nal[0] & 31 not in (1, 5):
            continue
        rbsp = nal[1:64].replace(b'\x00\x00\x03', b'\x00\x00')
        bits = ''.join(f'{byte:08b}' for byte in rbsp)
        position = 0
        def ue():
            nonlocal position
            zeros = 0
            while position < len(bits) and bits[position] == '0':
                zeros += 1
                position += 1
            if zeros > 31 or position+zeros >= len(bits):
                raise ValueError('Truncated slice header')
            value = int(bits[position:position+zeros+1], 2)-1
            position += zeros+1
            return value
        ue()  # first_mb_in_slice
        types.append(ue() % 5)
    return types


def run(executable, args, label, directory, seconds=22):
    destination = directory / label
    destination.mkdir(exist_ok=True)
    motion = subprocess.Popen([str(directory / "host_motion.exe"), str(seconds + 3)])
    time.sleep(.5)
    child = None
    frames = []
    slices = {}
    try:
        with (destination / "encoder.log").open("w") as log:
            began = time.perf_counter()
            child = subprocess.Popen([str(executable), "--stream", *args], stdout=subprocess.PIPE, stderr=log,
                                     creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
            timer = threading.Timer(seconds + 5, child.terminate)
            timer.start()
            try:
                header = exact(child.stdout, 8)
                if header[:4] != b"SPC1":
                    raise ValueError("Invalid stream header")
                size = struct.unpack("!I", header[4:])[0]
                if not 0 < size <= 4096:
                    raise ValueError("Invalid metadata size")
                capabilities = json.loads(exact(child.stdout, size))
                while time.perf_counter() - began < seconds:
                    size, pts, flags = struct.unpack("!IQI", exact(child.stdout, 16))
                    if not 0 < size <= 16 * 1024 * 1024:
                        raise ValueError("Invalid frame size")
                    data = exact(child.stdout, size)
                    for kind in slice_types(data):
                        slices[str(kind)] = slices.get(str(kind), 0)+1
                    del data  # Immediately discard image bytes.
                    frames.append((time.perf_counter() - began, pts, size))
            except EOFError:
                capabilities = locals().get("capabilities", {})
            finally:
                timer.cancel()
                if child.poll() is None:
                    child.terminate()
                child.wait(timeout=10)
    finally:
        if motion.poll() is None:
            motion.terminate()
        motion.wait(timeout=10)
    intervals = [(b[0] - a[0]) * 1000 for a, b in zip(frames, frames[1:])]
    pts_intervals = [(b[1] - a[1]) / 10000 for a, b in zip(frames, frames[1:])]
    steady = [f for f in frames if f[0] >= 4]
    result = {"label": label, "capabilities": capabilities, "frames": len(frames),
              "first_frame_s": frames[0][0] if frames else None,
              "steady_fps": (len(steady) - 1) / (steady[-1][0] - steady[0][0]) if len(steady) > 1 else 0,
              "pipe_arrival_interval_ms": percentiles(intervals), "sample_interval_ms": percentiles(pts_intervals),
              "encoded_bytes": sum(f[2] for f in frames), "last_frame_s": frames[-1][0] if frames else None}
    result['h264_slice_types'] = slices
    (destination / "result.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(result), flush=True)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--candidate", default="candidate.exe")
    parser.add_argument("--seconds", type=int, default=20)
    parser.add_argument("--prefix", default="")
    parser.add_argument("--variants", nargs='+', default=['original', 'legacy_debug', 'legacy_release', 'optimized'])
    options = parser.parse_args()
    root = options.directory.resolve()
    duration = ['--seconds', str(options.seconds)]
    runs = {
        'original': (root / 'baseline' / 'capture_probe.exe', []),
        'legacy_debug': (root / 'instrumented-debug.exe', ['--legacy', *duration]),
        'legacy_release': (root / options.candidate, ['--legacy', *duration]),
        'no_pool': (root / options.candidate, ['--no-pool', *duration]),
        'unthrottled': (root / options.candidate, ['--unthrottled', *duration]),
        'optimized': (root / options.candidate, duration),
    }
    for label in options.variants:
        executable, args = runs[label]
        run(executable, args, options.prefix+label, root, seconds=options.seconds+2)
