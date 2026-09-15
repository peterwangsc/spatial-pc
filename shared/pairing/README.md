# Shared short-code pairing primitive

The thin C wrapper uses unmodified BoringSSL SPAKE2 at the exact commit in `boringssl.lock.json`. Both platforms must use that pin and its default cofactor correction. This is BoringSSL's Ed25519 variant; it is not claimed wire-compatible with RFC 9382 or ADB pairing. No deterministic RNG, legacy scalar flag, private-key export or custom curve math is added.

On an Apple Silicon Mac, run `python3 scripts/build_pairing_apple.py macosx xros xrsimulator`, then `swift test` and the usual Xcode build. Dependencies and generated static libraries are local and ignored. Xcode links only the wrapper and required crypto objects; Network.framework still owns TLS. The supplied script builds arm64 and disables assembly for a common portable baseline. `--source` can reuse an existing clean checkout at the exact pin. Do not commit generated binaries or private signing settings.

The header defines the shared ownership ABI. `create` receives exactly four ASCII PIN bytes and generates a 32-byte public message. `finish` consumes a context, including malformed-peer failure, and returns the full 64-byte shared key; it is not authentication until the complete transcript's role-specific confirmation verifies. Destroy every handle; cleanse caller-owned raw key buffers. Managed-language/opaque-library memory erasure is not guaranteed. No secrets go in argv or diagnostic output.

Windows builds an app-local DLL with `SPATIAL_PAKE_SHARED` and loads the exact installed path via ctypes, without replacing Python's TLS libraries. It must export only the wrapper ABI and retain dependency/license data in its manifest. See `docs/pairing-v2.md` for transcript, admission and approval rules.

Native wrapper checks: set `SPATIAL_PAKE_LIBRARY` to the locally built shared wrapper and run `python3 tests/test_pake_native.py`. These six checks exercise native ownership, matching/wrong PINs, roles/context and malformed peer data. Swift tests exercise the same primitive plus protocol and client budget. Required integrated tests and remaining acceptance are recorded separately; build success alone is not a pairing pass.
