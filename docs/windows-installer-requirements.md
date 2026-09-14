# Windows host packaging handoff

Status: requirements for a future downloadable host, **not an installer-ready announcement**. Mac owns the dedicated `peterwang.tech/spatial-pc` page and website repository. Windows owns the host artifact, installation behavior and release metadata.

## Candidate and dependencies

Target the PRD's Windows 11 x64 host initially. The tested configuration is Windows 11 Home build 26200 with an RTX 4070. Detect capture/encoder support at startup and show a useful unsupported-hardware message; a single NVIDIA result does not establish AMD, Intel, ARM64 or other Windows configurations.

The current candidate is a native C++ capture executable plus the Python TLS lab harness. `dumpbin /dependents` on the tested release executable lists `D3DCOMPILER_47.dll`, `d3d11.dll`, `MF.dll`, `MFPlat.dll`, `MFReadWrite.dll`, `ole32.dll`, `OLEAUT32.dll` and `KERNEL32.dll`; it does not list a separately deployed MSVC runtime DLL. This is an import-table observation, not a clean-machine deployment test. Verify Media Foundation availability, including Windows editions where media components may be absent.

If Python remains in the first installer, bundle an isolated runtime, its TLS dependencies and required notices; users must not install Python, a compiler or packages themselves. Alternatively replace the lab harness with a native transport before packaging. The measured local sender costs do not justify a transport rewrite solely for performance. Do not bundle any developer virtual environment or lab enrollment. `cryptography` currently generates development certificates; that manual script is not consumer pairing.

## Product behavior required before enabling a download

1. A small host UI/background process for enable/disable access, pairing, connected clients, physical display selection, encoder/network status and bounded diagnostics. Start at login must be an explicit preference. Capture runs in the logged-in interactive session; a Session 0 service alone is insufficient for this desktop-capture design. Test lock/unlock, sleep/wake, sign-out and display changes.
2. A release-build pairing flow on both platforms: LAN discovery, explicit code/QR/challenge verification, persistent local device identities, mutual authentication on reconnect and revocation. The current seven-day lab certificates and Debug-only AVP provisioning cannot be the public install flow. Keep identities protected per Windows user and never ship a shared private key.
3. First-run networking that survives DHCP/adapter changes and handles Windows firewall permission clearly. Scope any rule to the host, chosen port and intended local-network profile; avoid broad firewall changes. Remove installer-owned rules during uninstall. Keep capture unavailable to unpaired peers.
4. Reconnect and failure handling with bounded queues, process cleanup and actionable errors. Verify release host and release AVP pairing together on a fresh Windows user/machine. Label a physical-display/view-only preview accurately if remote input, audio and virtual monitors are deferred; those features are not provided by the current candidate. A future virtual-display driver needs its own signing and installation work.

## Installer and signing

Proposed initial delivery: a signed, versioned x64 desktop installer with per-user background execution and narrowly scoped elevation only when installation operations require it. Choose MSIX versus MSI/EXE after testing the required firewall, startup, update and uninstall behavior; the current native executable does not itself require adopting WinUI or the Windows App SDK. Microsoft documents both direct MSIX distribution and conventional desktop installer paths. [Packaging options](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/)

The current candidate is **unsigned**, as checked with `Get-AuthenticodeSignature`. Provision a Windows code-signing identity separately from the Apple developer signing setup. Sign executable payloads and installer, timestamp with SHA-256, and verify the resulting signatures as part of release validation. No signing purchase, credential creation or installer release was performed in this pass. [Microsoft SignTool reference](https://learn.microsoft.com/en-us/windows/win32/seccrypto/signtool)

Test clean install, upgrade, interrupted upgrade/rollback and uninstall. Ensure uninstall stops the host and removes only its own startup entries, binaries and firewall rules. Define explicitly whether paired-device identities are retained for upgrade and whether uninstall offers their removal. Validate the downloaded artifact on a clean Windows 11 machine without development tools.

## Website/release contract

When an installer actually passes validation, Windows will supply Mac:

- Immutable versioned HTTPS artifact URL, ideally attached to a tagged release in the shared public repository.
- Product/version, Windows and CPU requirements, file size, SHA-256 and verified publisher identity.
- Concise setup steps, release notes, supported features and known limitations.
- Exact compatible AVP release/protocol range and rollback/support instructions.

The dedicated page can link to source and explain development status now. Enable a Windows download only after a real signed artifact and its validation record exist. Neither a source ZIP nor the current capture probe should be represented as an installable consumer host.
