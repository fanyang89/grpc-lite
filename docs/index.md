---
title: Getting started
description: A lightweight, streaming-first gRPC runtime for Zig, C, and C++.
---

# Getting started

grpc-lite is a lightweight gRPC runtime with raw unary and full-duplex streaming,
explicit ownership, and bounded backpressure. nghttp2 owns HTTP/2; libxev owns
sockets and the event loop.

## Choose your API

- **[Zig](zig-api.md)** — native transport, raw protobuf bytes, optional typed
  zig-protobuf adapters, and optional TLS/mTLS.
- **[C and C++](c-cpp-api.md)** — stable C ABI and a focused grpcpp-shaped synchronous
  facade. Release-generated C bundles build with CMake without Zig on Linux x86_64
  and ARM64; these bundles support cleartext transport only.

## Build from source

Install [mise](https://mise.jdx.dev/), then run:

```sh
git clone https://github.com/fanyang89/grpc-lite.git
cd grpc-lite
mise install
mise run bootstrap
mise run build
mise run test
```

See the [development guide](development.md) for build options and validation tasks,
or the [examples](../examples) for runnable clients and servers.

## Integrate with Zig

Add grpc-lite to your `build.zig.zon` dependencies, then import the raw module:

```zig
const grpc_lite = b.dependency("grpc_lite", .{
    .target = target,
    .optimize = optimize,
    .protobuf = false,
});
exe.root_module.addImport("grpc_lite", grpc_lite.module("grpc_lite"));
```

The raw API works with protobuf wire bytes:

```zig
const grpc = @import("grpc_lite");

var channel = try grpc.Channel.init(allocator, "127.0.0.1:50051", .{});
defer channel.deinit();

var result = try channel.callUnary(
    allocator,
    "/demo.EchoService/Echo",
    protobuf_wire_bytes,
    .{},
);
defer result.deinit();
```

## Next steps

- Read the [Zig API guide](zig-api.md) for streaming, deadlines, metadata, and TLS.
- Follow the [C/C++ guide](c-cpp-api.md) for release bundles and service generation.
- Review [capacity tuning](capacity-tuning.md) before sizing production workloads.
- Check the [interop profile](../tests/official/README.md) for supported gRPC cases.

grpc-lite targets a selected gRPC subset: IPv6, automatic RPC retries, reflection,
xDS, and the full grpcpp API are out of scope.
