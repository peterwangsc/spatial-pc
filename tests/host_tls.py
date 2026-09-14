"""Loopback-only real native capture/TLS smoke test. Requires cryptography.

Uses a fresh private test pair and port; never reads the live lab credentials.
Only frame sizes, counts and timings are saved, not desktop content.
"""
import argparse
import hashlib
import json
import os
import socket
import ssl
import struct
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'scripts'))
from create_lab_pair import create_pair


def exact(peer, size):
    data = bytearray()
    while len(data) < size:
        part = peer.recv(size-len(data))
        if not part:
            raise EOFError()
        data.extend(part)
    return bytes(data)


def run(directory, capture, port):
    directory.mkdir(parents=True, exist_ok=False)
    pair_dir = directory/'pair'
    create_pair(pair_dir, '127.0.0.1', port)
    pair = json.loads((pair_dir/'lab-pair.json').read_text())
    log_path = directory/'server.log'
    with log_path.open('w') as log:
        host = subprocess.Popen([sys.executable, str(ROOT/'windows/host/lab_server.py'),
            '--credentials', str(pair_dir), '--capture', str(capture), '--bind', '127.0.0.1', '--lifetime', '20'],
            stdout=log, stderr=log, creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
        try:
            deadline = time.perf_counter()+10
            while 'Lab host listening' not in log_path.read_text():
                if host.poll() is not None or time.perf_counter() >= deadline:
                    raise RuntimeError('Loopback test host did not start')
                time.sleep(.1)

            def context(client=True, trusted=True):
                value = ssl.create_default_context(cafile=str(pair_dir/'root.pem') if trusted else None)
                value.minimum_version = ssl.TLSVersion.TLSv1_3
                value.set_alpn_protocols(['spatialpc/1'])
                if client:
                    value.load_cert_chain(str(pair_dir/'client.pem'), str(pair_dir/'client-key.pem'))
                return value

            def connect(value):
                return value.wrap_socket(socket.create_connection(('127.0.0.1', port), timeout=5), server_hostname=pair['serverName'])

            for value in (context(client=False), context(trusted=False)):
                try:
                    with connect(value) as peer:
                        peer.sendall(b'SPC1'+struct.pack('!I', 2)+b'{}')
                        received = peer.recv(1)
                        assert not received, 'Unauthenticated peer received stream data'
                except ssl.SSLError:
                    pass
                else:
                    assert not received
            assert not (directory/'encoder.log').exists(), 'Capture began before authentication'

            frames = total = 0
            with connect(context()) as peer:
                assert peer.version() == 'TLSv1.3' and peer.selected_alpn_protocol() == 'spatialpc/1'
                assert hashlib.sha256(peer.getpeercert(binary_form=True)).hexdigest() == pair['serverSHA256']
                hello = json.dumps(dict(version=1, codecs=['h264-annexb'], maxWidth=8192, maxHeight=8192)).encode()
                peer.sendall(b'SPC1'+struct.pack('!I', len(hello))+hello)
                header = exact(peer, 8)
                assert header[:4] == b'SPC1'
                size = struct.unpack('!I', header[4:])[0]
                assert 0 < size <= 4096
                capabilities = json.loads(exact(peer, size))
                assert capabilities['hardwareEncoder'] is True
                end = time.perf_counter()+8
                previous = -1
                while time.perf_counter() < end:
                    header = exact(peer, 16)
                    size, pts, _ = struct.unpack('!IQI', header)
                    assert 0 < size <= 16*1024*1024 and pts > previous
                    previous = pts
                    exact(peer, size)
                    frames += 1
                    total += size
            assert frames > 0
            host.wait(timeout=25)  # Its independent deadline also bounds an idle pipe.
            assert host.returncode == 0
            assert 'transport_summary=' in log_path.read_text()
            result = dict(tls='TLSv1.3', loopback=True, authenticated_native_frames=frames, encoded_bytes=total,
                          missing_client_rejected=True, untrusted_host_rejected=True, capture_only_after_auth=True)
            (directory/'result.json').write_text(json.dumps(result, indent=2))
            print(json.dumps(result))
        finally:
            if host.poll() is None:
                host.terminate()
                host.wait(timeout=5)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--capture', type=Path, required=True)
    parser.add_argument('--port', type=int, default=47992)
    args = parser.parse_args()
    run(args.directory.resolve(), args.capture.resolve(), args.port)
