# Sparse-input encoder timing investigation

Ordinary-desktop LAN samples have acquire-to-encoded p95 around 35 ms, versus about 10 ms during controlled motion. In the exact cursor candidate's ordinary-desktop snapshot, submit-to-encoded p95 was 34.579 ms, `WriteSample` p95 0.044 ms and capacity wait effectively zero. The aggregate observations place most of this age after submission, but cannot determine whether output waits for the next input, a DXGI/D3D11 operation, or independent encoder scheduling. Common TLS send calls are much shorter; occasional transport stalls remain separately recorded.

`--trace-events` prepares that distinction without changing pacing, encoder settings, ownership or the wire protocol. It is disabled by default. It retains at most 8,192 events in memory, counts omitted events, performs no per-event I/O, and emits one metadata JSON record to stderr only after normal finalization. Events include capture wait entry/return/timeout, acquisition, write entry/return, encoded callback and pipe delivery. Frame PTS associates events across threads; relative QPC ticks preserve ordering. Acquisition timestamps are recorded retroactively and sorted by time at export. No pixels, cursor coordinates or certificate data are included.

Build a **separate diagnostic binary**; preserve the active lab host and wait for the coordinated physical-viewing pause before capturing. Run a bounded ordinary/sparse desktop sample with `--stream --seconds 20 --trace-events`, draining and discarding the framed output through the existing harness. A reader must let the capture finalize normally to obtain its trace; terminating a live session does not guarantee export. Do not redirect the binary stdout stream to a retained file. The trace limit covers the beginning of a long session, not a rolling tail.

Analyze the stderr metadata with:

```text
python tests/analyze_frame_trace.py path/to/encoder.log --output path/to/analysis.json
```

The analyzer counts callbacks arriving inside a capture wait, before the next write, or at/after the next write. It reports signed output-minus-next-write offsets, source submission gaps and output age. A cluster just after the next write would support further investigation of input-dependent output; callbacks during an ongoing capture wait would show that at least those outputs can progress independently. Neither observation alone proves a particular driver or transform mechanism. Trace overhead and sparse source behavior need recording with any run.

The diagnostic binary builds. CPU-only checks cover disabled output, cross-thread QPC ordering and bounded concurrent recording; analyzer fixtures distinguish independent and next-input-aligned output and reject unordered traces. **No diagnostic capture has run yet:** the user resumed physical headset viewing, and the existing tested host remains unchanged.
