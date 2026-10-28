# Testing

The complete pre-push gate is `mise run check`. Focused commands include:

```sh
mise run test
mise run test-release-safe
mise run test-tsan
mise run test-ubsan
mise run test-tls
mise run test-tls-tsan
mise run test-consumer
mise run test-consumer-cpp
mise run test-c-abi
mise run test-consumer-cmake-c
mise run interop-official
mise run interop-tls
mise run interop-http2
mise run interop-http2-edge
mise run soak-streaming
mise run coverage
mise run docs-check
```

The [official interop harness](../tests/official/README.md) documents test cases and
scope. Soak tests check correctness and liveness under sustained pressure; benchmarks
measure completed exchanges and latency. Neither alone establishes leak freedom or
a deployment capacity guarantee.

For historical soak configuration, observation phases and reproduction commands, see
the [baseline archive](records.md#streaming-soak) and
[evidence bundle](evidence/streaming-soak-baseline/README.md).

`mise run coverage` uses kcov (or `KCOV_IMAGE`) to produce a Cobertura report under
`coverage/`. CI uploads the report to Codecov.

## Package and ABI regression coverage

`tests/public_api_test.zig` checks public exports and defaults. The raw Zig package
consumer runs unary and duplex lifecycle checks in Debug and ReleaseSafe, plus a
TLS-enabled build. Its sanitizer configurations compile; they do not execute that
fixture under TSan/UBSan. Typed adapters have separate repository tests.

The C++ consumer uses an installed prefix and external Protobuf, compiles public
headers independently, regenerates service glue, and runs client RPC shapes and
ownership/admission checks. Generated server overrides are compiled here; server
runtime behavior is tested in `grpcpp_generated_server_test.cc`.

Package tasks include tracked worktree changes and non-ignored untracked files.
Watchdogs bound runtime checks, and C++ assertions stay active under `NDEBUG`.

`mise run test-c-abi` checks the selected v0.5.0 / ABI 1.6 frozen header against the
current native shared library. Provenance lives in
`tests/consumer/abi/baseline/provenance.json`. It checks exported symbols, signatures,
layouts, enum values and SONAME, then executes an old-header consumer with guarded
option prefixes. Deliberate incompatible fixtures must fail; supported appended
Channel options are a passing control. Native Linux x86_64/ARM64 execution requires
io_uring permission and is not silently skipped.

Baseline updates require explicit selection of a released version and review of
provenance, declaration inventory, extension rules and the consumer. Never refresh
the frozen header from the worktree merely to make a regression pass.

For documentation changes, check internal links and anchors in the static export as
well as type checking and building. Confirm that contributor records are absent from
both generated pages and the search index.
