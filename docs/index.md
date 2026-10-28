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

## Integrate with Zig

Use grpc-lite as a dependency of **your application**. The
[Zig quickstart](zig-quickstart.md) walks through:

1. Adding the package with `zig fetch --save` and wiring it into `build.zig`.
2. Defining messages and a service in a `.proto` file.
3. Generating Zig code as part of your application's build.
4. Implementing a typed server and calling it with a typed client.

Build and run with `zig build` and `zig build run`. You do not need a grpc-lite
checkout or its maintainer tasks. If your application already handles protobuf wire
bytes, the [raw Zig API](zig-api.md) is also available without protobuf code generation.

For C/C++, follow the [C/C++ integration guide](c-cpp-api.md).

## Next steps

- Read the [Zig API guide](zig-api.md) for streaming, deadlines, metadata, and TLS.
- Follow the [C/C++ guide](c-cpp-api.md) for release bundles and service generation.
- Review [capacity tuning](capacity-tuning.md) before sizing production workloads.
- Check [compatibility](compatibility.md) for supported platforms and gRPC features.

grpc-lite targets a selected gRPC subset: IPv6, automatic RPC retries, reflection,
xDS, and the full grpcpp API are out of scope.
