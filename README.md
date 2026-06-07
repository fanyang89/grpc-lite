# grpc-lite

[![CI](https://github.com/fanyang89/grpc-lite/actions/workflows/ci.yml/badge.svg)](https://github.com/fanyang89/grpc-lite/actions/workflows/ci.yml)
![C++17](https://img.shields.io/badge/C%2B%2B-17-blue)
![C++26](https://img.shields.io/badge/C%2B%2B-26%20reflection-orange)
![Platform](https://img.shields.io/badge/platform-Linux-lightgrey)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)

> A lightweight, protocol-compatible gRPC runtime for C++ — without the upstream bloat.

`grpc-lite` gives you HTTP/2 unary RPC building blocks on Linux using only `libuv` +
`nghttp2`. No `protoc`, no `libprotobuf`, no 50 MB dependency tree.
Just a static library you can link and run.

## Features

- **Tiny footprint** — core runtime is ~few thousand lines of C++17
- **Protocol compatible** — speaks standard gRPC over HTTP/2 (cleartext)
- **Zero code generation** — messages are plain C++ structs serialized via
  `struct_proto26` (C++26 reflection) or your own codec
- **Transport / message separation** — swap the protobuf layer without touching HTTP/2
- **Sanitizer-ready** — ASan / TSan presets with vendored deps built under
  instrumentation

## Quick Start

```bash
# 1. Install system dependencies (Ubuntu/Debian)
sudo apt-get install cmake ninja-build libuv1-dev libnghttp2-dev pkg-config

# 2. Clone and build
git clone https://github.com/fanyang89/grpc-lite.git
cd grpc-lite
cmake -S . -B build -G Ninja
cmake --build build

# 3. Run the echo server
./build/grpc_lite_echo_server
```

## Minimal Example

```cpp
#include "grpc_lite/server_builder.h"
#include "grpc_lite/service.h"

class EchoService final : public grpc_lite::Service {
  public:
    std::string service_name() const override { return "demo.EchoService"; }

    grpc_lite::Status HandleUnary(
        std::string_view method, std::string_view request,
        grpc_lite::ServerContext* ctx, std::string* response
    ) override {
        *response = std::string(request);
        return grpc_lite::Status::OK();
    }
};

int main() {
    EchoService svc;
    grpc_lite::ServerBuilder builder;
    builder.AddListeningPort("0.0.0.0:50051");
    builder.RegisterService(&svc);

    auto server = builder.Build();
    if (!server->Start().ok()) return 1;
    server->Wait();
    return 0;
}
```

## Building

### Prerequisites

| Component | Minimum | Notes |
| --- | --- | --- |
| CMake | 3.20 |  |
| C++ compiler | C++17 compliant | GCC ≥ 12 or Clang ≥ 16 recommended |
| libuv | system or vendored | `libuv1-dev` |
| libnghttp2 | system or vendored | `libnghttp2-dev` |

For the struct-based protobuf examples you also need a compiler that supports C++26
static reflection (`-std=c++26 -freflection`). These targets are skipped automatically
if your compiler lacks support.

### CMake Presets

```bash
# Default build (system packages)
cmake -S . -B build -G Ninja
cmake --build build

# Address sanitizer (uses vendored nghttp2 + libuv)
cmake -S . -B build-asan -G Ninja -DGRPC_LITE_SANITIZE=address
cmake --build build-asan

# Thread sanitizer
cmake -S . -B build-tsan -G Ninja -DGRPC_LITE_SANITIZE=thread
cmake --build build-tsan
```

### Running Tests

```bash
# Unit + integration tests
ctest --test-dir build --output-on-failure

# End-to-end smoke test (proto echo roundtrip)
./examples/proto_echo_smoke.sh
```

## Architecture

```
include/grpc_lite/   Public C++ API (channel, server_builder, service, status)
src/core/             HTTP/2 framing + libuv event-loop integration
src/                  Runtime implementation (server, client_call, grpcpp compat)
examples/             Smoke tests and reference wiring
tests/                Wire-compatibility checks and protocol tests
third_party/          struct_proto26, nghttp2, libuv, refl-cpp
golden/               Upstream reference trees for comparison work
```

The transport layer passes protobuf payloads as `std::string`. You can use
`struct_proto26` to serialize plain C++ structs directly to proto3 wire bytes, or bring
your own codec.

## Documentation

- [AGENTS.md](./AGENTS.md) — build constraints, CMake options, developer workflow, and
  architecture details for contributors and AI agents.

## Contributing

Issues and pull requests are welcome.
Please ensure:

- Code follows the existing style (`clang-format` is enforced in CI).
- All tests pass (`ctest --output-on-failure`).
- Sanitizer builds remain clean if you touch transport code.

## License

[MIT](https://opensource.org/licenses/MIT)
