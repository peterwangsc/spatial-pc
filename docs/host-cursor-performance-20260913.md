# Cursor GPU work reduction — 2026-09-13

Updating the existing cursor texture and drawing only its clipped rectangle reduced the measured cursor-plus-NV12 GPU interval in two ordered comparisons. Encoded delivery stayed near 60 FPS, with slightly higher pipe-arrival tails. This is a resource-efficiency improvement, not a demonstrated latency or frame-rate improvement.

## Method and results

Same Windows 11, RTX 4070/driver 566.14, 1920×1080 144.001 Hz physical display and NVIDIA hardware H.264 MFT as the [first performance pass](host-performance-20260913.md). Target 60 FPS, configured 20 Mbps. Each run used the same visible D3D11 moving checkerboard/bars workload, 20 seconds of native capture, and a pipe reader that discarded pixels. The first three seconds continued presenting static pixels. No competing streaming capture ran. Normal desktop processes remained running.

Order was before → after → after → before. Steady FPS excludes the first four seconds; percentiles include startup. Two runs per implementation are not statistical confidence bounds. GPU timestamps span cursor composition plus NV12 conversion and include scheduling, rather than measuring cursor work alone.

| Run | Steady FPS | GPU p50 / p95 / p99, ms | Pipe arrival p95 / p99, ms | Native CPU, % of one logical core |
| --- | ---: | ---: | ---: | ---: |
| Before 1 | 59.986 | 0.251 / 0.378 / 1.270 | 19.885 / 21.424 | 10.57 |
| After 1 | 59.997 | 0.166 / 0.193 / 0.319 | 20.311 / 22.224 | 6.18 |
| After 2 | 60.001 | 0.168 / 0.196 / 0.360 | 20.272 / 22.224 | 10.27 |
| Before 2 | 59.981 | 0.252 / 0.575 / 2.440 | 20.034 / 22.001 | 10.96 |

Every run delivered all 1,201 inputs, peak pending 1, zero pending at completion, with 21 I and 1,180 P slices and no B slices. The changing 32×32 pointer caused 401 uploads in each candidate run but only one texture allocation, versus 401 logged allocations before. No duplicate shapes occurred, so duplicate suppression did not explain the measured improvement. Overall CPU varied substantially; do not generalize a CPU reduction from these samples.

Before acquire-to-encoded p95/p99 were 9.817/11.468 and 9.702/11.666 ms; after were 9.612/11.208 and 9.782/11.380 ms. These timestamps start after desktop acquisition and exclude network, decoding, display scanout and optics. Pipe p99 increased by about 0.80 and 0.22 ms in the paired comparisons. No capture-to-photon claim is supported.

The [metadata JSON](host-cursor-performance-20260913.json) records all measured stages, sample counts, maxima and exact native binary hashes. The before binary is the canonical build from host performance commit `364eb060ebfbd2220ea72e0d2948b0b51744099c`. Candidate SHA-256 is `97f5560ffdfd2fd5050c18f46d28ae096c4db9887ab85446daa19193bc128334`.

## Implementation and validation

The compositor copies the desktop to its output, copies only the clipped pointer background into the shader input, then scissors the existing composition shader to that rectangle. A pointer entirely offscreen bypasses composition. Desktop pixels stay on the GPU. Same-size pointer changes reuse the texture and SRV; exact duplicate bytes and shape metadata skip upload. Cumulative metadata counters replace one stderr line per shape update.

Texture updates and draws use the same immediate D3D11 context. The default-usage texture supports `UpdateSubresource`; the runtime preserves prior GPU reads when an update contends with queued work. See Microsoft's [UpdateSubresource contract](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-id3d11devicecontext-updatesubresource). A test queues an old-shape draw and readback, updates the same texture, then verifies both the earlier and later images.

All 31 GPU checks passed, covering colored, masked and monochrome pointers, hidden and offscreen pointers, negative/right/bottom clipping, movement restoration, duplicate suppression, resource reuse, and composition over a varied background. The CPU reference permits one UNORM least-significant bit for floating-point color alpha blending; copy, masked XOR and monochrome checks are exact.

A fresh loopback TLS 1.3 test decoded the wire framing for 322 native encoded frames, checked increasing timestamps and frame bounds, and rejected missing-client and untrusted-host certificates before capture began. It did not decode pixels. The SPC1 protocol, certificate authentication, existing sample-pool ownership, admission limits and transport deadlines are unchanged. Physical headset validation of this exact cursor candidate remains separate from these local measurements.
