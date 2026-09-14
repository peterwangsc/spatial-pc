# Consumer client preparation

This change makes the visionOS Release configuration capable of enrollment and streaming. Distribution is still pending publisher-signed Windows packaging, physical consumer-build validation, and App Store processing. It does not broaden the demonstrated MVP beyond one physical Windows display on the local network.

## First connection

1. Install and open the Windows host; enable access on a Private network and choose its pairing action.
2. In Spatial PC, choose **Add Device**, select the discovered PC (or enter its address), and enter its one-time code.
3. Approve the request locally in the Windows host. The headset saves the PC and its own identity in its device-only Keychain.
4. **Connect** establishes an authenticated stream and opens the desktop window. The live image fills the window; Back returns to devices, and Focus changes the environment around the same window.

The first-pairing secret is 128 random bits represented as 26 base32 characters. It is not a six-digit PIN. The proof authenticates the actual TLS server leaf and both nonces, host/window identifiers, client public key, and device name. The private P-256 key is generated on the headset and never exported. A client also signs the transcript to prove possession of that key. Stream connections require TLS 1.3, the expected ALPN, private-CA/name/time validation, and the exact saved server leaf.

Canceled or failed enrollments delete their pending local key and certificate. Cold initialization removes abandoned enrollment keys only after the saved-host archive successfully loads; saved identities are retained. An unavailable or unreadable archive blocks enrollment and all device-list writes until a successful reload; foregrounding retries the load, and the home screen provides Try Again. Forget removes local access credentials; revocation on Windows independently removes host authorization. Changed identities and expired certificates require explicit re-pairing.

Discovery names are untrusted labels. `_spatialpc-pair._tcp` is advertised only during enrollment; `_spatialpc._tcp` resolves the saved stream endpoint. Both use the same instance and domain. The manual fallback uses pairing port 47990; the authenticated pairing response supplies the stream port. Development hosts use separate ports and identities.

## Recovery and input

Transport failures retry at most five consecutive times with delays of 1, 2, 4, 8 and 8 seconds. Each connection has a 15-second first-frame deadline. A successful frame resets the consecutive-failure count. Trust/protocol failures stop automatic retry. Back/Cancel stops the retry task and connection; backgrounding releases input and disconnects, with reconnect on foreground when a session had been active.

The existing bounded input queue and two-second host lease remain unchanged. Focus loss, scene inactivity, disconnect and teardown end input ownership. No held input is replayed after reconnect. Local diagnostics retain fixed states, frame/timing counters, and keyboard callback counts; they do not record entered text or desktop images, and are not automatically uploaded.

Physical testing of the prior input build established that letters and the floating keyboard worked. Physical Space/Tab navigated local app controls with visionOS Full Keyboard Access enabled. Peter confirmed they work when that accessibility mode is disabled. This is a compatibility limitation, not a claim of full keyboard accessibility support.

## Validation so far

- 25 Swift protocol/storage tests pass, including the exact Windows-generated transcript/HMAC/signature vector, strict JSON/framing limits, and existing video/input checks.
- Release simulator builds, a signed visionOS Release archive, and an App Store IPA export succeeded with the app icon and privacy manifest. Version 1.0.0 build 14 was exported with the verified distribution team; it has not been uploaded or approved.
- visionOS 26.5 simulator, Release build 11: manual enrollment reached local approval, installed the matching Keychain identity, saved the PC, and connected to an encrypted synthetic stream. More than 1,000 frames decoded in the first session.
- Killing and restoring the loopback server caused a visible reconnect state and automatic recovery with the same stored identity.
- Reinstalling/relaunching the app retained the paired PC; Connect again decoded more than 780 frames.
- Replacing the server identity caused a trust failure, zero decoded frames on that attempt, no input ownership, and no further automatic retry.
- Canceling at the approval screen closed the pairing attempt without enrollment or a stream. Forget removed the saved PC from the device list.
- Simulator-delivered Space/Tab generated two navigation-key callbacks while the remote surface held focus. This does not substitute for physical headset input validation of the production enrollment build.

The preceding loopback integration checks used a snapshot of the Windows pairing core on Mac loopback, substitute test identity storage, and synthetic video. They do **not** validate Windows DPAPI, its host UI, actual Windows capture, or LAN enrollment. The later packaged-host checks below exercise some of those separate boundaries. Bonjour registration was visible to a native Mac browser, but not the simulator browser in this environment; physical discovery is still pending.

An initial five-year server leaf was rejected by Apple's Security framework with `OtherTrustValidityPeriod` / OSStatus -67901. Shortening the test server leaf to 365 days resolved the failure without weakening verification. The host must issue compatible leaves. Apple documents the [825-day limit for this trust policy](https://support.apple.com/en-us/103769).

## Packaged Windows integration — September 14

Client source `5c28c33`, Release 1.0.0 build 12 (then `ed79af6`, build 13, for revocation), visionOS 26.5 simulator, was paired with Windows package source `41d26d6`. The package used its isolated runtime, native capture/input binaries, fresh Windows DPAPI identity storage, and a local approval operation. No development credential file was imported into the Release client.

Because the simulator did not discover the actual Windows Bonjour announcement, this phase used a temporary TLS-opaque TCP relay between loopback and the host's alternate test ports. TLS terminated only at the release app and Windows host. The relay retained byte counts, never payloads. This is not evidence of direct headset discovery, physical input, or end-to-end latency.

- Fresh code proof, Windows approval, certificate validation and simulator Keychain persistence completed; Windows retained exactly one approved test device.
- The first real Windows desktop session recorded 2,820 decoded frames. Input and text capabilities were negotiated, while input ownership stayed false and every keyboard callback counter stayed zero.
- Abrupt simulator termination closed the stream. Relaunch retained the saved PC and reconnect produced another 840 frames before interruption testing.
- Terminating the Mac relay caused a connection-refused state with zero frames and input unavailable. Restoring it recovered automatically against the unchanged host, with 1,020 fresh frames in the saved recovery snapshot.

No ordinary desktop screenshots or video were retained, and no pointer or keyboard actions were injected in this phase. A first SSH-launched UI helper stopped before connecting; a local GUI-session receiver then completed the same enrollment flow with the code kept in memory. The Windows host's normal-user first-run permission UI and clean-machine install remain separate checks. Active revocation then removed the sole test device, disconnected its active stream, and stopped Windows capture. Release build 13 refused reconnect, ending after its bounded retry sequence with zero frames and input unavailable. The temporary Windows listener and its separate firewall rules were removed afterward.

Build 14 added two recovery fixes after this Windows phase. With synthetic loopback video, the corner controls now become visible immediately after a live stream disconnects; previously the visibility condition inside the hover callback could stay stale. An authenticated host advertising unsupported stream version 2 now produces a specific incompatible-stream message and stops automatic retry with zero decoded frames. No Windows capture was used for these checks.

## Release scope and remaining gates

The demonstrated MVP has encrypted single-display streaming, pointer/keyboard input, a window beside other visionOS windows, and adjustable Focus immersion. Audio, clipboard transfer, WAN access, file transfer, multiple monitors and a headless virtual Windows monitor are outside this release scope. Capture still requires a logged-in interactive Windows session and a supported hardware H.264 encoder.

Before distribution: complete the remaining consumer host changes and physical integration, clean-machine installation/upgrade/uninstall checks, publisher signing, real-network discovery and pairing, and App Store metadata/review. Normal-user installer lifecycle checks on the development PC passed separately; that is not a clean-machine test. The support and privacy pages are live on the project website. No public installer is available yet.
