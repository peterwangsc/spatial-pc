# Client receive buffer and TCP candidate — September 15

The client previously reserved an output buffer and copied every Network.framework delivery into it, even when one delivery contained the entire record. `ExactStreamReader` now retains that complete delivery's `Data`; it allocates assembly storage only for fragmented records. The existing direct asynchronous receive loop remains. Each request is exactly the remaining record size, with a 16 MiB maximum and rejection of empty, oversized, or truncated input. No additional frame queue or protocol change is introduced.

The client also explicitly enables `NWProtocolTCP.Options.noDelay` for small reverse input records. Windows already uses TCP_NODELAY. This is an outbound setting, not a way to change Wi-Fi radio scheduling. Its actual reverse-input latency effect remains unmeasured. Apple's API reference: https://developer.apple.com/documentation/network/nwprotocoltcp/options/nodelay

## Validation

- 38 release Swift checks passed, including every two-part boundary of a synthetic record, single-byte fragmentation, EOF, transport error propagation, invalid sizes and excess delivery. Existing stream/input/pairing checks remain passing.
- Optimized arm64 visionOS development build 20 prepared; physical installation and acceptance pending. Build 18 on the headset contains four-digit pairing without these networking changes.
- Apple M4 Pro synthetic assembly, 2,000 iterations per case, before/candidate/candidate/before: a complete 64 KiB record averaged 15.21/15.36 µs before and 13.83/13.81 µs after, including async fixture overhead. Complete 1 MiB records averaged 29.95/30.67 µs before and 14.00/13.98 µs after. The complete candidate records reused the source storage in all 2,000 iterations; baseline reused none. This observes this Foundation build, not a general zero-copy guarantee. Fragmented records still require copying. Raw results: `validation/receive-buffer-20260915.json`.
- Four synthetic loopback TLS sessions delivered and verified all 1,000 ordered 64 KiB records each. The temporary peer wrote 16 KiB TLS chunks, used TLS 1.3, and matched the Windows host's TCP_NODELAY setting. Client trust evaluated a disposable CA and localhost leaf; no trust checks were bypassed. Fixture closed and private temporary keys were removed. Raw results: `validation/receive-tls-20260915.json`.
- The downlink-only loopback fixture does **not** measure the reverse-input benefit of noDelay, Wi-Fi behavior, H264 performance, Windows streaming, or physical headset latency. Short-run timing varies; no delivery-tail improvement is claimed.

An initial implementation wrapped receive in another generic async function and was slower in the loopback fixture. The final implementation keeps the original direct receive loop and shares only synchronous buffer assembly. An initial test-only CA-as-server-leaf certificate was rejected; the fixture was corrected to issue a separate server leaf rather than weakening verification.

## Reproduction

`swift test -c release` uses the existing pinned pairing dependency build. For the assembly fixture, compile `StreamWire.swift`, `ExactStreamReader.swift`, and `scripts/ReceiveBufferBenchmark.swift` together with `swiftc -O`. Run `scripts/benchmark_receive_tls.py` with a development Python environment containing `cryptography`; it compiles its native Swift probe and uses temporary loopback-only TLS credentials. Both fixtures generate synthetic bytes, never desktop pixels or input events.

Receive/decode overlap has not been implemented. The next useful measurement is paced LAN/headset reception under representative Wi-Fi conditions, with receive waits distinguished from source pacing and decoder time. Any added overlap must retain bounded ownership and ordered H264 reference decoding; a larger queue alone is not a latency optimization. Mouse/keyboard behavior debugging remains deferred at Peter's request.
