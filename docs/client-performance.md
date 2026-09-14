# Client performance validation

Use `Lab` for an optimized development streaming build (`-O` plus lab enrollment). `Debug` uses `-Onone`; `Release` excludes the unfinished development connection flow. Never publish a Lab build as a consumer release.

The window samples the decoder's Metal-compatible BGRA IOSurface directly. A single latest decoded image replaces the previous image; submitted GPU work retains its Core Video image and texture until completion. Focus mode copies into a RealityKit LowLevelTexture, with one copy in flight and the newest decoded frame waiting. Session generations prevent old copy completions from mutating a new session. Encoded frames are still decoded in order, including reference frames.

Network exact reads run outside the main actor and request the remaining bytes of a bounded protocol record. Diagnostic serialization and file writes use utility queues. Per-frame counters do not trigger SwiftUI view observation.

## September 13 development checks

- Four Swift protocol tests and four Python protocol tests passed.
- Optimized visionOS simulator and signed physical-device Lab builds passed; the signed Release archive also passed.
- A local-only TLS 1.3 fixture delivered 1080p H.264 generated from `ffmpeg testsrc2` at 60 fps. Each frame header was deliberately split across three sends. Window → Focus → window kept the changing image visible. Wrong server pin rejected with zero frames; corrected pairing reconnected and decoded at least 120 frames.
- Additional authenticated fixture faults closed promptly with zero frames: truncated frame header in 1.29 seconds and oversized frame length in 0.78 seconds. These test the new exact-read behavior at connection termination and the existing allocation bound.
- Simulator telemetry identifies direct-window versus RealityKit-copy presentation. Window submission was approximately 30 fps on this simulator, while Focus texture copies were approximately 60 fps. These are distinct counters and are not measurements of headset display rate or scanout.
- On an M4 Pro, 120 synthetic 1080p frames decoded with VideoToolbox hardware acceleration. A single paired run measured Debug decode p50/p95/p99 2.524/2.973/3.802 ms and optimized 1.955/2.623/2.686 ms. This is a local synthetic check, not a statistically controlled AVP latency benchmark.
- Borrowing Annex-B input storage eliminates one full input copy. A 1 MB synthetic parse-plus-AVCC microbenchmark (1,000 iterations after 100 warmups, optimized compiler) measured p50 0.508 → 0.480 ms. Small observed timing differences need repetition; the removed allocation is the stronger claim.

`stream-metrics.json` describes GPU submission/completion, not capture-to-photon delay. Decoder timing excludes Windows capture/encoding and network transit. Real headset motion testing, sustained thermal behavior, and optical capture-to-photon measurements remain necessary before publishing latency or frame-rate guarantees.

## Local decode probe

Compile `scripts/DecodeProbe.swift` together with `StreamWire.swift` and `H264Decoder.swift` using `swiftc -O`. It reads SPC1 from stdin and emits timing metadata without saving decoded pixels. `scripts/validate_lab_stream.py` connects with an explicitly provisioned pair and feeds 120 frames by default; `--frames 600` extends a sample. The probe reports decoder percentiles, arrival intervals, and relative arrival-versus-host-timestamp drift. Drift is referenced to the first payload, includes sender/network/pipe scheduling, and is not an absolute latency estimate. Coordinate with the host operator before capture tests; do not run it during another capture benchmark.

## Integrated development check

The reviewed RTX 4070 candidate delivered real 1920×1080 desktop frames over LAN TLS 1.3 to the optimized M4 Pro hardware decoder. A 600-frame ordinary-desktop sample decoded every frame in 15.344 seconds, with decode p50/p95/p99 2.846/4.404/5.719 ms. Source updates were uncontrolled; this is not a 60 FPS throughput benchmark. Client arrival interval p95 was 57.687 ms, while matched host pipe-read p95 was 56.567 ms and TLS-send p95 was 0.211 ms. Native acquire-to-encoded p95 was about 34.8 ms. These measurements point toward variable source/encoder scheduling for common gaps; they do not assign the isolated large client-arrival spike to a single stage.

The same host also delivered more than 14,000 frames to the visionOS simulator and passed the actual Windows window → progressive Focus → window transition. Missing-client and untrusted-host certificate rejection passed before the native probe sessions. All retained artifacts contain timing metadata; no desktop recordings are needed for these checks. Physical headset performance remains unverified for this revision while the device is off.
