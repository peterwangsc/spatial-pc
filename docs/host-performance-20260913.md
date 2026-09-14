# Windows host performance pass — 2026-09-13

The native pacing change reduced local encoded-frame delivery p95 from **34.76 ms to 20.21 ms**, and p99 from **41.39 ms to 22.43 ms**, while maintaining approximately 60 frames/s. This is a preliminary host measurement, not capture-to-photon latency or an integrated Vision Pro result.

## Environment and method

Windows 11 Home build 26200; Intel i9-13900KF (32 logical processors); NVIDIA GeForce RTX 4070, 12,595,494,912 dedicated video bytes, driver 566.14. The selected transform reports **NVIDIA H.264 Encoder MFT**, D3D11-aware, with the hardware marker present. No driver changes.

1920×1080 primary physical display, 144.001 Hz; capture target 60 FPS; H.264 configured at 20 Mbps. The visible D3D11 test draws a scrolling checkerboard and moving bars, synchronized to display vblank. The first three seconds keep pixels static but continue presenting; this phase is **not an idle-capture test**. The workload and reader discard encoded image data immediately. Only counts, timestamps, slice types and resource timings are recorded.

One sequential run per variant, 18 capture seconds for instrumented variants and approximately 20 seconds for the preserved original. Steady FPS excludes the first four seconds. Percentiles below include warmup. These are useful first-pass comparisons, not repeated-trial statistical estimates. Other normal desktop processes remained running.

The first exploratory run used Python's coarse Windows monotonic clock for arrivals. Its arrival percentiles are excluded here. The reported runs use `perf_counter`; native measurements use QPC. GPU timestamp intervals are collected asynchronously and explicitly flushed after conversion so the ending query does not wait for the next frame's submission.

## Results

| Variant | Steady FPS | Pipe interval p50 / p95 / p99, ms |
| --- | ---: | ---: |
| Preserved original binary | 59.92 | 15.85 / 34.76 / 41.39 |
| Optimized build, legacy pacing/allocation, instrumentation | 60.01 | 15.88 / 31.91 / 37.38 |
| Precise pacing and encoder configuration, fresh surfaces | 59.99 | 16.68 / 19.46 / 21.21 |
| Precise pacing and pooled surfaces | 59.99 | 16.68 / 20.21 / 22.43 |

Pooling primarily removes allocation work; it did not beat the fresh-surface variant's delivery tails in this single run. The main demonstrated pacing improvement comes from the timer and deadline handling. Compiler optimization alone was insufficient.

| Native stage | Legacy p50 / p95 / p99, ms | Pooled p50 / p95 / p99, ms |
| --- | ---: | ---: |
| Acquire to encoded callback | 4.919 / 11.299 / 13.370 | 6.250 / 10.245 / 12.104 |
| Surface acquisition | 0.356 / 0.808 / 1.065 | 0.013 / 0.025 / 0.068 |
| Cursor/conversion CPU submission, including flush | 0.559 / 1.270 / 1.691 | 0.463 / 1.072 / 1.523 |
| Cursor/conversion GPU elapsed interval | 0.229 / 1.028 / 3.582 | 0.260 / 0.481 / 1.299 |
| WriteSample call | 0.020 / 0.061 / 0.141 | 0.018 / 0.066 / 0.151 |
| Pipe write and flush | 0.083 / 0.160 / 0.215 | 0.086 / 0.169 / 0.247 |

GPU query intervals include GPU scheduling; they are not exclusive GPU utilization. Device-wide `nvidia-smi` snapshots during motion included the workload and all other applications, so they are not attributed to the encoder alone.

The pooled run delivered all 1,081 input samples, with zero pending at completion and peak pending 1 (legacy peak 3). DXGI coalesced 1,529 source updates because the source refreshes at 144 Hz and capture targets 60 Hz; this count is not encoded frames dropped. Native CPU time was 12.25% of one logical core pooled versus 5.81% legacy in these runs. Thus this pass demonstrates smoother pacing and cheaper allocation, **not lower overall CPU usage**. See the accompanying JSON for all counters, stages, sample counts and maxima.

The acquisition timestamp is taken after `AcquireNextFrame`. It excludes earlier compositor/capture waiting, network transit, decode, scanout and optics. It must not be presented as input latency. Sample timestamps use a session-relative monotonic clock, not synchronized host/headset wall clocks.

## Implementation and bounds

- Release builds use `/O2 /DNDEBUG`; a debug build and side-by-side output path remain available.
- A high-resolution one-shot Windows waitable timer maintains cadence and discards deadline debt after idle or backpressure. It does not busy-spin or change global timer resolution.
- An MF video sample allocator starts with four samples and stops at eight. Samples remain owned until downstream releases them; output views are cached separately. Tests hold all eight samples, verify distinct textures and initialized NV12 lengths, observe exhaustion, then verify capacity returns after release.
- Capture admits at most four undelivered input samples. Existing sink-writer throttling remains enabled by default. `--unthrottled` is an explicitly bounded experimental option and was not selected or benchmarked for deployment.
- Metadata statistics are bounded. The callback retains shared ownership of its statistics during asynchronous teardown.
- No encoded H.264 access units are discarded. Acquisition coalesces source updates when capacity is unavailable.
- Transport retains TLS 1.3 mutual authentication, paired-client certificate pin checking, ALPN and existing SPC1 size bounds/framing. It adds timing counters, hidden capture children and an independent session-deadline timer to terminate a capture child even when pipe reads are blocked.

The NVIDIA transform already reported low-latency mode enabled and GOP 60. Setting low latency, GOP 60, CBR and mean bitrate 20,000,000 succeeded with readback. The B-picture property rejected setting with `0x80070057` and did not implement reading (`0x80004001`); observed Annex B slice headers contained only I and P slices in every motion run (pooled: 19 I, 1,062 P). This verifies the tested stream, not every encoder/driver configuration. Reported encoder buffer-size property remained 21,993,846. No direct NVENC rewrite was justified by this first measurement.

## Validation and limits

Native resource/pacing tests pass, including idle-deadline rebasing. All seven existing GPU cursor cases pass. Seven Python protocol/metrics tests pass.

Real native pipe readers paused for 0.5 and 6.5 seconds, then resumed. Both sessions exited normally, retained at most three and two pending samples respectively, drained all inputs in timestamp order and left no pending samples. Sink-writer throttling can block `WriteSample` before the explicit capacity timeout executes. The capacity wait is therefore **not a universal five-second native stall timeout**. The transport owns the five-second socket timeout and session termination; consumers of the standalone pipe must likewise own process deadlines.

A separate loopback listener with fresh test credentials delivered 316 native frames over authenticated TLS 1.3. Missing-client and untrusted-host tests were rejected before capture started. On an uncontrolled ordinary desktop, sender `sendall` p50/p95/p99 was 0.127/0.231/0.446 ms; Python used about 1.36% of one logical core. This validates local transport behavior, not Wi-Fi or an AVP that decodes slowly. Actual LAN send backpressure and combined headset performance remain for the coordinated live test.

The timing run used candidate SHA-256 `4122f17eb5d9d0234d8748c60df65b6ee1817426bfda2f3b923abfce540b1388`. Subsequent final-source changes retain callback statistics through asynchronous teardown, make timestamp conversion overflow-safe and clarify the capacity-timeout error. Native/unit checks pass, and a second authenticated TLS test delivered 302 frames with the exact final binary while repeating the certificate rejection checks; the JSON separately identifies that binary. The original binary remains preserved (SHA-256 `5042957d22fb027704c7b032f6d68cf8c8ca12d85b2cdf1c0b982199d8d9ff02`). No production release or driver installation was performed.

## Reproduction

From the repository root in the interactive Windows session:

```bat
windows\host\build.cmd release .local\candidate.exe
windows\host\test_host.cmd
windows\host\test_cursor.cmd
python -m unittest discover -s tests -p "test_*.py"
python tests\host_backpressure.py --capture .local\candidate.exe --directory .local
```

Before running the visible motion test, coordinate the viewing pause. Put `host_motion.exe`, the candidate and the preserved original in a benchmark directory with the original under `baseline/capture_probe.exe`, then run:

```bat
python tests\host_perf.py --directory .local\benchmark --candidate candidate.exe --seconds 18 --variants original legacy_release no_pool optimized
```

For the loopback TLS smoke test, install the existing lab script's `cryptography` dependency in a local virtual environment, choose a free loopback port and a fresh output directory:

```bat
python tests\host_tls.py --directory .local\tls-test --capture .local\candidate.exe --port 47992
```

Private test enrollment stays under ignored `.local/`. Do not commit certificates, keys, binaries or desktop video.

API references: [Windows high-resolution waitable timers](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-createwaitabletimerexw), [MF sample allocator limits](https://learn.microsoft.com/en-us/windows/win32/api/mfidl/nf-mfidl-imfvideosampleallocatorex-initializesampleallocatorex), [MF low-latency mode](https://learn.microsoft.com/en-us/windows/win32/medfound/mf-low-latency), [sink-writer throttling](https://learn.microsoft.com/en-us/windows/win32/medfound/mf-sink-writer-disable-throttling), [D3D11 Flush](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-id3d11devicecontext-flush).
