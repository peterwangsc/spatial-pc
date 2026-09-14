# Protocol v1 — lab vertical slice

Implemented transport: TCP with TLS 1.3 and ALPN `spatialpc/1`. Both endpoints present certificates from the short-lived lab CA. The client validates the host's certificate chain, hostname, expiry and exact leaf fingerprint. The host validates the client chain and exact leaf fingerprint before starting desktop capture. Each new TLS connection establishes session keys. No desktop, input, audio, or clipboard is sent in plaintext.

## Enrollment boundary

The current **Debug-only** client imports an explicitly provisioned `lab-pair.json` from its Documents directory, stores it in the app's Keychain with `WhenUnlockedThisDeviceOnly`, and deletes the import file. The host protects its private key with per-user Windows DPAPI. Its credential directory has inheritance removed and access restricted to the current user. A temporary PEM exists inside that restricted directory only while constructing the TLS context, then is deleted.

The enrollment is delivered over the existing trusted SSH/device connection. This first experiment reuses one temporary client credential across the authorized Mac test, simulator and headset; production pairing must generate separate device identities. This is controlled provisioning, **not implemented consumer discovery + code/QR verification**. Certificates expire in seven days and the CA private key is not persisted. Removing the host's authorized client fingerprint or rotating the pair revokes future sessions; a user-facing revoke interface is still required. No credentials are embedded in source or the app bundle.

## Framing

All integers use network byte order. Both peers start with `SPC1`, a u32 JSON byte count, then UTF-8 capability JSON. The maximum capability message is 4 KiB. The client offers version, codec identifiers, and decoder dimension bounds. The host responds with selected codec, actual display dimensions, nominal target rate and verified encoder hardware status. Unknown versions/codecs are rejected.

For each video access unit, the host sends a u32 payload byte count, u64 presentation timestamp (100 ns ticks from capture-process start), u32 Media Foundation sample flags, and H.264 Annex B bytes. SPS and PPS establish the decoder format; the client checks decoded dimensions against negotiation and waits for an IDR when a format changes. Flags are reserved for diagnostics and are not trusted as a substitute for parsing the stream.

The current defensive allocation bound is 16 MiB per access unit and 16,777,216 decoded pixels. These bounds constrain this experiment's memory exposure, not product tiers. Future negotiation must derive feasible profiles from device capabilities, resource budgets, and measured load.

## Backpressure and limits

The client receives and decodes one access unit at a time. The native window samples the latest decoded surface directly and permits one presentation command in flight; it skips busy presentation ticks while still decoding reference frames. Focus retains the same window and presentation path. TCP provides integrity/order but can accumulate latency under loss or congestion. Native encoder and OS socket buffers are not yet measured or bounded as a complete pipeline. This transport establishes feasibility; it does not meet the final latency goal by assumption.

The host starts capture only after mutual authentication, times out stalled network operations, ends each experiment after ten minutes, and terminates its capture child on disconnect. It currently serves one physical display through a single connection. Bonjour selection, first-run pairing, display enumeration, reconnect, keyframe requests, adaptive bitrate, audio and input are still incomplete.

Next transport evaluation: QUIC datagrams or WebRTC for timely video, reliable control, independently versioned stream identifiers, keyframe recovery and measured queue depths. Keep the current encrypted path as a correctness baseline; never introduce a plaintext fallback.
