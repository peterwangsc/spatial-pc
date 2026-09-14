# Host LAN validation — 2026-09-13

The first optimized Windows host streamed the real desktop over mutually authenticated TLS 1.3 to the Mac team's native decoder and visionOS simulator. This report records **host-side** evidence for source `364eb060ebfbd2220ea72e0d2948b0b51744099c`, native SHA-256 `a00e2aa2d43c667fa9bfa55cf075a3f8e95957c48241ab7c2930d5adc67fa04f`. It precedes the separate [cursor optimization](host-cursor-performance-20260913.md).

## Controlled motion interval

The D3D11 workload ran for 90.0045 seconds, presenting 12,959 frames on the 144.001 Hz primary display. Native capture targeted 60 FPS. The simulator connected late in that workload; the last saved transport snapshot while motion remained active contains **1,497 sent frames over 25.028 seconds**. No competing local capture ran. The remaining simulator session continued after the workload returned to the ordinary desktop and is reported separately.

| Host metric during the saved motion interval | p50 / p95 / p99, ms | Maximum, ms |
| --- | ---: | ---: |
| Acquire to encoded callback | 6.270 / 9.925 / 11.772 | 98.980 |
| Pipe read wait | 16.498 / 20.214 / 22.016 | 26.851 |
| TLS send call | 0.129 / 0.294 / 0.469 | 120.586 |
| Send timeline drift relative to initial PTS | 1.450 / 5.167 / 7.171 | 118.601 |

The independently emitted native snapshot spans 25.345 seconds: 1,501 admitted inputs, 1,500 outputs, peak pending 2 and one pending at the snapshot. It is not an end-of-session drain check. The native and transport reporters sample adjacent boundaries; their counts are not identical frame sets. Native pipe write peaked at 103.44 ms and `WriteSample` at 90.52 ms. The isolated send stall propagated upstream; the common sub-millisecond send duration does not establish a stall-free connection. These counters do not identify the cause of that individual LAN/client scheduling stall.

Relative send drift measures change from the first timestamp and does not reveal constant buffering latency. Acquisition-to-encoded timing excludes time before desktop acquisition, network, decode and presentation. No capture-to-photon or physical headset latency is measured here.

## Complete mixed-desktop session

The same connection ultimately sent 16,811 frames over 413.163 seconds, including ordinary desktop periods and the motion interval. TLS send p50/p95/p99 was 0.122/0.224/0.983 ms, maximum 120.586 ms. The ordinary desktop produces uneven DXGI updates, so the whole-session average is not a controlled motion throughput benchmark. Nor is a sender frame count evidence that each frame was decoded or presented.

Mac's [client report](client-performance.md) and native probe log record a separate 600-frame ordinary-desktop hardware-decode pass: all 600 decoded, p50/p95/p99 2.846/4.404/5.719 ms. That probe did not overlap the controlled motion interval above. Mac also confirmed certificate-negative passes and a real-Windows simulator window → Focus → window round trip with more than 14,000 decoded frames. The physical headset was off during these dinner tests. The earlier physical streaming demonstration used an earlier build.

Only metadata was retained. The [JSON companion](host-lan-validation-20260913.json) includes exact counters and maxima, without credentials, desktop pixels, network addresses or device records. Pairing remains controlled lab provisioning; consumer pairing, input forwarding, installer delivery and release validation remain separate work.
