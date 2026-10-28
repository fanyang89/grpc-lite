---
title: C and C++ integration
description: Add grpc-lite to a CMake project and build C or typed C++ applications.
---

# C and C++ integration

Start by adding grpc-lite to **your application's CMake project**, then choose the
API that matches your application:

| Application | Header | CMake target |
| --- | --- | --- |
| C, protobuf wire bytes | `<grpc_lite/grpc_lite.h>` | `grpc_lite::c` |
| C++, raw bytes with RAII and event-driven callbacks | `<grpc_lite/grpc_lite.hpp>` | `grpc_lite::grpcpp` |
| C++, generated protobuf messages and services | Your generated `echo.grpc.pb.h` | `grpc_lite::grpcpp_protobuf` |

All three use the same transport. The C/C++ APIs currently provide cleartext transport;
native Zig TLS support does not enable TLS in these APIs. Use Linux x86_64 or ARM64
with io_uring permitted by the host and any container sandbox.

## 1. Get the library

### CMake source build

You need CMake 3.20+, Ninja, and Clang C/C++ compilers. Zig is not required when using a
published generated-C bundle.

Choose a release from [GitHub Releases](https://github.com/fanyang89/grpc-lite/releases).
Download **both** its source archive and its generated-C asset for your architecture,
plus the asset's `.sha256` file. The source tag and bundle version must match; the
generated-C asset alone is not a complete source package.

Run from your application directory, setting `VERSION` to the chosen numeric release
version (without `v`) and `ARCH` to `x86_64` or `arm64`:

```sh
VERSION=... # The release version you selected
ARCH=x86_64
BASE="https://github.com/fanyang89/grpc-lite"
BUNDLE="grpc-lite-transpiled-c-${VERSION}-linux-${ARCH}"
mkdir -p third_party
curl -fL "$BASE/archive/refs/tags/v${VERSION}.tar.gz" -o third_party/grpc-lite-source.tar.gz
curl -fL "$BASE/releases/download/v${VERSION}/${BUNDLE}.tar.gz" -o "third_party/${BUNDLE}.tar.gz"
curl -fL "$BASE/releases/download/v${VERSION}/${BUNDLE}.tar.gz.sha256" -o "third_party/${BUNDLE}.tar.gz.sha256"
(cd third_party && sha256sum --check "${BUNDLE}.tar.gz.sha256")
mkdir -p third_party/grpc-lite
tar -xzf third_party/grpc-lite-source.tar.gz --strip-components=1 -C third_party/grpc-lite
tar -xzf "third_party/${BUNDLE}.tar.gz" -C third_party
```

The CMake build fetches and builds its pinned nghttp2 and c-ares dependencies. For
offline builds, see [local dependency archives](c-cpp-reference.md#cmake-source-build).

### Installed package

If your environment already provides a grpc-lite installation, use
`find_package(grpc_lite CONFIG REQUIRED)` instead of `add_subdirectory`. Pass its prefix
with `-DCMAKE_PREFIX_PATH=/path/to/prefix`. For typed C++, request
`find_package(grpc_lite CONFIG REQUIRED COMPONENTS protobuf)`.

To produce such an installation from a native Zig source checkout, use
`zig build -Doptimize=ReleaseSafe --prefix /path/to/prefix` with the checkout's required
Zig version. The prefix contains headers, libraries, CMake config and the code generator.

## 2. Connect your CMake target

For a C application, create `CMakeLists.txt`:

```cmake
cmake_minimum_required(VERSION 3.20)
project(my_app LANGUAGES C CXX)
add_subdirectory(third_party/grpc-lite)
add_executable(my_app main.c)
target_link_libraries(my_app PRIVATE grpc_lite::c)
```

For a raw C++ application, use `main.cc` and link `grpc_lite::grpcpp` instead.
Neither raw API needs Protobuf or Abseil. Configure with the extracted bundle path:

```sh
cmake -S . -B build -G Ninja \
  -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
  -DGRPC_LITE_TRANSPILED_C_DIR="$PWD/third_party/$BUNDLE"
cmake --build build
```

The following sections give C and typed C++ examples. Choose the one you need.

The v0.5.0 x86_64 bundle and typed example were verified with Clang 22.1.8 and
Protobuf 3.19.6. With GCC 16.2.1 on the same host, the generated service plugin hung
at startup; use Clang for this walkthrough and a fresh build directory when switching
compilers.

## 3. Call a service from C

The C API sends protobuf wire bytes. Use your preferred protobuf encoder/decoder;
grpc-lite does not generate typed C messages.

This `main.c` calls an Echo service listening on `127.0.0.1:50051`. Its request and
response schemas each have a string field numbered 1, as in the `.proto` below.

```c
#include <grpc_lite/grpc_lite.h>
#include <stdio.h>
#include <string.h>

static grpc_lite_bytes_view text(const char *s) {
  return (grpc_lite_bytes_view){(const uint8_t *)s, strlen(s)};
}

int main(void) {
  grpc_lite_channel *channel = NULL;
  grpc_lite_error err = grpc_lite_channel_create(
      NULL, text("127.0.0.1:50051"), &channel);
  if (err != GRPC_LITE_OK) return 1;

  /* Protobuf field 1, length-delimited string "hello". */
  const uint8_t request[] = {0x0a, 5, 'h', 'e', 'l', 'l', 'o'};
  grpc_lite_unary_result *result = NULL;
  err = grpc_lite_channel_call_unary(
      channel, text("/demo.EchoService/Echo"),
      (grpc_lite_bytes_view){request, sizeof(request)}, NULL, &result);
  int exit_code = 1;
  if (err == GRPC_LITE_OK) {
    if (grpc_lite_unary_result_status_code(result) == 0) {
      grpc_lite_bytes_view payload = grpc_lite_unary_result_payload(result);
      printf("Received %zu protobuf bytes\n", payload.size);
      exit_code = 0;
    }
    grpc_lite_unary_result_destroy(result);
  }
  grpc_lite_channel_destroy(channel);
  return exit_code;
}
```

Check both the C API error and the returned gRPC status. Response views are borrowed
from the result; copy or decode them before destroying it. For hostnames, create a
Runtime before application threads and keep it alive until dependent handles are gone.

## 4. Define a typed C++ service

Install the official Protobuf C++ runtime and its compatible `protoc` compiler using
your application's dependency manager. grpc-lite supplies its service plugin; it does
not supply your Protobuf installation.

Create `proto/echo.proto`:

```proto
syntax = "proto3";
package demo;
message EchoRequest { string message = 1; }
message EchoReply { string message = 1; }
service EchoService {
  rpc Echo(EchoRequest) returns (EchoReply);
}
```

Replace `CMakeLists.txt` with this typed application build:

```cmake
cmake_minimum_required(VERSION 3.20)
project(echo_app LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
find_package(Protobuf REQUIRED)
set(GRPC_LITE_ENABLE_PROTOBUF ON CACHE BOOL "Enable typed C++")
add_subdirectory(third_party/grpc-lite)

set(generated "${CMAKE_CURRENT_BINARY_DIR}/generated")
set(schema "${CMAKE_CURRENT_SOURCE_DIR}/proto/echo.proto")
add_custom_command(
  OUTPUT "${generated}/echo.pb.cc" "${generated}/echo.pb.h"
         "${generated}/echo.grpc.pb.cc" "${generated}/echo.grpc.pb.h"
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${generated}"
  COMMAND "$<TARGET_FILE:protobuf::protoc>"
    "--proto_path=${CMAKE_CURRENT_SOURCE_DIR}/proto"
    "--cpp_out=${generated}"
    "--plugin=protoc-gen-grpc_lite_cpp=$<TARGET_FILE:grpc_lite::protoc-gen-grpc_lite_cpp>"
    "--grpc_lite_cpp_out=${generated}" "${schema}"
  DEPENDS "${schema}" protobuf::protoc grpc_lite::protoc-gen-grpc_lite_cpp
  VERBATIM)
add_library(echo_proto STATIC
  "${generated}/echo.pb.cc" "${generated}/echo.pb.h"
  "${generated}/echo.grpc.pb.cc" "${generated}/echo.grpc.pb.h")
target_include_directories(echo_proto PUBLIC "${generated}")
target_link_libraries(echo_proto PUBLIC grpc_lite::grpcpp_protobuf)
add_executable(echo_app main.cc)
target_link_libraries(echo_app PRIVATE echo_proto)
```

For an installed package, replace `find_package(Protobuf ...)`, the protobuf option,
and `add_subdirectory` with `find_package(grpc_lite CONFIG REQUIRED COMPONENTS protobuf)`.
The remaining generation and application targets are the same.

`protoc` generates `echo.pb.h/.cc` messages; the grpc-lite plugin generates
`echo.grpc.pb.h/.cc` service glue. Regenerate existing official gRPC service glue with
this plugin rather than relinking it. Keep generated files in the build directory.

## 5. Run a typed C++ client and server

This `main.cc` starts a local server, calls it, and shuts it down. Its tiny event-driven
handler completes the unary response directly on the transport thread; it must not
perform blocking work.

```cpp
#include "echo.grpc.pb.h"
#include <grpcpp/grpcpp.h>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <iostream>
#include <string>
#include <utility>

class EchoService final : public demo::EchoService::EventService {
 public:
  std::atomic<bool> finish_failed{false};
  void Echo(const grpc_lite::ServerContext&, demo::EchoRequest request,
            grpc_lite::UnaryCall<demo::EchoReply> call) noexcept override {
    demo::EchoReply response;
    response.set_message(request.message());
    if (!call.Finish(std::move(response)).ok()) finish_failed.store(true);
  }
};

int main() {
  EchoService service;
  grpc_lite::Server server;
  if (!grpc_lite::Server::Create({}, &server).ok()) return 1;
  if (!service.Register(server).ok() || !server.Start().ok()) return 1;
  std::uint32_t port = 0;
  if (!server.Port(&port).ok()) return 1;

  grpc::ChannelArguments args;
  args.SetAllowInitialOffline(false);
  auto channel = grpc::CreateCustomChannel(
      "127.0.0.1:" + std::to_string(port), grpc::InsecureChannelCredentials(), args);
  auto stub = demo::EchoService::NewStub(channel);
  demo::EchoRequest request;
  request.set_message("hello");
  demo::EchoReply response;
  grpc::ClientContext context;
  context.set_deadline(std::chrono::system_clock::now() + std::chrono::seconds(5));
  const grpc::Status status = stub->Echo(&context, request, &response);
  server.Shutdown();
  server.Wait();
  if (!status.ok()) {
    std::cerr << status.error_message() << '\n';
    return 1;
  }
  if (service.finish_failed.load()) return 1;
  std::cout << "Echo: " << response.message() << '\n';
}
```

Configure with the bundle path as above, then run:

```sh
cmake --build build
./build/echo_app
```

Expected output: `Echo: hello`. For separate processes, listen on a fixed server port
and connect the client to that address. Keep the service alive until its Server stops.

For blocking handlers, derive from the generated `Service` class instead and use
`CreateEventService(executor, options)` with an application-owned bounded executor.
The facade does not create worker threads. See [generated services](c-cpp-reference.md#generated-services)
for executor ownership, rejection and teardown requirements.

## Next steps

- [Managed Channels](c-cpp-reference.md#managed-channels): reconnection, admission and shutdown.
- [Operational snapshots](c-cpp-reference.md#operational-snapshots): observe retained work and queues.
- [Low-level C++ API](c-cpp-reference.md#low-level-c-api): raw event-driven integration.
- [Resource limits](resource-limits.md): size buffers and bound outstanding work.
- [Upgrading](upgrading.md): supported headers and compatibility boundaries.

The grpcpp-shaped facade supports selected synchronous source APIs, not grpcpp binary
compatibility, official generated service glue, CompletionQueue or callback/reactor APIs.
The C ABI is grpc-lite's own ABI. Use its option initialization macros and matching
destroy functions; see the [C/C++ reference](c-cpp-reference.md) for detailed contracts.
