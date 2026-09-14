# App Store preparation

The consumer release is being prepared as version 1.0.0. This document is submission material and a readiness record; it does not mean the app is uploaded, approved, or available. Build 11's intermediate version 0.1.0 signed archive and App Store export succeeded. The final 1.0.0 artifact must be built and verified after integration.

## Draft listing

Name: **Spatial PC** (provisional until App Store Connect reservation and collision review).

Subtitle: **Your PC, in your space**

Category: Productivity.

Description:

> Bring your Windows PC into Apple Vision Pro as a desktop window. Resize and place it beside your other apps, or enter Focus to adjust the environment around your screen with the Digital Crown.
>
> Connect to a saved PC with one action. Use a supported pointer and physical keyboard, or open the floating Vision Pro keyboard for text entry. Pairing requires a one-time code and approval on your Windows PC.
>
> Spatial PC requires its companion host on a Windows 11 x64 PC, an active physical display, a compatible hardware H.264 encoder, and both devices on the same private local network. Initial hardware validation used an NVIDIA RTX 4070. Audio, clipboard sharing, internet access, multiple monitors and a headless virtual Windows monitor are not included.
>
> Physical Space and Tab require visionOS Full Keyboard Access to be off. The floating keyboard remains available. Download the host and read setup instructions at peterwang.tech/spatial-pc.

Support: https://peterwang.tech/spatial-pc/support

Privacy: https://peterwang.tech/spatial-pc/privacy

Marketing/download page: https://peterwang.tech/spatial-pc

The download reference must not be used in a submitted listing until the signed installer is actually available and validated.

## Review notes to finalize

This is a remote desktop client for a user-owned PC on the same LAN. Software shown in the stream executes on that PC. There is no hosted cloud desktop, remote catalog, in-app store, account registration, advertising, or subscription.

Review requires the Windows companion on supported hardware. Provide the exact signed installer URL, hash, version, and setup steps. Use a fresh pairing; no private lab credential may be given to reviewers. Apple may require a demonstration video or specific hardware for features that are difficult to reproduce. Record only a dedicated synthetic/test desktop after consent and preparation, never a user's ordinary desktop.

Complete the age-rating, accessibility, motion, availability, pricing and review-contact fields from the actual final product and verified account information. No age rating, accessibility certification, or App Review acceptance is inferred here.

## Encryption and privacy basis

The visionOS binary uses only Apple operating-system cryptography: Network/Security TLS, Keychain, Security P-256 signatures, and CryptoKit SHA-256/HMAC. It embeds no third-party cryptographic implementation. The custom pairing message format composes these standard OS primitives; it does not implement a new cipher. Accordingly, `ITSAppUsesNonExemptEncryption` is false for the visionOS app's documentation declaration. This is separate from the Windows host's bundled Python/OpenSSL distribution obligations. Reassess if cryptographic dependencies change.

The privacy manifest declares app-local preferences (`CA92.1`) and elapsed-time measurement (`35F9.1`). There is no tracking or automatic off-device diagnostic collection. App Store privacy answers must continue to match the final binary and website policy.

## Pending validation and account steps

- Consumer Windows package to Release client enrollment, discovery, mTLS stream, reconnect, revoke and input lifecycle.
- Physical production-build regression after consumer pairing; current physical success used the earlier development enrollment.
- IPv6-only/local-accessory compatibility testing. Network.framework is address-family agnostic, but the current Windows listener/discovery is IPv4-specific. Do not assume NAT64 reaches a LAN host or mark this checked from ordinary IPv4 testing.
- Signed Windows installer with clean-machine lifecycle validation and a verified publisher; immutable HTTPS artifact metadata.
- App Store Connect sign-in, creation of the app record for the already-owned bundle identifier, actual name reservation and final collision review.
- Final archive/export, App Store validation/upload, TestFlight processing and beta regression, screenshots from the real final UI, then App Review.

## Official references checked September 14, 2026

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) — privacy policy, IPv6 and remote desktop provisions.
- [App Review](https://developer.apple.com/app-store/review/) — support/privacy links and review access for special hardware.
- [Export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance) and [encryption declarations](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations) — OS cryptography and documentation.
- [Required-reason APIs](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype) — manifest reasons.
- [IPv6-only networks](https://developer.apple.com/support/ipv6/) — actual testing and local accessory considerations.

App Store name availability, trademark rights and App Review acceptance are separate questions. The working name is not a claim of trademark clearance. Microsoft-prefixed names such as Windows Virtual Display and Windows Virtual Desktop are not being used as the proposed listing title.
