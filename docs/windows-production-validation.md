# Windows consumer-host validation — September 14, 2026

The single-display consumer host is implemented and packaged. Public Windows
distribution remains blocked on publisher signing and clean-machine acceptance.
This record distinguishes local component tests from physical-device results.

## Candidate

Application source: `ca1ea6a518e838f60f7bc713f3cb14cfc2899003`.
Version: `1.0.0`, Windows 11 x64, official isolated Python 3.14.7.
The manifest records a clean source tree and inventories the complete payload.

Unsigned test installer: `SpatialPC-1.0.0-win-x64-unsigned-test.exe`,
15,813,389 bytes, SHA-256
`b9c5d6ca40506761fccabedc82d440fa32594f318595e945bba6a2d04007a713`.
This artifact is private test material, not a production download.

## Windows checks

- The bundled runtime ran 59 unit/integration cases: 58 passed and the explicit
  eleven-minute fixture was skipped in that ordinary run. Tests include real
  DPAPI persistence/tamper rejection, IPv4/IPv6 TLS pairing and lifecycle,
  expiring proof/approval, active revocation, native owned-input cleanup,
  process crash, discovery goodbyes/socket closure, partial-record bounds and
  bounded diagnostic files. Native builds and input-engine tests passed.
- The separately invoked final production transport fixture remained idle for
  **660.965 seconds**, then accepted synthetic owned input, released it on
  revocation and rejected reconnect. The fixture imports no DXGI or SendInput
  and emits no video in idle mode. This tests the owner-handshake/session path
  from `a41eca9`, before the independent TCP keepalive addition.
- The actual native input helper stayed idle for **660.010 seconds**, received
  **zero input records**, and exited 0 on stdin EOF. Tested binary SHA-256:
  `3acc656de062ca5d1c205c60d21ac498d3c6a7bf17d0f5a1254b11f60548a4ad`.
  Later packaging rebuilds have different whole-file hashes; the helper source
  is unchanged. This is not a long hardware-video or input-injection test.
- The real capture executable refused owner EOF before DXGI initialization.
  A no-capture native fixture waited for the post-Job readiness byte and stopped
  on owner EOF even without frame writes.
- Authenticated fixture regressions passed certificate negatives, view-only
  defaults, text negotiation, replay rejection and held-state release. With a
  full video pipe, native release occurred at **2.015 seconds** after admission
  and TLS closed at **2.018 seconds**. No desktop input was injected.
- Assigned-interface IPv6 Bonjour resolved the exact AAAA address and separate
  pairing/stream ports. IPv4/IPv6 accepted sockets read back keepalive values
  10 seconds idle / 2 seconds interval / 3 probes. A healthy connection survived
  18 seconds idle. A physical IPv6-only topology and vanished-peer timing have
  not been tested.

## Installation and consumer integration

Normal-token install, versioned 1.0.0-to-1.0.1 upgrade, same-version candidate
replacement, protected identity reload and uninstall passed on the development
PC with PATH restricted to Windows System32. Test applications and temporary
scheduled runners were removed; protected test identity data was retained.
The latest replacement check used package `a41eca9`; `ca1ea6a` changes only
per-connection keepalive, its tests and documentation. This is not a clean
Windows machine without developer software.

The earlier packaged host `41d26d6` passed actual consumer enrollment/approval,
Windows DPAPI and simulator Keychain persistence, real desktop decoding,
cold relaunch, interruption recovery, active revocation and refused reconnect
with release visionOS builds 12/13. The simulator required a TLS-opaque relay;
native Mac discovered the Windows service, while simulator Bonjour was empty.
No desktop actions or ordinary-desktop images were retained. The final native
owner-start candidate still requires its coordinated short release-client check.

## Unfinished release gates

No verified Windows publisher code-signing identity is available. The signature
gate rejects unsigned executables and installers. A clean Windows 11 machine,
physical consumer setup/discovery/input acceptance, and IPv6-only network
acceptance remain unavailable or pending. Apple account/app-record/submission
work is tracked separately by the client owner. No installer upload or store
release is claimed by these tests.
