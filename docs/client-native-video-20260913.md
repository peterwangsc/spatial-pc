# Native video surfaces — September 13, 2026

The client requests hardware-decoded NV12 surfaces, samples their luma/chroma planes directly in the window, and converts them in a single Metal compute pass for RealityKit Focus. This removes the decoder’s BGRA conversion. Both paths retain Core Video buffers and their Metal mappings through GPU completion, with the existing bounded latest-frame ownership. BGRA and the synthetic preview remain supported by the renderer.

## Measurements and validation

On the M4 Pro Mac, six ordered 120-frame 1080p synthetic H.264 runs (BGRA, NV12, NV12, BGRA, BGRA, NV12), all optimized and hardware decoded:

| Output | Decode p50 | Decode p95 |
| --- | ---: | ---: |
| BGRA | 1.781–1.906 ms | 2.195–2.319 ms |
| NV12 | 0.851–0.864 ms | 0.962–0.998 ms |

These measure local decode, excluding GPU presentation and headset scanout. They are not physical AVP latency or statistical confidence bounds. A real LAN 120-frame check against the cursor-optimized Windows host also passed TLS 1.3, mutual certificate authentication, negative certificate tests and hardware decoding (p50 0.918 ms, p95 3.318 ms, p99 8.092 ms). Its ordinary desktop workload differs from the controlled synthetic comparison.

Seven Swift tests pass, including independent expected color primaries, neutral levels, video/full range, matrix metadata and shader buffer layout. The native GPU probe runs the actual window fragment shader and Focus compute kernel over three synthetic frames. Across 63,504 sampled color channels, GPU output matches an independent scalar BT.709 limited-range reference within one byte; window and Focus differ by at most one byte. On 57,984 samples with uniform vertical chroma, the former VideoToolbox BGRA output differs by at most two bytes (p99 zero).

The VideoToolbox BGRA reference has a different vertical chroma phase at colored edges: all-sample p99 difference 12, maximum 97. Its NV12 output declares progressive Left chroma. The new renderer follows that attachment (horizontal co-siting, vertical centering); an experimental half-luma-pixel vertical shift matched the former BGRA output but conflicts with the declared sample position, so it was not adopted. The scalar test explicitly checks the declared Left geometry, and the report retains the edge discrepancy rather than claiming byte-identical conversion.

Optimized visionOS simulator and signed device builds pass. Simulator wrong-pin rejection and a fragmented, local synthetic TLS stream pass; the window displays the decoded test pattern. Build 2 was installed and launched on the physical M5 Vision Pro running visionOS 27.0. Peter reports a much smoother desktop, correct colors and much improved cursor movement. He confirms gaze-revealed corner controls, Focus rendering, Crown adjustment and return to windowed mode beside Mac Virtual Display. The default progressive immersion bounces back below its system minimum (observed as 50%); a separate range adjustment follows. These are subjective functional observations, not measured capture-to-photon latency. Device diagnostics confirmed hardware decoding and 3,654 frames in the sampled session.

## Color scope

Conversion uses the actual pixel format’s video/full range and Core Video’s YCbCr matrix and chroma location attachments. Matrix coefficients cover 601, 709 and 2020; absent matrix metadata uses the established SD/HD convention. This is an 8-bit SDR host pipeline: coefficients alone do not implement HDR tone mapping or wide-gamut display management, and no such support is claimed. Progressive chroma positions are handled; the host does not produce interlaced video.

Apple documents [two-plane Metal sampling](https://developer.apple.com/documentation/arkit/displaying-an-ar-experience-with-metal), [YCbCr matrix metadata](https://developer.apple.com/documentation/corevideo/kcvimagebufferycbcrmatrixkey), and [chroma sample locations](https://developer.apple.com/documentation/corevideo/cvimagechromafield/samplelocation). The ARKit sample’s full-range color assumptions are not used for the Windows video-range stream.

The standalone `tests/VideoColorProbe.swift` reads a synthetic SPC1 fixture and reports errors only; it never writes decoded images. Compile it with StreamWire.swift, H264Decoder.swift and VideoColorConversion.swift and pass Desktop.metal as its argument. Its scalar reference requires a progressive Left, BT.709 fixture.
