# Immersive Mode integration

Spatial PC uses Apple’s Foveated Streaming framework in the same visionOS app
that displays the windowed Windows desktop. XR is included in every standard
build configuration, with visionOS 26.4 as the minimum. The legacy XR
configuration remains an alias for existing build scripts.

A saved PC connects windowed by default. Its fullscreen control opens an
authenticated control connection to the same host, obtains its Immersive Mode
permission if needed, stops the desktop session, and prepares Apple’s session.
The host presents Apple’s QR when requested. Desktop device pairing and Apple
system pairing remain separate trust operations in the same user flow.

The first content is a plain PC-rendered OpenXR scene. It does not render the
Windows desktop inside CloudXR or establish compatibility with arbitrary games.

## Connection ownership

The AppModel owns the session, control client, status observation, and cleanup.
Only one media transition may be active. Explicit Return requests host cleanup;
automatic desktop restoration requires an acknowledged, eligible desktop listener
and completion of Apple disconnect. After an error, Reconnect restores desktop.

The gate retains an outstanding system connection until it actually returns.
The Apple SDK operation is shielded from parent-task cancellation; the SDK’s
explicit disconnect operation requests shutdown. Terminal status during connect
is reconciled after the awaited result, and late success is disconnected again.
This avoids the checked-continuation cancellation path observed in build 27.

Bounded diagnostics record fixed stages, known Apple reason categories, numeric
error codes, and a validated error-domain identifier. They do not retain QR,
credentials, arbitrary error payloads, tracking data, or desktop content.

## Build and checks

Use the project’s existing pairing build dependencies and set the verified team
and owned bundle identifier in the environment before generating the project.
The app needs `com.apple.developer.foveated-streaming-session` in its signed
entitlements. Normal Debug and Release configurations include it.

```sh
python3 scripts/generate_project.py
xcodebuild -project visionos/SpatialPC.xcodeproj -scheme SpatialPC \
  -configuration Release -sdk xros -destination 'generic/platform=visionOS' \
  -derivedDataPath .local/device build
swift test --filter XRCoreTests
```

The simulator SDK cannot import FoveatedStreaming; the compile-time framework
availability guard permits UI testing there. Actual XR streaming requires hardware.
The explicit `--manual-focus` developer fixture remains available for isolated
endpoint testing; ordinary setup does not expose or require it.

See [the paired flow and current evidence](focus-client-development.md) for the
transport checks, physical outcomes, and unresolved post-readiness disconnect.
Apple’s system stream uses its own transport; desktop mTLS claims do not apply to
CloudXR media. No proprietary CloudXR binaries are committed in this client tree.

References: [Apple Foveated Streaming](https://developer.apple.com/documentation/foveatedstreaming),
[NVIDIA system integration](https://docs.nvidia.com/cloudxr-sdk/latest/usr_guide/foveated_streaming/getting_started.html).
