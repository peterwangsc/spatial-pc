# Spatial PC

A native Apple Vision Pro client and Windows desktop streaming host in one repository.

**Early development.** Live, encrypted, single-display streaming has been demonstrated on a physical Vision Pro. Consumer pairing, a Windows installer, remote input, audio, and robust reconnection are unfinished. There are no public app binaries yet, and no measured end-to-end latency claim. The project name is provisional.

## Project layout

- `visionos/` — SwiftUI windows, optional immersive workspace, VideoToolbox decoding, and Metal/RealityKit presentation.
- `windows/host/` — C++ DXGI capture, GPU cursor composition and NV12 conversion, Media Foundation hardware H.264 encoding, and a temporary Python TLS transport harness.
- `docs/protocol.md` — shared wire format and security boundaries.
- `tests/` — protocol validation, native decode probe, and GPU cursor tests.
- `scripts/` — project generation and local lab validation.

Host and client protocol changes should be reviewed together. Platform implementations can use separate branches and pull requests.

## visionOS development

The current project has been built with Xcode 26.5, the visionOS SDK, and the Metal toolchain. The minimum deployment target is visionOS 2.0; some display manipulation uses visionOS 26 APIs.

```sh
python3 scripts/generate_project.py
open visionos/SpatialPC.xcodeproj
```

The generated project uses a placeholder bundle identifier and no signing team. For a physical device, supply your own registered identifier and team:

```sh
SPATIAL_PC_TEAM=YOUR_TEAM_ID SPATIAL_PC_BUNDLE_ID=YOUR_REGISTERED_BUNDLE_ID python3 scripts/generate_project.py
```

Choose a simulator or provisioned Vision Pro in Xcode and run the `SpatialPC` scheme. Actual desktop streaming currently requires the Debug-only lab provisioning described in the [protocol notes](docs/protocol.md). Release builds exclude that lab client; they are not a complete remote desktop product.

## Windows development

Use Visual Studio 2022 Build Tools with the C++ toolchain and Windows SDK. The current script expects the default Build Tools installation path.

```bat
windows\host\build.cmd
windows\host\test_cursor.cmd
```

Capture requires an active interactive Windows desktop and a compatible hardware H.264 encoder. It currently selects the first output on the default graphics adapter. The executable can emit a local H.264 stream or record a short local probe; see its usage output. Recordings contain desktop content and must stay out of version control.

The lab transport requires Python and locally generated pairing credentials. Credential generation uses the `cryptography` Python package. The host requires a paired client certificate and TLS 1.3. This is a development harness, not an unattended production service.

## Validation

```sh
swift test
python3 -m unittest discover -s tests -p 'test_*.py'
```

On Windows, `windows\host\test_cursor.cmd` validates GPU cursor composition. Capture, encode, networking, and headset presentation need hardware testing; simulator timings do not establish headset performance.

## Security and distribution

Never commit pairing credentials, private keys, signing certificates, provisioning profiles, personal desktop recordings, or device logs. Generate distinct credentials for your own development environment. Public source does not grant access to someone else's PC; each connection still requires authenticated pairing.

The planned Windows host download page is [peterwang.tech/spatial-pc](https://peterwang.tech/spatial-pc). Installer and App Store distribution are separate milestones.

## License

MIT. See [LICENSE](LICENSE). Third-party SDKs and platform tools retain their respective terms.
