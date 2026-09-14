# Native desktop input — development validation

The desktop accepts pointer hit testing across the image and provides the system pointer style. An input-enabled host must positively negotiate SPI1 over the existing mutually authenticated TLS session; absent or unsupported input capabilities remain view-only. A click in the desktop starts control and sends a positioned button event. Hover alone cannot start control.

The client sends fixed 24-byte, increasing-sequence records for normalized position, positioned buttons, wheel units, physical keyboard HID usages, start, stop and heartbeat. It uses a bounded 128-event queue, coalesces only adjacent pointer movements, preserves event barriers, and sends at most two records per 1/120 second. A stop replaces queued events and releases host-held state. The host must independently enforce the negotiated lease, authentication, rate and input bounds; the client is not a security boundary for the host.

Input is scoped to the desktop view. Back, Focus navigation, pointer exit, keyboard focus loss, inactive scene and window removal stop control. Keyboard events use the host's layout; no text or clipboard interpretation is attempted. Modifiers are reconciled separately. Indirect mouse and touch/pinch events share the view, with position included in button records. Actual scroll direction, pointer targeting and keyboard behavior require hardware validation.

Validation so far:

- Fourteen Swift tests pass, including golden network-order bytes, signed wheel values, coordinate bounds, invalid events/keys, queue overflow, adjacent-only movement coalescing, stop priority and positive capability negotiation, held-key limits and inferred modifier release.
- Optimized simulator, signed device, and Release simulator builds pass. A loopback-only TLS fixture serves a synthetic 1080p pattern and accepts SPI1 without accessing Windows or injecting OS input. Connection alone produced zero input events. A desktop click produced start/down/up; hardware-keyboard forwarding in Simulator produced key records and returned to zero held keys. Focus navigation produced stop while video continued and the same desktop window remained visible.
- Simulator's gaze/controller emulation did not establish external-pointer hover or scroll behavior; those are not claimed as passed. The physical headset was removed before the pointer-target revision launched. Integrated native Windows input and physical AVP testing remain pending.

The client retains the tested NV12 stream and native-window Focus presentation. Neither the public Release configuration nor an older view-only host silently enables remote control. This development feature does not yet constitute a consumer pairing/permission flow.
