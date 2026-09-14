# Contributing

Use a branch and pull request for changes. Keep platform work in `windows/` or `visionos/`; coordinate changes to the shared protocol with both clients and include compatibility tests.

For performance changes, describe the workload, hardware, resolution, codec settings, and before/after measurements. Separate stage timings from capture-to-photon latency. Do not claim a performance improvement from a compiler switch or API change alone.

Keep credentials, private recordings, and machine-specific diagnostics out of commits. Do not add tests that require access to a maintainer's hardware, account, or local network.
