const std = @import("std");
const grpc = @import("grpc_lite");
const rpc = @import("grpc_lite_async");
const zio = @import("zio");

const allocator = std.testing.allocator;
const path = "/test.Async/Unary";

// The server deliberately keeps responses pending. Only a task running on the
// client's single executor can release them, so blocking RPC waits deadlock.
const HeldResponses = struct {
    io: std.Io,
    ready: std.Io.Semaphore = .{},
    cancelled: std.Io.Semaphore = .{},
    calls: [8]?grpc.ServerCall = @splat(null),
    count: usize = 0,

    fn handler(self: *HeldResponses) grpc.ServerStreamHandler {
        return .{
            .context = self,
            .on_start = onStart,
            .on_message = onMessage,
            .on_remote_end = onEnd,
            .on_cancel = onCancel,
        };
    }

    fn onStart(_: ?*anyopaque, _: grpc.ServerStream, context: *grpc.ServerContext) !void {
        try context.addInitialMetadata("x-initial", "async");
    }

    fn onMessage(_: ?*anyopaque, _: grpc.ServerStream, _: *grpc.ServerContext, _: []const u8, _: grpc.Compression) !grpc.StreamReceiveAction {
        return .continue_receiving;
    }

    fn onEnd(context: ?*anyopaque, stream: grpc.ServerStream, _: *grpc.ServerContext) !void {
        const self: *HeldResponses = @ptrCast(@alignCast(context.?));
        self.calls[self.count] = try stream.retain();
        self.count += 1;
        self.ready.post(self.io);
    }

    fn onCancel(context: ?*anyopaque, _: grpc.ServerStream, _: *grpc.ServerContext) void {
        const self: *HeldResponses = @ptrCast(@alignCast(context.?));
        self.cancelled.post(self.io);
    }

    fn respond(self: *HeldResponses, index: usize) !void {
        const call = self.calls[index].?;
        try call.send("response", .{});
        try call.finish(.ok, &.{.{ .key = "x-trailer", .value = "done" }});
    }

    // Call after all arrivals have been observed, before server destruction.
    fn deinit(self: *HeldResponses) void {
        for (&self.calls) |*slot| if (slot.*) |*call| {
            call.deinit();
            slot.* = null;
        };
    }
};

fn callUnary(client: *rpc.Client, options: grpc.CallOptions) anyerror!grpc.CallResult {
    return client.callUnary(allocator, path, "request", options);
}

fn discard(result: anyerror!grpc.CallResult) void {
    var value = result catch return;
    value.deinit();
}

fn targetFor(server: *grpc.Server, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "127.0.0.1:{d}", .{try server.port()});
}

test "single executor progresses while multiple unary calls wait" {
    const runtime = try zio.Runtime.init(allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();
    const io = runtime.io();
    var held: HeldResponses = .{ .io = io };
    var server = try grpc.Server.init(allocator, .{});
    defer server.deinit();
    defer {
        server.shutdown();
        server.wait();
        held.deinit();
    }
    try server.registerStream(path, held.handler());
    try server.start();
    var target_buffer: [32]u8 = undefined;
    var client = try rpc.Client.init(allocator, io, try targetFor(&server, &target_buffer), .{});
    defer client.deinit();

    var futures: [4]std.Io.Future(anyerror!grpc.CallResult) = undefined;
    var started: usize = 0;
    defer for (futures[0..started]) |*future| discard(future.cancel(io));
    for (&futures) |*future| {
        future.* = try io.concurrent(callUnary, .{ &client, .{} });
        started += 1;
    }
    for (&futures) |_| try held.ready.wait(io);
    for (0..futures.len) |index| try held.respond(index);
    for (&futures) |*future| {
        var result = try future.await(io);
        // Future stores the owning result; clear it before deferred cleanup.
        future.result = error.ResultConsumed;
        defer result.deinit();
        try std.testing.expect(result.status.isOk());
        try std.testing.expectEqualStrings("response", result.payload);
        try std.testing.expectEqualStrings("async", result.initial_metadata.getFirst("x-initial").?);
        try std.testing.expectEqualStrings("done", result.trailing_metadata.getFirst("x-trailer").?);
    }
    try std.testing.expectEqual(@as(usize, 0), client.channel.unaryAdmissionStats().retained_calls);
}

test "task cancellation resets one RPC and preserves its sibling and channel" {
    const runtime = try zio.Runtime.init(allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();
    var held: HeldResponses = .{ .io = io };
    var server = try grpc.Server.init(allocator, .{});
    defer server.deinit();
    defer {
        server.shutdown();
        server.wait();
        held.deinit();
    }
    try server.registerStream(path, held.handler());
    try server.start();
    var buffer: [32]u8 = undefined;
    var client = try rpc.Client.init(allocator, io, try targetFor(&server, &buffer), .{});
    defer client.deinit();
    var first = try io.concurrent(callUnary, .{ &client, .{} });
    defer discard(first.cancel(io));
    try held.ready.wait(io);
    var second = try io.concurrent(callUnary, .{ &client, .{} });
    defer discard(second.cancel(io));
    try held.ready.wait(io);

    try std.testing.expectError(error.Canceled, first.cancel(io));
    try held.cancelled.wait(io);
    try std.testing.expectEqual(@as(usize, 1), client.channel.unaryAdmissionStats().retained_calls);
    try held.respond(1);
    var result = try second.await(io);
    second.result = error.ResultConsumed;
    defer result.deinit();
    try std.testing.expect(result.status.isOk());
    try std.testing.expectEqual(@as(usize, 0), client.channel.unaryAdmissionStats().retained_calls);
}

test "deadline and shutdown complete pending task waits" {
    const runtime = try zio.Runtime.init(allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();
    var held: HeldResponses = .{ .io = io };
    var server = try grpc.Server.init(allocator, .{});
    defer server.deinit();
    defer {
        server.shutdown();
        server.wait();
        held.deinit();
    }
    try server.registerStream(path, held.handler());
    try server.start();
    var buffer: [32]u8 = undefined;
    var client = try rpc.Client.init(allocator, io, try targetFor(&server, &buffer), .{});
    defer client.deinit();

    var deadline_call = try io.concurrent(callUnary, .{ &client, .{ .timeout_ns = std.time.ns_per_s } });
    defer discard(deadline_call.cancel(io));
    try held.ready.wait(io);
    var expired = try deadline_call.await(io);
    deadline_call.result = error.ResultConsumed;
    defer expired.deinit();
    try std.testing.expectEqual(grpc.StatusCode.deadline_exceeded, expired.status.code);

    var pending = try io.concurrent(callUnary, .{ &client, .{} });
    defer discard(pending.cancel(io));
    try held.ready.wait(io);
    client.shutdown();
    var stopped = try pending.await(io);
    pending.result = error.ResultConsumed;
    defer stopped.deinit();
    try std.testing.expectEqual(grpc.StatusCode.unavailable, stopped.status.code);
    var rejected = try callUnary(&client, .{});
    defer rejected.deinit();
    try std.testing.expectEqual(grpc.StatusCode.unavailable, rejected.status.code);
    try std.testing.expectEqual(@as(usize, 0), client.channel.unaryAdmissionStats().retained_calls);
}

fn echo(_: ?*anyopaque, alloc: std.mem.Allocator, context: *grpc.ServerContext, request: []const u8) !grpc.UnaryResponse {
    try context.addInitialMetadata("x-initial", "value");
    try context.addTrailingMetadata("x-trailer", "value");
    return grpc.UnaryResponse.ok(alloc, request);
}

test "completion racing cancellation releases every operation" {
    const runtime = try zio.Runtime.init(allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();
    const io = runtime.io();
    var server = try grpc.Server.init(allocator, .{});
    defer server.deinit();
    try server.registerUnary(path, .{ .context = null, .invoke_fn = echo });
    try server.start();
    var buffer: [32]u8 = undefined;
    var client = try rpc.Client.init(allocator, io, try targetFor(&server, &buffer), .{});
    defer client.deinit();
    for (0..100) |_| {
        var future = try io.concurrent(callUnary, .{ &client, .{} });
        discard(future.cancel(io));
    }
    var result = try callUnary(&client, .{});
    defer result.deinit();
    try std.testing.expect(result.status.isOk());
    try std.testing.expectEqual(@as(usize, 0), client.channel.unaryAdmissionStats().retained_calls);
}

test "caller allocation failures release response and admission storage" {
    const runtime = try zio.Runtime.init(allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();
    var server = try grpc.Server.init(allocator, .{});
    defer server.deinit();
    try server.registerUnary(path, .{ .context = null, .invoke_fn = echo });
    try server.start();
    var buffer: [32]u8 = undefined;
    var client = try rpc.Client.init(allocator, io, try targetFor(&server, &buffer), .{});
    defer client.deinit();
    const Check = struct {
        fn run(alloc: std.mem.Allocator, c: *rpc.Client) !void {
            var result = try c.callUnary(alloc, path, "request", .{});
            defer result.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Check.run, .{&client});
    try std.testing.expectEqual(@as(usize, 0), client.channel.unaryAdmissionStats().retained_calls);
}

test "offline queued calls are cancelable and failed initialization cleans up" {
    const runtime = try zio.Runtime.init(allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();
    var server = try grpc.Server.init(allocator, .{});
    defer server.deinit();
    try server.start();
    var buffer: [32]u8 = undefined;
    const target = try targetFor(&server, &buffer);
    server.shutdown();
    server.wait();
    try std.testing.expectError(error.ConnectionFailed, rpc.Client.init(allocator, io, target, .{}));
    var client = try rpc.Client.init(allocator, io, target, .{
        .reconnect = .{ .allow_initial_offline = true },
    });
    defer client.deinit();
    var future = try io.concurrent(callUnary, .{ &client, .{} });
    defer discard(future.cancel(io));
    // Give the call task a chance to enter its wait, rather than cancelling it
    // before its first instruction. No remote response is needed for cleanup.
    try io.sleep(.fromMilliseconds(10), .awake);
    try std.testing.expectEqual(@as(usize, 1), client.channel.unaryAdmissionStats().retained_calls);
    try std.testing.expectError(error.Canceled, future.cancel(io));
    try std.testing.expectEqual(@as(usize, 0), client.channel.unaryAdmissionStats().retained_calls);
}

test "cancellation racing connection startup joins the transport before returning" {
    const runtime = try zio.Runtime.init(allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();
    const io = runtime.io();
    var server = try grpc.Server.init(allocator, .{});
    defer server.deinit();
    try server.start();
    var buffer: [32]u8 = undefined;
    const target = try targetFor(&server, &buffer);
    const Connect = struct {
        fn run(task_io: std.Io, address: []const u8) anyerror!void {
            var client = try rpc.Client.init(allocator, task_io, address, .{});
            defer client.deinit();
        }
    };
    for (0..100) |_| {
        var future = try io.concurrent(Connect.run, .{ io, target });
        future.cancel(io) catch |err| switch (err) {
            error.Canceled => {},
            else => return err,
        };
    }
}
