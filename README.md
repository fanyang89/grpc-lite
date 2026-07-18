# grpc-lite

[![CI](https://github.com/fanyang89/grpc-lite/actions/workflows/ci.yml/badge.svg)](https://github.com/fanyang89/grpc-lite/actions/workflows/ci.yml)

A lightweight gRPC core runtime for Zig. HTTP/2 and event-loop behavior are delegated
to pinned upstream `nghttp2` and `libuv` submodules. Protobuf encoding remains separate
from transport.

## Features

- Standard unary gRPC over cleartext HTTP/2
- Persistent multiplexed channels
- Initial and trailing metadata
- Deadlines and HTTP/2 stream cancellation
- Explicit allocators and deterministic `deinit`
- Raw protobuf wire payloads with no code generation dependency

The first phase is IPv4-only. Streaming, TLS, DNS, retries, reconnect, compression,
reflection, and generated protobuf code are not implemented.

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
mise run fmt
mise run interop
```

## Unary Client

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

See `examples/echo_server.zig` and `examples/echo_client.zig` for complete programs.

## Dependencies

- Zig 0.16.0
- nghttp2 1.69.0
- libuv 1.52.1
- CMake and Ninja for the upstream C builds
- mise for tool versions and project tasks

## License

MIT
