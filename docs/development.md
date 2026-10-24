# Development

## Toolchain

```bash
mise install
mise run bootstrap
```

The repository pins Zig and supporting tools through mise. CMake and Ninja build pinned
upstream C dependencies.

## Validation

Run the complete local release gate before pushing:

```bash
mise run check
```

It covers formatting, workflow lint, Debug and ReleaseSafe builds, package consumers,
ThreadSanitizer, C undefined behavior detection, TLS, gperftools, official gRPC interop,
and public HTTP/2 framing suites.

Useful focused tasks:

```bash
mise run build
mise run test
mise run test-release-safe
mise run coverage
mise run test-tsan
mise run test-ubsan
mise run test-tls
mise run test-tls-tsan
mise run test-consumer
mise run test-consumer-cmake-c
mise run test-consumer-cpp
mise run transpile-c
mise run package-transpiled-c
mise run check-transpiled-c
mise run check-release-version
mise run test-release-version
mise run prepare-network-deps
mise run prepare-tls-deps
mise run prepare-gperftools
mise run build-gperftools
mise run test-gperftools
mise run fmt
mise run ci-lint
mise run interop
mise run interop-official
mise run soak-streaming
mise run interop-tls
mise run interop-http2
mise run interop-http2-edge
mise run gen-proto
mise run gen-grpcpp
```

CI runs core tests on Linux x86_64 and arm64 in Debug and ReleaseSafe modes. Required
x86_64 jobs instrument Zig, libxev, and nghttp2 with ThreadSanitizer and C undefined
behavior detection. Runtime interop and vendored HTTP/2 edge cases run on both
architectures. The soak workflow retains extended unary runs and adds a native
cleartext x86_64 streaming smoke on relevant pull requests and extended scheduled runs.

The authoritative compatibility matrix lives in
[the official interop guide](../tests/official/README.md).

## Streaming soak

`mise run soak-streaming` reuses the official `FullDuplexCall` service with a dedicated
grpc-go driver. Initial coverage is **native Linux x86_64, ReleaseSafe, cleartext IPv4,
grpc-go client → grpc-lite server**, one connection and one persistent bidi stream.
It does not claim native grpc-lite client, TLS/mTLS, ARM64, C/C++ bundle, sanitizer,
resource plateau, or performance coverage. Runtime validation of this new harness is
pending; the existing unary interop results are not streaming-soak evidence.

```bash
mise run soak-streaming                         # smoke: 10s traffic, 300s overall
STREAMING_SOAK_MODE=extended mise run soak-streaming  # 600s traffic, 1200s overall
STREAMING_SOAK_DURATION_SECONDS=60 STREAMING_SOAK_TIMEOUT_SECONDS=360 \
  STREAMING_SOAK_SEED=123 mise run soak-streaming
```

The overall GNU `timeout` includes focused peer compilation, harness unit tests,
startup, traffic and cleanup; it sends TERM, then KILL after five seconds. The runner
verifies GNU coreutils identity, preferring `/usr/bin/timeout`, then `/bin/timeout`,
then the `timeout` executable on PATH; it does not use incompatible mise shadows.
If none is compatible, it records a fresh diagnostic and failure status before any
build. The selected executable is logged; PATH is not rewritten. On shared validation
hosts hold the exclusive lock for the **whole** invocation (including builds):

```bash
flock -x /home/fanmi/tmp/pi/grpc-lite-validation.lock mise run soak-streaming
# Likewise wrap extended runs and the pre-push `mise run check` in this lock.
```

`STREAMING_SOAK_MODE` is `smoke` or `extended`; duration/timeout are positive integer
seconds (at most five digits), and timeout must exceed duration + 30s. Seed is 1–9
decimal digits, default `47`. Workload `bidi-slow-large-v1` deterministically varies
request/response sizes from 1 MiB through 1 MiB + 65520 bytes using the seed and
message index. Each batch independently sends two large requests, each requesting
eight responses; their encoded sum exceeds the peer's 8 MiB outbound capacity within
one handler callback. The consumer pauses for 150ms, then delays 10ms before each of
the 16 responses. Fixed 65535-byte grpc-go flow-control windows disable adaptive growth. All batches share the same stream, repeat for at least the
configured duration (and at least twice), then drain and half-close with a 30s RPC
allowance. Batch count depends on machine speed; the seeded message sequence and
pause/drain pattern do not.

A passing run requires exact ordered response sizes/types/zero bodies, no missing or
extra responses, OK terminal EOF, and at least two server `WouldBlock` observations
and receive resumptions. Those opt-in counters live only in the existing official
peer's handler; they are not transport telemetry. Port zero avoids fixed-port collisions.
The runner traps failure/signals, terminates and reaps its peer/client, and bounds cleanup.

Logs under `.zig-cache/official/streaming-soak/{harness,build,server,client}.log` are
truncated per invocation. They record configuration, architecture, seed/workload,
progress, terminal status, pressure/recovery counts and exit code; failure prints log
tails. Only synthetic zero payloads are used, and payload bodies/metadata/credentials
are not logged. CI uploads logs even on failure (14-day retention). The existing soak
workflow runs smoke on relevant PRs, extended mode weekly, and allows manual mode/seed
selection without changing its unary soak job. This is a correctness/liveness soak,
not the benchmark or resource-sampling/plateau work owned by #48.

## Transpiled C Sources

`mise run transpile-c` emits the runtime and C++ protoc plugin through Zig's C backend,
vendors the matching `zig.h`, writes a manifest, and applies deterministic compatibility
transforms. The default target follows the host architecture. Set
`GRPC_LITE_TRANSPILED_C_TARGET=x86_64-linux-gnu` or `aarch64-linux-gnu` to override
it for `transpile-c`, `package-transpiled-c`, or `check-transpiled-c`. Generated C is
target-specific; it is not portable between architectures. Package suffixes are
`linux-x86_64` and `linux-arm64`. Use separate output directories when preserving
both architectures (`GRPC_LITE_TRANSPILED_C_DIST_DIR`), since the reproducibility
check clears its output directory.

The ignored `transpiled/` directory is for local use and is never committed.

`mise run check-transpiled-c` generates and packages twice with independent caches,
compares the resulting archives byte for byte, verifies the SHA-256 sidecar, and tests
that neither tracked files nor `git archive` contain `transpiled/`. The generated-only
release asset is named `grpc-lite-transpiled-c-<version>-linux-<arch>.tar.gz` and contains
only the manifest, two C translation units, and `zig.h`.

CI and tag releases package both architectures on native runners and consume the exact archive in a separate environment where Zig is absent and the
network is disabled. Git checkouts and GitHub automatic “Source code” archives do not
support no-Zig CMake by themselves: consumers must extract the same-version asset and
pass `GRPC_LITE_TRANSPILED_C_DIR`. The assets support insecure Linux x86_64 and ARM64 and includes
no nghttp2 or c-ares sources. TLS is out of scope for this transpiled-C release bundle
until separately selected, so CMake rejects `GRPC_LITE_ENABLE_TLS=ON`. Native Zig TLS
remains selected and is validated by the separate TLS tasks above. Fully offline builds
must stage those dependencies as hashed `file://` archives and set
`GRPC_LITE_NO_NETWORK=ON`. A colocated SHA-256 sidecar detects corruption but is not, by
itself, publisher authentication.

## Pre-tag version consistency

Use this procedure on the exact candidate commit before creating a release tag. It
checks consistency, not whether a version has already been published or which version
should come next. Release selection and publication still require maintainer approval.

1. Reconcile the candidate with current upstream history and releases first:

   ```bash
   git rev-parse HEAD origin/main
   git ls-remote origin refs/heads/main 'refs/tags/v*'
   gh release list --repo fanyang89/grpc-lite
   ```

   Inspect the version files at the relevant tag commits, not just on the working
   branch. At the issue #49 audit, main `25643b1` had internally consistent `0.4.0`
   metadata; Latest `v0.5.0` (`f284fe5`) and prerelease `v0.6.0` (`f256a25`) had
   matching `0.5.0` and `0.6.0` metadata respectively on separate release history.
   This is not evidence that published bundles are wrong and is not a reason to
   blindly bump main or retag an existing release.
2. For an approved new version, update `build.zig.zon`, the `project` version in
   `CMakeLists.txt`, and `cmake/grpc_liteConfigVersion.cmake` together. Update concrete
   `grpc-lite-transpiled-c-<version>-linux-<arch>` examples in `README.md` and `docs/`
   (currently `docs/c-cpp-api.md`). These examples follow the source checkout's version,
   not GitHub's Latest badge. Do not edit dependency/toolchain versions as part of a
   project version bump. Generated C and manifests are regenerated, never hand-edited
   or committed.
3. Run the cheap source check and its deliberate-mismatch regression:

   ```bash
   mise run check-release-version
   mise run test-release-version
   # Set candidate_tag to the approved vMAJOR.MINOR.PATCH, without creating a tag.
   mise run check-release-version --tag "$candidate_tag"
   ```

   The checker rejects missing/duplicate/malformed numeric versions, inconsistent
   Zig/CMake/package versions, stale concrete bundle examples anywhere under `docs/`
   or in `README.md`, and a proposed tag that differs from the source version.
   It is also used by packaging and the existing tag-release validation step.
4. After `mise install` and `mise run bootstrap`, run the existing
   `mise run check-transpiled-c` on native Linux x86_64 and ARM64 runners. Packaging
   checks the generated manifest's project version, source commit, dirty state, Zig
   version, target, optimization, and TLS flag; the task also checks reproducibility
   and checksums. Run `mise run test-consumer-cmake-c` to exercise the no-Zig/offline
   CMake consumer, including rejection of a mismatched manifest. The lightweight
   regression uses fixture C payloads; it does not replace these real generation and
   consumer checks. Commit the candidate and rerun packaging from a clean tree so
   release manifests identify that commit with `dirty: false`.
5. Require `mise run check` before pushing, and review validation for the exact clean
   candidate SHA before authorizing a tag. No tag/push/publish is performed by the
   version checker. The existing release workflow still runs full validation on the
   tag SHA, verifies tag/version agreement, clean manifest provenance, both native
   bundles and their exact no-Zig consumers, and rechecks the remote tag before
   publishing. Pre-tag checks complement rather than replace these release gates.

## Coverage

`mise run coverage` builds the core Debug test binary with the LLVM backend and runs it
through kcov. The task uses `kcov` on `PATH` by default, or the Docker image named by
`KCOV_IMAGE`, and writes a non-empty Cobertura report below `coverage/`. The dedicated
GitHub Actions workflow uploads that report to Codecov using OIDC authentication.

## Gperftools

Linux builds can optionally link the pinned gperftools fork for tcmalloc, CPU and heap
profiling, and guarded allocation sampling:

```bash
mise run prepare-gperftools
mise run build-gperftools -- -Doptimize=ReleaseFast
mise run test-gperftools
```

Downstream Zig packages pass `.gperftools = true` and import
`grpc_lite_gperftools`. For compatibility, this also replaces the final process C
allocator with tcmalloc; `perf.allocator` exposes the same allocator to Zig APIs.
Pass `.tcmalloc = false` to retain CPU profiling without replacing the allocator, or
pass `.tcmalloc = true, .gperftools = false` to enable only minimal tcmalloc. Heap
profiling and guarded allocation sampling require both options; the base MallocExtension
APIs require tcmalloc.

```zig
const grpc = @import("grpc_lite");
const perf = @import("grpc_lite_gperftools");

try perf.startCpuProfiler("/tmp/server.prof");
defer perf.stopCpuProfiler();

var server = try grpc.Server.init(perf.allocator, .{
    .host = "127.0.0.1",
    .port = 50051,
});
```

CPU and heap profilers are process-global and may also use `CPUPROFILE` and `HEAPPROFILE`.
Tcmalloc cannot be combined with ThreadSanitizer. Both options are Linux-only.

## Benchmarks

The cross-process E2E harness builds dedicated ReleaseFast client and server binaries. It
measures completed exchanges after warmup rather than local send-queue admission:

```bash
mise run bench -- --scenario bidi-ping-pong --transport typed
mise run bench -- --reactors=4 --channels=16 --streams=512
mise run bench-all
```

Scenarios are `unary`, `bidi-ping-pong`, and `bidi-throughput`. Common options include
`--warmup`, `--duration`, `--streams`, `--channels`, `--reactors`, `--pipeline`,
`--payload-bytes`, `--payload-pattern`, and `--compression`. For multi-reactor servers use
at least as many Channels as reactors.

`mise run bench-server` starts a separately managed server. `mise run bench-client` can
target it locally or remotely. Output is pretty JSON by default; `--compact` emits one
line.

Reported bytes are application request and response payloads, not HTTP/2 wire bytes. Raw
unary is event-driven; typed unary uses blocking worker slots and also includes protobuf
costs, so these modes are not a pure transport comparison.

The harness is closed-loop with fixed concurrency. Exchanges beginning inside the
measurement window remain eligible during bounded drain. `min_us` and `max_us` cover all
eligible latency; percentiles and mean may use the deterministic reservoir. Clock fields
report whether libcpucycles passed stability checks or fell back to `CLOCK_MONOTONIC`.

Compare only within one scenario: unary operations are complete RPCs while bidirectional
operations are messages on persistent streams. `repeated` is intentionally compressible;
`deterministic-random` is repeatable higher-entropy input.

## Resource accounting and lifecycle evidence

This inventory for [issue #43](https://github.com/fanyang89/grpc-lite/issues/43)
was checked against `25643b1` (2026-10-23). It describes existing behavior, not new
limits. API contracts remain in [Zig](zig-api.md#unary-admission) and
[C/C++](c-cpp-api.md#managed-channels).

### Accounting boundaries

**Configured capacity** is permission to retain data, not preallocated memory.
**Occupancy** is current logical queued data; draining a queue can retain its allocation.
**RSS** includes resident allocator pages, stacks, code and library storage, not just live
payloads. Neither admission snapshot bounds total heap use or RSS. Independent Channels
have independent budgets; server connection/stream limits are not a global byte budget.

| Budget (default) | Charge / release boundary | Owner and exclusions |
| --- | --- | --- |
| Unary: 4096 retained calls, 64 MiB logical requests per Channel | `Operation.init` reserves before allocation/encoding: path + 5-byte frame header + uncompressed payload + raw metadata keys/values. Construction/enqueue failure rolls back. `Operation.deinit` releases after async callback return or blocking result copy, not at HTTP/2 close. | Channel serialized allocator, budget in `Impl`. Excludes responses, encoded metadata expansion, compression scratch, structures and allocator overhead. A separately owned `CallResult` can remain after reservation release. |
| Streaming: 1024 retained streams, 1 GiB configured capacities per Channel | `ClientStreamState.init` reserves one and inbound + outbound configured capacity before construction. Failed opens roll back; `destroy` releases only after both application and loop ownership end. Terminal status, half-close and Channel teardown alone do not release a held handle. Default 8 + 8 MiB permits 64 streams, not 1024. | Refcounted serialized allocator owns budget and survives Channel teardown; backing allocator must survive final handle destruction. Excludes metadata, decoder/container overhead, concurrent temporary encodings and transport writes. No eager buffer allocation. |
| Per-stream message / inbound / outbound: 4 / 8 / 8 MiB, client and server | Message limit checks uncompressed size. Decoder limits unconsumed wire data; client paused inbound queue charges decoded payload + 5, with decoder feed reduced by queued bytes. Outbound charges encoded frames (gzip wire size), released as consumed/discarded. Server `outbound_reserved_bytes` also covers queued send commands. Outbound fullness returns retryable `WouldBlock`; receive pause defers stream credit, while inbound overflow fails the RPC with `RESOURCE_EXHAUSTED`. Client cancellation stops delivery, but an application-retained handle can keep queued frames, payloads and decoder storage until final destruction. Server cancellation discards outbound commands and queued frames. | Client serialized allocator; server reactor-local decoder and shared-allocator commands. Logical occupancy excludes ArrayList spare capacity, decoder/decompression temporaries and already-transferred transport writes. Buffers need not shrink on drain. |
| Unary response / request: 4 MiB each | Client `max_response_size`, server `max_request_size`: decode limit plus separate `wireMessageLimit` guard (message + message/8 + 1024 + 5, saturating) for encoded body. Storage freed with operation/server stream; blocking result copy has independent lifetime. | Client operation/result allocator; server local allocator. Not aggregate response storage or a bound on handler-produced response memory. |
| Client response headers: 64 KiB per RPC | Cumulative physical name + value + 32 across initial/trailing blocks; retained decoded metadata accounting also guards binary comma expansion. Rejected block not published; earlier accepted metadata survives. Counters live with RPC, not connection. | Client allocator. Excludes HPACK/session allocations; not a compressed-wire byte cap. |
| Server request headers: fixed 64 KiB | `onHeader` sums physical name + value lengths, unlike the client's +32 accounting. Freed with server stream. | Reactor-local metadata; excludes field/container and decoded binary expansion overhead. Not configurable or an aggregate metadata quota. |
| Server connections: 1024 across reactors | Coordinator CAS admission before connection construction; init failure releases; initializing, draining and async-closing connections retain slot through final destruction. | Shared coordinator, reactor-local connections. Kernel socket buffers, descriptors, TLS and HTTP/2 allocations are separate costs. |
| Server concurrent streams: 100 per connection | `onBeginHeaders` checks stream map before allocation; `onStreamClose` removes admission. Before SETTINGS acknowledgement refuse excess; after acknowledgement nghttp2 emits protocol-error GOAWAY. | Reactor-local stream map. Retained `ServerCall` control and pending command refs can outlive transport stream admission; no aggregate retained-call quota. |
| Cleartext preface 10s; idle 5m; TLS handshake 10s | Absolute preface deadline ends on initial non-ACK SETTINGS. Idle only while no inbound streams; PING does not refresh it. TLS uses separate handshake deadline. Expiry retires connection; slot remains through destruction. | Connection/reactor deadline state, not byte reservations. Active RPCs are idle-exempt; per-call deadlines/drain timeout bound different lifetimes. |
| HTTP/2 initial stream window 64 KiB; socket write high/low 1 MiB / 512 KiB | Flow-control credit returns on consumption/resume. Flush pauses at high and resumes below low; can overshoot by one serialized chunk. 64 KiB cleartext batch target is aggregation, not an additional memory quota. | Channel/connection write buffers and reusable descriptor pools, separate from stream buffers. Excludes nghttp2 queues, TLS ciphertext and kernel send/receive buffers. |

Sources: [Channel options, admission and allocator](../src/channel.zig#L88),
[stream construction/destruction](../src/channel.zig#L799),
[unary construction/destruction](../src/channel.zig#L1081),
[buffer limits](../src/stream.zig#L15), [decoder](../src/frame.zig#L46),
[server options](../src/server.zig#L216), [connection admission](../src/server.zig#L565),
[server stream/header admission](../src/server.zig#L2993),
[retirement and command refs](../src/server.zig#L2645),
[client response-header accounting tests](../src/channel.zig#L5359).

Ownership outside those budgets matters:

- Server reactor-local small-allocation pages are cached until allocator teardown;
  refills/large allocations and cross-thread commands use the serialized backing
  allocator. `ServerContext` allocator is callback-local. `ServerCall` clones own shared
  control, not the whole transport stream; release all clones **before Server deinit**.
  See [local allocator](../src/server.zig#L24) and
  [control release/retirement](../src/server.zig#L1195).
- [C handles](../src/c_api.zig#L208) use `c_allocator` (testing allocator in Zig tests).
  Unary result and stream wrapper storage are allocated before the transport call/open;
  even quota rejection can allocate a wrapper/result. Destroy results, metadata and
  stream handles explicitly. C++ RAII wraps these owners and adds `std::string`, metadata,
  callback and protobuf copies outside transport accounting; application executors own
  their workers/queues. See [C unary/open/destroy](../src/c_api.zig#L450),
  [C++ client stream](../include/grpc_lite/cpp/client_stream.hpp) and
  [executor lifetime](c-cpp-api.md#generated-services).
- nghttp2, libxev, c-ares, TLS state, libc allocator caches, application-retained results,
  thread stacks and OS socket buffers are not summed by admission snapshots. Allocation
  release need not immediately reduce RSS; no process-wide heap ceiling is promised.

### Existing coverage and concrete gaps

Test names below are source search keys, not claims of exhaustive interleaving coverage.
`mise run test` includes the Zig and C/C++ executables; sanitizers and interoperability
are separate stages in `mise run check`.

| Transition | Existing evidence | Still uncovered / follow-up |
| --- | --- | --- |
| Retained client handle → Channel gone → final destroy | [Channel](../src/channel.zig#L4608): `client stream handle outlives channel teardown` asserts one terminal, closed commands, retained count then zero after release. [C](../src/c_api.zig#L2000): `C stream admission snapshots retain closed handles until release` retains across shutdown/wait, checks rejection then zero. | #44: C destruction (not only shutdown) with surviving handle; successful terminal handle retaining quota and reopening after release; callback-owned release vs transport retirement. |
| Retained server call → transport retirement → last clone | [Server](../src/server.zig#L4468): `retained server call observes cancellation after transport retirement`; `retained server call abort is allocation free and submits a reset`. [Typed client](../tests/protobuf_adapter_test.zig#L656) deinitializes from callback. | #44: multiple retained clones/commands under distinct terminal causes, final control release and callback suppression; keep Server alive throughout, do not invent post-Server lifetime. |
| Reserve → reject / construct / enqueue | [Channel](../src/channel.zig#L8511): exact count/byte boundaries, reject-before-allocation/no rejected async callback, zero limits, validation/unavailable enqueue rollback; analogous stream tests at `stream admission enforces count and capacity reservations`. | #46: notify/submission failure after ownership transfer, not just unavailable enqueue; callback counts and reservation recovery at each failure stage. |
| Allocation failure → rollback | [Channel](../src/channel.zig#L8530): `unary admission rolls back every allocation failure` (gzip + metadata construction), `stream admission rolls back every allocation failure` (state/path/metadata). [Server](../src/server.zig#L4661): shared-command allocation, partial init/registration, multi-reactor registration/start rollback. Header builders and write bookkeeping have failure tests in both modules. | #46: result-copy failure, HTTP/2 submit/reset failure, retained send/finish/metadata enqueue failure with queued work; C wrapper allocation and C++ conversion failures. Existing all-allocation checks cover their helper, not all transport or foreign allocations. |
| C/C++ error surface and ownership | [C](../src/c_api.zig#L1869): failed creation clears handles; unary rejection is RESOURCE_EXHAUSTED; stats preserve unknown tails. [C smoke](../tests/c_api_smoke.c#L130), [C++ native](../tests/cpp_native_api_test.cc#L75): defaults, rejection, snapshots. | #44/#46: these smoke assertions do not prove wrapper lifetime under concurrent destruction or OOM at every conversion. Extend existing executables rather than duplicate ABI suites. |
| Active call → shutdown / deadline / GOAWAY / disconnect | [Channel](../src/channel.zig#L6583): connection replacement, accepted RPC drain, drain timeout/escalation, active call/blocked write/reconnect shutdown. [Server](../src/server.zig#L5384): preface admission/deadline release. [grpcpp facade](../tests/grpcpp_streaming_facade_test.cc#L205): pre-cancel, active cancel, early Finish, deadline, abandoned reader. | #45: deterministically order cancel vs trailers/deadline/disconnect/GOAWAY/shutdown while send or receive is blocked; assert one terminal, no later callback, bounded wait and final reservation/command cleanup. Ordinary success tests are not a race matrix. |
| Concurrent reserve/release and allocator use | [Channel](../src/channel.zig#L8600): four threads × 1000 budget attempts (unary and stream); serialized backing allocator and concurrent unary tests at [7408](../src/channel.zig#L7408). [Server](../src/server.zig#L5746): multi-reactor concurrent callbacks/allocations. | #45: reserve/open/send races against retirement with explicit barriers. Budget-only contention does not cover full open/destroy; TSAN passing does not establish all schedules. |
| Streaming backpressure / sustained load | [Channel](../src/channel.zig#L8456): full/half-closed no-allocation sends and gzip wire-size admission; [Server](../src/server.zig#L4871): ordered queue reuse/cancel; [receive credit](../src/server.zig#L5933): paused stream isolation/resume; [typed](../tests/protobuf_adapter_test.zig#L405): all cardinalities. | #47 adds [streaming soak](#streaming-soak) for long-lived slow consumers, repeated pause/resume, large messages, sustained backpressure and recovery in the existing [soak workflow](../.github/workflows/soak.yml); runtime validation pending. Initial scope is native cleartext x86_64 server only; benchmark bidi remains throughput evidence, not soak. |
| Resource reuse / process residency | [Server allocator test](../src/server.zig#L4353), write pools, and admission tests check local reuse/release. Baseline below samples process resources. | #48: time series through warmup, pressure, recovery and teardown, correlating reservation and actual queue occupancy; no existing benchmark occupancy export. No plateau established by these short runs. |

Exclusive follow-up seams: #44 owns retained-handle/control tests and wrapper lifetime
assertions; #45 owns deterministic terminal-event ordering using existing
`TestObserver`, semaphores and raw nghttp2 peers; #46 owns allocation/construction/submit
rollback helpers using `FailingAllocator`/`checkAllAllocationFailures`; #47 owns
`tests/official` streaming soak plus the existing scheduled workflow; #48 owns benchmark
measurement/evidence around existing binaries, `/proc` and optional gperftools. These are
recommendations, not implementation authorization. #44–46 share `channel.zig` and
`server.zig`: serialize edits to those files, partition by the named test families, and
reuse one observer/failure seam rather than creating competing harnesses. #47 should not
also edit benchmark measurement code; #48 should not add transport limits or public
telemetry without a separate scope decision.

### Bounded baseline (not a soak or heap bound)

On 2026-10-23, Linux x86_64 `7.2.8-200.fc44`, glibc 2.43, Zig 0.17.0,
source `25643b1`, native ReleaseFast, TLS/gperftools off, default allocators/options.
One fresh server/client pair per row, loopback, one reactor, one Channel, four workers or
persistent streams, identity compression, deterministic-random payloads. These runs were
**not isolated**: no shared validation lock was held, and concurrent compilation from
other worktrees may have overlapped. They are bounded observations, not a controlled
performance comparison. For reproduction on a shared host, serialize the entire build,
server/client and sampling lifecycle with the shared validation lock. Build first:

```bash
mise install
mise run bootstrap
mise exec -- zig build -Doptimize=ReleaseFast
# Repeat with (scenario, payload, pipeline) from the table:
mise run bench -- --scenario unary --transport raw --warmup 1s --duration 3s \
  --streams 4 --channels 1 --reactors 1 --pipeline 1 --payload-bytes 128 \
  --payload-pattern deterministic-random --compression identity
```

For resource sampling, launch the same `zig-out/bin/grpc-lite-benchmark-server` with
`--host=127.0.0.1 --port=0 --reactors=1`, read its reported port, then launch the client
with the above flags (`--server-reactors=1` rather than `--reactors=1`, plus host/port).
Sample `/proc/$pid/status` (`VmRSS`, `Threads`) and count `/proc/$pid/fd` every 100 ms
for each PID, starting at client launch; retain timestamps and exclude the first second
for the ranges below. Each run captured 41 samples per process over roughly four
seconds, including startup/warmup; client had a 20s external ceiling (not reached),
then server was terminated as in the bench wrapper. This does **not** measure server
graceful-teardown residency. Retain JSON stdout, stderr and raw samples outside git.

| Scenario | Payload bytes / pipeline | Completed / errors | Client RSS KiB min–max | Server RSS KiB min–max | Client / server FDs; threads |
| --- | --- | --- | --- | --- | --- |
| unary | 128 / 1 | 712284 / 0 | 3416–14552 | 4264–4264 | 6 / 8; 2 / 2 |
| bidi-ping-pong | 128 / 1 | 895828 / 0 | 3336–20836 | 4124–4124 | 6 / 8; 2 / 2 |
| bidi-throughput | 65536 / 8 | 36716 / 0 | 4964–5840 | 5860–8276 | 6 / 8; 2 / 2 |

Ranges are observations, not maxima between samples or performance guarantees. The
client includes the benchmark's growing latency reservoir (limit 1,000,000 samples),
so its RSS is not transport-only; no heap attribution was collected. The throughput run
also reported 2.762s maximum eligible latency, so it should not be presented as a
uniform-latency steady state. FD/thread samples were constant after warmup, but long-run
plateau, overload/recovery, allocator live bytes, kernel memory, queue occupancy and
admission snapshot time series are **unavailable** in this baseline. Four default bidi
streams imply 64 MiB reserved capacity by configuration; that is a derivation, **not a
sampled reservation** or measured occupancy/RSS.

Validation before documentation edits: `mise install`, `mise run bootstrap`,
`mise run test` (285/291 passed, 6 TLS-disabled skips), ReleaseFast build, all three
baseline clients, and a complete `mise run check` passed. An initial check invocation
exceeded the execution tool's 200s timeout; a 1200s retry completed with recorded exit 0,
including sanitizers, TLS, consumers and interop. For the later check after documentation
edits, the agent time limit interrupted exit-status capture. Its retained log subsequently
advanced through sanitizers, TLS and interop, ending with all eight HTTP/2 edge-case
passes, but there is **no captured exit status**; it is not an authoritative completed
final-tree gate. No source/tests changed, and local
Markdown links/anchors and `git diff --check` passed after recovery. No privilege changes
were needed. These earlier checks also ran without the shared validation lock.
Local raw evidence is retained at `/home/fanmi/tmp/grpc-lite-issue43-evidence/`
(`test.log`, `check.log`, `check-retry.log`, `check-retry.exit`, `check-final.log`,
`measure-summary.jsonl`, per-scenario JSON/samples/logs and `measure.py`); this path is
run-local, not a portable artifact link. The table and commands above are the committed
baseline; #48 needs isolated, longer, phase-separated measurement.

## Dependencies

- Latest stable Zig release through mise (minimum 0.17.0)
- nghttp2 1.69.0
- c-ares 1.34.8
- libcpucycles 20260625
- libxev b0650f0
- zig-protobuf 5.0.0
- nanozlog 0.1.0
- mbedTLS 3.6.6 (optional)
- gperftools 2.18.1-based fork (optional)
- CMake and Ninja for upstream C builds
- mise for tool versions and project tasks
