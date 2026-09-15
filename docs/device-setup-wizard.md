# Device setup wizard

Add Device presents one stage at a time: prepare the Windows host, choose a discovered PC (or enter an address on a separate page), confirm its four-digit code, wait for verified Windows approval, then Connect. Selecting a discovered PC advances directly; no extra selection confirmation is needed.

The code field follows GolfCore’s confirmation-code design: four large rounded boxes, empty dots, an accent on the active box, and a single native text input for keyboard/paste/deletion/accessibility. Confirm Code is explicit; entering the fourth digit does not spend another pairing attempt automatically.

The AppModel-owned PairingClient, PAKE wire, attempt budget, certificate validation and Keychain persistence are unchanged. Back/Cancel invalidate pending work and clear the entered code. Changing steps cannot reset the attempt budget. Success is shown only after the paired identity has been committed. The previous desktop connection is closed when the new PC becomes selected. Connect uses the existing desktop path; the window opens when a decoded frame arrives, and failures remain visible on the home page.

Content can scroll at larger text sizes while the primary action remains reachable. Local debug simulator fixtures render code, approval, completion and a long-name/error layout without enrollment or desktop connection. They use public fixture data and are not pairing success evidence.

Validation: visionOS XR device and Debug simulator builds pass. Simulator layouts inspected for preparation, GolfCore-style code boxes, approval, completion, and a long PC name/error with the largest accessibility text category. The error page scrolls at that size; Confirm Code remains outside the scroll area. Source review found no blocking pairing lifecycle issue. Actual new-wizard enrollment and input accessibility interaction remain hardware/functional checks. The prepared XR hardware build remains separate until this UI is integrated.

## Remaining unified XR step

The intended product wizard also initiates Apple system QR pairing where required, followed by normal windowed Connect and automatic fullscreen Focus. That host orchestration is not implemented by this UI change. Desktop SPP2 and Apple XR pairing remain separate trust operations; do not claim either replaces the other or that QR is retained across sessions without validation. The existing development XR path renders a plain scene, not a finished XR desktop surface.
