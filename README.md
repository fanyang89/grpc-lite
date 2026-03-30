# grpc-lite

`grpc-lite` is a Linux-first, C++17-friendly gRPC runtime skeleton aimed at
small C++ projects that want protocol-compatible building blocks without
pulling in the full upstream gRPC stack.

Current direction:

- public API in C++
- transport/runtime core backed by small C libraries
- unary RPC first
- official gRPC over HTTP/2 compatibility as the long-term target

## Dependency choices

Core dependencies:

- `protobuf`
- `libnghttp2`
- `libuv`
- `CMake`
- `C++17`

Optional dependencies:

- `OpenSSL` for TLS/ALPN
- `c-ares` for resolver support
- `spdlog` and `fmt` for internal logging
- `abseil-cpp` only when an internal utility really benefits from it

The design keeps these out of the public API where possible so C++ consumers do
not inherit unnecessary integration cost.

## Architecture

- `include/grpc_lite/`: stable public C++ API surface
- `src/core/`: transport/event-loop integration around vendorable or system C
  libraries
- `examples/`: compile-time smoke tests and reference wiring
- `golden/`: upstream reference trees for gRPC, protobuf, and Abseil

The current codebase is still a scaffold. It already expresses the chosen
dependency split and build strategy, and it now includes a minimal cleartext
HTTP/2 unary server path built on `libuv + nghttp2`. The runtime can accept a
single gRPC request, decode one unary frame, dispatch it to a registered
`Service`, and write a gRPC response with trailers. It also has a protobuf echo
example built from `proto/echo.proto` through `protoc`.

Current implementation limits:

- cleartext `h2c` only
- unary RPC only
- exactly one protobuf message per request body
- no compression
- no TLS, resolver, streaming, reflection, or code generation yet

## Build

```bash
cmake -S . -B build
cmake --build build
```

Run the demo echo server:

```bash
./build/grpc_lite_echo_server
```

Run the protobuf-backed echo server:

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

Smoke test the protobuf echo path end to end:

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
