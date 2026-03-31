# grpc-lite

`grpc-lite` is a Linux-first, C++17-friendly gRPC runtime skeleton aimed at
small C++ projects that want protocol-compatible building blocks without
pulling in the full upstream gRPC stack.

Current direction:

- public API in C++
- transport/runtime core backed by small C libraries
- unary RPC first
- official gRPC over HTTP/2 compatibility as the long-term target

## Current Selection

The current implementation is converging on this stack:

- transport: `libuv + libnghttp2`
- protobuf runtime: `upb`
- code generation: `protoc + protoc-gen-upb + protoc-gen-upb_minitable`
- build system: `CMake`
- language level: `C++17`

Design rules behind this selection:

- use Linux system packages first when they already exist
- prefer small C libraries in the runtime core
- keep heavy dependencies out of the public C++ API
- separate the transport/runtime layer from protobuf code generation

That means `grpc-lite` should eventually look like this:

- `grpc-lite` core: HTTP/2, gRPC framing, status, metadata, service dispatch
- `upb`: message parse and serialize
- `grpc-lite` plugin: generate thin unary service glue on top of `upb`

## Dependency choices

Core dependencies:

- `upb`
- `libnghttp2`
- `libuv`
- `CMake`
- `C++17`

Optional dependencies:

- `OpenSSL` for TLS/ALPN
- `c-ares` for resolver support
- `spdlog` and `fmt` for internal logging
- `abseil-cpp` only when an internal utility really benefits from it

Build-time tooling:

- `protoc`
- `protoc-gen-upb`
- `protoc-gen-upb_minitable`

Currently not selected as the long-term runtime path:

- `libprotobuf C++` as the main message runtime
- `grpc_cpp_plugin` as the final RPC code generator

`libprotobuf` can still appear in tooling or transitional examples, but the
runtime target is `upb` rather than the full C++ protobuf object model.

The design keeps these out of the public API where possible so C++ consumers do
not inherit unnecessary integration cost.

## Architecture

- `include/grpc_lite/`: stable public C++ API surface
- `src/core/`: transport/event-loop integration around vendorable or system C
  libraries
- `examples/`: compile-time smoke tests and reference wiring
- `golden/`: upstream reference trees for gRPC, protobuf, and Abseil

The current codebase already has a minimal cleartext HTTP/2 unary server path
built on `libuv + nghttp2`. The runtime can accept a single gRPC request,
decode one unary frame, dispatch it to a registered `Service`, and write a gRPC
response with trailers.

The protobuf message layer now uses `upb` for the main generated example path.
The intended steady state is:

- core runtime does not depend on `libprotobuf C++`
- service glue is generated separately from message code
- message code comes from `upb` generators

Current implementation limits:

- cleartext `h2c` only
- unary RPC only
- exactly one protobuf message per request body
- no compression
- no TLS, resolver, streaming, or load balancing yet
- only unary server-side glue is generated right now

## Build

```bash
cmake -S . -B build
cmake --build build
```

Run the demo echo server:

```bash
./build/grpc_lite_echo_server
```

Run the current `upb`-backed echo server:

```bash
./build/grpc_lite_proto_echo_server
```

Smoke test it with `curl` using HTTP/2 prior knowledge and an empty unary frame:

```bash
printf '\x00\x00\x00\x00\x00' > /tmp/grpc-lite-empty.bin
curl --http2-prior-knowledge \
  -H 'content-type: application/grpc' \
  -H 'te: trailers' \
  --data-binary @/tmp/grpc-lite-empty.bin \
  http://127.0.0.1:50051/demo.EchoService/Echo
```

Smoke test the `upb` echo path end to end:

```bash
./examples/proto_echo_smoke.sh
```

## Configuration knobs

- `GRPC_LITE_USE_SYSTEM_PROTOBUF=ON`
- `GRPC_LITE_USE_SYSTEM_NGHTTP2=ON`
- `GRPC_LITE_USE_SYSTEM_LIBUV=ON`
- `GRPC_LITE_ENABLE_OPENSSL=OFF`
- `GRPC_LITE_ENABLE_CARES=OFF`
- `GRPC_LITE_ENABLE_LOGGING=OFF`

Vendored fallback hooks are intentionally left as the next step so the project
can add `third_party/nghttp2` and `third_party/libuv` cleanly instead of mixing
system and local dependency logic into the first commit.

## Near-Term Plan

- keep `libuv + nghttp2` as the transport base
- switch protobuf examples and generated glue to `upb + upb_minitable`
- add a tiny `grpc-lite` code generator for unary server-side glue
- validate the generated service path before building a typed client stub

The generated example path now uses:

- `protoc-gen-upb`
- `protoc-gen-upb_minitable`
- `protoc-gen-grpc_lite_upb`
