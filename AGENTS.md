# grpc-lite Developer Guide

## Toolchain

- Zig 0.16.0
- CMake and Ninja for upstream C dependencies
- mise for tool versions and project tasks

Run `mise install` followed by `mise run bootstrap` before the first build.

## Commands

```bash
mise run build
mise run test
mise run fmt
mise run check
mise run interop
```

## Architecture

- `src/root.zig` is the public module entry point.
- Public APIs use explicit allocators and deterministic `deinit` methods.
- `nghttp2` owns HTTP/2 framing, HPACK, stream state, and flow control.
- `libuv` owns socket and event-loop integration.
- gRPC payloads remain raw protobuf wire bytes.
- The first phase supports cleartext IPv4 unary RPC only.

Keep C types private to transport modules. Do not add protobuf code generation,
streaming, TLS, or grpcpp compatibility without expanding the project scope first.

## Style

Use `zig fmt`. Prefer small modules, explicit ownership, and no detached threads.
