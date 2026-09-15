# Proposed Spatial PC four-digit pairing v2 — September 15

Frozen Mac/PC contract after PC review, September 15. Existing enrolled devices and SPC1/SPI1 streaming stay unchanged. New pairing supports v2 only, never silently downgrades a four-digit code into v1 HMAC.

## Primitive and distribution
Google BoringSSL SPAKE2 C API, pinned b780f192ce515ed8ed358f6c0947bd7acce438b9. This is its Ed25519/draft variant, NOT a claim of RFC9382 wire compatibility. Both platforms use the same upstream primitive and shared/pairing/spatial_pake.c thin ownership/bounds wrapper. Standard RNG, no test-secret/RNG injection in product. BoringSSL license/notice included; Apple export declaration requires reassessment for bundled non-OS crypto.

## Code and attempt policy
Uniform CSPRNG integer0..9999 displayed zero-padded as four ASCII decimal digits, including leading zeros. Typed as four digits, number-pad preference; no letters/dashes. Three admitted SPAKE exchanges TOTAL per 180-second explicitly user-opened window; count/reserve BEFORE generating/sending server SPAKE challenge. Every exchange gets fresh BoringSSL context/server nonce. No reset on reconnect, cancellation, malformed proof or timeout. Only one active handshake/pending approval. At exhaustion close window; new code needs explicit local action. Limit window openings to five per ten minutes per running host with cooldown that reconnect cannot reset; this in-memory opening throttle survives Disable/Enable/network changes but a local process restart resets it; no remote action can restart the process. Valid client confirmation consumes window before local approval; denial/failure requires new code. Approval at most60seconds and within original window. PIN, keys and proofs are never logged. A four-digit code allows at most3/10000 online guess probability per window before the additional local approval; do not describe it as 128-bit identity authentication.

## Wire
TLS1.3 ALPN spatialpc-pair/2. Records SPP2+u32BE JSON UTF8 byte count 1..16384. JSON version integer2. Same strict duplicate/unknown/size/deadline bounds as v1. On any rejection close TLS; do not depend on rejected envelope. Bonjour pair service remains same instance/domain/port while open, advertises pairingVersion=2; stream protocol version stays1. Unsupported clients receive update guidance, never insecure fallback.

Host challenge exact fields: version,type=challenge,hostId32lowercasehex,windowId16bytes base64,serverNonce32bytes base64,serverMessage32bytes base64.
Context C = actual TLS leaf SHA256(32) || hostID(16) || windowID(16) || serverNonce(32).
Alice identity = ASCII SpatialPC-Pair-v2/client + NUL || C.
Bob identity = ASCII SpatialPC-Pair-v2/server + NUL || C.
Windows role Bob creates using local Bob identity, peer Alice identity. Client role Alice creates local Alice, peer Bob. PIN password is exact four ASCII bytes. Windows sends its SPAKE message in challenge. Client generates its message and processes serverMessage ONCE, receiving64-byte key. No confirmation is computed from PIN itself.

T = ASCII SpatialPC-Pair-v2 + NUL || C || clientNonce(32) || enrollment public P256 point(65) || u16BE name length || exact name UTF8 || clientMessage(32) || serverMessage(32).
Confirmation key K = HKDF-SHA256(IKM=64-byte SPAKE result, salt=SHA256(T), info=ASCII SpatialPC-Pair-v2/confirm + NUL, output32).
Client proof = HMAC-SHA256(K, ASCII client + NUL || T).
Server proof = HMAC-SHA256(K, ASCII server + NUL || T).
Client possession signature = ECDSA-P256-SHA256(ASCII client-key + NUL || T), DER. Key remains Keychain-only.
Client proof record exact fields: version,type=proof,clientNonce,publicKey,name,clientMessage,proof,signature (base64 for bytes).
Windows processes one clientMessage ONCE and frees PAKE state whether confirmation succeeds or fails. Validate point/name/signature/proof, reserve consumed window. Send version2 type=pending serverProof, then explicit Windows approval. Client verifies server proof before displaying approval phase.
Paired record identical credential fields as v1 but version2; client verifies actual TLS leaf/host binding, own key, cert trust/EKU/expiry and commits atomically. DeviceID remains32lowercasehex. No persisted PAKE secrets. Existing mTLS pin/revoke/lease behavior unchanged.

## Required checks
Same/different/leading-zero PINs, mismatched role/context/TLS leaf/nonces/public key/name, malformed points, repeated finish, known-v1 downgrade, attempt budget across disconnects, deadline before persistence, rejection/no approval/no capture, cleanup and secret-free logs. Exchange dynamically between actual Swift wrapper and Windows wrapper, plus independent deterministic transcript/HKDF/HMAC/signature test vector. Test native and simulator, then coordinated hardware re-pair while preserving original working pair until replacement is confirmed.

## Accepted PC review additions
Client maintains its own monotonic three-exchange/180s budget independent of all server/discovery fields. One exchange per explicit Pair action; no automatic retry or endpoint failover with the PIN. Cancel/reopen/retype does not reset an unexpired budget. Exhaustion requires waiting until local budget expiry and obtaining a fresh PC code. Success can end the journey. Entry text clears on submission, cancellation, expiry and failure. Upstream default cofactor handling remains unchanged. Shared wrapper owns terminal contexts and cleans returned raw key storage; no claim of complete managed-memory erasure. Friendly name authenticates submitted data, not a person's verified identity. Separate test must reject a TLS-terminating proxy with changed leaf.

Builds: macOS and arm64 visionOS compiled successfully with exact pin, OPENSSL_NO_ASM=ON, BUILD_TESTING=OFF; CMAKE_MACOSX_BUNDLE=OFF for visionOS crypto-only build. Use full crypto target and linker dead stripping; no math extraction. Wrapper ABI prefix spatial_pake_ (exact supplied header). Windows DLL exports only wrapper; avoid exposing libcrypto. Both platforms prefix BoringSSL symbols as SPATIALPC_BSSL; Swift links the static pairing artifact, never an alternate TLS implementation.

## Mac validation to date
32 Swift checks pass, including the independently Windows-generated transcript/HKDF/HMAC/P256-signature fixture. The six shared C-wrapper checks and all six upstream SPAKE25519 tests pass on macOS. The library builds for arm64 macOS, visionOS and visionOS Simulator; the optimized simulator and development-signed device app build successfully.

The actual Swift PairingClient paired against host source 94cef1b on Mac loopback using the same pinned native primitive. Public fixture PIN0000 accepted,0001 rejected before any credential was saved. The test used real temporary Mac Keychain keys/certificates but an in-memory saved-host archive and test-local diagnostics path; the Windows identity store used an explicit test AES-GCM substitute. Both client identities were cleaned up, the server fixture revoked its enrolled test device and closed. No Windows capture, real input or actual Windows DPAPI was exercised by this Mac-only test. Actual cross-machine and physical v2 acceptance remain pending; existing v1 stored stream identities are unchanged.

Bundled cryptography changes the old OS-only rationale. PAKE is used only for device authentication and its key never encrypts desktop data; TLS remains Apple's implementation. Reassess the final export questionnaire against [Apple guidance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance) and the [BIS authentication exclusion](https://www.bis.gov/learn-support/encryption-controls/cryptography-for-data-confidentiality) before distribution. No new release upload is claimed.
