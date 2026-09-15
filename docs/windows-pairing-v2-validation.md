# Windows four-digit pairing candidate

SPP2 replaces the 26-character enrollment code with exactly four uniformly random
ASCII decimal digits, including leading zeros. Existing saved devices retain
SPC1/SPI1 streaming, mutual TLS and exact pins; this change does not reset identity
or change capture, encode, input, transport queues or stream lifetime.

The native PAKE uses the shared Mac-owned spatial_pake C ABI over BoringSSL commit
b780f192ce515ed8ed358f6c0947bd7acce438b9, its Edwards25519 SPAKE2 variant. This is
not RFC 9382 wire compatibility, an independent application audit or FIPS approval.
The Windows DLL statically links the full supported crypto target with
OPENSSL_NO_ASM, static MSVC runtime and private SPATIALPC_BSSL symbol prefix.
Its only four exports are spatial_pake_create/finish/destroy/cleanse, and its only
reported DLL dependency is KERNEL32.dll. It is loaded by absolute installed path
with DLL-directory/System32 search flags, without replacing Python or OS TLS.

Three admitted exchanges per 180-second local code window are counted before any
password-dependent output. EOF, malformed messages, wrong proof and timeout never
refund an attempt. There is one active handshake/pending approval. A valid client
confirmation consumes the window before local approval; approval lasts at most
60 seconds and cannot extend the original expiry. The host also permits at most
five manual window openings per ten minutes, surviving disable/network changes
within a process. Local restart resets this in-memory opening throttle; no remote
operation can restart or reopen it. Four digits bound online guesses to at most
3/10,000 per random window before the separate local approval, not zero risk.

TLS 1.3 uses spatialpc-pair/2 and SPP2 framing. Both sides bind roles, actual peer
leaf, host/window and fresh nonce into the PAKE context, then enrollment key/name,
client nonce and both PAKE messages into full role-separated confirmation.
Credentials are issued only after Windows approval and an expiry recheck at
atomic DPAPI persistence. There is no short-PIN SPP1 fallback or offline PIN MAC.
Client-owned exposure budgets and UX are implemented/reviewed on the Mac branch.

## September 15 validation

- Clean pinned source compiled on Windows with VS 2022/MSVC 19.42, CMake 3.29.5 and
  Ninja 1.12.1; no NASM requirement in this assembly-disabled configuration.
- All six upstream SPAKE25519 tests pass, plus the six supplied shared-wrapper
  tests (leading zero, wrong PIN, context/role, bounds, malformed point, one-use).
- Windows suite: 79 cases, 77 pass; two explicit opt-in checks skipped (assigned
  external-interface IPv6 discovery and eleven-minute idle). No new desktop
  capture or real SendInput; lifecycle tests use dedicated native fixtures.
- 28 focused pairing tests pass, including real loopback TLS IPv4/IPv6, DPAPI
  enrollment/reload, explicit denial, expiry, EOF before/after proof, three-attempt
  and single-handshake limits, replay/reflection/key/name/nonce mutation and
  persistent-per-worker opening throttle. An actual TLS-terminating relay with a
  different leaf cannot create pending approval or enroll a credential.
- Loopback Bonjour preserves stream version 1 and advertises pairingVersion=2 on
  separate pairing discovery; same instance/domain and bounded goodbye cleanup.
- docs/pairing-v2-test-vector.json independently checks exact transcript bytes,
  RFC 5869 HKDF expansion, role HMACs and P256 possession signature. Its messages
  and raw key are explicitly synthetic public fixtures, not deterministic PAKE
  ephemeral generation. Actual cross-Swift/Windows PAKE and hardware pairing
  remain separate integration gates.
- UI compiles and package import check loads the new DLL in isolated Python 3.14.7.
  No UI automation, installation, running-host switch, signing or upload is part
  of these checks. The previously paired physical session remains on its original
  installed package until a separately coordinated switch.

Pin and managed-key buffers are short-lived. The wrapper wipes owned buffers;
complete erasure of managed copies/upstream opaque state is not claimed. Vendor
updates, clean-machine install, cross-platform review and physical SPP2 acceptance
remain required. The owner has no existing Windows publisher certificate/account;
there is no signed/public Windows download. Apple export declarations must be
reassessed for the newly bundled non-OS cryptography by the Mac release owner.
