# grpc-lite

`grpc-lite` is a Linux-first gRPC runtime skeleton for small C++ projects that
want protocol-compatible unary RPC building blocks without pulling in the full
upstream gRPC stack.

## Current Selection

The current implementation uses this stack:

- transport: `libuv + libnghttp2`
- protobuf wire codec: `struct_proto26`
- schema source: C++ structs walked by C++26 static reflection
- build system: `CMake`
- core language level: C++17 for the transport/runtime core
- message language level: C++26 with `-freflection`

The protobuf layer intentionally does not use `.proto` code generation in the
default build. Message types are plain C++ structs, and `struct_proto26`
serializes/deserializes them directly to proto3 wire bytes.

## Architecture

- `include/grpc_lite/`: stable public C++ runtime API surface
- `include/grpc_lite/proto3/`: struct-based example schemas
- `src/core/`: transport/event-loop integration around system C libraries
- `third_party/struct_proto26/`: header-only proto3 wire codec
- `examples/`: compile-time smoke tests and reference wiring
- `tests/`: wire-compatibility checks against canonical proto3 bytes
- `golden/`: upstream reference trees kept for comparison work

The runtime currently has a minimal cleartext HTTP/2 unary server path built on
`libuv + nghttp2`. It accepts a single gRPC request, decodes one unary gRPC
frame, dispatches it to a registered `Service`, and writes a gRPC response with
trailers.

The message layer is separate from the transport layer. The transport passes
protobuf payloads as `std::string`; examples use `proto3::serialize()` and
`proto3::deserialize<T>()` from `struct_proto26` at the service boundary.

## Dependencies

Core dependencies:

- `libnghttp2`
- `libuv`
- `CMake`
- `C++17`

`libnghttp2` and `libuv` can come from system packages or from the public
submodules under `third_party/`. System packages are the default for normal
builds. Sanitizer builds use the submodules so the dependency code is built with
the same instrumentation as `grpc-lite`.

Message/example/test dependencies:

- `struct_proto26`
- a compiler with C++26 static reflection support and `-freflection`

Optional dependencies:

- `OpenSSL` for TLS/ALPN hooks
- `c-ares` for resolver hooks
- `spdlog` and `fmt` for internal logging hooks
- `abseil-cpp` only when an internal utility really benefits from it

Not used by the default build path:

- `upb`
- `protoc`
- `protoc-gen-upb`
- `protoc-gen-upb_minitable`
- `grpc_cpp_plugin`
- `libprotobuf C++`

## Build

Prefer Ninja when available:

```bash
cmake -S . -B build -G Ninja
cmake --build build
```

If the selected compiler does not support `-std=c++26 -freflection`, configure
may succeed but the struct_proto26 examples/tests will fail to compile.

Run the raw echo server:

```bash
./build/grpc_lite_echo_server
```

Run the struct_proto26-backed echo server:

```bash
./build/grpc_lite_proto_echo_server
```

Smoke test the struct_proto26 echo path end to end:

```bash
./examples/proto_echo_smoke.sh
```

Run the proto3 wire compatibility test:

```bash
ctest --test-dir build --output-on-failure
```

## Compatibility Testing

`tests/proto3_wire_test.cc` compares `struct_proto26` output with canonical
proto3 wire bytes for the reference schema in `proto/echo.proto`:

```proto
message EchoRequest {
  string message = 1;
}

message EchoReply {
  string message = 1;
}
```

For `message = "hello grpc-lite"`, the canonical wire bytes are:

```text
0a 0f 68 65 6c 6c 6f 20 67 72 70 63 2d 6c 69 74 65
```

The test checks both directions:

- struct serialization equals the canonical proto3 bytes
- canonical proto3 bytes deserialize into the expected C++ structs
- default string fields are omitted, matching proto3 semantics

`proto/echo.proto` remains as a human-readable compatibility reference only; it
is not used by CMake and does not introduce a `protoc` dependency.

## Configuration Knobs

- `GRPC_LITE_USE_SYSTEM_NGHTTP2=ON` uses `pkg-config` system `libnghttp2`
- `GRPC_LITE_USE_SYSTEM_NGHTTP2=OFF` builds `third_party/nghttp2`
- `GRPC_LITE_USE_SYSTEM_LIBUV=ON` uses `pkg-config` system `libuv`
- `GRPC_LITE_USE_SYSTEM_LIBUV=OFF` builds `third_party/libuv`
- `GRPC_LITE_ENABLE_OPENSSL=OFF`
- `GRPC_LITE_ENABLE_CARES=OFF`
- `GRPC_LITE_ENABLE_LOGGING=OFF`
- `GRPC_LITE_BUILD_EXAMPLES=ON`
- `GRPC_LITE_BUILD_TESTS=ON`
- `GRPC_LITE_SANITIZE=` enables no sanitizer
- `GRPC_LITE_SANITIZE=address` builds with ASan and vendored `nghttp2/libuv`
- `GRPC_LITE_SANITIZE=thread` builds with TSan and vendored `nghttp2/libuv`
