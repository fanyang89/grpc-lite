# grpc-lite

[![CI](https://github.com/fanyang89/grpc-lite/actions/workflows/ci.yml/badge.svg)](https://github.com/fanyang89/grpc-lite/actions/workflows/ci.yml)

A lightweight gRPC core runtime for Zig. HTTP/2 and event-loop behavior are delegated
to pinned upstream `nghttp2` and `libuv` submodules. Protobuf encoding remains separate
from transport.

## Features

- Standard unary gRPC over cleartext HTTP/2
- Persistent multiplexed channels
- ASCII and binary initial and trailing metadata
- Deadlines and HTTP/2 stream cancellation
- Unary identity and gzip compression
- GOAWAY connection replacement and graceful server draining
- Explicit allocators and deterministic `deinit`
- Raw protobuf wire APIs with no required message runtime
- Optional typed APIs and service registration through zig-protobuf

The first phase is IPv4-only. Streaming, TLS, DNS, automatic RPC retries, and server
reflection are not implemented.

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
modes. Runtime interoperability runs on both architectures; the official HTTP/2
edge-case container runs on x64 because its pinned image is amd64-only. A scheduled x64
workflow runs extended official unary soak tests.

## Unary Client

`Channel.callUnary` supports concurrent callers. `Channel.shutdown` may run while calls
are active; join those caller threads before giving `Channel.deinit` exclusive access.

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

`CallResult` owns its payload, status message, and response metadata.

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
gRPC status. A context hook exposes request and response metadata. Generated streaming
methods are rejected at compile time because the current transport is unary-only.

## Dependencies

- Zig 0.16.0
- nghttp2 1.69.0
- libuv 1.52.1
- zig-protobuf 5.0.0
- CMake and Ninja for the upstream C builds
- mise for tool versions and project tasks

## License

MIT
