# Optional NVENC 12.2 candidate

This is an isolated native candidate, not a live-host replacement. The ordinary
build and product launcher continue using Media Foundation. No pairing, TLS,
input, framing, topology, or desktop-color conversion code changes are included.

## Build and header provenance

The adapter requires the exact 12.2 ABI. `build_nvenc.cmd` requires an explicit
external SDK root containing `Interface/nvEncodeAPI.h` and checks SHA256:

`4677a397e3ec5300a6b38bf49cba42bb63a922ab26f24bc63a05ed08857cba16`

The compile-only copy came from FFmpeg's `nv-codec-headers` mirror, tag
`n12.2.72.0`, peeled commit `c69278340ab1d5559c7d7bf0edf615dc33ddbba7`:
[exact header](https://github.com/FFmpeg/nv-codec-headers/blob/c69278340ab1d5559c7d7bf0edf615dc33ddbba7/include/ffnvcodec/nvEncodeAPI.h).
It carries NVIDIA's 2010–2024 copyright and permissive MIT-style license grant;
the original notice is intact. The header is not vendored in this repository.

**Provenance gate remains open:** compare this copy with the original NVIDIA
12.2.72 SDK archive, record archive/header hashes, and retain its applicable
license before treating it as an official-source-verified dependency. The
[NVIDIA archive](https://developer.nvidia.com/video-codec-sdk-archive) links to
the authenticated [12.2.72 download](https://developer.nvidia.com/designworks/video-codec-sdk/secure/12.2/video_codec_sdk_12.2.72.zip).
That download required login in this environment. No SDK sample code or full
SDK archive has been redistributed, and no 13.x structures have been edited to
pretend to be 12.2.

From the repository root, with Visual Studio 2022 Build Tools installed:

```bat
windows\host\build.cmd release .local\capture_mf.exe
windows\host\build_nvenc.cmd PATH_TO_SDK_ROOT
windows\host\test_nvenc.cmd PATH_TO_SDK_ROOT
.local\capture_nvenc.exe --nvenc-api-version
```

The last command only loads the System32 DLL, checks its exported maximum API
and 12.2 function table, and exits. It does not create D3D resources, an encoder
session, a capture, or a listener. The other test commands run no GPU work.
Only a later, separately coordinated capture may select `--encoder nvenc` with
`--stream`; omission or `--encoder mf` preserves MF. Legacy/no-pool/unthrottled/
disabled-codec-configuration combinations are refused for NVENC. The default
build does not link, load, or require NVENC and rejects that selection.

## API and capability gates

`LoadLibraryExW` uses `LOAD_LIBRARY_SEARCH_SYSTEM32` exclusively for
`nvEncodeAPI64.dll`; no application directory, cwd or PATH resolution. Required
version is `(12 << 4) | 2`; all function pointers used by the adapter are checked.
Once an actual candidate capture is coordinated, initialization opens the same
D3D11 device used by the converter and checks H.264, NV12, async-event support,
dimension limits and successful P1/ULL preset/configuration initialization.
These device-specific capability gates are implemented but have not been run.

Initialization failures can fall back to MF only after successful cleanup and
before the SPC1 hello or any encoded frame. Cleanup failure fails closed; it does
not continue with an uncertain session. There is no midstream backend change.

## Requested settings

| Control | Candidate request |
| --- | --- |
| Codec / input | H.264 High, 8-bit NV12 4:2:0, progressive |
| Preset / tuning | P1 / ultra low latency |
| Rate | 60 fps; existing source display dimensions, even and bounded |
| Rate control | CBR, average and maximum 20,000,000 bit/s |
| GOP / IDR | 60; first frame forced IDR; repeat SPS/PPS |
| Reordering | frameIntervalP=1, B references disabled, zeroReorderDelay=1 |
| Lookahead / AQ | Disabled; depth zero; spatial and temporal AQ disabled |
| Multipass | Disabled |
| VBV / initial VBV | 333,333 bits (one nominal frame) |
| Intra refresh / temporal SVC / filler | Disabled |
| Color | Same existing D3D11 conversion; VUI remains unspecified |
| Resource pool / queue | Four I/O slots, one encode in flight |

These are explicit requests over a queried preset, not bitstream readbacks.
Zero B-frames, SPS/PPS/profile/range behavior, actual output size, and unchanged
client decoding must be verified in a later bounded encode. No latency, quality,
bandwidth, memory improvement or frame-rate claim follows from compilation.

## Ownership and cancellation

Each owned D3D11 NV12 default/render-target texture is registered once. Conversion
finishes through an EVENT query before mapping/submitting to NVENC. Completion
events are awaited before locking the bounded bitstream, delivering through the
unchanged `EncodedSink`, unlocking, unmapping, and reusing a slot. Four textures
are allocated, but this first candidate deliberately submits only one frame at a
time. There is no unbounded queue and no overlap-performance claim.

Owner cancellation is checked after producer completion, after map and after
encoder completion. Already-submitted work drains before unmap; canceled output
is discarded. A scope guard drains queued producer work before DXGI ReleaseFrame
even if cursor/conversion work throws. Normal shutdown sends EOS, waits, then
unregisters/destroys resources, events and encoder in order. A failed unmap or
cleanup is not retried. An ambiguous submitted operation never frees/reuses the
surface while hardware may still own it.

Producer and completion waits have 5-second limits. A separate 6-second watchdog
bounds vendor calls and synchronous output writes. A wedged/uncertain operation
terminates **only the current opt-in capture process**, exit 72, before unwinding
its DXGI lease; this is fail-closed process containment, not a claim that a vendor
call can be canceled. The UI/backend and unrelated processes are not targeted.
Initialization/cleanup failure retains uncertain resources until capture-process
exit. Ordinary cancellation uses orderly completion/cleanup instead.

## Validation and later measurement

Both optimized x64 configurations compile. Twelve no-GPU ownership/order cases
cover success, cancellation at each ownership boundary, producer/map/submit/
completion/delivery/unmap failures, no repeated failed unmap, and producer drain
before DXGI release on conversion error. Settings fixtures check overrides and
five invalid size/rate cases. The deadline fixture verifies disarming/rearming
and exit 72 of its own deliberately stalled hidden child. These tests validate
application ordering; they do not emulate or validate an actual NVIDIA driver.

The System32 version-only query on the existing driver returned maximum 194
(0xC2, API 12.2), with no encoder session. Hardware H.264/NV12/capability queries,
actual encode behavior, EOS/cancellation under driver load, and fallback on an
unsupported adapter still require coordinated hardware validation.

For the later matched 60fps comparison, preserve resolution, cursor content,
motion workload, color conversion, bitrate, driver, client, and transport. Log
the selected backend, API/capabilities, settings and binary hashes. Record
producer wait, NVENC submit, completion wait, acquire-to-output age, pipe wait,
frame pacing and client decode separately. `write_sample_ms` and the legacy
`encode_submit_avg_ms` encompass the complete NVENC transaction including its
wait/output, unlike MF's asynchronous WriteSample; do not compare those two
fields as encoder service time. Do not compare across a driver update without
rerunning both backends under the same driver. Verify bitstream and lifecycle
before interpreting performance. This work makes no CloudXR compatibility claim.

API lifecycle reference: [NVIDIA NVENC programming guide](https://docs.nvidia.com/video-technologies/video-codec-sdk/13.0/nvenc-video-encoder-api-prog-guide/).
The versioned 12.2 header, rather than newer guide-only features, controls this ABI.
