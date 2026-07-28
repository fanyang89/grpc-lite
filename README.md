# grpc-lite

[![CI](https://github.com/fanyang89/grpc-lite/actions/workflows/ci.yml/badge.svg)](https://github.com/fanyang89/grpc-lite/actions/workflows/ci.yml)

A lightweight gRPC core runtime for Zig. HTTP/2 behavior is delegated to pinned upstream
`nghttp2`; sockets and the event loop use native Zig through `libxev`. Protobuf encoding
remains separate from transport.

The top-level types shown in this README form the stable public API. Lower-level module
exports remain available for experimentation but may change before 1.0.

## Features

- Unary and streaming gRPC over cleartext HTTP/2 or optional TLS
- Persistent multiplexed channels
- Asynchronous IPv4 hostname resolution through c-ares
- ASCII and binary initial and trailing metadata
- Deadlines and deadline-driven HTTP/2 stream cancellation
- Unary identity and gzip compression
- GOAWAY connection replacement and graceful server draining
- Explicit allocators and deterministic `deinit`
- Raw protobuf wire APIs with no required message runtime
- Optional typed APIs and service registration through zig-protobuf
- Shared asynchronous process logging for Zig applications

The transport remains IPv4-only. Automatic RPC retries, mTLS, system CA discovery, and
server reflection remain out of scope.

## Streaming Target

The compatibility target is `grpc-lite-streaming-insecure-v2`: raw unary,
client-streaming, server-streaming, and bidirectional streaming over cleartext HTTP/2,
with TLS available as an opt-in transport extension.
Raw streaming is implemented and verified against grpc-go. The optional zig-protobuf
adapter provides event-driven typed clients and servers for every streaming cardinality.

The raw API is entirely event-driven. Application callbacks run on transport
loop threads and must not block. It provides explicit half-close and streaming-only
explicit cancellation, explicit allocators and deterministic `deinit`, bounded
backpressure in both directions, and per-message `identity` or `gzip` compression.

## Development

```bash
mise install
mise run bootstrap
mise run check
```

Useful tasks:

```bash
mise run build
mise run test
mise run test-release-safe
mise run test-tsan
mise run test-ubsan
mise run test-tls
mise run test-tls-tsan
mise run test-consumer
mise run test-consumer-cpp
mise run prepare-network-deps
mise run prepare-tls-deps
mise run prepare-gperftools
mise run build-gperftools
mise run test-gperftools
mise run fmt
mise run ci-lint
mise run interop
mise run interop-official
mise run interop-tls
mise run interop-http2
mise run interop-http2-edge
mise run gen-proto
mise run gen-grpcpp
```

See `tests/official/README.md` for the supported interoperability profile and current
results.

CI runs the core build and test suite on Linux x64 and arm64 in Debug and ReleaseSafe
modes. Required x64 jobs instrument Zig, libxev, and nghttp2 with ThreadSanitizer and C
undefined behavior detection. Runtime interoperability runs on both architectures; the
vendored official HTTP/2 edge-case container also runs on both architectures. A
scheduled x64 workflow runs extended official unary soak tests.

## C ABI

`zig build` installs the C ABI header and self-contained shared library under
`zig-out/include` and `zig-out/lib`. The ABI uses opaque handles, fixed-width error
codes, and pointer-length byte views; memory allocated by the library is released only
through its matching destroy function.

```bash
cc app.c \
  -Izig-out/include \
  -Lzig-out/lib -Wl,-rpath,"$PWD/zig-out/lib" \
  -lgrpc_lite
```

The ABI surface provides version and feature discovery, owning Runtime and Metadata
handles, insecure connected or managed Channels, blocking raw unary calls, and
cancellable event-driven client streams with bounded backpressure. Managed Channels
may be created before their endpoint is available and reconnect with bounded exponential
backoff. Stream callbacks run on the
transport loop thread and must not block. The C server API supports event-driven
method registration, retained cross-thread calls, explicit metadata, streaming
responses, cancellation observation, and graceful drain. Runtime
initialization must happen before application threads are created and must outlive
dependent handles. C and C++ compile/link smoke tests run as part of `zig build test`;
the grpcpp-shaped facade builds on this ABI in later stages.

Channel and Server options accept an optional `grpc_lite_logger`. It reports transport
lifecycle events such as connection recovery, GOAWAY, startup, and graceful drain.
Callbacks run synchronously on API caller or transport threads and may run concurrently.
Logger configuration is borrowed during handle creation, while its user data must
outlive the owning handle.

`grpc_lite_channel_create_managed` creates a durable Channel. Set
`allow_initial_offline` when creation must return before the first connection succeeds.
The Channel reconnects after transport failures without replaying submitted RPCs.
Unsubmitted unary calls retain their original deadline while waiting for a connection.
Use `grpc_lite_channel_shutdown` to stop admission and active work, then
`grpc_lite_channel_wait` before exclusive destruction when calls may be concurrent.
Direct compiler invocation should use the versioned shared library. CMake consumers can
also build and link the static archive directly from source with FetchContent; the
static target carries its required Linux system libraries:

```cmake
include(FetchContent)
FetchContent_Declare(
  grpc_lite
  GIT_REPOSITORY https://github.com/fanyang89/grpc-lite.git
  GIT_TAG v0.3.1)
FetchContent_MakeAvailable(grpc_lite)

target_link_libraries(shared_app PRIVATE grpc_lite::c)
target_link_libraries(static_app PRIVATE grpc_lite::c_static)
```

This source-build integration requires Zig 0.16.0 and currently supports Linux. Set
`GRPC_LITE_ENABLE_TLS=ON` before `FetchContent_MakeAvailable` to enable TLS, or set
`GRPC_LITE_ZIG_OPTIMIZE` to override the optimization mode derived from the CMake build
configuration.

## Synchronous C++ Facade

The installed C++17 facade provides the common synchronous grpcpp client shape through
`<grpcpp/grpcpp.h>`. It includes `Status`, `ClientContext`, `CreateChannel`, insecure
credentials, and the internal blocking unary helper used by regenerated service glue.
It does not provide grpcpp ABI compatibility or official generated glue.

```cmake
find_package(grpc_lite 0.3 CONFIG REQUIRED)
target_link_libraries(app PRIVATE grpc_lite::grpcpp)
```

`grpc_lite::grpcpp` links the versioned shared C transport through `grpc_lite::c`.
The initial facade accepts IPv4 targets; hostname channels require explicit Runtime
ownership through the lower-level C ABI.

The installed Zig protoc plugin generates synchronous unary service stubs alongside
the standard protobuf C++ messages. Streaming-only services and streaming methods are
omitted from this glue.

```bash
protoc -I proto \
  --cpp_out=generated \
  --plugin=protoc-gen-grpc_lite_cpp=zig-out/bin/protoc-gen-grpc_lite_cpp \
  --grpc_lite_cpp_out=generated \
  proto/echo.proto
```

This produces `echo.grpc.pb.h` and `echo.grpc.pb.cc`. Compile both those files
and the standard `echo.pb.cc`, then link `grpc_lite::grpcpp` and protobuf.

`examples/cpp` contains complete CMake consumers for typed echo calls, metadata and
large messages, and status/deadline handling. They require `protoc` and the protobuf
C++ development library. Build them against an installed prefix:

```bash
cmake -S examples/cpp -B build-cpp -G Ninja \
  -DCMAKE_PREFIX_PATH="$PWD/zig-out"
cmake --build build-cpp
```

`mise run test-consumer-cpp` builds an isolated package snapshot, regenerates the C++
sources, starts the installed Zig server, and runs all three examples.

## Unary Client

IPv4 literals require no global setup. Hostname targets use c-ares and require a Runtime
initialized before the application creates any threads. The runtime must outlive every
channel that references it.

```zig
var runtime = try grpc.Runtime.init();
defer runtime.deinit();

var channel = try grpc.Channel.init(allocator, "api.example.com:50051", .{
    .runtime = &runtime,
    .reconnect = .{ .allow_initial_offline = true },
});
defer channel.deinit();
```

Reconnect backoff defaults to the gRPC connection-backoff parameters: a one-second
initial delay, 1.6 multiplier, 120-second cap, and 20 percent jitter. A successful
connection resets the backoff. Connection recovery never retries an RPC that may have
reached the server; applications remain responsible for RPC retry policy.

`Channel.callUnary` supports concurrent callers. `Channel.shutdown` may run while calls
are active; join those caller threads before giving `Channel.deinit` exclusive access.
The channel serializes access to the allocator passed to `Channel.init`.

```zig
const std = @import("std");
const grpc = @import("grpc_lite");

var channel = try grpc.Channel.init(allocator, "127.0.0.1:50051", .{});
defer channel.deinit();

var result = try channel.callUnary(
    allocator,
    "/demo.EchoService/Echo",
    protobuf_wire_bytes,
    .{ .timeout_ns = 5 * std.time.ns_per_s },
);
defer result.deinit();
```

Each `CallResult` owns its payload, status message, and response metadata through the
result allocator passed to `callUnary`. Callers must ensure thread safety when sharing
one result allocator across threads. A non-thread-safe result allocator must not alias
the channel backing allocator while the channel is active.

Raw unary calls also have an event-driven API:

```zig
try channel.callUnaryAsync(
    "/demo.EchoService/Echo",
    protobuf_wire_bytes,
    .{ .timeout_ns = 5 * std.time.ns_per_s },
    .{
        .context = &state,
        .on_complete = State.onComplete,
    },
);
```

`callUnaryAsync` copies the method path, request, and request metadata before returning.
A successful return means the call was accepted and its completion callback will run
exactly once. Synchronous validation, allocation, unavailable-channel, and notification
failures return an error without invoking the callback. There is no unary cancellation
API; explicit cancellation remains streaming-only.

The completion callback runs on the Channel transport loop thread and must not block or
call `Channel.deinit`. Its payload, status message, and initial and trailing metadata are
borrowed only until the callback returns and must not be retained. The Channel releases
the operation immediately after callback return. `Channel.deinit` shuts down the loop
and waits for every accepted async unary callback to finish before releasing Channel
storage.

## TLS

TLS is an optional mbedTLS 3.6.6 dependency. Prepare it once, then enable it on the package
dependency:

```bash
mise run prepare-tls-deps
zig build -Dtls=true
```

```zig
const grpc_lite = b.dependency("grpc_lite", .{
    .target = target,
    .optimize = optimize,
    .tls = true,
});
```

Client TLS trusts only the supplied PEM CA bundle. It does not search system roots.
Hostname verification and SNI use the hostname from the channel target, TLS 1.2 or newer
is required, and ALPN must negotiate `h2`. The default handshake timeout is 10 seconds.

```zig
var runtime = try grpc.Runtime.init();
defer runtime.deinit();

var channel = try grpc.Channel.init(allocator, "api.example.com:443", .{
    .runtime = &runtime,
    .tls = .{ .ca_certificates_pem = ca_pem },
});
defer channel.deinit();
```

Server TLS accepts a PEM certificate chain and an unencrypted PEM private key. PEM input
is parsed during `init` and may be released after it returns.

```zig
var server = try grpc.Server.init(allocator, .{
    .host = "127.0.0.1",
    .port = 50051,
    .tls = .{
        .certificate_chain_pem = certificate_chain_pem,
        .private_key_pem = private_key_pem,
    },
});
```

## Metadata

Application metadata keys use lowercase gRPC header syntax. ASCII values must be visible
ASCII when sent; invalid incoming ASCII fields are discarded as required by the gRPC
protocol. Binary `-bin` values remain raw bytes in the API, accept padded, unpadded, and
comma-joined base64 on the wire, and reject malformed input on only the affected RPC.

## Unary Server

```zig
var server = try grpc.Server.init(allocator, .{
    .host = "127.0.0.1",
    .port = 50051,
    .reactor_count = 4,
});
defer server.deinit();

try server.registerUnary(
    "/demo.EchoService/Echo",
    grpc.UnaryHandler.bind(EchoService, &service, EchoService.echo),
);
try server.start();
server.wait();
```

`reactor_count` defaults to one. Values greater than one create independent Linux
reactor threads, event loops, listeners, HTTP/2 sessions, connection state, deadline
heaps, and write pools. The listeners share the configured IPv4 port with
`SO_REUSEPORT`; each TCP connection and all of its streams remain on one reactor.
Multi-core scaling therefore requires multiple client connections or channels.

Each reactor uses a non-thread-safe local size-class allocator for connection, stream,
deadline, TLS session, and socket-write state. Small transport allocations therefore
remain on the owner reactor. Page refills, large allocations, coordinator state,
`std.Io.Threaded`, TLS configuration, and cross-thread streaming commands use a
serialized allocator backed by the allocator passed to `Server.init`, so that backing
allocator may be non-thread-safe.

The allocator passed to unary handlers and stored in `ServerContext` is reactor-local.
It may be used only during the callback on its owner reactor; allocations must be freed
there and must not be retained by another thread. A returned `UnaryResponse` is consumed
and released synchronously on that reactor. `ServerStream` handles may be used from
application threads because `send`, `finish`, and `resumeReceive` copy command data into
shared serialized storage. With multiple reactors, handler contexts, application-owned
shared state, and application allocators used across callbacks must still be
thread-safe. Callbacks run concurrently across reactor threads and must not block.

`ServerStream` itself is a borrowed callback view. A handler that dispatches work to
another thread must call `ServerStream.retain` and pass the returned owning `ServerCall`.
The call remains queryable after transport termination, when its commands return
`CallClosed`; every clone must be deinitialized before the Server. `on_terminal` runs
exactly once and is the final callback for that call.

Adapters that need to decide response metadata outside `on_start` can register a stream
handler with `receive_initially_paused = true` and `initial_metadata_mode = .explicit`.
The worker then calls `ServerCall.sendInitialMetadata`, `resumeReceive`, `send`, and
`finish`. Initial metadata must be queued before a message or final status; `finish`
copies its status and trailing metadata before returning. Existing handlers retain the
default behavior of submitting initial metadata immediately after `on_start`.

Handlers can inspect propagated deadlines with `ServerContext.hasDeadline`,
`remainingTimeNs`, and `isDeadlineExceeded`. Handlers are not force-cancelled; a response
returned after the deadline is replaced with `DEADLINE_EXCEEDED`.

See `examples/echo_server.zig` and `examples/echo_client.zig` for complete programs.

## Protobuf

The `grpc_lite` module exports the shared zig-protobuf runtime as `grpc.protobuf`.
Its build package exports `createProtocStep` and `protobuf_codegen` for downstream
code generation. The optional `grpc_lite_protobuf` module adds typed gRPC adapters
while keeping the transport core raw-byte based. `proto/echo.proto` is generated into
`.zig-cache/generated/demo.pb.zig` during the build.

Downstream dependencies always expose `grpc_lite` and
`grpc_lite_protobuf_runtime`. Pass `.protobuf = true` when declaring the dependency
to additionally expose `grpc_lite_protobuf`. Repository builds enable the typed
adapter by default.

Generated service VTables can be registered without manually specifying method paths:

```zig
const demo = @import("demo_proto");
const grpc_pb = @import("grpc_lite_protobuf");

const EchoApi = demo.EchoService(EchoState, EchoError);

var registration = grpc_pb.ServiceRegistration(EchoApi).init(
    allocator,
    &state,
    .{ .Echo = EchoState.echo },
    .{
        .map_error = mapError,
        .context_hook = configureContext,
    },
);
try registration.register(&server);
// Call registration.deinit() after server.deinit().
```

The adapter derives `/demo.EchoService/Echo`, decodes `EchoRequest`, invokes the
generated VTable, and encodes `EchoReply`. Registration and userdata must outlive the
server. Returned response fields must be releasable with the registration allocator.

Typed calls infer their request and response types from the same service:

```zig
var client = grpc_pb.ServiceClient(EchoApi).init(&channel);
var result = try client.callUnary(
    allocator,
    "Echo",
    demo.EchoRequest{ .message = "hello" },
    .{},
);
defer result.deinit();
```

Business errors default to `INTERNAL`; an optional typed mapper can return another
gRPC status. A context hook exposes request and response metadata.

Typed streaming derives message types and identifies cardinality from the generated
service while preserving the raw event-driven transport:

```zig
const StreamingApi = demo.StreamingEchoService(AppState, AppError);

var registration = grpc_pb.StreamRegistration(StreamingApi, "Chat").init(
    allocator,
    .{
        .context = &state,
        .on_start = AppState.onStart,
        .on_message = AppState.onMessage,
        .on_remote_end = AppState.onRemoteEnd,
    },
);
try registration.register(&server);
// Call registration.deinit() after server.deinit().

var client = grpc_pb.ServiceClient(StreamingApi).init(&channel);
var call = try client.openStream(
    callback_allocator,
    "Chat",
    .{},
    callbacks,
);
defer call.deinit();
try call.send(send_allocator, demo.EchoRequest{ .message = "hello" }, .{});
try call.closeSend();
```

Typed callbacks run on transport loop threads and must not block. Decoded callback
messages are borrowed until the callback returns. `send` encodes into a temporary
buffer and propagates raw `WouldBlock`, pause/resume, cancellation, and compression
semantics without adding an unbounded queue. The generated blocking `std.Io.Queue`
service handlers are not executed by this adapter.

The callback allocator must remain valid through stream `deinit`; if `deinit` runs in a
callback, it must remain valid until that callback returns. An allocator shared across
application and callback threads must be thread-safe. Stream registrations, handler
contexts, and their allocators must remain at stable addresses until the server and all
active streams have stopped.

## Gperftools

Linux builds can optionally link the pinned gperftools fork for tcmalloc, CPU profiling,
heap profiling, and guarded allocation sampling. Prepare its Zig package cache once,
then enable it explicitly:

```bash
mise run prepare-gperftools
mise run build-gperftools -- -Doptimize=ReleaseFast
mise run test-gperftools
```

Downstream packages pass `.gperftools = true` to the `grpc_lite` dependency and import
`grpc_lite_gperftools`. Enabling the option replaces the final process C allocator with
tcmalloc; `perf.allocator` provides the same allocator explicitly to Zig APIs.

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

CPU and heap profilers are process-global and may also be activated with `CPUPROFILE`
and `HEAPPROFILE`. The module exposes profiler lifecycle functions, tcmalloc numeric
properties, ownership checks, memory release, and guarded sampling controls. Gperftools
cannot be combined with ThreadSanitizer and is not currently supported outside Linux.

## Benchmarks

The cross-process E2E harness builds dedicated client and server binaries in
`ReleaseFast`. It measures completed request/response exchanges after warmup rather than
local send-queue admission. Results are pretty JSON by default:

```bash
mise run bench -- --scenario bidi-ping-pong --transport typed
mise run bench -- --reactors=4 --channels=16 --streams=512
```

Supported scenarios are `unary`, `bidi-ping-pong`, and `bidi-throughput`. Common options
include `--warmup`, `--duration`, `--streams`, `--channels`, `--reactors`, `--pipeline`,
`--payload-bytes`, `--payload-pattern`, and `--compression`. Unary concurrency slots and
persistent streams are assigned round-robin across the configured channels; the channel
count must not exceed the stream count. Run `mise run bench --help` for the complete task
interface.

For multi-reactor server measurements, use at least as many channels as reactors, for
example `--reactors=N --channels=N` or greater. The result JSON records
`server_reactor_count`; this field is descriptive and does not alter client load.

The default matrix writes one parseable JSON document per case and prints each path:

```bash
mise run bench-all
```

Use `mise run bench-server` to start a separately managed server, then run
`mise run bench-client` with `--host` and `--port` locally or from a remote machine. Add
`--compact` only when single-line JSON is needed for automation.
Reported bytes are application request plus response payload bytes, not HTTP/2 wire
bytes. Raw unary uses event-driven callbacks with one in-flight call per preallocated
slot, while typed unary currently uses one blocking worker thread per slot. JSON reports
these as `client_execution_model: "event-driven"` and `"blocking-workers"`. Raw and typed
unary results therefore cannot be interpreted as a pure transport comparison; typed
runs also include protobuf encoding, decoding, and per-message arena costs.

The harness uses a closed-loop load model with fixed concurrency and one or more
channels. An exchange is eligible when its request starts inside the measurement window.
Eligible exchanges that finish during the bounded drain are included in completed/error
counts and full latency; warmup exchanges that finish during measurement are excluded.
Throughput still uses the configured measurement duration as its denominator. JSON
`min_us` and `max_us` cover every eligible latency, while percentiles and mean may use
the documented deterministic reservoir sample. `clock_source`, `clock_uses_cpucycles`,
and `clock_fallback_reason` report whether the selected cycle counter passed monotonic
stability checks or fell back to `CLOCK_MONOTONIC`.

Unary operations are complete RPCs, while bidi operations are messages on persistent
streams, so compare results only within the same scenario. `repeated` fills payloads with
`0x5a` and represents a highly compressible gzip workload. `deterministic-random` uses a
fixed-seed byte sequence for a repeatable higher-entropy workload. This harness remains
closed-loop: it does not provide open-loop arrival control or a cross-framework
comparison methodology.

## Dependencies

- Zig 0.16.0
- nghttp2 1.69.0
- libcpucycles 20260625
- libxev b0650f0
- zig-protobuf 5.0.0
- gperftools 2.18.1-based fork (optional)
- CMake and Ninja for the upstream C builds
- mise for tool versions and project tasks

## License

MIT
