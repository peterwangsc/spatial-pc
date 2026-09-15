# Disposable control interoperability preparation

This fixture exercises the reviewed control TLS/parser/dispatcher with a
disposable identity and fake media. It does not construct the production Worker,
access DPAPI/paired-device storage, start native/vendor processes, or change a
firewall. It is separate from the integration package and is never shipped in it.

The scripts are prepared only. Do not launch or arm a listener until the matching
Mac executable and a bounded phase have been coordinated. No physical/LAN or
runtime readiness follows from these fixtures.

## Memory-only operator interface

`tests/support/control_interop_fixture.py` reads newline-delimited JSON from
stdin (8192-byte limit, queue8), writes newline-delimited JSON to stdout
(queue16), and produces no credential file. Use a private pipe for the existing
operator/SSH transport, not command-line arguments, a transcript, or a shell
log. Stdout records are public fixture certificates and metadata, never private
keys. The client creates and retains its P256 private key in its own process.

Point `SPATIAL_PC_FIXTURE_HOST_ROOT` at the exact reviewed package's `host`
directory when using packaged Python. Without this process-local override the
fixture imports the checkout's `windows/host`. The ready record reports the
normalized SHA256 of the loaded control source. The fixture source itself is
not part of the reviewed product revision.

The process starts with `waiting` and no identity, socket or expiry window.
Commands have exact fields:

1. `{"version":1,"type":"enroll","publicKey":"BASE64_DER_SPKI"}`.
   The public key must be DER SubjectPublicKeyInfo for P256, not the raw X9.63
   point. Exactly one enrollment per process. The returned `enrolled` record has
   `fixtureOnly:true`, `hostId`, `deviceId`, `serverName`, `caCertificate`,
   `serverCertificate`, `clientCertificate`, `serverSHA256`, `clientSHA256`,
   `alpn:"spatialpc-control/1"`, `keyRetention:"client-memory-only"` and
   `systemEndpointUsable:false`. Certificates are base64 DER; fingerprints are
   lowercase SHA256 hex. No listener or timer is opened by enrollment.
2. Only when armed by the operator:
   `{"version":1,"type":"arm","lifetimeSeconds":180}`.
   Bounds are10..180 seconds, one arm per process, fixed127.0.0.1, ephemeral port.
   No arbitrary address/port option exists. `ready` returns the assigned port,
   PID, lifetime and control source hash. Mac can later use an explicitly
   coordinated TLS-opaque SSH tunnel; this would not be a direct LAN result.
3. A real wire `focus.requestPermission` emits an operator `permissionPending`
   record containing its fresh `requestId` and expiry. The operator answers
   `{"version":1,"type":"permission","requestId":"32_LOWER_HEX","accepted":true}`.
   Only the matching live request can complete. Grants persist only in this
   disposable in-memory state. `permissionClosed` ends that prompt.
4. `{"version":1,"type":"status"}` reports fixture enrollment/arm/session/media
   metadata only. `{"version":1,"type":"close"}`, operator EOF, malformed
   commands or expiry close all owned control sessions/listeners. There is no
   rearm or credential reuse; create a fresh process/key for another phase.

The Python SSL API requires filenames when loading a server key. The fixture
uses the existing loader: an encrypted temporary server key is deleted before
listener creation; its encryption password and CA/server keys stay in process
memory. The client private key is neither generated nor received by Windows.
This is not a claim of Python memory zeroization or Windows DPAPI validation.

## Matching client phase

The first phase covers TLS/SNI/leaf pin/client certificate, capabilities,
explicit permission, heartbeat, stop and EOF. Two connections including
handshakes, one per enrolled device and all reviewed wire limits still apply.
Do not connect ordinary desktop TLS or Apple's local service.

Fake media implements only start/stop ownership. Its synthetic prepare response
may name55000 as dictated by the production schema, but it opens no55000
listener, presents no QR and starts no media. The bootstrap explicitly marks
that system endpoint unusable. Any future fake prepare test must be labeled as
such; it cannot validate Apple trust, video, runtime readiness or physical Focus.

## Preparation validation

Ten new tests cover exact stdin records, public-key/certificate/pin agreement,
single-use enrollment/arming, no-listener enrollment, removed encrypted TLS
temporary files, exact permission ID, fake ownership cleanup and discarded
fixture state. Tests replace listener creation and expiry scheduling; no
listener or timed window is opened. Previously completed control/native suites
are not repeated by this preparation.

`windows/package/assemble-reviewed-focus.ps1` assembles an exact source commit
using a hash-pinned reviewed base manifest and deployment. It exports that commit
to a new directory, compiles only UI, copies manifest-listed files, overlays
reviewed Python source, verifies module imports/deployment hashes and writes a
new complete manifest plus operator readiness JSON. Native/vendor files are
reused only when their source and bytes match the reviewed base. It neither
launches the UI nor constructs a real identity. Failed assembly leaves a local
build directory for inspection; only a verified readiness record designates a
candidate. No binaries or vendor artifacts belong in the public source PR.
