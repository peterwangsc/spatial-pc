# Optional Focus inside the Spatial PC Windows host

The same Windows Forms UI and Python backend now select an optional NVENC
desktop executable and own a CloudXR Focus lifecycle. Default desktop capture
remains Media Foundation. The native NVENC adapter retains startup-only MF
fallback and the existing SPC1 framing/input/SDR conversion. No live backend switch is performed by building this source.

`SpatialPC.exe --xr-development` exposes local Focus development controls while
preserving the ordinary SpatialPC identity directory and ports47990/47991.
It is distinct from `--development`, which still uses the separate test identity
and ports47992/47993. Both remain the same product/application/mutex. This change
does not enable startup automatically or modify any existing paired entry.

## Local integration contract

The existing bounded private UI/backend stdio channel adds:

- `desktopEncoder`, `value: "mf" | "nvenc"`: idle only, optional file required.
- `startFocus`: explicit local confirmation opens a separate system QR
  development window; enabled access, reviewed configuration and idle media required.
- `stopFocus`: idempotent; restore the desktop listener only after clean stop.

Status adds `mediaMode`, `desktopEncoder`, `nvencConfigured` and `focus`.
Focus reports compiled/runtimeConfigured/hardwareValidated/available separately,
its lifecycle state, `mediaSecurity: "development-only-unencrypted"` and
`remoteControl: false`. Hardware validation is false until separately established.
Configured requires
the deployment checks below; available also requires idle exclusive media ownership.
No token or fingerprint is included in general status. No new SPC1 hello field, Bonjour capability or custom remote Focus control
listener is implemented. Intentional QR credentials travel only through private
UI IPC and are rendered in memory with a hash-pinned optional QRCoder dependency.

One event-loop owner covers desktop and Focus. Focus admission claims ownership
before closing the idle desktop listener, so concurrent desktop admission fails.
An active desktop must end before Focus starts; it is not silently interrupted.
Start failure/cancel/stop/revoke/backend EOF disposes the adapter. Failed cleanup
poisons media ownership and refuses a new session. Unexpected child exit does not
restart XR. Existing pairing is retained on all mode transitions.

## Native ownership

The helper blocks on its first private message until the backend assigns a
kill-on-close Job Object. It then loads only the selected client library using
restricted DLL lookup, starts Manager with atomic job membership and an isolated
named pipe, requests Runtime6.2.3 and compares its returned manifest with the
explicit selected file. The selected scene is another owned child. Each receives
XR_RUNTIME_JSON in its own environment; no global ActiveRuntime or system service
registration. Parent and managed logging do not retain vendor output.

Native RPC calls have watchdog deadlines; start has a parent deadline, helper
EOF ends the session, and the current development session has a ten-minute hard limit.
Jobs close before vendor RPC cleanup. Timeout terminates only the owned helper;
the backend refuses recovery if orderly shutdown is not confirmed. Exact vendor
service/breakaway behavior still requires a coordinated runtime phase. Actual
Manager6.1.0 header signatures and native/managed status layout have been checked. Reused source provenance is in
windows/focus/PROVENANCE.md.

## Deployment gates

An optional `focus/deployment.json` in the application directory has exact keys:
version1, runtimeVersion6.2.3, managerVersion6.1.0, reviewed, mediaSecurity,
manager, clientLibrary, manifest, scene, runtimeConfig, and files. `files` maps relative paths
inside focus/ to lowercase SHA256. All files must be listed with no extras,
selected libraries must be in the inventory, and the selected runtime manifest
must be Manager's releases/6.2.3/openxr_cloudxr.json. Hashes are rechecked at start.
The helper resides at native/focus_bridge.exe as part of the host bundle.

The loader currently accepts only an explicitly reviewed development inventory
with `mediaSecurity: "development-only-unencrypted"`, and only in an XR development
configuration. Do not create that authorization marker until the exact binary,
ABI, signature, vendor logging and bounded test scope are reviewed. Consumer
Focus stays unavailable. There is no default deployment file or vendor binary in
the source/package; guessed file hashes are never supplied.

## Documented Apple local system pairing

The earlier custom47994/47995 credential proposal is withdrawn. Apple public
FoveatedStreaming has no local endpoint token/pin injection API. This development
adapter implements the pinned Apple StreamingSession version1 local protocol on
TCP55000, explicitly bound to the selected host address. It uses unsigned four-byte
LITTLE-endian lengths, 1..8192-byte UTF8 JSON, strict duplicate/unknown-field/type
checks and bounded reads/writes. ProtocolVersion is the string "1". One accepted
connection per explicitly opened180-second window; there are no automatic retries.

RequestConnection supplies an untrusted bounded ClientID and SessionID. The owned
Manager receives that exact ClientID and returns token/fingerprint. No runtime or
scene starts yet. AcknowledgeConnection omits CertificateFingerprint to request
a fresh system QR every development session. RequestBarcodePresentation renders
{token,digest} in memory in the same Windows UI; only an actual UI receipt allows
AcknowledgeBarcodePresentation. WAITING starts the reviewed runtime/scene within
a separate deadline and then sends MediaStreamIsReady. This progression is not a
claim of SPP2 authentication: system QR/CloudXR handles its own trust exchange.
EOF/DISCONNECTED/stop/expiry/disable/backend EOF cancels the whole generation.
Any local SPP2 revoke during Focus stops the entire XR session because no reliable
SPP2-device-to-system-ClientID binding is established. Late QR receipts and startup
completions cannot resurrect an invalidated generation. No automatic XR reconnect.

NVIDIA's FAQ says native video/audio/input are unencrypted. Existing desktop mTLS
claims do not transfer. Audio/microphone are explicitly false in the development
runtime YAML and NV_CXR_FILE_LOGGING=0 is inherited by owned children. Manager RPC
supports the isolated pipe/config path; its runtime network property forwarding
and actual signaling/media ports still require review/measurement before any LAN
runtime phase or firewall expansion. No global service/OpenXR registration.

Primary references:
- https://github.com/apple/StreamingSession at b8a3b7502f5f3a46553f957ec0a841c6b27ab069
- https://docs.nvidia.com/cloudxr-sdk/latest/usr_guide/foveated_streaming/server_setup.html
- https://docs.nvidia.com/cloudxr-sdk/latest/usr_guide/cloudxr_runtime/runtime_mgmt_api.html
- https://docs.nvidia.com/cloudxr-sdk/latest/support/faq.html

## Candidate build and verification

`windows/package/build-focus-candidate.ps1` takes a manifest-verified preserved
consumer1.0.1 package and external pinned NVENC header root. It copies only
listed package files, compiles the UI/helper/NVENC, overlays host source and
creates an unsigned internal manifest. Optional stage-focus-development.ps1
extracts exact hash-verified user-supplied archives into that private candidate,
checks NVIDIA signatures, stages the pinned plain scene/loader and QR renderer,
and writes a complete deployment inventory with reviewed=false. It does not
authorize execution. Neither script installs or starts the host.
No local identity, uninstaller, session evidence or arbitrary base-directory extras
are copied. Default capture/input/pairing binaries remain from the verified base.

`tests/test_focus_host.py` and `tests/test_focus_local.py` use fake adapters/identity/listeners and nonexecuting
inventory contents. It covers ownership, failure/cancel/revoke, pair preservation,
default MF versus optional NVENC arguments, inventory bounds and fail-closed
cleanup. Native helper admission tests send only EOF/malformed commands and exit
before vendor loading. These are not capture, CloudXR, network or input tests.
Prior native ownership suites need not repeat for this unchanged native adapter.

Hardware readiness still requires accepted NVENC dependency provenance, exact
runtime network/logging/containment behavior and coordinated candidate validation.
The downloaded CloudXR archives/signatures/ABI have been inspected; public binary
redistribution clearance and hardware acceptance are separate outstanding gates. Build success alone
does not authorize a host switch or prove XR/encoder performance.
