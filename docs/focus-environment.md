# Focus environment

Windowed mode stays in the shared space so it can coexist with Mac Virtual Display. Focus uses a progressive ImmersiveSpace with a quiet studio backdrop: one 1024×512 gradient texture, an inward-facing dome, and an unlit floor. There are no per-frame environment animations or dynamic lights. Returning to the window dismisses the environment while retaining the stream.

Progressive immersion lets the system's Digital Crown control how much of the custom environment surrounds the person. At lower immersion levels some passthrough remains visible; full immersion covers it. System safety and interaction overlays remain controlled by visionOS.

The simulator displayed the backdrop with a changing synthetic TLS stream and returned to the window without reconnecting. Both simulator and signed device Lab builds pass. Worn-headset Crown behavior, comfort, display color matching, and gaze-revealed controls still need physical validation. This is a minimal environment, not a finished library of selectable rooms.

References: [Apple progressive immersion](https://developer.apple.com/documentation/swiftui/immersionstyle/progressive), [building an immersive environment](https://developer.apple.com/documentation/realitykit/construct-an-immersive-environment-for-visionos), and [unlit material tone mapping](https://developer.apple.com/documentation/realitykit/unlitmaterial/init(applypostprocesstonemap:)).
