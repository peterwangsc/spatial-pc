# Optional Focus inside the Spatial PC Windows host

The same Windows Forms UI and Python backend now select an optional NVENC
desktop executable and own a CloudXR Focus lifecycle. Default desktop capture
remains Media Foundation. The native NVENC adapter retains startup-only MF
fallback and the existing SPC1 framing/input/SDR conversion. No live backend
switch or protocol change is included.

`SpatialPC.exe --xr-development` exposes local Focus development controls while
preserving the ordinary SpatialPC identity directory and ports47990/47991.
It is distinct from `--development`, which still uses the separate test identity
and ports47992/47993. Both remain the same product/application/mutex. This change
does not enable startup automatically or modify any existing paired entry.

## Local integration contract

The existing bounded private UI/backend stdio channel adds:

- `desktopEncoder`, `value: "mf" | "nvenc"`: idle only, optional file required.
- `startFocus`, `deviceId`: explicit local confirmation for an existing paired
  device, enabled access, reviewed configuration and idle media required.
- `stopFocus`: idempotent; restore the desktop listener only after clean stop.

Status adds `mediaMode`, `desktopEncoder`, `nvencConfigured` and `focus`.
Focus reports supported/configured/available independently, its lifecycle state,
`mediaSecurity: "unresolved"` and `remoteControl: false`. Supported is an adapter
implementation, not proof of native runtime compatibility. Configured requires
the deployment checks below; available also requires idle exclusive media ownership.
No token or fingerprint is included in general status. No new SPC1 hello field,
Bonjour capability or remote Focus control listener has been implemented.

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
EOF ends the session, and the current local-only session has a ten-minute limit.
Jobs close before vendor RPC cleanup. Timeout terminates only the owned helper;
the backend refuses recovery if orderly shutdown is not confirmed. Exact vendor
service/breakaway behavior and API signatures still require artifact inspection
and a coordinated runtime phase. Reused source provenance is in
windows/focus/PROVENANCE.md.

## Deployment gates

An optional `focus/deployment.json` in the application directory has exact keys:
version1, runtimeVersion6.2.3, managerVersion6.1.0, reviewed, mediaSecurity,
manager, clientLibrary, manifest, scene, and files. `files` maps relative paths
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

## Proposed remote handoff — not implemented

The review draft reserves selected-interface TCP47994 (production) /47995
(development), ALPN spatialpc-focus/1, TLS1.3 using existing paired client certs
and host pins. Per-session local approval precedes token creation. The intended
private ready response carries actual CloudXR leaf SHA256, ephemeral token,
sessionId, endpoint and expiry to the authenticated control owner only. SPP2
establishes control identity; it is not CloudXR pairing. Heartbeat/owner-disconnect
lease, exact JSON schema and native trust API require client agreement first.

CloudXR documents TCP48322 signaling and UDP47998–48002,48005,48008,48012 media.
No firewall expansion or vendor listener is started by this integration work.
Existing desktop mTLS guarantees do not transfer to XR media. NVIDIA's current
FAQ says native video/audio/input are unencrypted; exact FoveatedStreaming6.2.3
protection and redistribution remain separate gates.

## Candidate build and verification

`windows/package/build-focus-candidate.ps1` takes a manifest-verified preserved
consumer1.0.1 package and external pinned NVENC header root. It copies only
listed package files, compiles the UI/helper/NVENC, overlays host source and
creates an unsigned internal manifest. It neither installs nor starts the host.
No local identity, uninstaller, session evidence or arbitrary base-directory extras
are copied. Default capture/input/pairing binaries remain from the verified base.

`tests/test_focus_host.py` uses fake adapters/identity/listeners and nonexecuting
inventory contents. It covers ownership, failure/cancel/revoke, pair preservation,
default MF versus optional NVENC arguments, inventory bounds and fail-closed
cleanup. Native helper admission tests send only EOF/malformed commands and exit
before vendor loading. These are not capture, CloudXR, network or input tests.
Prior native ownership suites need not repeat for this unchanged native adapter.

Hardware readiness still requires original-header provenance or an explicitly
accepted mirror dependency, exact CloudXR artifacts/signatures/terms/ABI review,
control-wire agreement and a coordinated candidate phase. Build success alone
does not authorize a host switch or prove XR/encoder performance.
