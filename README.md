# grpc-lite

[![CI](https://github.com/fanyang89/grpc-lite/actions/workflows/ci.yml/badge.svg)](https://github.com/fanyang89/grpc-lite/actions/workflows/ci.yml)

A lightweight gRPC core runtime for Zig. HTTP/2 behavior is delegated to pinned upstream
`nghttp2`; sockets and the event loop use native Zig through `libxev`. Protobuf encoding
remains separate from transport.

The top-level types shown in this README form the stable public API. Lower-level module
exports remain available for experimentation but may change before 1.0.

## Features

- Standard unary gRPC over cleartext HTTP/2
- Persistent multiplexed channels
- ASCII and binary initial and trailing metadata
- Deadlines and deadline-driven HTTP/2 stream cancellation
- Unary identity and gzip compression
- GOAWAY connection replacement and graceful server draining
- Explicit allocators and deterministic `deinit`
- Raw protobuf wire APIs with no required message runtime
- Optional typed APIs and service registration through zig-protobuf

The transport remains IPv4-only. TLS, DNS, automatic RPC retries, and server reflection
remain out of scope.

## Streaming Target

The compatibility target is `grpc-lite-streaming-insecure-v2`: raw unary,
client-streaming, server-streaming, and bidirectional streaming over cleartext HTTP/2.
Raw streaming is implemented and verified against grpc-go. Typed streaming will follow
the raw transport incrementally and is not claimed complete.

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
mise run test-consumer
mise run fmt
mise run ci-lint
mise run interop
mise run interop-official
mise run interop-http2
mise run interop-http2-edge
mise run gen-proto
```

See `tests/official/README.md` for the supported interoperability profile and current
results.

CI runs the core build and test suite on Linux x64 and arm64 in Debug and ReleaseSafe
modes. Required x64 jobs instrument Zig, libxev, and nghttp2 with ThreadSanitizer and C
undefined behavior detection. Runtime interoperability runs on both architectures; the
official HTTP/2 edge-case container runs on x64 because its pinned image is amd64-only.
A scheduled x64 workflow runs extended official unary soak tests.

## Unary Client

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
});
defer server.deinit();

try server.registerUnary(
    "/demo.EchoService/Echo",
    grpc.UnaryHandler.bind(EchoService, &service, EchoService.echo),
);
try server.start();
server.wait();
```

Handlers can inspect propagated deadlines with `ServerContext.hasDeadline`,
`remainingTimeNs`, and `isDeadlineExceeded`. Handlers are not force-cancelled; a response
returned after the deadline is replaced with `DEADLINE_EXCEEDED`.

See `examples/echo_server.zig` and `examples/echo_client.zig` for complete programs.

## Protobuf

The optional `grpc_lite_protobuf` module integrates Arwalk/zig-protobuf while keeping
the transport core raw-byte based. `proto/echo.proto` is generated into
`.zig-cache/generated/demo.pb.zig` during the build.

Downstream dependencies expose only the raw `grpc_lite` module by default. Pass
`.protobuf = true` when declaring the dependency to fetch zig-protobuf and expose
`grpc_lite_protobuf`. Repository builds enable protobuf support by default.

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
defer registration.deinit();

try registration.register(&server);
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
gRPC status. A context hook exposes request and response metadata. Typed streaming is
planned to follow the raw transport and may remain unsupported while that work is
ongoing.

## Dependencies

- Zig 0.16.0
- nghttp2 1.69.0
- libxev b0650f0
- zig-protobuf 5.0.0
- CMake and Ninja for the upstream C builds
- mise for tool versions and project tasks

## License

MIT
