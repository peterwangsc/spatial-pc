# Client performance validation

Use `Lab` for an optimized development streaming build (`-O` plus lab enrollment). `Debug` uses `-Onone`; `Release` excludes the unfinished development connection flow. Never publish a Lab build as a consumer release.

The window samples the decoder's Metal-compatible BGRA IOSurface directly. A single latest decoded image replaces the previous image; submitted GPU work retains its Core Video image and texture until completion. Focus mode copies into a RealityKit LowLevelTexture, with one copy in flight and the newest decoded frame waiting. Session generations prevent old copy completions from mutating a new session. Encoded frames are still decoded in order, including reference frames.

Network exact reads run outside the main actor and request the remaining bytes of a bounded protocol record. Diagnostic serialization and file writes use utility queues. Per-frame counters do not trigger SwiftUI view observation.

## September 13 development checks

- Four Swift protocol tests and four Python protocol tests passed.
- Optimized visionOS simulator and signed physical-device Lab builds passed.
- A local-only TLS 1.3 fixture delivered 1080p H.264 generated from `ffmpeg testsrc2` at 60 fps. Each frame header was deliberately split across three sends. Window → Focus → window kept the changing image visible. Wrong server pin rejected with zero frames; corrected pairing reconnected and decoded at least 120 frames.
- Simulator telemetry identifies direct-window versus RealityKit-copy presentation. Window submission was approximately 30 fps on this simulator, while Focus texture copies were approximately 60 fps. These are distinct counters and are not measurements of headset display rate or scanout.
- On an M4 Pro, 120 synthetic 1080p frames decoded with VideoToolbox hardware acceleration. A single paired run measured Debug decode p50/p95/p99 2.524/2.973/3.802 ms and optimized 1.955/2.623/2.686 ms. This is a local synthetic check, not a statistically controlled AVP latency benchmark.
- Borrowing Annex-B input storage eliminates one full input copy. A 1 MB synthetic parse-plus-AVCC microbenchmark (1,000 iterations after 100 warmups, optimized compiler) measured p50 0.508 → 0.480 ms. Small observed timing differences need repetition; the removed allocation is the stronger claim.

`stream-metrics.json` describes GPU submission/completion, not capture-to-photon delay. Decoder timing excludes Windows capture/encoding and network transit. Real headset motion testing, sustained thermal behavior, and optical capture-to-photon measurements remain necessary before publishing latency or frame-rate guarantees.

## Local decode probe

Compile `scripts/DecodeProbe.swift` together with `StreamWire.swift` and `H264Decoder.swift` using `swiftc -O`. It reads SPC1 from stdin and emits timing metadata without saving decoded pixels. `scripts/validate_lab_stream.py` connects with an explicitly provisioned pair and feeds 120 frames to the probe. Coordinate with the host operator before capture tests; do not run it during another capture benchmark.
