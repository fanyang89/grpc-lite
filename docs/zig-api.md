---
title: Zig API
description: Channels, streaming, servers, TLS, and typed protobuf adapters.
---

# Zig API

New applications should start with the [Zig quickstart](zig-quickstart.md): package
installation, build integration, `.proto` generation, and a runnable typed client/server.
This page is the API reference.

The public Zig transport is raw-byte based. Applications may use protobuf wire bytes
directly or opt into the shared zig-protobuf runtime and typed adapters.

See the [public surface inventory and upgrade guide](upgrading.md) for supported
exports, toolchain constraints, and ownership/error regression fixtures.

## Runtime and Channels

IPv4 literals require no global setup. Hostname targets use c-ares and require a Runtime
initialized before the application creates threads. The Runtime must outlive every
Channel that references it.

```zig
const grpc = @import("grpc_lite");

var runtime = try grpc.Runtime.init();
defer runtime.deinit();

var channel = try grpc.Channel.init(allocator, "api.example.com:50051", .{
    .runtime = &runtime,
    .reconnect = .{ .allow_initial_offline = true },
});
defer channel.deinit();
```

Reconnect backoff follows the gRPC defaults: one-second initial delay, 1.6 multiplier,
120-second cap, and 20 percent jitter. Success resets the backoff. Recovery never retries
an RPC that may have reached the server; applications own RPC retry policy.

`max_response_header_list_size` defaults to 65536 and must be nonzero. The advertised
HTTP/2 setting applies per header list, while grpc-lite enforces the bound cumulatively
across all initial headers and trailers for each RPC. Every decoded physical field costs
its name bytes, value bytes, and 32 bytes. A rejected block is not disclosed; the RPC
finishes with `RESOURCE_EXHAUSTED` and the connection remains reusable. Initial metadata
accepted before oversized trailers remains available.

`Channel.callUnary` supports concurrent callers. `Channel.shutdown` may run while calls
are active; join caller threads before giving `Channel.deinit` exclusive access. The
Channel serializes access to the allocator passed to `Channel.init`.

## Unary Admission

For allocator ownership, admission budgets and accounting exclusions, see
[Resource limits](resource-limits.md).

Channels default to `unary_admission.max_calls = 4096` and
`unary_admission.max_request_bytes = 64 * 1024 * 1024`. Both must be nonzero.
Admission is reserved before copying or compressing a unary request and covers
construction, pending, and in-flight operations until their storage is released.
For async calls this includes the completion callback; for blocking calls it includes
copying the result. A callback starting another call still occupies its original slot.

The byte charge is the method path, five-byte frame header, uncompressed payload,
and raw metadata key/value lengths. It is a logical request budget, **not** a total
heap or wire-byte limit: response storage, compression workspace, allocator overhead,
and streaming calls are excluded. Set both limits for the deployment's capacity.

Both unary entry points return `error.UnaryAdmissionRejected` immediately on quota
exhaustion; rejected async calls never invoke the completion callback. Allocation or
validation failures roll back reservations. `channel.unaryAdmissionStats()` returns a
thread-safe snapshot of `retained_calls`, `retained_request_bytes`, and the saturating
`rejected_calls` quota counter. Release of operation storage makes quota reusable.

C/C++ channels use the same default limits and receive gRPC `RESOURCE_EXHAUSTED` on
quota rejection. ABI 1.7 exposes configuration and snapshots through C and C++; see
[Managed Channels](c-cpp-api.md#managed-channels). Streaming uses the separate capacity reservation described below.

## Unary Calls

```zig
const std = @import("std");

var result = try channel.callUnary(
    allocator,
    "/demo.EchoService/Echo",
    protobuf_wire_bytes,
    .{ .timeout_ns = 5 * std.time.ns_per_s },
);
defer result.deinit();
```

Each `CallResult` owns its payload, status message, and response metadata through the
result allocator. Callers must synchronize a shared result allocator. A non-thread-safe
result allocator must not alias the Channel backing allocator while the Channel is active.

Raw unary also has an event-driven API:

```zig
try channel.callUnaryAsync(
    "/demo.EchoService/Echo",
    protobuf_wire_bytes,
    .{ .timeout_ns = 5 * std.time.ns_per_s },
    .{ .context = &state, .on_complete = State.onComplete },
);
```

Input is copied before return. A successful return guarantees exactly one completion
callback. Validation, allocation, unavailable-channel, and notification failures return
without invoking it. There is no explicit unary cancellation API.

The callback runs on the transport loop and must not block or call `Channel.deinit`.
Payload, status, and metadata are borrowed until callback return. `Channel.deinit` waits
for every accepted callback before releasing Channel storage.

## Streaming Admission

Each Channel has `stream_admission.max_streams = 1024` and
`stream_admission.max_buffer_bytes = 1024 * 1024 * 1024`; both must be nonzero.
Before allocating a stream, `openStream` reserves one slot and the sum of that
stream's `max_inbound_buffer_size` and `max_outbound_buffer_size`. With the default
8 MiB per direction, the 1 GiB budget admits at most 64 retained streams per Channel.
Tune either the per-stream capacities or the Channel budget for higher concurrency.
Reservation does not eagerly allocate the buffers.

Exhaustion returns `error.StreamAdmissionRejected` without invoking callbacks.
Failed construction or submission returns the reservation. Successful streams retain
it until both transport ownership and the application handle are released, including
terminal streams still held by the application. The accounting storage outlives the
Channel when handles do; always deinitialize application-owned stream handles.

`channel.streamAdmissionStats()` returns a thread-safe snapshot of `retained_streams`,
`reserved_buffer_bytes`, and saturating `rejected_streams`. This is a conservative
sum of configured capacities, not current queue occupancy or a total heap limit.
Metadata, decoder/workspace overhead, temporary concurrent send allocations, and
transport write buffers are not included. Unary admission remains independent.

C/C++ share these defaults. A rejected open returns C `WOULD_BLOCK`
(or `grpc_lite::ErrorCode::WouldBlock`); the grpcpp facade maps that failure to
`RESOURCE_EXHAUSTED`. ABI 1.8 exposes `max_streams`, `max_stream_buffer_bytes`, and
stream admission snapshots through C/C++; see [Managed Channels](c-cpp-api.md#managed-channels).

## Raw Streaming

`Channel.openStream` opens an event-driven client stream for all streaming cardinalities:

```zig
var call = try channel.openStream(
    "/demo.StreamingEchoService/Chat",
    .{},
    callbacks,
);
defer call.deinit();

try call.send(protobuf_wire_bytes, .{});
try call.closeSend();
```

`send` copies and queues one message. It returns `WouldBlock` when the bounded outbound
queue is full. `closeSend` half-closes only the local direction after queued messages
drain. `cancel` terminates both directions. An `on_message` callback may return `.pause`;
call `resumeReceive` to continue delivery.

Callbacks run on transport loop threads and must not block. Callback stream handles are
borrowed; deinitialize only the application-owned handle. Deinitializing an active client
stream cancels it and suppresses future callbacks.

Servers register raw streaming handlers with `Server.registerStream`. `ServerStream` is a
borrowed callback view. Cross-thread work must retain an owning `ServerCall`, release every
clone before Server teardown, and treat `CallClosed` as terminal. `on_terminal` runs once
and is the final callback for a call.

If copying or enqueueing a retained-call response command fails, `ServerCall.abort` makes
an allocation-free, thread-safe emergency request. The reactor submits
`RST_STREAM(INTERNAL_ERROR)` without status trailers; if nghttp2 cannot allocate the reset
command, grpc-lite closes the connection to guarantee local cleanup.

`send`, `finish`, `sendInitialMetadata`, and `resumeReceive` copy command data into bounded
shared storage. Handlers that decide metadata outside `on_start` can use
`receive_initially_paused = true` and `initial_metadata_mode = .explicit`.

### Runnable bounded lifecycle example

[`examples/streaming_lifecycle.zig`](../examples/streaming_lifecycle.zig) runs a raw
IPv4 loopback client and server in one process. It sends the protobuf wire bytes
`08 01` directly: no schema, generated code, protobuf runtime, or global `Runtime`
is needed. After the usual `mise install` and `mise run bootstrap` setup:

```bash
# Recommended: all three modes, each under an external shutdown watchdog.
mise run test-streaming-lifecycle
zig build test-streaming-lifecycle -Dprotobuf=false -Doptimize=ReleaseSafe --summary all

# Individual modes (without the external watchdog).
zig build run-streaming-lifecycle -Dprotobuf=false -- normal
zig build run-streaming-lifecycle -Dprotobuf=false -- interrupt
zig build run-streaming-lifecycle -Dprotobuf=false -- pre_handler_failure

# Install the raw artifact, then smoke-test it directly.
zig build -Dprotobuf=false
bash tests/run_streaming_lifecycle.sh ./zig-out/bin/grpc-lite-streaming-lifecycle
```

Execution requires Linux with usable `io_uring` (including permission under any
container/seccomp policy), IPv4 loopback sockets, Bash, and GNU coreutils
`/usr/bin/timeout`. The [smoke script](../tests/run_streaming_lifecycle.sh) deliberately
rejects a missing/non-GNU watchdog rather than using a possibly incompatible PATH
command. Each mode has a 20-second timeout and a further 2-second kill grace. A
watchdog expiry, nonzero exit, or missing/duplicate expected evidence line fails.
The smoke step joins existing `zig build test` / `mise run check` coverage and
inherits optimization and sanitizer settings through `addExample`. Since Bash
executes the binary directly, automatic smoke coverage requires the target OS,
architecture, and ABI to match the build host; explicitly requesting the smoke
step for another target fails rather than executing it. Cross-target installation
remains available; the individual run step uses Zig's normal artifact runner.

For `normal` and `interrupt`, the intended ordering is:

1. Main queues one request and calls `closeSend`. This half-closes requests only;
   responses remain independent.
2. The server's `on_remote_end` callback attempts two responses. The first fills
   the outbound queue; the second must return `WouldBlock`. The unsent index is
   retained and retried only from `on_writable`, without polling or sleeping.
3. Main first waits for client progress or terminal notification. An early terminal
   is an error in these modes and enters cleanup without waiting on a server
   event that might never be set. Otherwise, after both responses arrive, main
   waits for the server readiness event before reading the retained `ServerCall`.
   With final status still pending, it requests graceful drain with a 5-second
   bound while the RPC is active.
4. In `normal` mode, main finishes the retained `ServerCall` with OK. In
   `interrupt` mode, main explicitly cancels the client stream and requires
   client CANCELLED and server `peer_cancelled`. Drain stops admission and lets
   the active RPC finish; forced drain expiry is not an accepted outcome here.
   The 10-second RPC deadline is a failure bound, not the intended interruption.
5. Main waits for terminal notification, joins the draining Server while keeping
   the Channel alive to flush cancellation, then shuts down and joins the
   Channel. Only after both joins does it validate callback counters, release the
   owning `ClientStream` and retained `ServerCall`, and tear down Channel/Server.
   Terminal notification alone does not release admission: the example checks
   one retained stream / 4103 reserved bytes before `ClientStream.deinit`, then
   zero afterward. Contexts, allocator, and `init.io` outlive loops and handles;
   error-path defers also join before releasing retained server state.

The third mode, `pre_handler_failure`, deliberately calls an unregistered method.
It uses the same client-first wait but expects exactly one UNIMPLEMENTED terminal
and zero messages. It requests immediate Server shutdown instead of graceful
drain, joins both loops, then verifies no handler started, no server-handler
terminal callback ran, no `ServerCall` was retained, and the server readiness
event remains unset. It also checks the same admission release boundary. Only
this checked outcome emits `EXPECTED_FAILURE` and exits zero; it demonstrates
early-failure cleanup, not backpressure or graceful-drain success. Unexpected
statuses (including deadline expiry), abnormal failure in `normal`/`interrupt`,
and watchdog termination remain failures.

Callbacks run on transport loop threads and must not block. Here they only
validate bounded data, issue transport commands, and signal events; only main
waits or prints. Callback messages, metadata, and stream views are borrowed and
must not be retained or deinitialized. Only an explicitly retained owning
`ServerCall` crosses from the server callback to main; events publish it and
loop joins protect final counter reads.

Both endpoints advertise a **4096-byte initial stream window** and configure
**4096-byte inbound capacity**. Inbound capacity must cover the advertised window;
using 4096 with the default 65536-byte window would be invalid. The maximum
payload is 2 bytes and outbound capacity is **7 bytes** (payload plus the
five-byte gRPC frame header), deliberately fitting only one response. Client
admission permits one retained stream with **4103 bytes** of configured buffer
capacity. The source also sets one reactor, one connection, one concurrent RPC,
header and unary-admission budgets, write watermarks, and preface/idle timeouts.
These are explicit queue/admission limits, **not a total heap bound**; see
[Resource limits](resource-limits.md).

## Server

```zig
var server = try grpc.Server.init(allocator, .{
    .host = "127.0.0.1",
    .port = 50051,
    .reactor_count = 4,
});
defer server.deinit();

try server.registerUnary(
    "/demo.EchoService/Echo",
    grpc.UnaryHandler.bind(EchoService, &service, EchoService.echo),
);
try server.start();
server.wait();
```

`reactor_count` defaults to one. Larger values create independent Linux reactor threads,
listeners, HTTP/2 sessions, connection state, deadline heaps, and write pools. Listeners
share the IPv4 port with `SO_REUSEPORT`; each connection and all its streams remain on one
reactor. Multi-core scaling therefore needs multiple client connections or Channels.

Server transport admission is finite by default:

- `max_connections = 1024` caps admitted connections across all reactors. Initializing,
  draining, and asynchronously closing connections continue to occupy a slot until final
  destruction.
- `max_concurrent_streams_per_connection = 100` is advertised exactly as HTTP/2
  `SETTINGS_MAX_CONCURRENT_STREAMS`. Before the peer acknowledges the setting, excess
  streams are reset with `REFUSED_STREAM`; exceeding the acknowledged limit is an HTTP/2
  protocol error and causes GOAWAY.
- `cleartext_preface_timeout_ns = 10s` is an absolute deadline through receipt of the
  complete client preface and initial non-ACK SETTINGS. Partial or trickled input does not
  refresh it.
- `connection_idle_timeout_ns = 5m` bounds a continuous interval with no active inbound
  RPC streams. PING, SETTINGS, reads, and writes do not refresh it. Any active unary or
  streaming RPC disarms idle expiry; after the final stream closes a fresh interval starts.
  Idle retirement sends `GOAWAY(NO_ERROR)` and closes gracefully.

All four values must be nonzero; there is no unlimited or disabled sentinel.

Each reactor uses a local allocator for connection and stream state. Page refills, large
allocations, coordinator state, `std.Io.Threaded`, TLS configuration, and cross-thread
stream commands use a serialized allocator backed by the allocator passed to
`Server.init`, so that backing allocator may be non-thread-safe.

The allocator in `ServerContext` is reactor-local and valid only during its callback.
Callbacks may run concurrently across reactors and must not block. Shared application
state and allocators used across callbacks must be thread-safe.

Handlers can inspect deadlines with `hasDeadline`, `remainingTimeNs`, and
`isDeadlineExceeded`. Handlers are not force-cancelled; a response after the deadline is
replaced with `DEADLINE_EXCEEDED`.

See `examples/echo_server.zig` and `examples/echo_client.zig` for complete programs.

## Operational Snapshots

`Channel.operationalStats(self: *Channel) ChannelOperationalStats` and
`Server.operationalStats(self: *const Server) ServerOperationalStats` return
caller-owned values without allocating or invoking callbacks. The root aliases are
`grpc.ChannelOperationalStats` (`grpc.channel.OperationalStats`) and
`grpc.ServerOperationalStats` (`grpc.server.OperationalStats`). No snapshot needs
`deinit`; it contains no borrowed mutable storage. [C getters and thin C++ wrappers](c-cpp-api.md#operational-snapshots)
expose the same metrics starting with ABI 1.9, with flat admission fields. Existing
C/C++ admission options, snapshot layouts, getters, and minimum sizes are unchanged.

Both methods may run concurrently with supported operations, `shutdown`, and `wait`,
and may be called after `wait` while the owner is still alive. **Owner `deinit` requires
exclusive access**: stop and join snapshot readers before deinitializing the Channel or
Server, and never query a destroyed owner, even if a client stream handle survives it.

Fields start at zero when their accounting owner is initialized; live snapshots reflect
activity since then (a successfully connected Channel can already have an active
connection when `init` returns). There is no reset API. Event counters saturate at
`maxInt(u64)` and high-water marks never decrease. Current local gauges use matching
addition/subtraction, not saturating subtraction; Server aggregate sums saturate.
These are accounting samples, not transactions with transport/container mutations.

### Channel operational fields

Sampling is O(1). Operational fields are copied under one accounting mutex; the two
admission snapshots are acquired independently, not atomically with each other or the
operational fields. All top-level fields below are `u64` except the two admission structs.
Counts are objects/events and byte fields are logical charges, not allocated capacity.

| Field | Meaning and ownership boundary |
| --- | --- |
| `unary_admission` | `UnaryAdmissionStats`: `retained_calls: usize`, `retained_request_bytes: usize`, `rejected_calls: u64`. Existing [unary admission](#unary-admission) ownership, logical request bytes, and quota rejection counter. |
| `stream_admission` | `StreamAdmissionStats`: `retained_streams: usize`, `reserved_buffer_bytes: usize`, `rejected_streams: u64`. Existing [streaming admission](#streaming-admission) ownership, sum of configured buffer capacities, and quota rejection counter. |
| `active_unary_calls`, `active_streams` | Accepted enqueue/open through the first terminal outcome, decremented before callbacks. Failed enqueue/open is not active; terminal retained handles are not active RPCs. |
| `active_connections` | Usable transport, including GOAWAY draining; excludes dialing, backoff and closing. At most one: replacement starts after the old TCP connection closes. |
| `pending_unary_calls` | Accepted unary work until submission starts or a pre-submit terminal outcome, including work waiting during reconnect. |
| `pending_unary_calls_high_water` | Channel-lifetime peak pending unary count. |
| `stream_inbound_bytes` | Queued decoded uncompressed payload plus a five-byte frame charge per message. Excludes decoder storage and payload delivered immediately to a callback. |
| `stream_inbound_bytes_high_water` | Channel-lifetime peak aggregate inbound queue charge. |
| `stream_outbound_bytes` | Whole encoded frames, including gzip wire size. A partially consumed frame retains its full charge until fully consumed or destroyed. |
| `stream_outbound_bytes_high_water` | Channel-lifetime peak aggregate outbound queue charge, not a sum of per-stream peaks. |
| `socket_write_bytes` | Owned socket-write buffers until full completion/discard, including in-flight writes; TLS ciphertext when enabled. Not bytes delivered to the peer. |
| `socket_write_bytes_high_water` | Channel-lifetime peak aggregate socket-write charge. |
| `terminal_ok`, `terminal_cancelled`, `terminal_deadline_exceeded`, `terminal_other` | One mutually exclusive final-status bucket per accepted unary/stream RPC, even when application callback delivery is suppressed. `terminal_other` includes unavailable, resource exhaustion and application failures. |
| `reconnect_attempts` | TCP connect submissions after the initial TCP attempt, including later address candidates. DNS-only failures and backoff scheduling are excluded. |
| `reconnect_successes` | Successful transport activations from those later TCP attempts. |
| `reconnect_goaway` | GOAWAY entering drain. |
| `reconnect_transport_failure` | Usable transport failure initiating recovery when reconnect is enabled. A draining transport can contribute to both reconnect trigger counters; these are not exhaustive or disjoint failed-dial reasons. No RPC replay is implied. |

Stream queue byte gauges include terminal, detached, application-retained buffers until
final stream destruction. **They can remain nonzero after `Channel.wait()`**. Their
accounting storage survives with the retained stream, but querying still requires a live
Channel. Releasing a reservation, reaching a terminal outcome, and freeing queue storage
are distinct boundaries; high-water marks persist after current gauges return to zero.

```zig
const snapshot: grpc.ChannelOperationalStats = channel.operationalStats();
// Configured capacity reserved by retained streams:
const reserved_capacity = snapshot.stream_admission.reserved_buffer_bytes;
// Current whole encoded-frame queue charge, including retained terminal buffers:
const queued_frames = snapshot.stream_outbound_bytes;
```

### Server operational fields

Sampling is O(reactors), loading independent atomics without acquiring a snapshot lock
or traversing mutable transport containers. Fields and reactor contributions are sampled
at different instants: the result is **approximate**, not a globally consistent snapshot.
All fields are `u64`; byte gauges count owned slices/reservations, not configured capacity.

| Field | Meaning and ownership boundary |
| --- | --- |
| `admitted_connections` | Existing coordinator admission count: initializing, active, draining and asynchronously closing slots through final connection destruction. |
| `active_rpcs` | Successfully inserted inbound HTTP/2 request-stream entries, including malformed/unhandled RPC requests, until transport retirement. Excludes retained `ServerCall` controls after retirement. |
| `rejected_connections` | Accepts refused by the aggregate connection cap only; excludes drain and initialization failures. |
| `pre_ack_rejected_streams` | Pre-SETTINGS-ACK stream-cap refusals plus the defensive application cap guard. Excludes drain refusals and allocation failures. Pinned nghttp2 uniquely identifies the pre-ACK path via request HEADERS/`NGHTTP2_ERR_REFUSED_STREAM`; generic post-ACK protocol cap rejections are unavailable and not counted. |
| `streaming_outbound_reserved_bytes` | Remaining encoded streaming frame bytes, including queued cross-thread send commands. Released as consumed/discarded/destroyed; unlike the Channel whole-frame charge, partial consumption reduces this gauge. Excludes unary responses and temporary send encodings. |
| `streaming_outbound_reserved_bytes_high_water_sum` | Sum of reactor-lifetime outbound reservation peaks. |
| `socket_queued_write_bytes` | Owned socket-write buffers until full completion/discard, including in-flight writes; TLS ciphertext when enabled. Excludes nghttp2/TLS-internal pending data. |
| `socket_queued_write_bytes_high_water_sum` | Sum of reactor-lifetime socket-write peaks. |
| `close_peer_transport` | Read/write transport failures or TLS peer EOF. |
| `close_protocol_local` | Protocol/local failure or nghttp2 session termination, including TLS handshake timeout. |
| `close_preface_timeout` | Absolute cleartext preface timeout. |
| `close_idle_timeout` | Idle expiry, including GOAWAY-write completion or fallback close. |
| `close_graceful_drain` | Graceful shutdown's drained connection closure. |
| `close_forced_shutdown` | Immediate shutdown or graceful drain timeout. |

The `*_high_water_sum` fields are conservative sums of non-simultaneous reactor peaks,
**not true global peaks**. Close counters are mutually exclusive for each admission-owning
connection object. The first effective close initiation (including close-after-write)
latches the reason; the counter increments once at final object destruction. Later
shutdown/errors cannot overwrite it. Rejected accepts and failures before object admission
ownership do not count as closed objects. Decoder occupancy and post-ACK stream-cap
rejection counts are explicitly unavailable, not zero-valued measurements.

### Memory scope

Neither snapshot measures or bounds total heap use or RSS. Stream and socket ownership
are separate gauges, not a deduplicated memory total. Excluded costs include spare
capacity, decoder/metadata/HPACK storage, compression temporaries, TLS workspace, kernel
buffers, allocator overhead/caches, and application copies. Admission reservations are
configured/logical budgets rather than allocated bytes; queue charges are not allocation
sizes. See the [resource limits](resource-limits.md)
for ownership and accounting boundaries. Collect application and process measurements
alongside snapshots when diagnosing memory growth.

## TLS

TLS is an optional mbedTLS 3.6.6 dependency:

```bash
mise run prepare-tls-deps
zig build -Dtls=true
```

Downstream packages pass `.tls = true` to the grpc-lite dependency. Clients trust only
the supplied PEM CA bundle; system roots are not searched. Hostname verification and SNI
use the Channel target. TLS 1.2 or newer and ALPN `h2` are mandatory. TLS 1.2 is limited
to ECDHE AEAD suites, while TLS 1.3 uses its AES-GCM and ChaCha20-Poly1305 suites, matching
the HTTP/2 cipher profile. The default handshake timeout is ten seconds.

```zig
var channel = try grpc.Channel.init(allocator, "api.example.com:443", .{
    .runtime = &runtime,
    .tls = .{ .ca_certificates_pem = ca_pem },
});
```

For mutual TLS, a client presents a certificate chain and unencrypted PEM private key
when the server requests one. The key must match the leaf certificate, otherwise
`Channel.init` fails with `error.CertificateKeyMismatch`. PEM input is parsed during
`Channel.init` and may be released afterward.

```zig
var channel = try grpc.Channel.init(allocator, "api.example.com:443", .{
    .runtime = &runtime,
    .tls = .{
        .ca_certificates_pem = ca_pem,
        .identity = .{ .certificate_chain_pem = client_cert_pem, .private_key_pem = client_key_pem },
    },
});
```

A server can require client certificates by setting `client_ca_certificates_pem`:

```zig
var server = try grpc.Server.init(allocator, .{
    .tls = .{
        .certificate_chain_pem = server_cert_pem,
        .private_key_pem = server_key_pem,
        .client_ca_certificates_pem = client_ca_pem,
    },
});
```

The default (`null`) does not request a client certificate. When configured, a
missing, expired, or untrusted client certificate fails the handshake. An empty or
invalid CA PEM fails initialization; it does not disable verification. CA PEM is
parsed during `Server.init` and may then be released. Client and server trust roots
may differ. This authenticates certificate trust only, not per-RPC authorization;
peer identity APIs, dynamic credential rotation, and C/C++ TLS are not provided.

Servers accept a PEM certificate chain and unencrypted PEM private key. PEM input is
parsed during `Server.init` and may be released afterward.

## Metadata

Keys use lowercase gRPC header syntax. Outgoing ASCII values must be visible ASCII.
Invalid incoming ASCII fields are discarded. Binary `-bin` values remain raw bytes in
the API; the wire parser accepts padded, unpadded, and comma-joined base64 and rejects
malformed input only on the affected RPC.

## Protobuf

The raw `grpc_lite` module has no zig-protobuf import. Package dependencies disable
protobuf support by default, and an explicit `.protobuf = false` does not resolve or
compile zig-protobuf for either the target or host. Repository builds enable protobuf
support by default so their typed tests and code-generation steps remain available.

Pass `.protobuf = true` to expose the separate `grpc_lite_protobuf_runtime` and
`grpc_lite_protobuf` modules. The build package's `createProtocStep` and
`protobuf_codegen` exports are also opt-in code-generation APIs: using them resolves
zig-protobuf. `createProtocStep` returns an optional step so callers can use
`orelse return` with Zig's lazy dependency fetch. The typed adapter continues to operate
over the raw-byte transport.

Generated service VTables can be registered without manual method paths:

```zig
const demo = @import("demo_proto");
const grpc_pb = @import("grpc_lite_protobuf");

const EchoApi = demo.EchoService(EchoState, EchoError);
var registration = grpc_pb.ServiceRegistration(EchoApi).init(
    allocator,
    &state,
    .{ .Echo = EchoState.echo },
    .{ .map_error = mapError, .context_hook = configureContext },
);
try registration.register(&server);
// Call registration.deinit() after server.deinit().
```

The adapter derives the method path, decodes the request, invokes the generated VTable,
and encodes the response. Registration and userdata must outlive the Server. Returned
fields must be releasable with the registration allocator.

Typed streaming preserves raw transport semantics:

```zig
const StreamingApi = demo.StreamingEchoService(AppState, AppError);
var client = grpc_pb.ServiceClient(StreamingApi).init(&channel);
var call = try client.openStream(callback_allocator, "Chat", .{}, callbacks);
defer call.deinit();

try call.send(send_allocator, demo.EchoRequest{ .message = "hello" }, .{});
try call.closeSend();
```

Decoded callback messages are borrowed. Typed send operations use temporary encoding
buffers and preserve raw `WouldBlock`, pause/resume, cancellation, and compression
behavior without introducing unbounded queues. Registrations, contexts, and allocators
must remain at stable addresses until the Server and active streams stop.
