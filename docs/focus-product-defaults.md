# Desktop and Focus in Spatial PC

Normal Spatial PC launches expose desktop, XR Focus and authenticated Focus control. No XR feature flags, separate development configuration, or separate product are required. The old package-local development-defaults.json is no longer read or generated. Start Menu and sign-in launches use the ordinary executable.

Startup validates the installed runtime inventory but does not start CloudXR, a scene, capture, input, pairing or a QR window. Access remains an explicit user action. Enabling access opens the desktop and authenticated control listeners. Devices still pair normally, and each device needs explicit Focus permission; Apple system QR pairing remains separate. Disable access and revocation retain their existing cleanup behavior.

A missing or invalid Focus runtime is an installation/setup error, shown in Windows Settings and reported through runtimeConfigured=false to the client. It does not remove desktop pairing. Runtime hashes, inventory, path containment and native ownership checks remain in place.

Normal network setup covers exact installed Python paths for TCP47990/47991/47994/55000 and UDP5353, plus installed CloudXrService for TCP48322 and the documented video/pose UDP ports. The existing Private/LocalSubnet restriction and explicit-block preservation still apply; no audio/microphone ports are added. This source change does not modify the narrower rules used by an already-running physical test.

Focus-control v1 framing and capability values remain wire-compatible. Historical `development-only` media-security and `plain-scene-development` content values still describe the current unencrypted XR transport and scene; they are not feature switches. This UI/default change does not claim encrypted XR media or replace Apple pairing with desktop mTLS. Matching client wording should describe unavailable runtime as an installation issue rather than asking users to enable a hidden feature.

The isolated test-only --development switch still selects disposable state and alternate desktop/pairing ports. It is not needed for any product capability and is not used by normal shortcuts.
