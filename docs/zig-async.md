---
title: Task-friendly Zig RPCs
description: Unary and streaming clients and server handlers with std.Io and zio.
---

# Task-friendly Zig RPCs

`grpc_lite_async` provides owning `Client` and `Server` adapters whose network
waits use a supplied `std.Io`. With zio, these waits suspend the current task so
other tasks on the executor can run. Server handlers run as runtime tasks and may
also suspend in ordinary Io operations. The transport still uses its own libxev
threads and transport resource limits.

The first supported integration is Zig 0.17 with zio commit
`c5716c4698a7a25be4390812804638e9fb37cdd0`. The adapter itself does not import zio;
applications own their runtime. Other `std.Io` implementations must support
cross-thread futex wakeups and the same cancellation/lifetime contract. Server
adapters also require concurrent task/group submission from transport threads.

## Build integration

Add zio to your application's dependencies:

```sh
zig fetch --save=zio https://codeload.github.com/lalinsky/zio/tar.gz/c5716c4698a7a25be4390812804638e9fb37cdd0
```

Use the existing grpc-lite package setup, then import the adapter and runtime:

```zig
const grpc = b.dependency("grpc_lite", .{
    .target = target,
    .optimize = optimize,
    .protobuf = false,
});
const zio = b.dependency("zio", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("grpc_lite_async", grpc.module("grpc_lite_async"));
exe.root_module.addImport("zio", zio.module("zio"));
```

`-Dzio=true` in the grpc-lite checkout enables its zio tests and examples; consumers
do not need that option to import the adapter. Raw consumers still avoid protobuf
and code-generation dependencies.

## Unary calls

```zig
const std = @import("std");
const zio = @import("zio");
const rpc = @import("grpc_lite_async");

pub fn main(init: std.process.Init) !void {
    const runtime = try zio.Runtime.init(init.gpa, .{ .executors = .exact(1) });
    defer runtime.deinit();
    const io = runtime.io();

    var client = try rpc.Client.init(init.gpa, io, "127.0.0.1:50051", .{});
    defer client.deinit();

    var result = try client.callUnary(init.gpa, "/demo.EchoService/Echo", "\x0a\x05hello", .{
        .timeout_ns = 2 * std.time.ns_per_s,
    });
    defer result.deinit();
    if (!result.status.isOk()) return error.RpcFailed;
    // result owns its protobuf wire bytes, status message, and metadata.
}
```

Hostname targets additionally require `grpc.Runtime.init()` **before** creating
zio or transport threads. Pass its address in `ChannelOptions.runtime` and destroy
it after every client. IPv4 literals need no resolver runtime.

## Concurrent calls and cancellation

Use `io.concurrent` to start calls concurrently, then `Future.await` or
`Future.cancel` to join them. A task group is useful for an arbitrary number of
calls; each member should own and deinitialize its result, and group members must
handle application errors themselves because `std.Io.Group` accepts
`std.Io.Cancelable!void` tasks.

The runnable [zio example](../examples/zio_unary_client.zig) demonstrates sequential
calls, concurrent calls, deadlines, and task cancellation:

```sh
# With the echo server running on 127.0.0.1:50051:
zig build run-zio-unary -Dzio=true
```

- **Task cancellation:** returns `error.Canceled`. An admitted RPC is cancelled on
  the transport loop; the task waits uncancelably for local transport completion
  before freeing its operation. This does not cancel sibling calls or retry the RPC.
- **Deadline:** returns an owned result with gRPC `deadline_exceeded`, as in the
  existing unary API. It is distinct from task cancellation.
- **Remote failure:** returns an owned non-OK status, rather than a Zig error.
- **Local failure:** invalid arguments, allocation errors, and admission rejection
  remain Zig errors. Quota exhaustion does not enqueue a waiting caller.
- **Cancellation/completion race:** completion may win. Always consume or destroy
  any successful result returned by `Future.cancel`; it can return a completed
  task's result. Awaiting/cancelling a future again does not transfer ownership again.
- **Shutdown:** `client.shutdown()` stops admission and finishes outstanding calls.
  Join all caller tasks before `client.deinit()`; deinit requires exclusive access
  and waits uncancelably through the stored `io`.

The runtime and transport allocator must remain alive until deinit returns.
Result allocation and protobuf encoding/decoding run on the calling task. A
task-local result allocator may be non-thread-safe, but it must not alias the
transport allocator or be shared unsafely between tasks. Allocation, compression,
short internal locks, and initial clock calibration are synchronous work; the
adapter specifically makes transport waits task-friendly.

## Typed unary calls

Enable `.protobuf = true` in the grpc-lite dependency and add:

```zig
exe.root_module.addImport("grpc_lite_protobuf_async", grpc.module("grpc_lite_protobuf_async"));
```

Use the generated service type from the [Zig quickstart](zig-quickstart.md):

```zig
const pb_async = @import("grpc_lite_protobuf_async");
var typed = pb_async.ServiceClient(EchoApi).init(&client);
var result = try typed.callUnary(allocator, "Echo", .{ .message = "hello" }, .{});
defer result.deinit();
if (result.raw.status.isOk()) {
    const response = result.response.?;
    // response.message remains valid until result.deinit().
    _ = response;
}
```

`ServiceClient` borrows the raw async client. Unary results use the existing
`TypedResult` ownership model; non-OK responses have `response == null`.
`callUnary` rejects streaming method names at compile time; `openStream` accepts them.

For existing Channel owners, `Channel.callUnaryIo(allocator, io, ...)` provides the
same task-aware RPC wait. Use `Channel.initIo(allocator, io, ...)` when connection
and teardown waits must also suspend. A Channel created with ordinary `init` keeps
its ordinary blocking lifecycle.

## Streaming calls

`Client.openStream` supports raw client, server, and bidirectional streaming:

```zig
var stream = try client.openStream(stream_allocator, "/example.Echo/Chat", .{});
defer stream.deinit();
try stream.send(protobuf_wire_bytes, .{});
try stream.closeSend();

while (true) {
    const next = stream.receive(result_allocator) catch |err| switch (err) {
        error.RpcFailed => break,
        else => return err,
    };
    var message = next orelse break;
    defer message.deinit();
    // message.payload and message.compression belong to this message.
}
var result = try stream.finish(result_allocator);
defer result.deinit();
// Inspect result.status, result.initial_metadata, result.trailing_metadata.
```

| Operation | Behavior |
| --- | --- |
| `send(bytes, options)` | Suspends until outbound capacity is available; success means queued, not delivered to the peer. Input bytes are borrowed until return. |
| `closeSend()` | Half-closes the send direction after queued messages drain. Responses remain readable. |
| `receive(allocator)` | Returns an owned `StreamMessage`. An empty payload is a message, not EOF. Returns `null` only for successful terminal status and `error.RpcFailed` for non-OK status after buffered messages are consumed. |
| `finish(allocator)` | Waits for final status and returns an owned `StreamResult`, including initial and trailing metadata. It neither closes send nor discards unread messages. |
| `cancel()` | Requests termination of both directions. The final result normally has status `cancelled`. |
| `deinit()` | Cancels unfinished work, waits uncancelably for the terminal callback, fences callbacks, and releases the stream. Requires exclusive access. |

For full-duplex RPCs, use independent writer and reader tasks. There may be **one
writer and one reader** per stream; overlapping sends/half-close return
`error.ConcurrentSend`, and overlapping receives return `error.ConcurrentReceive`.
`finish` may wait concurrently with these tasks. Drain responses before waiting
for `finish` alone: unread messages deliberately maintain backpressure and can
prevent terminal delivery. A cancelled send, receive, or finish task cancels the
whole RPC and waits for its terminal callback; sibling RPCs are independent.

The self-contained [duplex example](../examples/zio_stream_client.zig) starts a local
echo server and runs concurrent reader/writer tasks on a single zio executor:

```sh
zig build run-zio-stream -Dzio=true
```

### Buffers, allocation, and ownership

The adapter retains **at most one decoded message**, then pauses raw delivery.
Consuming the message resumes delivery. This application-side slot adds at most
`max_message_size` payload bytes per stream **in addition to** the configured raw
inbound/outbound capacities. Transport admission and operational buffer counters
retain their transport-only meanings; the slot and copied metadata are adapter
storage, not additional transport capacity. Independently owned returned messages
are caller storage and may outlive both the stream and client.

The allocator passed to `openStream` is used by transport callbacks as well as
caller tasks, serialized per stream. Use a thread-safe allocator when it is shared
with other streams, the Client, or application work. The `receive`/`finish` result
allocator is used on the calling task; a non-thread-safe result allocator must not
alias the callback/transport allocator or be shared unsafely across tasks.

Failure to allocate a caller-owned raw message leaves the buffered message in
place for a retry. Failure to allocate a final result also permits retrying
`finish`. Callback allocation failures cancel the RPC and surface as local errors.
`Client.shutdown`/`deinit` wakes stream waiters; stream handles may outlive their
Client, but must be destroyed before their allocators and I/O runtime. Join all
tasks using a stream before destroying that stream.

### Typed streaming

Generated client-streaming, server-streaming, and bidirectional methods all use
`ServiceClient.openStream`. As with raw streams, applications follow the method's
message cardinality and explicitly half-close:

```zig
var typed = pb_async.ServiceClient(StreamingEchoApi).init(&client);
var stream = try typed.openStream(stream_allocator, "Chat", .{});
defer stream.deinit();
try stream.send(allocator, .{ .message = "hello" }, .{});
try stream.closeSend();
while (try stream.receive(allocator)) |value| {
    var message = value;
    defer message.deinit();
    // message.value is the generated response; its arena belongs to message.
}
var result = try stream.finish(allocator);
defer result.deinit();
```

Typed messages carry `value` and `compression`; their `deinit` releases the decoding
arena. Encoding and decoding run on the calling task. A decoding failure cancels
both directions, since the consumed wire message cannot be retried or silently
skipped. `openStream` rejects unary method names at compile time.

## Task-based servers

`grpc_lite_async.Server` owns a raw server and a structured group of handler tasks.
Register methods before `start`, using `registerUnary` or `registerStream`:

```zig
fn echo(_: ?*anyopaque, call: *rpc.ServerCall) !void {
    while (try call.receive(std.heap.page_allocator)) |value| {
        var request = value;
        defer request.deinit();
        try call.io().sleep(.fromMilliseconds(10), .awake);
        try call.send(request.payload, .{});
    }
    try call.finish(.ok, &.{});
}

// The allocator must be thread-safe; the runtime outlives the server.
var server = try rpc.Server.init(allocator, io, .{
    .transport = .{ .port = 50051 },
    .max_calls = 128,
});
defer server.deinit();
try server.registerStream("/example.Echo/Chat", .{ .invoke_fn = echo });
try server.start();
// Run application work, then request shutdown before waiting.
server.shutdownGracefully(std.time.ns_per_s);
server.wait();
```

Run the self-contained single-executor server/client example:

```sh
zig build run-zio-server -Dzio=true
```

### Handler APIs

Raw unary handlers receive `(context, allocator, io, *grpc.ServerContext,
request_bytes)` and return an owned `grpc.UnaryResponse`. The adapter waits for
exactly one request and client half-close, invokes the handler, sends response
metadata and an OK payload, then finishes with its status and trailers. The adapter
deinitializes the response. `rpc.UnaryHandler.bind(T, context, function)` adapts a
typed context pointer. Missing or multiple requests produce `invalid_argument`;
`transport.max_request_size` and the transport streaming message limit both apply.

Streaming handlers receive a borrowed `*rpc.ServerCall`; use
`rpc.ServerHandler.bind(T, context, function)` for a typed application context.

| Operation | Behavior |
| --- | --- |
| `io()` | Runtime used by this call, including cancellation of ordinary Io waits. |
| `context()` | Read-only request metadata/deadline snapshot, valid until handler return. Per-message compression is on each received message. |
| `receive(allocator)` | Owned raw message, or `null` after client half-close; allocation failure preserves the slot for retry. |
| `sendInitialMetadata(entries, compression)` | Explicit initial metadata and response compression, before sending responses. |
| `send(bytes, options)` | Queues a copied response, suspending on outbound backpressure. Defaults to empty initial metadata and identity if headers were not sent explicitly. |
| `finish(status, trailers)` | Queues final status after pending responses; does not wait for network delivery. |
| `abort()` | Allocation-free local termination using an INTERNAL_ERROR stream reset. |

One reader and one writer may run concurrently. Initial metadata, send, and finish
are writer operations; overlapping operations return `ConcurrentSend` or
`ConcurrentReceive`. Join child tasks before returning and do not retain the borrowed
call. Returning without finishing produces `internal`; unhandled allocation errors
produce `resource_exhausted`, cancellation errors produce `cancelled`, and other
handler errors produce `internal`. If a final response cannot be allocated/queued,
the adapter aborts the stream. Explicit non-OK statuses use `finish`.

### Cancellation, shutdown, and limits

Each admitted call has a supervisor task and a handler task. Terminal notification
(peer cancellation, deadline, shutdown, transport failure, or completed response)
cancels and joins the handler. This interrupts ordinary cancelable Io operations,
including sleep or external I/O, not just RPC send/receive. After finishing a call,
return promptly; post-finish work may be cancelled. Tasks must cooperate with
cancellation, and handlers must join any children in deferred cleanup.

`shutdown` requests immediate transport shutdown; `shutdownGracefully(timeout_ns)`
stops new admission and drains within the timeout. `wait` suspends uncancelably
until transport completion and joins handler cleanup. `deinit` requests shutdown,
waits, then frees transport and adapter storage. Startup waits also suspend
uncancelably once started. Lifecycle operations require exclusive access and must
run outside handlers. Destroy the server before its allocator, runtime, or handler
contexts. Shared handler state must support concurrent invocations.

`ServerOptions.max_calls` defaults to 1024 and bounds retained calls across all
reactors, including handlers still unwinding after transport termination. Excess
calls receive `resource_exhausted`. `activeCalls()` snapshots this retained count.
Each call also retains one decoded inbound message (at most
`transport.stream_limits.max_message_size`) and copied request metadata, in addition
to transport buffers. Received messages are independently owned caller storage;
unary handling retains its request until the handler returns. Task stacks, typed
arenas, response storage, and application work are outside this count budget.

### Typed server methods

`grpc_lite_protobuf_async.ServiceServer(Service)` borrows the task server and
derives wire paths and message types from generated service declarations:

```zig
fn echoTyped(
    _: *App,
    arena: std.mem.Allocator,
    io: std.Io,
    ctx: *grpc.ServerContext,
    request: demo.EchoRequest,
) !demo.EchoReply {
    try io.sleep(.fromMilliseconds(1), .awake);
    try ctx.addTrailingMetadata("x-handler", "task");
    return .{ .message = try arena.dupe(u8, request.message) };
}

var service = pb_async.ServiceServer(EchoApi).init(&server);
try service.registerUnary("Echo", &app, echoTyped, .{});
```

The unary handler's supplied allocator is an arena: allocate response fields there
and do not manually deinitialize the response. Request/response storage lasts only
through the invocation and encoding. The optional compile-time
`.map_error = fn (anyerror) grpc.Status` maps application errors; cancellation and
allocation errors retain their standard mappings.

For streaming, use `service.registerStream("Chat", &app, chat)` where `chat` takes
`(*App, *pb_async.ServerCall(Request, Response))`. The typed call exposes the same
operations as the raw call, with `receive(allocator)` returning an owned
`StreamMessage(Request)` and `send(allocator, response, options)` encoding a response.
Decode failures terminate the RPC (`invalid_argument`, or `resource_exhausted` for
OOM); they cannot silently skip requests. Applications follow the method's message
cardinality. Unary/streaming registration mismatches are rejected at compile time.

## Validation

```sh
mise run test-async
mise run interop-async
zig build test-async -Dzio=true -Doptimize=ReleaseSafe --test-timeout 30s
```

The suite checks single-/multi-executor progress, independent cancellation,
flow-controlled sends, slow readers, half-close, metadata/compression, deadline and
shutdown completion, cancellation races, retained quota release, and raw/typed
allocation failure cleanup. Server coverage includes suspended-handler isolation,
all streaming cardinalities, cancellation of ordinary Io waits, task launch failure,
retained-call admission, graceful drain, and joined teardown.

`interop-async` runs pinned grpc-go clients against the task server on one zio
executor. It adds wire-level coverage for unary and all streaming cardinalities,
metadata/status, mixed identity/gzip messages, cancellation, delayed responses,
and independent progress during handler waits. See the
[official interop matrix](../tests/official/README.md#task-handler-interoperability).
