# Paired PC to XR Focus — development flow

The desktop remains the default connection. In the XR build, its fullscreen
button uses the saved PC's authenticated control endpoint, requests the explicit
Windows Focus grant if needed, then stops desktop input/capture and prepares the
same host's Apple session. Windows presents its QR and visionOS owns scanning.
The regular Settings page no longer needs an IP/port setup step. The prior
manual fixture remains available only with the `--manual-focus` launch argument.

Returning from either Focus control requests host cleanup and disconnects the
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

- XR configuration compiles with the same app ID and Apple session entitlement.
- 47 XCTest cases and 12 Swift Testing cases pass, including nine new wire
  methods and seven resolver cases with no real DNS/desktop connection.
- The actual compiled Swift transport passed permission, fake prepare,
  heartbeat, stop and cleanup against reviewed Windows-host Python f96c004
  running on Mac loopback. A wrong saved server-leaf pin was rejected.
  Disposable fixture identity was imported into process memory only.
- Native Windows interoperability and the physical XR flow still need testing.
  The scene is the existing plain XR development scene; this does not turn the
  Windows desktop into XR content. Apple trust remains separate, and this
  development XR media path remains unencrypted.

Keyboard and mouse bugs remain active work. This is development, not a release
candidate or a production-launch readiness claim.
