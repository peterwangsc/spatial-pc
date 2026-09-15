# Focus lifecycle source

NvCloudXR.cs and ProcessJobObject.cs derive from Apple StreamingSession,
upstream b8a3b7502f5f3a46553f957ec0a841c6b27ab069 (MIT; full license included).
ContainedChild.cs and FixturePolicy.cs reuse the reviewed local hardening at
861daa8cbaeefc1594ef8856cf45018d068e5251. Original notices are retained.

FocusBridge.cs is the same Spatial PC host's optional private IPC child. No WPF
sample application, registry identity or separate product is installed. No vendor
runtime binaries are included. P/Invoke signatures are from Apple's pinned
sample, not verified against the unavailable exact Manager6.1.0 header yet.
That ABI comparison, PE signature/hash inventory and native behavior are gates.

Runtime/scene processes join kill-on-close jobs atomically at CreateProcess.
The helper waits for backend ownership before any vendor load, uses an isolated
pipe and explicit manifest per child, and gives vendor operations deadlines.
Child-job cleanup precedes RPC disposal; timeout exits only this contained helper.
The exact vendor's process breakaway/service behavior and token/certificate
semantics remain untested. No claim of encrypted media follows from TLS signaling.
