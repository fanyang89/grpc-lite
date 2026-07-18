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
mise run test-release-safe
mise run fmt
mise run ci-lint
mise run check
mise run interop
mise run interop-official
mise run interop-http2
mise run interop-http2-edge
mise run gen-proto
```

## Architecture

- `src/root.zig` is the public module entry point.
- `src/protobuf_adapter.zig` is the optional typed zig-protobuf integration.
- Public APIs use explicit allocators and deterministic `deinit` methods.
- `nghttp2` owns HTTP/2 framing, HPACK, stream state, and flow control.
- `libuv` owns socket and event-loop integration.
- gRPC payloads remain raw protobuf wire bytes.
- Generated protobuf sources live under `.zig-cache` and are not committed.
- The first phase supports cleartext IPv4 unary RPC only.

Keep C types private to transport modules. Keep protobuf out of `src/root.zig` so the
raw transport remains independently usable. Do not add streaming, TLS, or grpcpp
compatibility without expanding the project scope first.

## Scope Decisions

The compatibility target is `grpc-lite-unary-insecure-v1`. This table is authoritative:
change it before implementing a feature with a different decision.

| Capability | Decision | Notes |
| --- | --- | --- |
| Raw and typed unary RPC | Required | Client and server |
| Official bidirectional unary interop profile | Required | Test against official grpc-go peers |
| Large messages and HTTP/2 flow control | Required | Include padding and max-stream tests |
| ASCII and binary metadata | Required | Emit padded base64; accept padded, unpadded, and comma-joined `-bin` values |
| Status codes and Unicode status messages | Required | Preserve percent-encoded UTF-8 bytes |
| Deadlines | Required | No separate public cancellation API |
| Unary gzip compression | Selected | Only `identity` and `gzip` |
| GOAWAY connection replacement | Selected | New calls use a new connection; no RPC retry |
| Graceful server drain | Selected | Stop admission, send GOAWAY, wait with timeout |
| Client, server, or bidi streaming | Out of scope | Generated streaming methods remain unsupported |
| TLS, ALPN, and mTLS | Out of scope | Interop profile is explicitly insecure |
| DNS and IPv6 | Out of scope | IPv4 literals only |
| Reflection and health services | Out of scope | Reflection requires bidi streaming |
| Interceptors and middleware | Out of scope | Keep the core API small |
| Retry policies and connection backoff | Out of scope | Applications retry explicitly |
| Service config and load balancing | Out of scope | No policy layer |
| xDS, ORCA, ALTS, and cloud credentials | Out of scope | Not required for lite deployments |
| Cacheable unary GET | Out of scope | Depends on proxy cache semantics |
| grpcpp compatibility | Out of scope | Zig-native APIs only |

## Official Interop Profile

The required standard cases are `empty_unary`, `large_unary`,
`special_status_message`, `unimplemented_method`, `unimplemented_service`,
`client_compressed_unary`, and `server_compressed_unary`. Also run `rpc_soak`,
`channel_soak`, the public HTTP/2 framing suite, and the negative HTTP/2 client cases.

Cases requiring streaming, TLS, auth, service config, ORCA, or xDS must be reported as
skipped with the scope-table reason, never presented as passing. grpc-core `bad_client`
tests use private C APIs and are not part of this profile; use the public HTTP/2 interop
tools instead.

## Style

Use `zig fmt`. Prefer small modules, explicit ownership, and no detached threads.
