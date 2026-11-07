---
title: Task-friendly Zig clients
description: Sequential unary calls, structured concurrency, and cancellation with std.Io and zio.
---

# Task-friendly Zig clients

`grpc_lite_async` provides an owning unary `Client` whose connection, RPC, and
teardown waits use a supplied `std.Io`. With zio, these waits suspend the current
task so other tasks on the executor can run. The transport still uses its own
libxev thread and the existing unary admission limits.

The first supported integration is Zig 0.17 with zio commit
`c5716c4698a7a25be4390812804638e9fb37cdd0`. The adapter itself does not import zio;
applications own their runtime. Other `std.Io` implementations must support
cross-thread futex wakeups and the same cancellation/lifetime contract.

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

`-Dzio=true` in the grpc-lite checkout enables its zio tests and example; consumers
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

`ServiceClient` borrows the raw async client. Results use the existing `TypedResult`
ownership model; non-OK responses have `response == null`. Streaming method names
are rejected at compile time.

For existing Channel owners, `Channel.callUnaryIo(allocator, io, ...)` provides the
same task-aware RPC wait. Use `Channel.initIo(allocator, io, ...)` when connection
and teardown waits must also suspend. A Channel created with ordinary `init` keeps
its ordinary blocking lifecycle.

## Validation

```sh
mise run test-async
zig build test-async -Dzio=true -Doptimize=ReleaseSafe --test-timeout 30s
```

The suite checks single-executor progress, independent cancellation, deadline and
shutdown completion, cancellation races, retained quota release, and raw/typed
allocation failure cleanup.
