# Consumer client preparation

This change makes the visionOS Release configuration capable of enrollment and streaming. Distribution is still pending a packaged Windows host, integrated production-host testing, and App Store processing. It does not broaden the demonstrated MVP beyond one physical Windows display on the local network.

## First connection

1. Install and open the Windows host; enable access on a Private network and choose its pairing action.
2. In Spatial PC, choose **Add Device**, select the discovered PC (or enter its address), and enter its one-time code.
3. Approve the request locally in the Windows host. The headset saves the PC and its own identity in its device-only Keychain.
4. **Connect** establishes an authenticated stream and opens the desktop window. The live image fills the window; Back returns to devices, and Focus changes the environment around the same window.

The first-pairing secret is 128 random bits represented as 26 base32 characters. It is not a six-digit PIN. The proof authenticates the actual TLS server leaf and both nonces, host/window identifiers, client public key, and device name. The private P-256 key is generated on the headset and never exported. A client also signs the transcript to prove possession of that key. Stream connections require TLS 1.3, the expected ALPN, private-CA/name/time validation, and the exact saved server leaf.

Canceled or failed enrollments delete their pending local key and certificate. Cold initialization removes abandoned enrollment keys only after the saved-host archive successfully loads; saved identities are retained. Forget removes local access credentials; revocation on Windows independently removes host authorization. Changed identities and expired certificates require explicit re-pairing.

Discovery names are untrusted labels. `_spatialpc-pair._tcp` is advertised only during enrollment; `_spatialpc._tcp` resolves the saved stream endpoint. Both use the same instance and domain. The manual fallback uses pairing port 47990; the authenticated pairing response supplies the stream port. Development hosts use separate ports and identities.

## Recovery and input

Transport failures retry at most five consecutive times with delays of 1, 2, 4, 8 and 8 seconds. Each connection has a 15-second first-frame deadline. A successful frame resets the consecutive-failure count. Trust/protocol failures stop automatic retry. Back/Cancel stops the retry task and connection; backgrounding releases input and disconnects, with reconnect on foreground when a session had been active.

The existing bounded input queue and two-second host lease remain unchanged. Focus loss, scene inactivity, disconnect and teardown end input ownership. No held input is replayed after reconnect. Local diagnostics retain fixed states, frame/timing counters, and keyboard callback counts; they do not record entered text or desktop images, and are not automatically uploaded.

Physical testing of the prior input build established that letters and the floating keyboard worked. Physical Space/Tab navigated local app controls with visionOS Full Keyboard Access enabled. Peter confirmed they work when that accessibility mode is disabled. This is a compatibility limitation, not a claim of full keyboard accessibility support.

## Validation so far

- 22 Swift protocol tests pass, including the exact Windows-generated transcript/HMAC/signature vector, strict JSON/framing limits, and existing video/input checks.
- Release simulator builds and a signed visionOS Release archive build succeeded with the app icon and privacy manifest. An archive is not an App Store upload or approval.
- visionOS 26.5 simulator, Release build 11: manual enrollment reached local approval, installed the matching Keychain identity, saved the PC, and connected to an encrypted synthetic stream. More than 1,000 frames decoded in the first session.
- Killing and restoring the loopback server caused a visible reconnect state and automatic recovery with the same stored identity.
- Reinstalling/relaunching the app retained the paired PC; Connect again decoded more than 780 frames.
- Replacing the server identity caused a trust failure, zero decoded frames on that attempt, no input ownership, and no further automatic retry.
- Canceling at the approval screen closed the pairing attempt without enrollment or a stream. Forget removed the saved PC from the device list.
- Simulator-delivered Space/Tab generated two navigation-key callbacks while the remote surface held focus. This does not substitute for physical headset input validation of the production enrollment build.

These integration checks used a snapshot of the Windows pairing core on Mac loopback, substitute test identity storage, and synthetic video. They do **not** validate Windows DPAPI, its host UI, actual Windows capture, or LAN enrollment. Those are separate integration gates. Bonjour registration was visible to a native Mac browser, but not the simulator browser in this environment; actual LAN discovery is still pending.

An initial five-year server leaf was rejected by Apple's Security framework with `OtherTrustValidityPeriod` / OSStatus -67901. Shortening the test server leaf to 365 days resolved the failure without weakening verification. The host must issue compatible leaves. Apple documents the [825-day limit for this trust policy](https://support.apple.com/en-us/103769).

## Release scope and remaining gates

The demonstrated MVP has encrypted single-display streaming, pointer/keyboard input, a window beside other visionOS windows, and adjustable Focus immersion. Audio, clipboard transfer, WAN access, file transfer, multiple monitors and a headless virtual Windows monitor are outside this release scope. Capture still requires a logged-in interactive Windows session and a supported hardware H.264 encoder.

Before distribution: complete consumer host integration, clean installation/upgrade/uninstall checks, publisher signing, real-network discovery and pairing, physical production-build regression, privacy/support pages, and App Store metadata/review. No public installer is available yet.
