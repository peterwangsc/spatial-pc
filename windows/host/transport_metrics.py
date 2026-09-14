"""Bounded metadata shared by consumer and lab transports."""
import time

MAX_MESSAGE = 16 * 1024 * 1024  # allocation safety bound, not a resolution tier


class TransportStats:
    """Bounded metadata samples. Socket time includes TLS and peer backpressure."""
    def __init__(self):
        self.began = time.perf_counter()
        self.cpu_began = time.process_time()
        self.frames = self.bytes = 0
        self.series = {}
        self.first_pts = self.first_arrival = None

    def add(self, name, value):
        samples = self.series.setdefault(name, [])
        if len(samples) < 36000:
            samples.append(value)

    def frame(self, timestamp, size, read_ms, send_ms):
        now = time.perf_counter()
        self.frames += 1
        self.bytes += size
        self.add('pipe_read_wait_ms', read_ms)
        self.add('tls_send_ms', send_ms)
        if self.first_pts is None:
            self.first_pts, self.first_arrival = timestamp, now
        # Relative drift only; clocks are not synchronized across processes/devices.
        self.add('send_timeline_drift_ms', (now-self.first_arrival)*1000-(timestamp-self.first_pts)/10000)

    def report(self):
        metrics = {}
        for name, values in self.series.items():
            ordered = sorted(values)
            metrics[name] = {'n': len(ordered), **{key: ordered[int(q*(len(ordered)-1))]
                for key, q in (('p50', .5), ('p95', .95), ('p99', .99))}, 'max': max(ordered)}
        elapsed = time.perf_counter()-self.began
        return {'frames': self.frames, 'encodedBytes': self.bytes, 'elapsed_s': elapsed,
                'cpu_core_percent': 100*(time.process_time()-self.cpu_began)/elapsed, 'metrics': metrics}
