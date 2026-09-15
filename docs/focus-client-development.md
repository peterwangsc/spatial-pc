# Paired PC to Immersive Mode

The desktop remains the default connection. Its fullscreen
button uses the saved PC's authenticated control endpoint, requests the explicit
Windows Immersive Mode grant if needed, then stops desktop input/capture and prepares the
same host's Apple session. Windows presents its QR and visionOS owns scanning.
The regular Settings page no longer needs an IP/port setup step. The prior
manual fixture remains available only with the `--manual-focus` launch argument.

Returning from either immersive control requests host cleanup and disconnects the
Apple session. Automatic desktop reconnection requires an explicit Return and
an acknowledged, eligible desktop listener. Control loss, failed cleanup and
canceled setup leave an explicit reconnect action instead. No input or desktop
connection starts just because a control socket opens.

The control client has one reader, exact bounded JSON frames, request correlation,
TLS 1.3, the existing saved CA/hostname/leaf checks, no tickets or automatic
failover, and a heartbeat. Bonjour resolution reads service addresses only and
never connects to the advertised desktop port. The fixed control port is 47994;
the returned Apple IP must match the authenticated numeric control endpoint.

## Current development evidence

- Debug, Release, Lab, and the legacy XR configuration include XR by default,
  with visionOS 26.4 as the minimum and the Apple session entitlement.
  Configuration differences control diagnostics/optimization, not XR availability.
- 47 XCTest cases and 12 Swift Testing cases pass, including nine new wire
  methods and seven resolver cases with no real DNS/desktop connection.
- The actual compiled Swift transport passed permission, fake prepare,
  heartbeat, stop and cleanup against reviewed Windows-host Python f96c004
  running on Mac loopback. A wrong saved server-leaf pin was rejected.
  Disposable fixture identity was imported into process memory only.
- The actual Swift client also passed against the packaged Windows dispatcher
  through a TLS-opaque SSH forward, including pin rejection and EOF cleanup.
  The physical XR flow still needs testing.
  The scene is the existing plain XR development scene; this does not turn the
  Windows desktop into XR content. Apple trust remains separate, and this
  development XR media path remains unencrypted.

Keyboard and mouse bugs remain active work.

## Physical debugging, September 15

Build 27 produced two distinct outcomes. One attempt crashed in Apple's checked
continuation cancellation, reached from our terminal-status observer through
`XRConnectionGate.stop()`. A later attempt completed QR authorization and received
host media readiness, then returned an Apple disconnect error. The latter attempt
cleaned up and the user confirmed desktop Reconnect worked.

Build 28 addresses the cancellation path. A terminal status during connect no
longer cancels that pending operation. The system connection runs in an owned,
awaited task; explicit cancellation uses the SDK disconnect API. The gate retains
ownership until connect and cleanup return, including a second disconnect for
late success. A terminal status is checked again after connect returns. Nine
lifecycle regressions pass; physical verification of this correction is pending.

The post-readiness disconnect remains unresolved. Host runtime readiness and
scene process creation do not establish successful OpenXR initialization or
headset frames. Apple and Windows now keep bounded stage metadata so subsequent
attempts can locate that failure without retaining credentials or desktop content.

Build 29 retains the cancellation correction and adds presentation appearance,
disappearance, and bounded underlying-error context. An independent source review found no further mismatch
between its automatic presentation setup and the Apple sample.

The PC completed a separate non-rendering probe using the installed Manager 6.1.0,
Runtime 6.2.3, and runtime configuration. OpenXR instance, system, graphics
requirements, D3D11 device, and session creation succeeded. A loopback TLS 1.3
handshake presented a certificate matching the Manager fingerprint. The probe
substituted its own scene executable, sent no application payload, and cleaned up
all owned children. These results do not validate the installed renderer, Apple
authorization or signaling, AVP network reachability, or streamed frames. No
additional physical test or successful XR connection is claimed.

The next physical build-29 test again failed after QR approval, with a fixed
keyword match for `configuration` in Apple's error description and no immersive
presentation event. Windows recorded successful instance/system/graphics
requirements calls before cleanup, but no device/session or frame result.
Reconnect restored the desktop, and neither build-29 attempt crashed.

Build 30 adds the immersive scene role and default window role from Xcode's
Foveated Streaming template to `UIApplicationSceneManifest`. The built manifest
matches the template; the signed build and streaming entitlement checks pass.
This tests a concrete configuration omission, not a confirmed explanation of
the disconnect. The SwiftUI progressive style and streaming code are unchanged.

Physical build-30 tests, including a new enrollment, still failed after QR
approval. The earlier `configuration` keyword did not recur, which does not
establish a causal effect of the manifest change. The latest matched Windows
attempt completed D3D11 device, OpenXR session, reference-space, view and swapchain
initialization, began the session, and entered its first frame wait. No completed
frame or negative API result was recorded before cancellation. The headset
reported an unclassified public disconnect reason; reconnect restored the desktop.

Build 31 preserves the public `DisconnectReason.errorDescription` from the first
non-app-initiated status and connect error before cleanup, instead of relying only
on keyword matches and NSError bridging. Descriptions distinguish absent, empty,
and oversized values; known peer values, URLs, IP addresses and token-like values
are redacted before a 1,024-character cap. The existing error view shows the first
available redacted description. No private SDK state or error userInfo is dumped.
Fourteen diagnostic/lifecycle tests and the signed visionOS build pass. This is a
diagnostic change, not a connection fix; physical validation remains pending.
