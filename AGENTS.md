# grpc-lite — Agent / Developer Guide

This document contains build constraints, configuration references, and internal
architecture details for contributors and automated agents working on `grpc-lite`.

## Build Constraints

### Language Levels

- **Transport / runtime core**: C++17 (`-std=c++17`)
- **Message layer (struct_proto26)**: C++26 with `-freflection`

If the selected compiler does not support `-std=c++26 -freflection`, CMake configuration
will still succeed, but the `struct_proto26` examples and tests will fail to compile.
The core runtime builds fine with C++17 only.

### Compiler Recommendations

- GCC ≥ 12
- Clang ≥ 16

### Platform

Linux-first. The codebase uses `epoll` and Linux-specific `libuv` APIs.
Porting to other platforms requires abstraction work in `src/core/uv_loop.cc` and the
transport layer.

## Dependency Matrix

### Core Dependencies

| Dependency | System Default | Vendored Path | Notes |
| --- | --- | --- | --- |
| `libnghttp2` | `pkg-config libnghttp2` | `third_party/nghttp2` | Vendored build used automatically for sanitizer builds |
| `libuv` | `pkg-config libuv` | `third_party/libuv` | Vendored build used automatically for sanitizer builds |
| `CMake` | ≥ 3.20 | — |  |

### Message / Example / Test Dependencies

| Dependency | Source | Notes |
| --- | --- | --- |
| `struct_proto26` | `third_party/struct_proto26/` | Header-only proto3 wire codec |
| `refl-cpp` | `third_party/refl-cpp/include/` | Fallback reflection backend when C++26 `<meta>` is unavailable |
| `doctest` | `golden/grpc/.../doctest/` | Test framework (header-only) |

### Optional Dependencies

| Feature | CMake Option | Dependency |
| --- | --- | --- |
| TLS / ALPN | `GRPC_LITE_ENABLE_OPENSSL=ON` | OpenSSL |
| Async DNS | `GRPC_LITE_ENABLE_CARES=ON` | c-ares |
| Structured logging | `GRPC_LITE_ENABLE_LOGGING=ON` | spdlog + fmt |

### Explicitly NOT in Default Build

- `upb`
- `protoc`
- `protoc-gen-upb`
- `protoc-gen-upb_minitable`
- `grpc_cpp_plugin`
- `libprotobuf` (C++ runtime)

## CMake Configuration Reference

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `GRPC_LITE_USE_SYSTEM_NGHTTP2` | BOOL | `ON` | Use system `libnghttp2` via `pkg-config` |
| `GRPC_LITE_USE_SYSTEM_LIBUV` | BOOL | `ON` | Use system `libuv` via `pkg-config` |
| `GRPC_LITE_ENABLE_OPENSSL` | BOOL | `OFF` | Enable TLS hooks through OpenSSL |
| `GRPC_LITE_ENABLE_CARES` | BOOL | `OFF` | Enable c-ares based resolver hooks |
| `GRPC_LITE_ENABLE_LOGGING` | BOOL | `OFF` | Enable spdlog/fmt logging hooks when present |
| `GRPC_LITE_BUILD_EXAMPLES` | BOOL | `ON` | Build example executables |
| `GRPC_LITE_BUILD_TESTS` | BOOL | `ON` | Build test executables and enable `ctest` |
| `GRPC_LITE_ENABLE_IWYU` | BOOL | `OFF` | Run include-what-you-use during C++ builds |
| `GRPC_LITE_ENABLE_UBSAN` | BOOL | `ON` | Also enable UBSan when ASan is active |
| `GRPC_LITE_COVERAGE` | BOOL | `OFF` | Build with code-coverage instrumentation (Clang preferred) |
| `GRPC_LITE_SANITIZE` | STRING | `""` | `"address"` or `"thread"`. Forces vendored nghttp2/libuv. |
| `GRPC_LITE_PROTO_REFLECTION` | STRING | `"auto"` | `"auto"`, `"meta"` (C++26 `<meta>`), or `"refl_cpp"` |
| `GRPC_LITE_IWYU_EXECUTABLE` | FILEPATH | `""` | Path to `include-what-you-use` binary |

## Development Workflow

### Formatting

```bash
# Check formatting (CI uses Docker image built from repo Dockerfile)
./scripts/clang-format.sh check

# Apply formatting
./scripts/clang-format.sh
```

### Sanitizer Builds

Sanitizer builds automatically switch to vendored `nghttp2` and `libuv` so the
dependency code is instrumented with the same flags as `grpc-lite`.

```bash
cmake -S . -B build-asan -G Ninja -DGRPC_LITE_SANITIZE=address
cmake --build build-asan
ctest --test-dir build-asan --output-on-failure
```

```bash
cmake -S . -B build-tsan -G Ninja -DGRPC_LITE_SANITIZE=thread
cmake --build build-tsan
ctest --test-dir build-tsan --output-on-failure
```

### Coverage

```bash
cmake -S . -B build-cov -G Ninja -DGRPC_LITE_COVERAGE=ON
cmake --build build-cov
ctest --test-dir build-cov --output-on-failure
```

### Include-What-You-Use

```bash
cmake -S . -B build-iwyu -G Ninja -DGRPC_LITE_ENABLE_IWYU=ON
cmake --build build-iwyu 2>&1 | tee iwyu.log
```

## Architecture Details

### Directory Layout

- **`include/grpc_lite/`** — Stable public C++ runtime API surface.
  - `channel.h`, `server_builder.h`, `service.h`, `status.h`, `server_context.h`,
    `client_context.h`
- **`include/grpc_lite/proto3/`** — Struct-based example schemas (e.g., `echo.h`).
- **`src/core/`** — Transport and event-loop integration around system C libraries.
  - `grpc_frame.{cc,h}` — gRPC framing logic (length-prefixed messages, compression
    flags)
  - `http2_transport.cc` — nghttp2 integration
  - `uv_loop.cc` — libuv event-loop wiring
  - `transport.h` — Internal transport abstraction
- **`src/`** — Runtime implementation.
  - `server.cc`, `server_builder.cc`, `channel.cc`, `client_call.cc`
  - `grpcpp_server.cc`, `grpcpp_channel.cc` — `grpcpp`-compatible wrappers
  - `status.cc`, `version.cc`
- **`examples/`** — Compile-time smoke tests and reference wiring.
- **`tests/`** — Wire-compatibility checks against canonical proto3 bytes.
- **`golden/`** — Upstream reference trees (`abseil-cpp`, `grpc`, `protobuf`) kept for
  comparison work.

### Transport / Message Separation

The runtime currently has a minimal cleartext HTTP/2 unary server path built on
`libuv + nghttp2`. It accepts a single gRPC request, decodes one unary gRPC frame,
dispatches it to a registered `Service`, and writes a gRPC response with trailers.

The message layer is intentionally separate from the transport layer.
The transport passes protobuf payloads as `std::string`. Examples use
`proto3::serialize()` and `proto3::deserialize<T>()` from `struct_proto26` at the
service boundary, but any codec that produces proto3 wire bytes will work.

### Proto Reflection Backends

CMake auto-detects which reflection backend to use:

1. **C++26 `<meta>`** (`-std=c++26 -freflection`) — preferred, compile-time static
   reflection.
2. **`refl-cpp`** — fallback when `<meta>` is unavailable; slightly slower compile
   times.

Force a backend with `-DGRPC_LITE_PROTO_REFLECTION=meta` or `refl_cpp`.

## Compatibility Testing

`tests/proto3_wire_test.cc` compares `struct_proto26` output with canonical proto3 wire
bytes for the reference schema in `proto/echo.proto`:

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

`proto/echo.proto` remains as a human-readable compatibility reference only; it is not
used by CMake and does not introduce a `protoc` dependency.

## Submodules

The following submodules are required for a full build:

```bash
# For tests
git submodule update --init -- golden/grpc third_party/struct_proto26

# Nested: doctest via opentelemetry-cpp
git -C golden/grpc submodule update --init -- third_party/opentelemetry-cpp
git -C golden/grpc/third_party/opentelemetry-cpp submodule update --init -- third_party/nlohmann-json

# For vendored dependencies (sanitizer builds)
git submodule update --init -- third_party/nghttp2 third_party/libuv
```

## CI / Automation Notes

- CI runs on `ubuntu-24.04`.
- Format job builds a Docker image from the repo `Dockerfile` and runs `clang-format`.
- Smoke and test jobs use `ccache` for acceleration.
- Sanitizer jobs are separate from the default build to keep PR feedback fast.
