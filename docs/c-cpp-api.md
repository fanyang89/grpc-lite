---
title: C and C++ APIs
description: Stable C ABI, release bundles, CMake integration, and the synchronous C++ facade.
---

# C and C++ APIs

grpc-lite provides a stable C ABI, a low-level C++ RAII API in `grpc_lite::*`, and a
focused synchronous grpcpp-shaped facade in `grpc::*`. All three use the same transport.

See the [public surface inventory and upgrade guide](upgrading.md) for supported
headers, source-versus-binary compatibility, and migration steps.

## Installed Package

`zig build` installs the versioned shared library, static archive, C and C++ headers,
CMake package files, and `protoc-gen-grpc_lite_cpp` under `zig-out`.

```bash
cc app.c \
  -Izig-out/include \
  -Lzig-out/lib -Wl,-rpath,"$PWD/zig-out/lib" \
  -lgrpc_lite
```

The transport, low-level C++ API, and `grpc_lite::grpcpp` facade do not require
Protobuf or Abseil. Typed generated C++ services use the official Protobuf runtime as an
optional external dependency. grpc-lite does not fetch, vendor, or select a Protobuf or
Abseil version for downstream applications.

The C ABI uses opaque handles, fixed-width error codes, and pointer-length byte views.
Memory allocated by the library must be released by its matching destroy function.

Runtime initialization must happen before application threads are created and must
outlive dependent handles. The API provides:

- version and feature discovery
- owning Runtime and Metadata handles
- connected and reconnecting managed Channels
- blocking raw unary calls
- cancellable event-driven client streams
- event-driven server registration and retained cross-thread calls
- metadata, bounded backpressure, cancellation observation, and graceful drain

### Released C ABI compatibility

The selected released regression baseline is **v0.5.0, C ABI 1.6**. This is grpc-lite's
own C ABI, **not grpc-core or grpcpp ABI compatibility**. The baseline is the
latest non-prerelease selected when this check was introduced; it does not move
automatically when a new release appears.

The old-header/current-library regression checks:

- All 56 baseline functions remain exported by the ELF shared library, with
  unchanged public function signatures and callback/field types.
- All 10 public value structures preserve alignment, field offsets and widths.
  Only Channel and Server options may grow; their released prefixes must not
  shrink. Other baseline value structures retain their exact size.
- Error/enum values and feature-bit assignments stay fixed. ABI versions encode
  `(major << 16) | minor`; the baseline major stays 1, the minor must be at least
  6, the current header and runtime versions agree, and the SONAME remains
  `libgrpc_lite.so.1`. Product release numbers are separate from ABI versions.

Accepted old option extents (byte sizes on supported Linux x86_64/ARM64):

| Options | Accepted old extents |
| --- | --- |
| Channel | 40 (through jitter), 48 (logger), 56 (response header limit / full baseline) |
| Server | 56 (buffers), 64 (logger), 72 (connections), 80 (preface timeout), 88 (idle timeout), 100 (stream limit), 104 (full baseline including padding) |

Missing resource-limit fields use finite library defaults.
This focused check does not prove every behavior, compiler/platform ABI, or
compatibility of the C++ facade; normal transport and interop tests still apply.

`grpc_lite_features()` reports capabilities usable through the C ABI, rather than every
transport capability compiled into the library. `GRPC_LITE_FEATURE_TLS` remains defined
for source compatibility, but the returned mask leaves it clear because C Channel and
Server options currently create only insecure transports. Building with `-Dtls=true`
still enables TLS for the Zig API and does not change the C option struct layouts.

C and C++ callback code runs synchronously on API caller or transport threads, may run
concurrently, and must not block unless the specific synchronous facade contract permits
it.

`grpc_lite_server_call_abort` and `grpc_lite::ServerCall::Abort` make an allocation-free,
thread-safe emergency termination request for a retained server call. The reactor resets
the stream with `INTERNAL_ERROR`, or closes the connection if reset submission fails.

## Managed Channels

See [Resource limits](resource-limits.md)
for quota ownership, wrapper allocations and memory accounting boundaries.

`grpc_lite_channel_create_managed` creates a durable Channel. Set
`allow_initial_offline` to return before the first connection succeeds. A managed Channel
reconnects with bounded exponential backoff without replaying submitted RPCs. Unsubmitted
unary calls retain their original deadlines while waiting for a connection.

ABI 1.7 appends `max_unary_calls` (default 4096) and `max_unary_request_bytes`
(default 64 MiB) to `grpc_lite_channel_options`; the C++ `ChannelOptions` uses the
same fields. Both limits must be nonzero and fit `size_t`. Older option prefixes
retain the defaults for absent fields. Initialize options with
`GRPC_LITE_CHANNEL_OPTIONS_INIT` and preserve `struct_size`.

Unary quota rejection returns a result with gRPC `RESOURCE_EXHAUSTED`, not a C API
error. The limits cover retained unary operations, including construction and result
copying. Bytes charge the method path, five-byte frame header, uncompressed payload,
and raw metadata keys/values, not total heap usage or response storage.

Initialize `grpc_lite_unary_admission_stats` with
`GRPC_LITE_UNARY_ADMISSION_STATS_INIT`, then call
`grpc_lite_channel_get_unary_admission_stats`. C++ provides
`Channel::GetUnaryAdmissionStats(UnaryAdmissionStats*)`. Snapshots report retained
calls, retained request bytes, and a saturating quota-rejection count. They are
thread-safe but must not race Channel destruction. These symbols require ABI 1.7
or newer and exclude streaming.

Streaming has a separate default admission
budget of 1024 retained streams and 1 GiB of configured aggregate buffer capacity
(64 streams at the default 8 MiB per direction). A rejected stream open returns
`GRPC_LITE_ERROR_WOULD_BLOCK`; the grpcpp facade maps it to `RESOURCE_EXHAUSTED`.
ABI 1.8 appends `max_streams` and `max_stream_buffer_bytes` to Channel options;
both must be nonzero and fit `size_t`. Old prefixes retain the defaults. Initialize
`grpc_lite_stream_admission_stats` with `GRPC_LITE_STREAM_ADMISSION_STATS_INIT` and
call `grpc_lite_channel_get_stream_admission_stats`; C++ exposes
`Channel::GetStreamAdmissionStats(StreamAdmissionStats*)`. These new symbols require
ABI 1.8 or newer. Snapshots report `retained_streams`, `reserved_buffer_bytes`, and
saturating `rejected_streams`. Buffer bytes are reserved capacities, not current
occupancy or total heap usage. Closed streams still held by the application retain
their reservation until their handle and transport ownership are both released.

Use `grpc_lite_channel_shutdown` to stop admission and active work, then
`grpc_lite_channel_wait` before exclusive destruction when calls may be concurrent.

Channel and Server options accept an optional `grpc_lite_logger` for connection recovery,
GOAWAY, startup, and drain events. The logger configuration is borrowed during handle
creation; its user data must outlive the owning handle.

`grpc_lite_server_options` and `grpc_lite::ServerOptions` expose finite server admission
bounds: `max_connections = 1024` across all reactors,
`max_concurrent_streams_per_connection = 100`,
`cleartext_preface_timeout_ns = 10000000000`, and
`connection_idle_timeout_ns = 300000000000`. Every value must be nonzero. The preface
limit is an absolute cleartext deadline through the initial non-ACK SETTINGS; input does
not refresh it. Idle means no active inbound RPC streams, so transport traffic does not
refresh the deadline and any active unary or streaming RPC is exempt.

C callers must initialize `struct_size`. Callers using an older size receive the finite
resource defaults for missing fields; each appended field is read only when its own end
offset is present. Excess streams are reset with `REFUSED_STREAM` before SETTINGS is
acknowledged; exceeding an acknowledged stream limit causes `GOAWAY(PROTOCOL_ERROR)`.
Idle retirement sends `GOAWAY(NO_ERROR)` before graceful closure.

`grpc_lite_channel_options.max_response_header_list_size` and the matching low-level C++
option default to 65536 and accept values from 1 through `UINT32_MAX`. The HTTP/2 setting
is advertised per header list, but local enforcement charges each decoded physical field
as name bytes plus value bytes plus 32 and accumulates across all response header and
trailer blocks in an RPC. Oversize blocks are withheld atomically and finish only that RPC
with `RESOURCE_EXHAUSTED`; an accepted initial block survives oversized trailers and the
connection remains reusable.

## Operational Snapshots

ABI **1.9** adds `grpc_lite_channel_get_operational_stats` and
`grpc_lite_server_get_operational_stats`, plus const thin C++ methods
`grpc_lite::Channel::GetOperationalStats(ChannelOperationalStats*)` and
`grpc_lite::Server::GetOperationalStats(ServerOperationalStats*)`. These are not
`grpc::Channel` / `grpc::Server` grpcpp APIs. Existing admission options, snapshot
layouts, getters, and minimum sizes remain unchanged.

C outputs have a `size_t struct_size` envelope and `uint64_t` metrics. Initialize
with the matching macro; for example, given live Channel and Server handles:

```c
#include <grpc_lite/grpc_lite.h>

void sample(grpc_lite_channel *channel, const grpc_lite_server *server) {
  grpc_lite_channel_operational_stats cs =
      GRPC_LITE_CHANNEL_OPERATIONAL_STATS_INIT;
  grpc_lite_server_operational_stats ss =
      GRPC_LITE_SERVER_OPERATIONAL_STATS_INIT;
  grpc_lite_error ce = grpc_lite_channel_get_operational_stats(channel, &cs);
  grpc_lite_error se = grpc_lite_server_get_operational_stats(server, &ss);
  if (ce != GRPC_LITE_OK || se != GRPC_LITE_OK) return;
  /* Consume cs and ss as independent samples, not a transaction. */
}
```

Short outputs must end at a complete known metric boundary. The real minimum
prefix macros end after the first metric, not after the envelope alone:

- `GRPC_LITE_CHANNEL_OPERATIONAL_STATS_MIN_SIZE` is
  `offsetof(grpc_lite_channel_operational_stats, unary_retained_calls) + sizeof(uint64_t)`.
- `GRPC_LITE_SERVER_OPERATIONAL_STATS_MIN_SIZE` is
  `offsetof(grpc_lite_server_operational_stats, admitted_connections) + sizeof(uint64_t)`.

Both are currently 16 bytes on supported x86_64/ARM64 targets. Every subsequent
complete metric boundary is supported; sizes at least `sizeof` the known structure
are accepted for future extensions. Supply aligned writable storage for the declared
extent. Only present known metrics are written: `struct_size` and any unknown tail
are always preserved. Null output or an undersized/mid-field short size returns
`GRPC_LITE_ERROR_INVALID_ARGUMENT` without writes. A null owner with valid output
returns that error after zeroing its present known metrics. A valid live owner and
valid output return `GRPC_LITE_OK`. Fabricated or destroyed non-null handles are
invalid use, not safely detectable error arguments.

C++ values have zero-default `std::uint64_t` metrics with the same flat names and
units, but no `struct_size`, INIT call, or snapshot destruction requirement:

```cpp
#include <grpc_lite/grpc_lite.hpp>

void Sample(const grpc_lite::Channel& channel, const grpc_lite::Server& server) {
  grpc_lite::ChannelOperationalStats cs;
  grpc_lite::ServerOperationalStats ss;
  const grpc_lite::Error ce = channel.GetOperationalStats(&cs);
  const grpc_lite::Error se = server.GetOperationalStats(&ss);
  if (!ce.ok() || !se.ok()) return;
  // Consume cs and ss as independent samples, not a transaction.
}
```

Null C++ output and empty/moved-from owners return `ErrorCode::InvalidArgument`
(including Server, not `InvalidState`); non-null outputs are cleared on error.
Getters allocate nothing and invoke no callbacks. Snapshots are owning values without
borrowed storage: copies survive owner destruction and require no deinit.
**Getter calls still require a live owner.**
Sampling may overlap supported operations, shutdown, and wait, including after wait.
Synchronize shared output objects. Owner destruction and C++ owner moves require
exclusive access: stop and join all readers first, even if client stream handles survive.

See the native [complete field semantics](zig-api.md#operational-snapshots) for every
field's units and lifetime boundary. The six C/C++ admission fields flatten native
`unary_admission.{retained_calls, retained_request_bytes, rejected_calls}` with a
`unary_` prefix and `stream_admission.{retained_streams, reserved_buffer_bytes,
rejected_streams}` with a `stream_` prefix; all other names match. In particular:

- Channel operational fields share one accounting lock, but admission is sampled
  independently. Retained terminal handles are not active RPCs. Stream admission
  reserves configured capacities, not current queue occupancy. Inbound queue charges
  are decoded payload plus five bytes per frame (excluding decoder storage and
  immediate callback delivery); outbound charges retain whole encoded frames until
  fully consumed/destroyed, even during partial consumption. Terminal, detached,
  application-retained queue charges can remain nonzero after wait. Reservation
  release, terminal outcome, and queue destruction are distinct. Channel high-water
  marks are lifetime aggregate peaks.
- Server snapshots are approximate independent reactor samples. Streaming outbound
  reservations include queued send commands and decrease with partial consumption;
  unary responses and temporary encodings are excluded. Socket gauges charge owned
  buffers through completion/discard, including in-flight writes, not peer delivery;
  Server socket gauges exclude nghttp2/TLS-internal pending data. Server
  `*_high_water_sum` fields sum non-simultaneous reactor peaks, not true global peaks.
- Admission rejection counters count quota refusals. Server `rejected_connections`
  excludes drain and initialization failures; `pre_ack_rejected_streams` counts
  pre-ACK cap/defensive-guard refusals, excluding drain and allocation failures.
  Decoder occupancy and generic post-ACK stream-cap rejection counts are unavailable,
  not measured as zero. Channel terminal buckets are disjoint per accepted RPC;
  Server close buckets are disjoint per admission-owning connection, counted at final
  destruction with the first effective close reason. Rejected accepts and failures
  before admission ownership are excluded from close counts.

Event counters and Server aggregate sums saturate; lifetime high-water marks never
decrease, and there is no reset. Samples are not global transactions. Neither snapshots
nor reservations measure or bound heap use or RSS; queue charges are not allocation
sizes or a deduplicated memory total. Spare capacity, decoder/metadata/HPACK storage, compression temporaries, TLS
workspace, kernel buffers, allocator overhead/caches, and application copies are
excluded. These APIs do not close the outstanding validation gaps in the
[resource limits](resource-limits.md).

## CMake Source Build

Git checkouts and GitHub automatic “Source code” archives intentionally contain no
generated C. A no-Zig CMake build pairs the source at a tag with that release's matching
`grpc-lite-transpiled-c-<version>-linux-<arch>.tar.gz` asset. Verify its sidecar from the
folder containing both files, extract it, and pass the extracted root explicitly:

```bash
sha256sum --check grpc-lite-transpiled-c-0.4.0-linux-x86_64.tar.gz.sha256
tar -xzf grpc-lite-transpiled-c-0.4.0-linux-x86_64.tar.gz
cmake -S grpc-lite -B build \
  -DGRPC_LITE_TRANSPILED_C_DIR="$PWD/grpc-lite-transpiled-c-0.4.0-linux-x86_64"
```

Choose `linux-x86_64` or `linux-arm64` to match the consumer architecture; the examples
above use x86_64. CMake rejects bundles generated for a different architecture.

The generated-only asset targets insecure Linux x86_64 and ARM64. TLS is out of scope for this
transpiled-C release bundle until separately selected, and CMake rejects
`GRPC_LITE_ENABLE_TLS=ON`. This does not change the optional mbedTLS support available to
native Zig builds.

The asset contains only its manifest, two generated C translation units, and the matching
`zig.h`; it does not contain project sources or third-party dependencies.
`sha256sum --check` provides integrity/error detection, but a checksum colocated with an
asset is not publisher authentication.

After setting `GRPC_LITE_TRANSPILED_C_DIR`, add the source directory and link its targets:

```cmake
add_subdirectory(third_party/grpc-lite)
target_link_libraries(c_app PRIVATE grpc_lite::c)
target_link_libraries(cpp_app PRIVATE grpc_lite::grpcpp)
```

Typed C++ source builds additionally call `find_package(Protobuf REQUIRED)` and set
`GRPC_LITE_ENABLE_PROTOBUF=ON` before `add_subdirectory`, then link
`grpc_lite::grpcpp_protobuf`. `grpc_lite::grpcpp_protobuf_lite` is defined when the
Protobuf package exports `protobuf::libprotobuf-lite`. The application must select one
compatible Protobuf dependency graph.

`grpc_lite::c` and `grpc_lite::c_static` both refer to the source-built static transport.
An installed package exposes the versioned shared transport through `grpc_lite::c` and
the static archive through `grpc_lite::c_static`.

The generated bundle does not make dependency resolution offline. For a fully offline
configuration, stage nghttp2 and c-ares archives separately, hash them, and enable the
network guard:

```bash
cmake -S grpc-lite -B build \
  -DGRPC_LITE_TRANSPILED_C_DIR="$PWD/grpc-lite-transpiled-c-0.4.0-linux-x86_64" \
  -DGRPC_LITE_NO_NETWORK=ON \
  -DGRPC_LITE_NGHTTP2_URL="file://$PWD/deps/nghttp2.tar.gz" \
  -DGRPC_LITE_NGHTTP2_URL_HASH=SHA256=... \
  -DGRPC_LITE_CARES_URL="file://$PWD/deps/c-ares.tar.gz" \
  -DGRPC_LITE_CARES_URL_HASH=SHA256=...
```

Without `GRPC_LITE_NO_NETWORK`, nghttp2 may use the nested source directory and both
dependencies otherwise use their pinned archives. Maintainers use `mise run transpile-c`
for an ignored local bundle directory and `mise run package-transpiled-c` for an asset;
generated output is never committed.

## Low-Level C++ API

Headers under `<grpc_lite/cpp/...>` provide explicit RAII wrappers over the C ABI,
including `grpc_lite::Runtime`, `Channel`, `ClientStream`, `Server`, `Metadata`, and
`Status`. This is the event-driven API for applications that need ownership and streaming
control without using C directly.

Hostname channels require explicit Runtime ownership. Use
`grpc_lite::Runtime` with `grpc_lite::Channel::CreateManaged`, or the equivalent C API.

## No-Zig Bounded Executor Example

`examples/cpp_bounded_executor` is a standalone raw C++ consumer using the low-level
API, not generated services. It owns one worker and permits **one total outstanding
job with no waiting backlog**. Reactor submission uses `try_lock`: contention, a
busy worker, or closed admission rejects immediately with `RESOURCE_EXHAUSTED`.
This is application executor admission, separate from transport resource limits.

The callback retains a `ServerCall` and moves it into the executor only on acceptance.
It never saves the borrowed `ServerStream` or context. Rejection finishes and releases
the retained call on the reactor; accepted work releases it on the worker. Command
failure uses `Abort` rather than leaving a call unfinished. The sample consumes an
empty request and returns fixed raw protobuf bytes; it needs neither `protoc` nor the
external Protobuf runtime. Typed generated code still needs the application's official
Protobuf dependency, as described below.

Use the **same-version source tag and release asset**, verify/extract the asset as
above, then build in an environment without Zig:

```bash
! command -v zig
cmake -S grpc-lite/examples/cpp_bounded_executor -B build-bounded -G Ninja \
  -DGRPC_LITE_SOURCE_DIR="$PWD/grpc-lite" \
  -DGRPC_LITE_TRANSPILED_C_DIR="$PWD/grpc-lite-transpiled-c-0.4.0-linux-x86_64" \
  -DGRPC_LITE_ENABLE_PROTOBUF=OFF \
  -DCMAKE_DISABLE_FIND_PACKAGE_Protobuf=ON
cmake --build build-bounded --target grpc_lite_bounded_executor
ctest --test-dir build-bounded --output-on-failure
```

The bundle remains **cleartext-only Linux x86_64/ARM64**. Choose the matching
architecture asset. CMake still needs nghttp2 and c-ares; use the offline archive
options above when network access is unavailable. Zig is needed only by maintainers
producing the generated-C asset, not by this consumer build.

The executable accepts `success`, `overload`, or `shutdown`. An application-controlled
work gate models blocking downstream work on the worker, making overload deterministic
without sleeps. The shutdown scenario closes executor admission, verifies rejection,
requests graceful transport drain while an accepted call is still pending, releases
work, joins the worker, and checks the accepted response. All scenarios verify that a
closed, idle executor still rejects. Retained calls are released before Server
destruction, and Runtime outlives all threads and handles. Real applications must bound
or cancel their downstream work too: a transport drain timeout does not join application
workers. The tiny single-response example aborts on send failure; it is not a general
streaming `WouldBlock`/`on_writable` implementation.

`tests/consumer/run_cmake_c.sh <asset.tar.gz> <asset.tar.gz.sha256>` reuses the existing
independent generated-C harness: it archives source HEAD, verifies the exact supplied
asset/checksum, builds a copied example with Protobuf discovery disabled, and runs all
three smoke cases alongside the existing generated-code coverage. Its isolated consumer
rejects a visible Zig executable and runs without network access. The harness's typed
checks separately require Protobuf. `GRPC_LITE_KEEP_E2E=1` preserves CMake/CTest logs.
The runtime needs Linux io_uring permission. Docker's default seccomp profile may
reject `io_uring_setup` with `EPERM`. The harness therefore applies a scoped profile
by default to its trusted consumer container, including existing CI/release callers:
it verifies a vendored, commit-and-SHA-256-pinned Moby default allowlist, then adds
only `io_uring_setup`, `io_uring_enter`, and `io_uring_register`. Upstream default-deny
and all unrelated rules remain intact; network isolation and the nonroot user remain.
No privileged mode, additional capabilities, unconfined fallback, or daemon-wide
policy change is used. See [profile provenance and tests](../tests/consumer/seccomp/README.md).
This is not a deployment sandbox recommendation. The host kernel/outer sandbox must
also permit io_uring; failures are test failures, never skipped or counted as passes.
The pre-isolated host route (`GRPC_LITE_NETWORK_ISOLATED=1`) must provide that permission
itself.

Maintainer validation with `mise run package-transpiled-c` followed by that harness is
**locally packaged exact-artifact testing**, not proof that a published release was
tested. Published-release testing must instead supply that release's downloaded asset
and checksum with its matching tagged source (including this example). Record the
source commit, asset checksum, architecture, and test logs in either case. No published
release validation is implied by the local packaging command.

## Synchronous grpcpp Facade

`<grpcpp/grpcpp.h>` provides the common synchronous client and generated server shapes:

- `grpc::Status` and status codes
- `grpc::ClientContext` and `grpc::ServerContext`
- Channels and channel arguments
- unary, client-streaming, server-streaming, and bidirectional client calls
- generated nested `Service` classes
- `grpc::ServerReader<T>`, `grpc::ServerWriter<T>`, and
  `grpc::ServerReaderWriter<W, R>` with bounded request and response backpressure

It is source-compatible with this selected API subset, not ABI-compatible with grpcpp.
It does not provide official generated glue, CompletionQueue, callbacks/reactors, generic
services, interceptors, or grpc-core internals.

The grpcpp-shaped `grpc::CreateChannel` facade currently accepts IPv4 targets. Use the
low-level C++ or C API when hostname resolution requires explicit Runtime ownership.

## Generated Services

The protoc plugin generates synchronous glue for unary, client-streaming,
server-streaming, and bidirectional methods beside standard protobuf C++ messages.
Generated services expose both `EventService` and a grpcpp-shaped nested `Service` with
virtual methods. Existing official gRPC
`*.grpc.pb.cc` files must be regenerated with the grpc-lite plugin; relinking official
generated service glue is not supported. Standard `*.pb.h` and `*.pb.cc` message files
continue to come from the selected official `protoc` release.

```bash
protoc -I proto \
  --cpp_out=generated \
  --plugin=protoc-gen-grpc_lite_cpp=zig-out/bin/protoc-gen-grpc_lite_cpp \
  --grpc_lite_cpp_out=generated \
  proto/echo.proto
```

An installed package exposes the optional integration through a CMake component:

```cmake
find_package(grpc_lite 0.4 CONFIG REQUIRED COMPONENTS protobuf)
target_link_libraries(echo_proto PUBLIC grpc_lite::grpcpp_protobuf)
```

The component locates the application's official Protobuf package and propagates
`protobuf::libprotobuf`; it does not make Protobuf a dependency of the raw targets. Use
`grpc_lite::grpcpp_protobuf_lite` only with messages generated for the lite runtime.
Keep `protoc` and the linked runtime on compatible releases so their generated-code
version checks agree.

Create a fresh adapter for every server instance:

```cpp
auto adapter = service.CreateEventService(executor, options);
server.RegisterService(adapter.get());
```

Keep the service, executor, and adapter alive until the Server has stopped. Drain
submitted executor work before destroying the service. Direct `EventService`
implementations receive client-streaming and bidirectional call handles on reactor
threads; move those handles to application workers before calling their blocking `Read`
helpers.

`grpc_lite::ServerExecutor` is application-owned. `Submit` must enqueue without blocking;
handlers may block only on executor threads. Rejection completes the call with
`RESOURCE_EXHAUSTED`. The facade never creates worker threads.

`SynchronousServiceOptions::admission` may provide an application-owned, nonblocking
reactor hook that rejects metadata before a call enters the executor.

Complete consumers live under `examples/cpp`. Build them against an installed prefix:

```bash
cmake -S examples/cpp -B build-cpp -G Ninja \
  -DCMAKE_PREFIX_PATH="$PWD/zig-out"
cmake --build build-cpp
```

`mise run test-consumer-cpp` packages the project, resolves the installed package's
`protobuf` component, regenerates C++ sources, starts the installed server, and runs the
examples.

## Abseil Policy

grpc-lite does not expose Abseil in its selected grpcpp-shaped API and does not install
substitute `absl/*` headers. Abseil used internally by a chosen Protobuf release remains
that package's transitive dependency. Applications that include Abseil directly must
continue to provide it or migrate those call sites separately.

## Sanitizing transpiled-C consumers

The Zig C backend reconstructs imported C types (including opaque pointers and
nghttp2 callback types). Clang's UBSan `function` check cannot match those
reconstructed types to the original C declarations. For a sanitized CMake
consumer, compile the C runtime and its C dependencies with
`-fsanitize=address,undefined -fno-sanitize=function`; C++ consumer code can keep
`-fsanitize=address,undefined` without that exclusion. Link with the sanitizer
flags as well.

Zig's thread startup installs its own alternate signal stack. Run ASan consumers
with `ASAN_OPTIONS=detect_leaks=1:halt_on_error=1:use_sigaltstack=0` to avoid ASan
trying to unmap that stack at pthread teardown. This disables ASan's alternate
signal stack, not address or leak detection. Use `UBSAN_OPTIONS=halt_on_error=1`
to fail on the remaining undefined-behavior checks. These settings are validation
constraints, not a claim of full function-type sanitizer coverage.
