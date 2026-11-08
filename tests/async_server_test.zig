const std = @import("std");
const grpc = @import("grpc_lite");
const rpc = @import("grpc_lite_async");
const zio = @import("zio");
const allocator = std.testing.allocator;
const method = "/test.Task/Call";

fn targetFor(server: *rpc.Server, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "127.0.0.1:{d}", .{try server.port()});
}

const Unary = struct {
    entered: std.Io.Event = .unset,
    release: std.Io.Event = .unset,

    fn invoke(self: *Unary, alloc: std.mem.Allocator, io: std.Io, ctx: *grpc.ServerContext, request: []const u8) !grpc.UnaryResponse {
        if (std.mem.eql(u8, request, "held")) {
            self.entered.set(io);
            try self.release.wait(io);
        }
        if (std.mem.eql(u8, request, "reject")) return grpc.UnaryResponse.fail(alloc, .init(.invalid_argument, "rejected ☃"));
        if (ctx.request_metadata.getFirst("x-request")) |value| try ctx.addInitialMetadata("x-request", value);
        try ctx.addTrailingMetadata("trace-bin", "\x00\xff");
        ctx.setResponseCompression(.gzip);
        try io.sleep(.fromMilliseconds(1), .awake);
        return grpc.UnaryResponse.ok(alloc, request);
    }
};

fn unaryRequest(client: *rpc.Client, request: []const u8) !void {
    var result = try client.callUnary(allocator, method, request, .{});
    defer result.deinit();
    try std.testing.expect(result.status.isOk());
    try std.testing.expectEqualStrings(request, result.payload);
}

test "unary task handlers suspend independently on one executor and multiple reactors" {
    const runtime = try zio.Runtime.init(allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();
    const io = runtime.io();
    var handler: Unary = .{};
    var server = try rpc.Server.init(allocator, io, .{ .transport = .{ .reactor_count = 2 } });
    defer server.deinit();
    try server.registerUnary(method, rpc.UnaryHandler.bind(Unary, &handler, Unary.invoke));
    try server.start();
    var buffer: [32]u8 = undefined;
    var client = try rpc.Client.init(allocator, io, try targetFor(&server, &buffer), .{});
    defer client.deinit();
    var held = try io.concurrent(unaryRequest, .{ &client, "held" });
    defer held.cancel(io) catch {};
    try handler.entered.wait(io);
    var result = try client.callUnary(allocator, method, "independent", .{ .metadata = &.{.{ .key = "x-request", .value = "copied" }} });
    defer result.deinit();
    try std.testing.expect(result.status.isOk());
    try std.testing.expectEqualStrings("independent", result.payload);
    try std.testing.expectEqualStrings("copied", result.initial_metadata.getFirst("x-request").?);
    try std.testing.expectEqualStrings("\x00\xff", result.trailing_metadata.getFirst("trace-bin").?);
    var rejected = try client.callUnary(allocator, method, "reject", .{});
    defer rejected.deinit();
    try std.testing.expectEqual(grpc.StatusCode.invalid_argument, rejected.status.code);
    try std.testing.expectEqualStrings("rejected ☃", rejected.status.message);
    server.shutdownGracefully(std.time.ns_per_s);
    var waiter = try io.concurrent(rpc.Server.wait, .{&server});
    defer waiter.cancel(io);
    // Waiting for transport drain must suspend, leaving this executor able to
    // release a handler whose response is needed to finish that drain.
    try io.sleep(.fromMilliseconds(5), .awake);
    handler.release.set(io);
    try held.await(io);
    waiter.await(io);
    try std.testing.expectEqual(@as(usize, 0), server.activeCalls());
}

const Duplex = struct {
    const payload: [512]u8 = @splat('x');

    fn write(call: *rpc.ServerCall) !void {
        try call.sendInitialMetadata(&.{.{ .key = "x-handler", .value = "task" }}, .gzip);
        for (0..100) |_| try call.send(&payload, .{});
    }

    fn invoke(_: ?*anyopaque, call: *rpc.ServerCall) !void {
        const io = call.io();
        var writer = try io.concurrent(write, .{call});
        defer writer.cancel(io) catch {};
        var count: usize = 0;
        while (try call.receive(allocator)) |value| {
            var message = value;
            defer message.deinit();
            try std.testing.expectEqualStrings(&payload, message.payload);
            count += 1;
        }
        try std.testing.expectEqual(@as(usize, 100), count);
        try writer.await(io);
        try call.finish(.init(.ok, "done ☃"), &.{.{ .key = "trace-bin", .value = "\x00\xff" }});
    }

    fn clientWrite(stream: *rpc.Stream) !void {
        for (0..100) |_| try stream.send(&payload, .{});
        try stream.closeSend();
    }
};

test "duplex server reader and writer tasks progress through bounded flow control" {
    for ([_]u8{ 1, 2 }) |executors| {
        const runtime = try zio.Runtime.init(allocator, .{ .executors = .exact(executors) });
        defer runtime.deinit();
        const io = runtime.io();
        var warmup_handler: Unary = .{};
        var server = try rpc.Server.init(allocator, io, .{ .transport = .{
            .initial_stream_window_size = 1024,
            .stream_limits = .{ .max_message_size = 512, .max_inbound_buffer_size = 4096, .max_outbound_buffer_size = 1024 },
        } });
        defer server.deinit();
        try server.registerUnary("/test.Task/Ready", rpc.UnaryHandler.bind(Unary, &warmup_handler, Unary.invoke));
        try server.registerStream(method, .{ .invoke_fn = Duplex.invoke });
        try server.start();
        var buffer: [32]u8 = undefined;
        var client = try rpc.Client.init(allocator, io, try targetFor(&server, &buffer), .{ .initial_stream_window_size = 1024 });
        defer client.deinit();
        // Exchange SETTINGS before testing the negotiated 1 KiB window. Before
        // that exchange, HTTP/2 permits a 65,535-byte initial burst, which can
        // exceed this test's intentionally small 4 KiB inbound buffer.
        {
            var ready = try client.callUnary(allocator, "/test.Task/Ready", "ready", .{ .timeout_ns = std.time.ns_per_s * 5 });
            defer ready.deinit();
            try std.testing.expectEqual(grpc.StatusCode.ok, ready.status.code);
        }
        var stream = try client.openStream(allocator, method, .{
            .limits = .{ .max_message_size = 512, .max_inbound_buffer_size = 4096, .max_outbound_buffer_size = 1024 },
        });
        defer stream.deinit();
        var writer = try io.concurrent(Duplex.clientWrite, .{&stream});
        defer writer.cancel(io) catch {};
        var count: usize = 0;
        while (stream.receive(allocator) catch |err| {
            if (err != error.RpcFailed) return err;
            var failure = try stream.finish(allocator);
            defer failure.deinit();
            std.debug.print("duplex receive failed with {d} executors after {d} messages: {s}, status={s}: {s}\n", .{
                executors, count, @errorName(err), @tagName(failure.status.code), failure.status.message,
            });
            return err;
        }) |value| {
            var message = value;
            defer message.deinit();
            try std.testing.expectEqualStrings(&Duplex.payload, message.payload);
            count += 1;
        }
        try writer.await(io);
        try std.testing.expectEqual(@as(usize, 100), count);
        var result = try stream.finish(allocator);
        defer result.deinit();
        try std.testing.expect(result.status.isOk());
        try std.testing.expectEqualStrings("task", result.initial_metadata.getFirst("x-handler").?);
        try std.testing.expectEqualStrings("\x00\xff", result.trailing_metadata.getFirst("trace-bin").?);
    }
}

const Suspended = struct {
    entered: std.Io.Event = .unset,
    unwound: std.Io.Event = .unset,
    cancelled: bool = false,
    deadline_seen: bool = false,

    fn invoke(self: *Suspended, call: *rpc.ServerCall) !void {
        const io = call.io();
        defer self.unwound.set(io);
        self.deadline_seen = call.context().hasDeadline();
        self.entered.set(io);
        io.sleep(.fromSeconds(60), .awake) catch |err| {
            self.cancelled = err == error.Canceled;
            return err;
        };
        return error.ExpectedCancellation;
    }
};

test "peer cancellation deadline and shutdown interrupt unrelated handler Io waits" {
    const Mode = enum { cancel, deadline, shutdown };
    for ([_]Mode{ .cancel, .deadline, .shutdown }) |mode| {
        const runtime = try zio.Runtime.init(allocator, .{});
        defer runtime.deinit();
        const io = runtime.io();
        var handler: Suspended = .{};
        var server = try rpc.Server.init(allocator, io, .{});
        defer server.deinit();
        try server.registerStream(method, rpc.ServerHandler.bind(Suspended, &handler, Suspended.invoke));
        try server.start();
        var buffer: [32]u8 = undefined;
        var client = try rpc.Client.init(allocator, io, try targetFor(&server, &buffer), .{});
        defer client.deinit();
        var stream = try client.openStream(allocator, method, .{ .timeout_ns = if (mode == .deadline) 100 * std.time.ns_per_ms else null });
        defer stream.deinit();
        try handler.entered.wait(io);
        switch (mode) {
            .cancel => stream.cancel(),
            .deadline => {},
            .shutdown => server.shutdown(),
        }
        var result = try stream.finish(allocator);
        defer result.deinit();
        try std.testing.expect(!result.status.isOk());
        if (mode == .deadline) try std.testing.expectEqual(grpc.StatusCode.deadline_exceeded, result.status.code);
        try handler.unwound.wait(io);
        try std.testing.expect(handler.cancelled);
        try std.testing.expectEqual(mode == .deadline, handler.deadline_seen);
        server.shutdown();
        server.wait();
        try std.testing.expectEqual(@as(usize, 0), server.activeCalls());
    }
}

test "retained task admission rejects excess calls and teardown joins handlers" {
    const runtime = try zio.Runtime.init(allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();
    var handler: Suspended = .{};
    var server = try rpc.Server.init(allocator, io, .{ .max_calls = 1 });
    var server_owned = true;
    defer if (server_owned) server.deinit();
    try server.registerStream(method, rpc.ServerHandler.bind(Suspended, &handler, Suspended.invoke));
    try server.start();
    var buffer: [32]u8 = undefined;
    var client = try rpc.Client.init(allocator, io, try targetFor(&server, &buffer), .{});
    defer client.deinit();
    var first = try client.openStream(allocator, method, .{});
    defer first.deinit();
    try handler.entered.wait(io);
    var rejected = try client.callUnary(allocator, method, "excess", .{});
    defer rejected.deinit();
    try std.testing.expectEqual(grpc.StatusCode.resource_exhausted, rejected.status.code);
    try std.testing.expectEqual(@as(usize, 1), server.activeCalls());
    first.cancel();
    try handler.unwound.wait(io);
    for (0..200) |_| {
        if (server.activeCalls() == 0) break;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(@as(usize, 0), server.activeCalls());
    handler = .{};
    var second = try client.openStream(allocator, method, .{});
    defer second.deinit();
    try handler.entered.wait(io);
    try std.testing.expectEqual(@as(usize, 1), server.activeCalls());
    server.deinit();
    server_owned = false;
    try std.testing.expect(handler.unwound.isSet());
    try std.testing.expect(handler.cancelled);
}

test "unary cardinality and handler failures produce final status" {
    const runtime = try zio.Runtime.init(allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();
    var handler: Unary = .{};
    var server = try rpc.Server.init(allocator, io, .{ .transport = .{ .max_request_size = 8 } });
    defer server.deinit();
    try server.registerUnary(method, rpc.UnaryHandler.bind(Unary, &handler, Unary.invoke));
    const Failures = struct {
        fn missing(_: ?*anyopaque, _: *rpc.ServerCall) !void {}
        fn oom(_: ?*anyopaque, _: *rpc.ServerCall) !void {
            return error.OutOfMemory;
        }
    };
    try server.registerStream("/test.Task/Missing", .{ .invoke_fn = Failures.missing });
    try server.registerStream("/test.Task/Oom", .{ .invoke_fn = Failures.oom });
    try server.start();
    var buffer: [32]u8 = undefined;
    var client = try rpc.Client.init(allocator, io, try targetFor(&server, &buffer), .{});
    defer client.deinit();
    for ([_]usize{ 0, 2 }) |count| {
        var stream = try client.openStream(allocator, method, .{});
        defer stream.deinit();
        for (0..count) |_| try stream.send("request", .{});
        try stream.closeSend();
        var result = try stream.finish(allocator);
        defer result.deinit();
        try std.testing.expectEqual(grpc.StatusCode.invalid_argument, result.status.code);
    }
    inline for (.{
        .{ method, grpc.StatusCode.resource_exhausted },
        .{ "/test.Task/Missing", grpc.StatusCode.internal },
        .{ "/test.Task/Oom", grpc.StatusCode.resource_exhausted },
    }) |case| {
        var result = try client.callUnary(allocator, case[0], "oversized request", .{});
        defer result.deinit();
        try std.testing.expectEqual(case[1], result.status.code);
    }
}

test "task server construction and registration clean up every allocation failure" {
    const runtime = try zio.Runtime.init(allocator, .{});
    defer runtime.deinit();
    const Check = struct {
        fn run(alloc: std.mem.Allocator, io: std.Io) !void {
            var handler: Unary = .{};
            var server = try rpc.Server.init(alloc, io, .{ .transport = .{ .reactor_count = 2 } });
            defer server.deinit();
            try server.registerUnary(method, rpc.UnaryHandler.bind(Unary, &handler, Unary.invoke));
            try server.registerStream("/test.Task/Stream", .{ .invoke_fn = Duplex.invoke });
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Check.run, .{runtime.io()});
}

test "server receive allocation failure preserves the request for retry" {
    const runtime = try zio.Runtime.init(allocator, .{});
    defer runtime.deinit();
    const Handler = struct {
        fn invoke(_: ?*anyopaque, call: *rpc.ServerCall) !void {
            var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
            try std.testing.expectError(error.OutOfMemory, call.receive(failing.allocator()));
            var request = (try call.receive(allocator)).?;
            defer request.deinit();
            try std.testing.expectEqualStrings("retained", request.payload);
            try std.testing.expect(try call.receive(allocator) == null);
            try call.send(request.payload, .{});
            try call.finish(.ok, &.{});
        }
    };
    var server = try rpc.Server.init(allocator, runtime.io(), .{});
    defer server.deinit();
    try server.registerStream(method, .{ .invoke_fn = Handler.invoke });
    try server.start();
    var buffer: [32]u8 = undefined;
    var client = try rpc.Client.init(allocator, runtime.io(), try targetFor(&server, &buffer), .{});
    defer client.deinit();
    try unaryRequest(&client, "retained");
}

test "server startup failure and unused server teardown do not wait on absent threads" {
    const runtime = try zio.Runtime.init(allocator, .{});
    defer runtime.deinit();
    var unused = try rpc.Server.init(allocator, runtime.io(), .{});
    unused.deinit();
    var invalid = try rpc.Server.init(allocator, runtime.io(), .{ .transport = .{ .host = "invalid" } });
    defer invalid.deinit();
    try std.testing.expectError(error.InvalidAddress, invalid.start());
}

test "task launch failures reject or abort the call and reclaim its reservation" {
    const Fail = struct {
        fn group(_: ?*anyopaque, _: *std.Io.Group, _: []const u8, _: std.mem.Alignment, _: *const fn (*const anyopaque) void) std.Io.ConcurrentError!void {
            return error.ConcurrencyUnavailable;
        }
        fn task(_: ?*anyopaque, _: usize, _: std.mem.Alignment, _: []const u8, _: std.mem.Alignment, _: *const fn (*const anyopaque, *anyopaque) void) std.Io.ConcurrentError!*std.Io.AnyFuture {
            return error.ConcurrencyUnavailable;
        }
    };
    for ([_]bool{ true, false }) |fail_group| {
        const runtime = try zio.Runtime.init(allocator, .{});
        defer runtime.deinit();
        var io = runtime.io();
        var vtable = io.vtable.*;
        if (fail_group) vtable.groupConcurrent = Fail.group else vtable.concurrent = Fail.task;
        io.vtable = &vtable;
        var handler: Unary = .{};
        var server = try rpc.Server.init(allocator, io, .{});
        defer server.deinit();
        try server.registerUnary(method, rpc.UnaryHandler.bind(Unary, &handler, Unary.invoke));
        try server.start();
        var buffer: [32]u8 = undefined;
        var client = try rpc.Client.init(allocator, runtime.io(), try targetFor(&server, &buffer), .{});
        defer client.deinit();
        var result = try client.callUnary(allocator, method, "request", .{});
        defer result.deinit();
        try std.testing.expect(!result.status.isOk());
        if (fail_group) try std.testing.expectEqual(grpc.StatusCode.resource_exhausted, result.status.code);
        server.shutdown();
        server.wait();
        try std.testing.expectEqual(@as(usize, 0), server.activeCalls());
    }
}

test "terminal notification unwinds blocked server send and receive tasks" {
    const Handler = struct {
        sending: bool,
        entered: std.Io.Event = .unset,
        unwound: std.Io.Event = .unset,
        fn invoke(self: *@This(), call: *rpc.ServerCall) !void {
            defer self.unwound.set(call.io());
            self.entered.set(call.io());
            if (self.sending) {
                const payload: [128 * 1024]u8 = @splat('x');
                // The client never consumes responses, so its receive window
                // prevents these messages from all fitting into bounded queues.
                for (0..100) |_| try call.send(&payload, .{});
                return error.ExpectedBackpressure;
            } else if (try call.receive(allocator)) |value| {
                var message = value;
                message.deinit();
                return error.UnexpectedRequest;
            }
        }
    };
    for ([_]bool{ true, false }) |sending| {
        const runtime = try zio.Runtime.init(allocator, .{});
        defer runtime.deinit();
        const io = runtime.io();
        var handler: Handler = .{ .sending = sending };
        var server = try rpc.Server.init(allocator, io, .{ .transport = .{
            .stream_limits = .{ .max_message_size = 128 * 1024, .max_outbound_buffer_size = 128 * 1024 + 5 },
        } });
        defer server.deinit();
        try server.registerStream(method, rpc.ServerHandler.bind(Handler, &handler, Handler.invoke));
        try server.start();
        var buffer: [32]u8 = undefined;
        var client = try rpc.Client.init(allocator, io, try targetFor(&server, &buffer), .{ .initial_stream_window_size = 1024 });
        defer client.deinit();
        var stream = try client.openStream(allocator, method, .{});
        defer stream.deinit();
        try handler.entered.wait(io);
        try io.sleep(.fromMilliseconds(5), .awake);
        try std.testing.expect(!handler.unwound.isSet());
        stream.cancel();
        try handler.unwound.wait(io);
        server.shutdown();
        server.wait();
        try std.testing.expectEqual(@as(usize, 0), server.activeCalls());
    }
}
