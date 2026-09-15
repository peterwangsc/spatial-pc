# Focus lifecycle source

NvCloudXR.cs and ProcessJobObject.cs derive from Apple StreamingSession,
upstream b8a3b7502f5f3a46553f957ec0a841c6b27ab069 (MIT; full license included).
ContainedChild.cs and FixturePolicy.cs reuse the reviewed local hardening at
861daa8cbaeefc1594ef8856cf45018d068e5251. Original notices are retained.

FocusBridge.cs is the same Spatial PC host's optional private IPC child. No WPF
sample application, registry identity or separate product is installed. No vendor
runtime binaries are included in public source. P/Invoke signatures have now
been checked against the user-supplied Manager6.1.0 header SHA256
540b0b918c38e2ce824fe07d096d81a52855c17153a7f10bedf0d15f66d33627.
The token is an unsigned byte buffer with an explicit output length, not a
StringBuilder. Native/managed status sizeof16656 and offsets3/264/272 agree.
Actual runtime behavior remains a separate coordinated gate.

Runtime/scene processes join kill-on-close jobs atomically at CreateProcess.
The helper waits for backend ownership before any vendor load, uses an isolated
pipe and explicit manifest per child, and gives vendor operations deadlines.
Child-job cleanup precedes RPC disposal; timeout exits only this contained helper.
The exact vendor's process breakaway/service behavior and token/certificate
semantics remain untested. No claim of encrypted media follows from TLS signaling.

The optional QR renderer is QRCoder1.6.0, NuGet net40 DLL SHA256
5ae2792c76262943a4e34140bbd64b2aa7d9ed5c5822680c00d9eaa322412680,
the same dependency as Apple's pinned sample. Its full MIT license is included
as QRCODER-LICENSE.txt, retrieved from the upstream v1.6.0 tag. No DLL is committed.
https://raw.githubusercontent.com/codebude/QRCoder/v1.6.0/LICENSE.txt

User-supplied Manager ZIP SHA256
11b13a5b3414094fbaded0cba78844ce1552fc138dfa1f01fe0dee345ac02fe9
and Runtime6.2.3 ZIP SHA256
1d372ae4b8d98dda16b467707067e506a964f2a2a3054de20d66aab5b752fb31
were inventoried privately. All19 packaged PE/SYS/catalog signatures were Valid.
The same February25,2025 NVIDIA EULA is supplied in both archives; its SHA256 is
5388ce3a919f218e37d9b0573444634ae1f49a5c76bbba7320db98b581a19cc4.
This inspection is not public redistribution clearance or runtime acceptance.

Private scene staging uses the no-opaque-extension Apple derivative fixture
861daa8cbaeefc1594ef8856cf45018d068e5251, executable SHA256
ae1691acab8d6e38e9ad4f58797e72c1da7980440122d1ae13b8ce52e686dacb.
The unmodified x64 OpenXR.Loader1.0.6.2 NuGet dependency has SHA256
f7d6eb54c79bd923e9f008b81b89d4b0b5893fd33599e9591ff62becba936dac.
Its package nuspec declares Khronos Group and Apache-2.0; full license included.
The private staging script requires these exact artifacts; it does not fetch or
build a new scene implicitly. Source and runtime acceptance remain separate.
