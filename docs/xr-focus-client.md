# XR Focus integration — development configuration

This adds Apple's Foveated Streaming path to the existing Spatial PC app target.
It does not create another app, replace the installed build, or change the desktop
stream protocol. The `XR` build configuration enables `SPATIALPC_XR` and requires
visionOS 26.4. Debug, Lab and Release keep the existing Focus implementation.

The first integration uses a plain PC-rendered OpenXR scene. It does not yet
render the Windows desktop inside CloudXR or promise compatibility with VR games.
The Windows host must finish its matching runtime integration before live use.

## Development operation

In the XR configuration, Settings contains a temporary Focus validation section
with an explicit PC IP address and session-management port (default 55000).
Connect in Focus allows testing without first launching desktop capture. Once
configured, the desktop's existing expand button selects this XR path as well.
This address entry is development tooling; the intended product selects the
host's supported Focus path internally.

Entering XR stops the desktop input session and disconnects desktop streaming.
Every app-owned desktop connection entrypoint is blocked while XR is connecting,
connected or shutting down. Cancel remains reachable while connecting. A local
Return control requests XR shutdown; desktop streaming resumes only after the
session operations settle, when a desktop session was active before entry.
An unexpected immersive dismissal also requests shutdown. Session-status
observation belongs to the model rather than to a potentially closed window.

The connection gate rejects overlapping attempts. A 30-second connection timeout
requests cancellation and disconnect; it does not claim to forcibly cancel an OS
operation. Reconnect stays blocked until outstanding system calls return. A late
successful connect receives another disconnect before the gate becomes idle.
Errors shown by this integration are fixed strings; no tokens, raw framework
errors, tracking data, or streamed pixels are logged.

## Build

Use the existing paired Apple build dependencies described in the project setup.
Generate the project using the verified team and owned bundle identifier in your
environment, then build the existing `SpatialPC` scheme with configuration `XR`.
The only new entitlement is `com.apple.developer.foveated-streaming-session`.
Signing may require updating the provisioning profile for that existing app ID.

```sh
python3 scripts/generate_project.py
xcodebuild -project visionos/SpatialPC.xcodeproj -scheme SpatialPC \
  -configuration XR -sdk xros -destination 'generic/platform=visionOS' \
  -derivedDataPath .local/xr-device build
swift test -c release
```

Do not install an XR configuration over a user's current app during source review.
Use a coordinated hardware phase and preserve the current app/data for regression.

## Validation and limits

September 15, 2026: Xcode 26.5 / visionOS 26.5 SDK.

- XR device compilation and development signing passed. App and provisioning
  profile both contain the Foveated Streaming entitlement. Build 21 is uninstalled.
- Ordinary Release device compilation passed.
- Existing 38 tests plus five new fake-session cancellation/race/timeout tests
  passed. These do not invoke Foveated Streaming or prove its native cancellation.
- The installed simulator SDK cannot import FoveatedStreaming. A compile-time
  availability guard builds the existing app UI and explicitly marks XR streaming
  hardware-only in the validation section. An initial simulator launch reached
  the home UI but reported a Keychain load error; a local simulator signing
  experiment subsequently failed to relaunch. Simulator UI acceptance is pending.
  Neither attempt tests XR streaming, gaze, tracking or performance.
- Read-only source review found and corrected overlapping desktop reconnect,
  missing pre-immersion cancellation UI and lost deferred foreground restoration.

No CloudXR media session, game, physical-headset input, foveation measurement,
latency comparison or network protocol test was performed in this client pass.
Native view-presentation cancellation, interruption, scene dismissal and return
to the desktop still require physical validation with the exact Windows candidate.

The framework's session-management/pairing path is distinct from Spatial PC's
existing SPP2/mTLS pairing. No saved desktop credentials are exported or repurposed.
Exact CloudXR media protection remains unresolved; this prototype does not inherit
or advertise the existing desktop stream's encryption guarantee. Windows runtime
signatures, redistribution permissions, and exact GPU/runtime support remain
separate prerequisites. No proprietary CloudXR binaries are bundled here.

References: [Apple Foveated Streaming](https://developer.apple.com/documentation/foveatedstreaming),
[NVIDIA's system-framework integration](https://docs.nvidia.com/cloudxr-sdk/latest/usr_guide/foveated_streaming/getting_started.html).
