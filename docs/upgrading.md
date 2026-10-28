---
title: Public API and upgrades
description: Compatibility boundaries, supported APIs, and upgrade migration steps.
---

# Public API and Upgrade Guide

## Compatibility boundaries

| Surface | Contract |
| --- | --- |
| Zig package modules and build helpers below | Source API for the pinned Zig toolchain. Recompile consumers; no Zig binary ABI promise. |
| `<grpc_lite/grpc_lite.h>` | grpc-lite's own versioned C ABI. The selected released-baseline regression protects old-header/current-library use on supported native Linux targets. |
| `<grpc_lite/cpp/...>` and selected `<grpcpp/...>` | C++17 source API only. Recompile every consumer and regenerate service glue when upgrading; no C++ object-layout or grpcpp binary ABI promise. |
| gRPC wire protocol | The selected interoperability profile, not source or binary compatibility with grpc-core. |

The product is pre-1.0: Zig and C++ source-breaking changes may occur before 1.0.
The fixtures are regression guards, **not a promise that every 0.x upgrade is
source-compatible**. An intentional source break must update this guide with its
migration, the relevant API guide, and the affected consumers in the same change.
Do not quietly weaken a fixture to accommodate an accidental break. The separate
C ABI major/minor and SONAME rules still apply; a product version is not an ABI
version. See [the released C ABI regression](c-cpp-api.md#released-c-abi-regression)
for the frozen baseline, provenance, and explicitly supported option prefixes.

## Supported surface inventory

### Zig

Import `grpc_lite`, not a relative path into `src/`. These root exports and their
documented operations form the supported transport source surface:

| Group | Exports |
| --- | --- |
| Runtime and connection | `version`, `Runtime`, `Channel`, `ChannelOptions`, `ReconnectOptions`, `ClientTlsOptions`, `ClientTlsIdentity` |
| Unary | `CallOptions`, `CallResult`, `AsyncCallResult`, `UnaryCallCallbacks`, `UnaryHandler`, `UnaryResponse` |
| Admission and snapshots | `UnaryAdmissionOptions`, `UnaryAdmissionStats`, `StreamAdmissionOptions`, `StreamAdmissionStats`, `ChannelOperationalStats`, `ServerOperationalStats` |
| Server | `Server`, `ServerOptions`, `ServerTlsOptions`, `ServerLocalAddress`, `ServerContext` |
| Streaming | `StreamBufferLimits`, `StreamOptions`, `StreamSendOptions`, `StreamReceiveAction`, `ClientStream`, `ClientStreamCallbacks`, `ServerStream`, `ServerStreamHandler`, `ServerCall`, `ServerCallId`, `ServerTerminalReason`, `ServerInitialMetadataMode` |
| Shared values | `Metadata`, `MetadataEntry`, `Status`, `StatusCode`, `Compression`, `Logger`, `LogLevel` |

The root also exposes `call`, `channel`, `compression`, `frame`, `log`, `message`,
`metadata`, `server`, `service`, `status`, `stream`, and `xev` namespaces. Prefer
the root aliases for transport types; namespace access to the same types does
not expand the compatibility contract to their implementation fields/helpers.
`log` and `xev` expose pinned dependency APIs, not independently versioned
grpc-lite logging/event-loop guarantees. Framing/message helpers and
`grpc.internal` are lower-level implementation/diagnostic surfaces, not supported
application transport APIs. Other private Zig modules, C bindings, reactor state,
allocator internals, and files imported directly from `src/` are excluded.

With `.protobuf = true`, `grpc_lite_protobuf` exports `ServiceClient`,
`ServiceRegistration`, `StreamRegistration`, `TypedResult`, `ClientStream`,
`ClientStreamView`, `ClientStreamCallbacks`, `ServerStream`, `ServerStreamHandler`,
`MethodKind`, `methodPath`, `methodKind`, `RequestType`, `ResponseType`, and
`runtime`. `grpc_lite_protobuf_runtime` shares the pinned zig-protobuf runtime;
do not add a second incompatible runtime. The build package exports
`createProtocStep` and `protobuf_codegen` for opt-in generation. Handle lazy
dependency suspension with `orelse return` and regenerate messages with the
selected dependency/toolchain; generated output is not committed.

`grpc_lite_gperftools` is separately opt-in. Its allocator/capability flags,
CPU/heap profiler controls and tcmalloc property/release/sampling operations
require the corresponding build options; it is not part of the raw import.
See [profiling setup](development.md).

### Installed C and C++ headers

- C: `grpc_lite/grpc_lite.h` (opaque handles, values, callbacks, initializers,
  ABI/feature discovery, and declared functions).
- Low-level C++: `grpc_lite/grpc_lite.hpp` and `grpc_lite/cpp/{channel,
  client_stream,metadata,runtime,server,status,sync_service,typed_service}.hpp`.
  These provide move-only owners, metadata/status values, snapshots, raw
  callbacks, typed calls/registrations, and application-owned executor/admission
  interfaces. Namespaces named `internal` and private members are excluded.
- Selected grpcpp facade: `grpcpp/grpcpp.h`, `channel.h`, `channel_arguments.h`,
  `client_context.h`, `create_channel.h`, `server_context.h`,
  `security/credentials.h`, and `support/{status,status_code_enum,stub_options,
  sync_stream}.h`. Supported shapes are status/codes, contexts and metadata,
  insecure channels/arguments, and synchronous unary plus all three streaming
  cardinalities, including regenerated `StubInterface`, `Stub`, `EventService`,
  and nested `Service` overrides. Only the methods actually declared by these
  headers are provided, not every upstream grpcpp overload.

`grpcpp/impl/*` is installed for generated glue, **not an application API**.
Official gRPC generated service glue, grpc-core ABI, CompletionQueue,
callback/reactor, generic-service, interceptor/middleware, load-balancing/service
config, xDS/auth/cloud APIs, and substitute Abseil headers are excluded. C/C++
TLS is not exposed; optional native Zig TLS does not enable it. The authoritative
feature decisions remain in [AGENTS.md](../AGENTS.md).

## Upgrade checklist

1. Record the old/new source commit or release, Zig version, target, feature
   flags, C/C++ compiler, and Protobuf compiler/runtime versions. Read the target
   release notes and this guide; do not infer compatibility from a successful
   transport interop test alone.
2. Run `mise install` and `mise run bootstrap` for the selected checkout.
   `mise.toml` and `build.zig.zon` currently select **Zig 0.17.0**; this is the
   tested toolchain, not a promise that all later Zig releases work. Native
   transport execution requires Linux x86_64/ARM64, IPv4, and permitted
   `io_uring`. A sandbox denial is a failure, not a passing/skipped consumer.
3. Re-resolve the Zig package URL/hash using Zig's normal verified dependency
   workflow. Rebuild downstream code from its public imports; do not edit shared
   dependency caches or bypass hashes. Keep `.protobuf = false` for raw-only
   consumers. Opt into typed/profiling/TLS modules explicitly when needed.
4. Rebuild C++17 consumers against the new installed prefix. Use the
   application's compatible official `protoc`/Protobuf runtime pair, generate
   `*.pb.*` with `--cpp_out`, and regenerate `*.grpc.pb.*` with
   `--grpc_lite_cpp_out` and the new `protoc-gen-grpc_lite_cpp`. Do not link old
   official grpcpp service objects or assume C++ ABI stability.
5. For no-Zig CMake builds, pair the **same-version** tagged source and
   architecture-specific generated-C release asset, verify the checksum, and
   stage hashed nghttp2/c-ares archives if offline. Those bundles remain
   cleartext-only; native Zig TLS/mTLS is a separate build path.
6. Review resource defaults and lifetime rules below. Run the focused consumers
   and your application tests. Maintainers must pass `mise run check` before
   pushing; source fixtures do not replace sanitizer or official interop suites.

### Current API changes and migration actions

These are feature/ABI milestones, not a mapping to product release numbers:

| Change | Migration |
| --- | --- |
| Standalone synchronous-stream header | `<grpcpp/support/sync_stream.h>` can now be the first include; its internal blocking helper no longer pulls in the umbrella header recursively. No include-order workaround is needed. |
| Raw/typed event-driven streaming and retained server calls | Keep callbacks nonblocking. Half-close with `closeSend`/`CloseSend`/`WritesDone`; explicitly cancel a stream to end both directions. Retain/clone owning server calls for cross-thread work, never save a borrowed server stream/context. |
| Async unary | Use `UnaryCallCallbacks`/`AsyncCallResult`; accepted calls complete once. Synchronous validation/submission failures invoke no callback. Copy borrowed callback data before return. There is no explicit unary cancellation API. |
| Finite server bounds and unary admission (C ABI 1.7) | Review connection/stream/preface/idle and unary budgets. Initialize C options with the matching `*_INIT`, preserving `struct_size`; missing old-prefix fields receive finite defaults, not unlimited capacity. Unary quota rejection maps to gRPC `RESOURCE_EXHAUSTED` in C/C++. |
| Stream admission (C ABI 1.8) | Budget retained stream count and the sum of configured inbound/outbound capacities. Handle Zig `StreamAdmissionRejected`, low-level C/C++ `WOULD_BLOCK`/`WouldBlock`, or grpcpp `RESOURCE_EXHAUSTED`. Terminal handles still reserve admission until destroyed. |
| Operational snapshots (C ABI 1.9) | Use root Zig snapshot aliases or the low-level C/C++ getters, not nonexistent grpcpp getters. Initialize C output envelopes; snapshots are owning values, need no destruction, and do not measure heap/RSS. Join readers before owner destruction/moves. New symbols require the corresponding library ABI minor or later. |

For all upgrades, release blocking unary results with their result allocator or
matching C destroy function. They own their payload/status/metadata independently
of the Channel. Zig/C callback views are borrowed; low-level C++ callback
payload/status/metadata arguments are owning copies, but `ServerStream` remains
borrowed. Destroy only application-owned client streams, outside callbacks;
release all retained server calls and application workers before Server teardown.
Runtime must be initialized before threads and outlive dependent handles. Stop
admission, join loops/callers, then destroy owners with exclusive access. See the
[Zig](zig-api.md) and [C/C++](c-cpp-api.md) guides for detailed errors and bounds.

## Regression fixtures and limits

```bash
mise run test-consumer
mise run test-consumer-cpp
mise run test-c-abi
```

- `tests/public_api_test.zig` checks root type exports and option/snapshot defaults
  in normal Debug/ReleaseSafe core CI.
- `tests/consumer/raw` is copied outside the checkout and imports a package
  archive through a fresh Zig package cache. The existing raw consumer task now
  **runs** unary, async unary, raw duplex streaming, half-close, copied send input,
  owned result lifetime, retained-call clone/terminal errors, and admission release
  checks in Debug and ReleaseSafe, plus a TLS-enabled build. It retains existing
  sanitizer compile checks, optional profiling checks, and assertions that raw
  consumers do not resolve zig-protobuf/grpc-proto. These sanitizer configurations
  compile; the task does not claim to execute the new fixture under TSan/UBSan.
- `tests/consumer/cpp` is copied outside the source tree by the existing C++
  task. Its CMake build uses only the installed prefix and external Protobuf,
  compiles each supported header as the first include, and regenerates a tiny
  service. It runs unary and every streaming client shape against a raw server,
  UNIMPLEMENTED status, low-level move/error/callback-copy behavior, quota
  rejection, and reservation release. Generated synchronous server override
  signatures are compiled; their runtime/executor behavior remains covered by
  the existing `grpcpp_generated_server_test.cc`, not this small consumer.
- Both package tasks include tracked worktree changes and untracked non-ignored
  files, so local runs validate pending edits rather than silently testing HEAD.
  They join the existing package-consumer CI job and `mise run check`; C++ checks
  stay active even with CMake `Release`/`NDEBUG`. Runtime watchdogs fail on hangs.
- The released C ABI fixture remains separate: it tests frozen old headers against
  the current library, not C++ ABI or Zig compiler compatibility. Typed Zig
  adapters/codegen are tested by the existing repository suites; these raw-only
  package fixtures do not claim independent typed-Zig package coverage, exhaustive
  API/overload coverage, all platform/compiler combinations, or a released C++
  binary baseline.
