"""M1 test harness: mutually authenticated TLS 1.3, native capture/encode child.

Run only in the interactive Windows session. Input defaults disabled; negotiated
native input requires explicit --enable-input and --input-bridge. No audio, clipboard, WAN,
installation, or automatic startup. Desktop frames stay in memory. A client must
present the provisioned certificate before capture begins. Connections have a
ten-minute limit and stall timeout; disconnect terminates the capture child.
"""
import argparse, ctypes, hashlib, json, os, socket, ssl, struct, subprocess, tempfile, threading, time
from pathlib import Path

from transport_metrics import MAX_MESSAGE, TransportStats


def read_exact(stream, size):
    result = bytearray()
    while len(result) < size:
        chunk = stream.recv(size-len(result)) if isinstance(stream, socket.socket) else stream.read(size-len(result))
        if not chunk: raise EOFError('Connection ended')
        result.extend(chunk)
    return bytes(result)

def read_hello(stream):
    header = read_exact(stream, 8)
    if header[:4] != b'SPC1': raise ValueError('Unsupported protocol')
    size = struct.unpack('!I', header[4:])[0]
    if not 0 < size <= 4096: raise ValueError('Invalid capability length')
    payload = read_exact(stream, size)
    message = json.loads(payload)
    if not isinstance(message, dict) or type(message.get('version')) is not int or message['version'] != 1:
        raise ValueError('Unsupported version')
    return header+payload, message

def protect_key(path, decrypt=False):
    # Per-user DPAPI. The private PEM only exists briefly while SSLContext loads it.
    class Blob(ctypes.Structure):
        _fields_ = [('size', ctypes.c_ulong), ('data', ctypes.POINTER(ctypes.c_ubyte))]
    data = path.read_bytes()
    backing = (ctypes.c_ubyte * len(data)).from_buffer_copy(data)
    source = Blob(len(data), backing); target = Blob()
    function = ctypes.windll.crypt32.CryptUnprotectData if decrypt else ctypes.windll.crypt32.CryptProtectData
    if not function(ctypes.byref(source), None, None, None, None, 1, ctypes.byref(target)):
        raise ctypes.WinError()
    try: return ctypes.string_at(target.data, target.size)
    finally: ctypes.windll.kernel32.LocalFree(target.data)

def context_for(directory):
    protected = directory/'server-key.dpapi'
    unprotected = directory/'server-key.pem'
    if not protected.exists():
        protected.write_bytes(protect_key(unprotected))
        unprotected.unlink()
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    context.verify_mode = ssl.CERT_REQUIRED
    context.load_verify_locations(cafile=str(directory/'root.pem'))
    context.set_alpn_protocols(['spatialpc/1'])
    key = protect_key(protected, decrypt=True)
    with tempfile.NamedTemporaryFile(dir=directory, suffix='.pem', delete=False) as file:
        temporary = Path(file.name); file.write(key)
    try: context.load_cert_chain(str(directory/'server.pem'), str(temporary))
    finally: temporary.unlink()
    return context

def serve(directory, executable, bind, lifetime):
    policy = json.loads((directory/'server-policy.json').read_text())
    context = context_for(directory)
    with socket.socket() as listener:
        listener.setsockopt(socket.SOL_SOCKET,
            socket.SO_EXCLUSIVEADDRUSE if os.name == 'nt' else socket.SO_REUSEADDR, 1)
        listener.bind((bind, policy['port'])); listener.listen(2); listener.settimeout(1)
        deadline = time.monotonic()+lifetime
        print('Lab host listening; authenticated clients only', flush=True)
        while time.monotonic() < deadline:
            try: raw, address = listener.accept()
            except socket.timeout: continue
            child = None
            stats = None
            capture_deadline = None
            try:
                raw.settimeout(5)
                with context.wrap_socket(raw, server_side=True) as peer:
                    fingerprint = hashlib.sha256(peer.getpeercert(binary_form=True)).hexdigest()
                    if fingerprint != policy['clientSHA256']: raise ValueError('Unpaired client')
                    if peer.selected_alpn_protocol() != 'spatialpc/1': raise ValueError('ALPN mismatch')
                    _, hello = read_hello(peer)
                    codecs = hello.get('codecs')
                    if not isinstance(codecs, list) or not all(isinstance(codec, str) for codec in codecs) or 'h264-annexb' not in codecs:
                        raise ValueError('No common codec')
                    print('Authenticated session; TLS='+peer.version(), flush=True)
                    with open(directory.parent/'encoder.log', 'w') as log:
                        child = subprocess.Popen([str(executable), '--stream'], stdout=subprocess.PIPE, stderr=log,
                                                 creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
                        # A blocked pipe read must not defeat the session/lab deadline.
                        capture_deadline = threading.Timer(max(0, min(600, deadline-time.monotonic())), child.terminate)
                        capture_deadline.daemon = True
                        capture_deadline.start()
                        encoded_header, capabilities = read_hello(child.stdout)
                        for key in ('width', 'height'):
                            limit = hello.get('max'+key.title())
                            if type(limit) is not int or capabilities[key] > limit: raise ValueError('Display exceeds client capability')
                        peer.sendall(encoded_header)
                        session_end = min(deadline, time.monotonic()+600)
                        stats = TransportStats()
                        next_report = time.perf_counter()+5
                        while time.monotonic() < session_end:
                            read_start = time.perf_counter()
                            header = read_exact(child.stdout, 16)
                            size, timestamp, _ = struct.unpack('!IQI', header)
                            if not 0 < size <= MAX_MESSAGE: raise ValueError('Invalid encoded frame length')
                            payload = read_exact(child.stdout, size)
                            send_start = time.perf_counter()
                            peer.sendall(header+payload)
                            sent = time.perf_counter()
                            stats.frame(timestamp, size, (send_start-read_start)*1000, (sent-send_start)*1000)
                            if sent >= next_report:
                                print('transport_summary='+json.dumps(stats.report()), flush=True)
                                next_report = sent+5
            except (OSError, ValueError, EOFError, ssl.SSLError) as error:
                print('Session ended: '+type(error).__name__, flush=True)
            finally:
                if capture_deadline:
                    capture_deadline.cancel()
                if stats:
                    print('transport_summary='+json.dumps(stats.report()), flush=True)
                raw.close()
                if child:
                    child.terminate()
                    try: child.wait(timeout=5)
                    except subprocess.TimeoutExpired: child.kill(); child.wait()

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--credentials', type=Path, required=True)
    parser.add_argument('--capture', type=Path, required=True)
    parser.add_argument('--bind', required=True)
    parser.add_argument('--lifetime', type=int, default=1800)
    parser.add_argument('--enable-input', action='store_true', help='Explicitly allow negotiated SPI1 input for the paired client')
    parser.add_argument('--input-bridge', type=Path)
    args = parser.parse_args()
    if args.enable_input:
        if not args.input_bridge or not args.input_bridge.is_file():
            parser.error('--enable-input requires a native --input-bridge executable')
        from input_server import serve_input
        serve_input(args.credentials, args.capture, args.input_bridge, args.bind, args.lifetime)
    else:
        serve(args.credentials, args.capture, args.bind, args.lifetime)
