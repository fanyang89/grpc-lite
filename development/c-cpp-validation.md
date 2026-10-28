# C/C++ validation notes

User integration starts in [the C/C++ guide](../docs/c-cpp-api.md).

## Released C ABI baseline

The selected regression baseline is v0.5.0 / ABI 1.6. It does not automatically move
to the latest release. The old-header/current-library check covers 56 exported
functions, 10 value structures, signatures, callbacks, field layouts, enum values,
feature bits and `libgrpc_lite.so.1`. Only Channel and Server option structures may
grow; their released prefixes must not shrink.

Accepted old option extents on Linux x86_64/ARM64:

| Options | Extents in bytes |
| --- | --- |
| Channel | 40 (jitter), 48 (logger), 56 (header limit/full baseline) |
| Server | 56 (buffers), 64 (logger), 72 (connections), 80 (preface), 88 (idle), 100 (streams), 104 (full baseline/padding) |

Absent fields receive finite defaults. ABI encodes `(major << 16) | minor`; baseline
major is 1 and minor must be at least 6. Product versions are separate. This check
does not establish every runtime behavior, compiler/platform ABI or C++ compatibility.

## Generated-C consumer harness

`tests/consumer/run_cmake_c.sh <asset.tar.gz> <asset.tar.gz.sha256>` archives source
HEAD, verifies the supplied artifact, and builds the copied bounded-executor example
with Protobuf discovery disabled. It runs success, overload and shutdown cases along
with separate typed checks requiring Protobuf. The isolated consumer rejects visible
Zig and runs without network. `GRPC_LITE_KEEP_E2E=1` preserves logs.

The trusted test container uses a scoped seccomp profile: a vendored,
commit-and-SHA-256-pinned Moby default allowlist plus `io_uring_setup`,
`io_uring_enter` and `io_uring_register`. Default-deny and unrelated rules, network
isolation and the nonroot user remain. There is no privileged/unconfined fallback,
extra capability or daemon-wide change. See [provenance and tests](../tests/consumer/seccomp/README.md).
This is not a deployment sandbox recommendation. The outer sandbox and host must also
permit io_uring. Failures are not skipped; `GRPC_LITE_NETWORK_ISOLATED=1` callers
must provide the permission themselves.

`mise run package-transpiled-c` followed by the harness validates a locally packaged
exact artifact, not a published release. Published-release testing must supply the
downloaded asset/checksum and matching tagged source, recording source commit,
checksum, architecture and logs. No published-release validation follows from local
packaging alone.

`mise run test-consumer-cpp` packages and installs the native project, resolves the
installed protobuf component, regenerates sources and runs the C++ examples.
