# SPI1 authenticated input — development implementation

The Windows lab host can explicitly opt into pointer, button, wheel and physical keyboard input from its authenticated paired client. Default startup remains view-only. A client must negotiate input and receive positive capability confirmation, then start control through a user interaction in the displayed PC desktop. Connecting or hovering does not start control. Consumer pairing and an installer remain separate work.

## Wire contract

TLS 1.3, mutual certificate validation, exact pair fingerprints, ALPN `spatialpc/1` and all SPC1 video records remain unchanged. Client hello optionally includes `"input":{"version":1}`. An explicitly enabled host with a ready native helper replies with:

```json
{"input":{"version":1,"enabled":true,"wire":"SPI1","recordBytes":24,"maxEventsPerSecond":240,"heartbeatMS":500,"leaseMS":2000}}
```

Absent or unsupported capability means view-only and no reverse input traffic. Input uses the reverse direction of the same authenticated connection. Every record is 24 bytes, network byte order: `magic[4]="SPI1", type:u8, flags:u8, reserved:u16=0, sequence:u32, a:i32, b:i32, c:i32`. The network sequence starts at 1 and strictly increases without wrapping. Unknown types/flags, invalid fields, replay, rate overflow or malformed framing close the session and initiate release. Event contents and coordinates are never logged.

| Type | Operation | Flags | a / b / c |
| --- | --- | --- | --- |
| 1 | Move | 0 | x / y / 0; x and y each 0..65535 |
| 2 | Button | bit 0 = down | x / y / button; 1 left, 2 right, 3 middle |
| 3 | Wheel | 0 | vertical / horizontal / 0; each -1200..1200 |
| 4 | Physical key | bit 0 = down; bit 1 = repeat, down only | HID usage / 0 / 0 |
| 5 | Start control | 0 | 0 / 0 / 0 |
| 6 | Stop control | 0 | 0 / 0 / 0 |
| 7 | Heartbeat | 0 | 0 / 0 / 0 |
| 8 | Committed text (negotiated textVersion 1 only) | 0 | Unicode scalar / 0 / 0 |

Pointer coordinates describe video content, excluding letterboxing and window chrome, with top-left origin, right-positive x and down-positive y. Button messages include the location; the native helper sends movement before the button change in one `SendInput` batch. Wheel units are 120 per notch, positive vertical up/away and positive horizontal right.

Keyboard usages are USB HID keyboard-page 0x04..0x45, 0x49..0x65, and 0xE0..0xE7. They map to physical scan codes; Windows keyboard layout determines characters. Modifiers are separate left/right HID events. Repeat requires an already held key; ordinary duplicate down/up is idempotent. PrintScreen, ScrollLock, Pause and media/system usages are excluded. Retained state is bounded to 32 ordinary keys, eight modifiers and three buttons. No clipboard, paths or command execution messages exist. Committed keyboard text uses the optional extension below.

### Committed text extension

System keyboards may deliver committed text instead of physical key presses. A client can add integer `textVersion:1` inside its input offer. The input-enabled host adds the same field to its positive capability only for that exact supported integer; absent, boolean, string, floating-point or unsupported values leave text unavailable while retaining negotiated pointer/HID input. Type 8 is rejected without text negotiation. The native helper also requires the per-session `--enable-text` argument, supplied by the server only after negotiation.

Each type 8 record contains one scalar U+0020 through U+10FFFF excluding U+007F..U+009F and the surrogate range U+D800..U+DFFF. Flags and b/c must be zero. Newline, tab and backspace use existing HID taps. Text records require active control, count against the existing rate/queue bounds, and never coalesce. Stop cancels pending text with other pending actions. The client must avoid duplicate printable HID and committed-text delivery for one keystroke; physical HID remains available for shortcuts.

The helper converts a scalar to one or two UTF-16 units, sending each down/up pair in a single batch of two or four `INPUT` structures with `wVk=0` and `KEYEVENTF_UNICODE`. Windows delivers `VK_PACKET`, which an application's normal message translation turns into `WM_CHAR`; see [KEYBDINPUT](https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-keybdinput). A batch is serialized, not transactional. On partial injection, the helper conservatively owns both possibly-down units (maximum two) and fails the session; cleanup sends only corresponding Unicode key-ups and retains ownership if release fails. Completed text retains no held units. Existing UIPI, desktop, lease and bounded process cleanup restrictions remain. No scalar or text content is logged.

Native fake-injector tests cover scalar boundaries, exact BMP/surrogate sequences, every partial batch return count and failed-release retry. Authenticated fixtures verify exact capability negotiation, rejection without negotiation and balanced text injection using no real capture or `SendInput`. An authorized dedicated Windows window additionally received the exact Latin, CJK and supplementary UTF-16 `WM_CHAR` sequence from the real helper, with four balanced key downs/ups and clean EOF exit. Run the guarded harness with `--text` only during a coordinated test window. This establishes Windows character delivery; physical AVP keyboard behavior and application compatibility still require integration checks.

## Ownership, bounds and release

The opt-in server accepts and handshakes one connection at a time. An asyncio event loop owns all TLS reads and writes; no SSL object is called concurrently from multiple threads. Video reads only its next bounded access unit after the preceding write drains. Video records retain the 16 MiB maximum and five-second network stall timeout. Async stream backpressure pauses the capture pipe instead of discarding reference frames. See Python's [event-loop transport API](https://docs.python.org/3/library/asyncio-eventloop.html#asyncio.loop.connect_accepted_socket).

Input has a 240 events/s token bucket with burst 120, a 4 KiB reader backpressure threshold, a 128-record application queue and a low native-pipe write watermark. The reader threshold is not a strict cap on TLS/OS buffers; the application parses one fixed 24-byte record at a time. Only adjacent pending moves are replaceable; buttons, keys and wheel events are ordering barriers. Explicit stop cancels undelivered actions and releases already-held state. This cancellation can create gaps before the native helper, so the helper checks increasing sequence while the network gate additionally checks the initial 1.

The client sends heartbeats every 500 ms while controlling and stop on Back, app inactivity, focus loss, window closure or control-off. Stop returns to view-only; a new explicit interaction starts control again. Start itself never clicks. The host's two-second input lease closes a stale control session. Independently, the native helper polls its local stdin and lease; EOF, expiry, stop, desktop transition and session termination release owned keys/buttons. Teardown closes native stdin and aborts TLS before waiting for child cleanup. It drains and discards child output concurrently with process exit, allows three seconds for graceful cleanup and one bounded second after a necessary kill, and stops the host if cleanup still cannot finish. Capture sessions and the helper have a ten-minute ceiling.

The helper uses the same adapter 0/output 0 physical display selection as capture, checks dimensions and identity rotation, maps through physical monitor coordinates to the virtual desktop, and checks display topology while controlling. DPI awareness is explicit. It rejects starting control while local keys/buttons are already held. It does not reset unrelated keyboard state. See Microsoft's [absolute mouse coordinates](https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-mouseinput), [scan-code input](https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-keybdinput), and [SendInput restrictions](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput).

No elevation or secure-desktop bypass is attempted. `SendInput` can be rejected by UIPI, and Windows does not reliably identify that cause in its return value. New input stops on failure; release is attempted conservatively. Release itself cannot be guaranteed while the OS refuses injection. The active input desktop must remain the normal desktop, and rotated/topology-changing displays require reconnection. This does not claim compatibility with elevated applications, protected games, all keyboard layouts or every hardware pointer.

## Build and validation

```text
windows\host\build_input.cmd
windows\host\test_input.cmd
python -m unittest discover -s tests -p "test_*.py"
python tests/input_tls.py --directory .local/input-tls --fixture .local/input_fixture.exe
python tests/input_tls_flood.py --directory .local/input-flood --fixture .local/input_fixture.exe
```

The TLS fixture has no desktop capture or input injection. It validates mutual authentication, positive negotiation, older-client view-only behavior, duplex video/control, rate/queue parsing, replay/lease rejection and balanced native-engine release counts. The default-host check confirms that offering input does not enable it without the startup flag. Pure native checks cover multi-monitor geometry, click ordering, scan-code mapping, repeat, held-state bounds and injection failure recovery.

A separate, authorized visible native-window test passed using the real helper: pointer position within one pixel, buttons, both wheel axes, modifier/repeat behavior and actual key/button releases after stdin EOF. A second mode left the parent pipe open and silent and verified the native lease released both held inputs within 2.75 seconds. Its foreground guard confines synthetic events to that test window, which closes automatically. The harness counts the repeat field in `WM_KEYDOWN` because Windows can combine repeats into one message. No user input content or desktop images were retained. Build with `windows\host\build_input_window_test.cmd`, then run `.local\input_window.exe ABSOLUTE_PATH_TO_INPUT_BRIDGE` (optionally `--lease`) only during a coordinated test window.

One early transport fixture run failed its frame-count-based lease assertion; its exact scheduling cause was not established. The revised check observes native control admission and applies an explicit four-second wall-clock deadline, and repeated runs pass alongside the independent real-helper silent-pipe test. This is development validation rather than proof of behavior under every OS scheduling or secure-desktop condition.

A separate review reproduced a full-stdout-pipe cleanup defect: asyncio process exit can remain waiting for a paused pipe even after the OS child exits. Cleanup now drains under bounded deadlines and closes the network session first. Two disposable-process regressions exercise full 1 MiB stdout with terminated and graceful children. A full-duplex TLS flood fixture deliberately leaves video unread while a fake held key expires: both native release and observable session closure completed about 2.016 seconds after native admission, with process cleanup also completing. The flood fixture never captures desktop content or calls `SendInput`.

For an explicitly reviewed lab session, add `--enable-input --input-bridge PATH_TO_INPUT_BRIDGE` to the existing host command. Keep the tested capture binary and pairing unchanged.

The reviewed host revision `8e4225d` was then enabled in a coordinated LAN session with the same capture binary and pairing. The Mac control-only probe negotiated SPI1 over TLS 1.3, sent six start/heartbeat/stop records, and received 127 actual desktop video frames, including 25 after stop. It sent no pointer, key or button actions and retained no pixels. Host metadata confirmed six accepted records, no expired lease, native exit 0 and no remaining capture/helper children after disconnect. A separate older-client probe passed certificate rejection checks and hardware-decoded 120 frames on Mac (local decode p50/p95/p99 1.586/2.495/3.120 ms). These are interoperability checks, not a controlled performance comparison or headset latency measurement. Physical AVP pointer, scrolling and keyboard behavior remains pending.
