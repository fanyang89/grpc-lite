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
| Metadata, deadlines, gzip, graceful drain | Supported; explicit public cancellation is streaming-only in the raw API |
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

See [upgrade boundaries](upgrading.md) for version and ABI expectations, and the
[test matrix on GitHub](../tests/official/README.md) for detailed validation coverage.
