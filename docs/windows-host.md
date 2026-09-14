# Windows host release candidate

The consumer Windows host is under review. Public download is gated on publisher
signing, clean-machine installation and Windows-to-visionOS release integration.
The source build is not a signed public installer.

## Setup and lifecycle

Windows 11 x64, one active physical display, a supported hardware H.264 encoder,
and a Private LAN shared with Vision Pro are required. The demonstrated hardware
is an NVIDIA RTX 4070; this is not an all-GPU compatibility claim. Windows Forms
uses the .NET Framework 4.8 family included with Windows 11. Python and its pinned
dependencies are bundled privately; no Python or developer tools are installed
globally.

Windows N editions also need Microsoft's Media Feature Pack. ARM64 emulation is
outside the initial Windows package. The native binaries import Windows media,
graphics and input libraries; the package includes the runtime DLLs required by
the bundled Python extensions.

Install per user, open Spatial PC, select your Private network, then choose
**Set up network**. The administrator prompt permits only this installation's
runtime on TCP47990/47991 and UDP5353, Private profile, LocalSubnet, with no edge
traversal. It does not change your network category or enable/disable Windows
Firewall. Enterprise firewall policy can still prohibit connections.
If Windows already has an inbound block rule for this runtime on a Private
network, setup preserves it and asks for administrator review. The application
does not silently delete or override an existing block to enable sharing.

Network selection supports assigned IPv4 or IPv6 addresses, including scoped
IPv6 link-local addresses. TCP binds only the selected address and family;
Bonjour advertises its A or AAAA record with distinct pairing and stream ports.
Local TLS/pairing/revocation tests pass on both loopback families, and discovery
resolved the selected Windows interface's IPv6 AAAA record. These checks do not
replace physical Vision Pro acceptance on an IPv6-only network.

Discovery shutdown explicitly aborts its own datagram transports after goodbye
messages. This handles an outstanding-write close issue in the pinned Windows
Python3.14.7 Proactor runtime. The adapter uses zeroconf0.151.3 engine transport
handles and must be rechecked when that dependency changes; tests assert every
owned discovery socket is closed, rather than relying on an arbitrary delay.

Choose **Enable access**, then **Pair a new device**. Enter the displayed one-time
code on Vision Pro and approve the named request on this PC. The code expires
after three minutes and at most five failed attempts; local approval cannot
extend that window. Client private keys remain on Vision Pro. Repeat connections
use mutual TLS and exact certificate pins. See [pairing-v1.md](pairing-v1.md).

Access always starts disabled. The selected network and paired identities persist
under the current Windows user's DPAPI protection. Closing the window leaves the
tray application running; **Disable access** or **Quit** stops sharing and releases
input. Startup at sign-in is opt-in and does not enable sharing automatically.
Changing away from the selected Private network disables access. Revoking the
connected device immediately ends its session, releases held input and rejects
its next connection before desktop capture starts.

Production sessions remain connected until disconnect, disable, revocation,
certificate expiry or a watchdog failure. The lab entry point retains its
ten-minute session maximum. Both retain the two-second input lease; an incomplete
input record also expires after two seconds. Idle viewing does not claim control
and does not force periodic reconnection. Native diagnostics rotate within
256 KiB per child. Physical Space and Tab require visionOS Full Keyboard Access
to be off. Audio, clipboard, additional virtual displays and internet relay are
outside this MVP.

Production capture waits for a local readiness byte sent only after assignment
to the backend's kill-on-close Windows Job. The owner pipe also stops idle
capture on EOF, including a parent failure before Job assignment. Input uses its
separate EOF cleanup so it can release owned keys and buttons. Native continuous
lifetime is explicit; default lab command lines keep their original time limits.

Accepted TCP peers enable keepalive after 10 idle seconds, with 2-second probe
intervals and 3 unanswered probes. This lets Windows detect a vanished peer even
when a static desktop emits no frames. Socket-option readback and healthy idle
connections are tested; physical network-loss recovery still needs device
acceptance. These are per-connection settings, not system-wide network changes.

Update and uninstall ask only this user's Spatial PC UI to quit, then wait for
bounded cleanup. Uninstall removes this installation's firewall rules (with
administrator permission if configured) and its own sign-in entry. Protected
pairing data is retained for reinstall; installation does not silently rotate an
identity or import lab credentials. Removing a saved PC on Vision Pro and revoking
it on Windows is the supported way to end that device's access.

## Build and distribution gates

`windows/package/build-bundle.ps1` builds the Windows UI and native binaries and
assembles official Python3.14.7 with hash-pinned wheels. Supply the official x64
embedded runtime archive, pinned wheelhouse, a build-only Python with pip, and the
matching zeroconf source archive. The script validates archive hashes, uses only
local hashed wheels and writes a file/hash manifest. The LGPL component remains
replaceable, with corresponding source and notices included.

`windows/package/build-installer.ps1` verifies all manifest files and rejects extra
files before compiling Inno Setup6.7.3. The current output is explicitly named
`unsigned-test`. Never publish it as ready. The bundle excludes lab provisioning,
test fixtures, certificates, private keys, captured media and developer runtimes.

Release requires a clean reviewed source commit, valid Authenticode signatures
from the verified publisher for Spatial PC executables and installer, trusted
timestamping, exact artifact hash/size, a clean Windows11 install/upgrade/uninstall
test without developer tools, and authenticated consumer pairing/reconnect/input
integration with the release visionOS client. Do not bypass certificate checks or
describe a self-signed certificate as public publisher trust.

No Windows code-signing identity or clean Windows VM is available in the current
development environment. Local install/reinstall/uninstall testing is useful but
does not substitute for that clean-machine gate. No installer has been uploaded.
