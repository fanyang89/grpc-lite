---
title: Compatibility
description: Supported platforms, protocols, and integration boundaries.
---

# Compatibility

grpc-lite supports Linux x86_64 and ARM64. Client DNS resolves IPv4 candidates;
listeners and native transport use IPv4.

| Capability | Support |
| --- | --- |
| Unary, client/server streaming, bidirectional streaming | Raw Zig, typed Zig and selected synchronous C++ APIs |
| Metadata, deadlines, gzip, graceful drain | Supported |
| Explicit cancellation | Raw and typed Zig unary calls via `Cancellation`; streaming via `cancel()`; raw C unary has no cancellation parameter |
| TLS 1.2+ and mandatory ALPN `h2` | Optional native Zig build with mbedTLS |
| mTLS | Native Zig with explicit PEM identity and trusted CAs |
| Transpiled-C release bundles | Cleartext Linux x86_64 and ARM64; no Zig needed by consumers |
| Reconnection and GOAWAY replacement | New connections without replaying submitted RPCs |

IPv6, automatic RPC retry policies, reflection, health services, service config,
load balancing and xDS are outside the supported profile. Applications implement retries
explicitly when appropriate for their RPC semantics.

The C ABI is grpc-lite's own ABI, not grpc-core's. The grpcpp-shaped C++ facade supports
a selected common synchronous source API, not official generated glue, CompletionQueue,
callback/reactor APIs or grpcpp binary compatibility. Typed C++ services require the
official Protobuf runtime and regenerated grpc-lite service glue.

Interoperability is tested against official grpc-go peers and public HTTP/2 framing
tools. This covers unary and streaming exchanges, compression, status messages,
cancellation/deadlines, soak workloads, and HTTP/2/TLS protocol cases within the selected
profile; it does not imply compatibility with every gRPC feature.

## Unary cancellation in Zig

Pass a single-use `grpc.Cancellation` through `CallOptions.cancellation` to either
`Channel.callUnary` or `Channel.callUnaryAsync`. The typed Zig unary adapter forwards
the same options. Existing calls without this option retain their behavior.

```zig
var cancellation = try grpc.Cancellation.init(allocator);
defer cancellation.deinit();
try channel.callUnaryAsync("/example.Echo/Unary", request, .{
    .cancellation = &cancellation,
}, callbacks);
cancellation.cancel(); // May also be called from another thread.
```

`cancel()` is idempotent and does not wait for completion. Cancellation before
submission prevents sending the request; in-flight cancellation resets only that
HTTP/2 stream. The transport loop arbitrates cancellation, deadlines, and responses:
the first committed terminal outcome wins. Accepted async calls still invoke
`on_complete` exactly once; cancellation after completion is harmless, including
after Channel teardown. Cancellation does not roll back server-side effects or
interrupt a running synchronous server handler.

Do not copy the owning cancellation value or reuse it for another call
(`CancellationAlreadyUsed`). A source may be consumed even if enqueue fails.
`deinit()` releases ownership without cancelling; accepted calls retain the internal
state. Do not race `deinit()` with access to the same value. Its allocator must
support cross-thread frees and remain alive until transport retirement (Channel
teardown is a safe boundary). Callback context and result borrowing rules are unchanged.

See [upgrade boundaries](upgrading.md) for version and ABI expectations, and the
[test matrix on GitHub](../tests/official/README.md) for detailed validation coverage.
