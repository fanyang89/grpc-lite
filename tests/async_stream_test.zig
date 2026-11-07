const std = @import("std");
const grpc = @import("grpc_lite");
const rpc = @import("grpc_lite_async");
const zio = @import("zio");

const allocator = std.testing.allocator;
const method = "/test.Async/Chat";

const Echo = struct {
    fn start(_: ?*anyopaque, _: grpc.ServerStream, context: *grpc.ServerContext) !void {
        context.setResponseCompression(.gzip);
        try context.addInitialMetadata("x-initial", "stream");
        try context.addTrailingMetadata("trace-bin", "\x00\xff");
    }

    fn message(_: ?*anyopaque, stream: grpc.ServerStream, _: *grpc.ServerContext, payload: []const u8, compression: grpc.Compression) !grpc.StreamReceiveAction {
        try stream.send(payload, .{ .compression = compression });
        return .continue_receiving;
    }

    fn end(_: ?*anyopaque, stream: grpc.ServerStream, _: *grpc.ServerContext) !void {
        try stream.finish(.init(.ok, "done ☃"));
    }

    const handler: grpc.ServerStreamHandler = .{
        .on_start = start,
        .on_message = message,
        .on_remote_end = end,
    };
};

fn targetFor(server: *grpc.Server, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "127.0.0.1:{d}", .{try server.port()});
}

fn writeMessages(stream: *rpc.Stream) anyerror!void {
    for (0..64) |index| {
        var buffer: [32]u8 = undefined;
        const payload = try std.fmt.bufPrint(&buffer, "message-{d}", .{index});
        try stream.send(payload, .{ .compression = if (index % 2 == 0) .gzip else .identity });
    }
    try stream.closeSend();
}

fn readMessages(stream: *rpc.Stream) anyerror!void {
    var count: usize = 0;
    while (try stream.receive(allocator)) |value| {
        var message = value;
        defer message.deinit();
        var buffer: [32]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&buffer, "message-{d}", .{count}), message.payload);
        try std.testing.expectEqual(if (count % 2 == 0) grpc.Compression.gzip else .identity, message.compression);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 64), count);
}

test "single and multiple executors stream both directions with half-close metadata and gzip" {
    for ([_]u8{ 1, 2 }) |executors| {
        const runtime = try zio.Runtime.init(allocator, .{ .executors = .exact(executors) });
        defer runtime.deinit();
        const io = runtime.io();
        var server = try grpc.Server.init(allocator, .{});
        defer server.deinit();
        try server.registerStream(method, Echo.handler);
        try server.start();
        var buffer: [32]u8 = undefined;
        var client = try rpc.Client.init(allocator, io, try targetFor(&server, &buffer), .{ .initial_stream_window_size = 4096 });
        defer client.deinit();
        {
            var stream = try client.openStream(allocator, method, .{
                .send_compression = .gzip,
                .limits = .{ .max_message_size = 1024, .max_inbound_buffer_size = 8192, .max_outbound_buffer_size = 1029 },
            });
            defer stream.deinit();
            var writer = try io.concurrent(writeMessages, .{&stream});
            defer writer.cancel(io) catch {};
            var reader = try io.concurrent(readMessages, .{&stream});
            defer reader.cancel(io) catch {};
            try writer.await(io);
            try reader.await(io);
            var result = try stream.finish(allocator);
            defer result.deinit();
            try std.testing.expect(result.status.isOk());
            try std.testing.expectEqualStrings("done ☃", result.status.message);
            try std.testing.expectEqualStrings("stream", result.initial_metadata.getFirst("x-initial").?);
            try std.testing.expectEqualStrings("\x00\xff", result.trailing_metadata.getFirst("trace-bin").?);
        }
        // Channel teardown joins the last transport release as well as callbacks.
        client.shutdown();
        client.channel.wait();
        try std.testing.expectEqual(@as(usize, 0), client.channel.streamAdmissionStats().retained_streams);
    }
}

const PausedSink = struct {
    io: std.Io,
    started: std.Io.Event = .unset,
    call: ?grpc.ServerCall = null,

    fn start(context: ?*anyopaque, stream: grpc.ServerStream, _: *grpc.ServerContext) !void {
        const self: *PausedSink = @ptrCast(@alignCast(context.?));
        self.call = try stream.retain();
        self.started.set(self.io);
    }

    fn message(_: ?*anyopaque, _: grpc.ServerStream, _: *grpc.ServerContext, _: []const u8, _: grpc.Compression) !grpc.StreamReceiveAction {
        return .continue_receiving;
    }

    fn end(_: ?*anyopaque, stream: grpc.ServerStream, _: *grpc.ServerContext) !void {
        try stream.send("received", .{});
        try stream.finish(.ok);
    }

    fn handler(self: *PausedSink) grpc.ServerStreamHandler {
        return .{ .context = self, .receive_initially_paused = true, .on_start = start, .on_message = message, .on_remote_end = end };
    }
};

const BlockingSend = struct {
    stream: *rpc.Stream,
    io: std.Io,
    entered: std.Io.Event = .unset,
    done: std.Io.Event = .unset,
    payload: []const u8,

    fn run(self: *BlockingSend) anyerror!void {
        self.entered.set(self.io);
        try self.stream.send(self.payload, .{});
        self.done.set(self.io);
    }
};

test "send suspends on flow control and resumes when the peer consumes" {
    const runtime = try zio.Runtime.init(allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();
    var sink: PausedSink = .{ .io = io };
    var server = try grpc.Server.init(allocator, .{ .initial_stream_window_size = 1024 });
    defer server.deinit();
    defer {
        server.shutdown();
        server.wait();
        if (sink.call) |*call| call.deinit();
    }
    try server.registerStream(method, sink.handler());
    try server.start();
    var buffer: [32]u8 = undefined;
    var client = try rpc.Client.init(allocator, io, try targetFor(&server, &buffer), .{});
    defer client.deinit();
    var stream = try client.openStream(allocator, method, .{
        .limits = .{ .max_message_size = 128 * 1024, .max_outbound_buffer_size = 128 * 1024 + 5 },
    });
    defer stream.deinit();
    try sink.started.wait(io);
    const payload = try allocator.alloc(u8, 128 * 1024);
    defer allocator.free(payload);
    @memset(payload, 'x');
    try stream.send(payload, .{});
    var send: BlockingSend = .{ .stream = &stream, .io = io, .payload = payload };
    var writer = try io.concurrent(BlockingSend.run, .{&send});
    defer writer.cancel(io) catch {};
    try send.entered.wait(io);
    try std.testing.expect(!send.done.isSet());
    try std.testing.expectError(error.ConcurrentSend, stream.closeSend());
    try sink.call.?.resumeReceive();
    try writer.await(io);
    try stream.closeSend();
    var response = (try stream.receive(allocator)).?;
    defer response.deinit();
    try std.testing.expectEqualStrings("received", response.payload);
    try std.testing.expect(try stream.receive(allocator) == null);
    var result = try stream.finish(allocator);
    defer result.deinit();
    try std.testing.expect(result.status.isOk());
}

const BlockingReceive = struct {
    stream: *rpc.Stream,
    io: std.Io,
    entered: std.Io.Event = .unset,

    fn run(self: *BlockingReceive) anyerror!void {
        self.entered.set(self.io);
        if (try self.stream.receive(allocator)) |value| {
            var message = value;
            message.deinit();
        }
    }
};

test "cancelling a receive wakes the stream and leaves sibling streams usable" {
    const runtime = try zio.Runtime.init(allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();
    var server = try grpc.Server.init(allocator, .{});
    defer server.deinit();
    try server.registerStream(method, Echo.handler);
    try server.start();
    var buffer: [32]u8 = undefined;
    var client = try rpc.Client.init(allocator, io, try targetFor(&server, &buffer), .{});
    defer client.deinit();
    var first = try client.openStream(allocator, method, .{});
    defer first.deinit();
    var blocked: BlockingReceive = .{ .stream = &first, .io = io };
    var reader = try io.concurrent(BlockingReceive.run, .{&blocked});
    defer reader.cancel(io) catch {};
    try blocked.entered.wait(io);
    try std.testing.expectError(error.ConcurrentReceive, first.receive(allocator));
    try std.testing.expectError(error.Canceled, reader.cancel(io));
    var cancelled = try first.finish(allocator);
    defer cancelled.deinit();
    try std.testing.expectEqual(grpc.StatusCode.cancelled, cancelled.status.code);

    var second = try client.openStream(allocator, method, .{});
    defer second.deinit();
    try second.send("sibling", .{});
    try second.closeSend();
    var message = (try second.receive(allocator)).?;
    defer message.deinit();
    try std.testing.expectEqualStrings("sibling", message.payload);
    try std.testing.expect(try second.receive(allocator) == null);
}

test "deadline and client teardown wake readers and preserve final status" {
    const runtime = try zio.Runtime.init(allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();
    var server = try grpc.Server.init(allocator, .{});
    defer server.deinit();
    try server.registerStream(method, Echo.handler);
    try server.start();
    var buffer: [32]u8 = undefined;
    var client = try rpc.Client.init(allocator, io, try targetFor(&server, &buffer), .{});
    var client_owned = true;
    defer if (client_owned) client.deinit();
    var expired = try client.openStream(allocator, method, .{ .timeout_ns = 20 * std.time.ns_per_ms });
    defer expired.deinit();
    try std.testing.expectError(error.RpcFailed, expired.receive(allocator));
    var status = try expired.finish(allocator);
    defer status.deinit();
    try std.testing.expectEqual(grpc.StatusCode.deadline_exceeded, status.status.code);

    var surviving = try client.openStream(allocator, method, .{});
    defer surviving.deinit();
    var blocked: BlockingReceive = .{ .stream = &surviving, .io = io };
    var reader = try io.concurrent(BlockingReceive.run, .{&blocked});
    defer reader.cancel(io) catch {};
    try blocked.entered.wait(io);
    client.deinit();
    client_owned = false;
    try std.testing.expectError(error.RpcFailed, reader.await(io));
    var stopped = try surviving.finish(allocator);
    defer stopped.deinit();
    try std.testing.expectEqual(grpc.StatusCode.unavailable, stopped.status.code);
}

test "receive allocation failure keeps the message and finish can be retried" {
    const runtime = try zio.Runtime.init(allocator, .{});
    defer runtime.deinit();
    var server = try grpc.Server.init(allocator, .{});
    defer server.deinit();
    try server.registerStream(method, Echo.handler);
    try server.start();
    var buffer: [32]u8 = undefined;
    var client = try rpc.Client.init(allocator, runtime.io(), try targetFor(&server, &buffer), .{});
    defer client.deinit();
    var stream = try client.openStream(allocator, method, .{});
    defer stream.deinit();
    try stream.send("retained", .{});
    try stream.closeSend();
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, stream.receive(failing.allocator()));
    var message = (try stream.receive(allocator)).?;
    defer message.deinit();
    try std.testing.expectEqualStrings("retained", message.payload);
    try std.testing.expect(try stream.receive(allocator) == null);
    const Check = struct {
        fn run(alloc: std.mem.Allocator, s: *rpc.Stream) !void {
            var result = try s.finish(alloc);
            defer result.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Check.run, .{&stream});
}

test "bridge allocation failures clean up callbacks messages and metadata" {
    const runtime = try zio.Runtime.init(allocator, .{});
    defer runtime.deinit();
    var server = try grpc.Server.init(allocator, .{});
    defer server.deinit();
    try server.registerStream(method, Echo.handler);
    try server.start();
    var buffer: [32]u8 = undefined;
    var client = try rpc.Client.init(allocator, runtime.io(), try targetFor(&server, &buffer), .{});
    defer client.deinit();
    const Check = struct {
        fn run(alloc: std.mem.Allocator, c: *rpc.Client) !void {
            var stream = try c.openStream(alloc, method, .{});
            defer stream.deinit();
            try stream.send("payload", .{});
            try stream.closeSend();
            while (try stream.receive(allocator)) |value| {
                var message = value;
                message.deinit();
            }
            var result = try stream.finish(allocator);
            defer result.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Check.run, .{&client});
}

test "cancelling send receive or finish wakes both flow-controlled directions" {
    const CancelTarget = enum { reader, writer, finish };
    for ([_]CancelTarget{ .reader, .writer, .finish }) |cancel_target| {
        const runtime = try zio.Runtime.init(allocator, .{});
        defer runtime.deinit();
        const io = runtime.io();
        var sink: PausedSink = .{ .io = io };
        var server = try grpc.Server.init(allocator, .{ .initial_stream_window_size = 1024 });
        defer server.deinit();
        defer {
            server.shutdown();
            server.wait();
            if (sink.call) |*call| call.deinit();
        }
        try server.registerStream(method, sink.handler());
        try server.start();
        var buffer: [32]u8 = undefined;
        var client = try rpc.Client.init(allocator, io, try targetFor(&server, &buffer), .{});
        defer client.deinit();
        var stream = try client.openStream(allocator, method, .{
            .limits = .{ .max_message_size = 128 * 1024, .max_outbound_buffer_size = 128 * 1024 + 5 },
        });
        defer stream.deinit();
        try sink.started.wait(io);
        const payload = try allocator.alloc(u8, 128 * 1024);
        defer allocator.free(payload);
        @memset(payload, 'x');
        try stream.send(payload, .{});
        var send: BlockingSend = .{ .stream = &stream, .io = io, .payload = payload };
        var writer = try io.concurrent(BlockingSend.run, .{&send});
        defer writer.cancel(io) catch {};
        try send.entered.wait(io);
        var receive: BlockingReceive = .{ .stream = &stream, .io = io };
        var reader = try io.concurrent(BlockingReceive.run, .{&receive});
        defer reader.cancel(io) catch {};
        try receive.entered.wait(io);
        const Finish = struct {
            fn run(s: *rpc.Stream) anyerror!void {
                var result = try s.finish(allocator);
                defer result.deinit();
                try std.testing.expectEqual(grpc.StatusCode.cancelled, result.status.code);
            }
        };
        var finish = try io.concurrent(Finish.run, .{&stream});
        defer finish.cancel(io) catch {};
        switch (cancel_target) {
            .reader => {
                try std.testing.expectError(error.Canceled, reader.cancel(io));
                try std.testing.expectError(error.StreamClosed, writer.await(io));
                try finish.await(io);
            },
            .writer => {
                try std.testing.expectError(error.Canceled, writer.cancel(io));
                try std.testing.expectError(error.RpcFailed, reader.await(io));
                try finish.await(io);
            },
            .finish => {
                try std.testing.expectError(error.Canceled, finish.cancel(io));
                try std.testing.expectError(error.StreamClosed, writer.await(io));
                try std.testing.expectError(error.RpcFailed, reader.await(io));
            },
        }
    }
}

test "empty messages are distinct from EOF and buffered data precedes failure status" {
    const runtime = try zio.Runtime.init(allocator, .{});
    defer runtime.deinit();
    var server = try grpc.Server.init(allocator, .{});
    defer server.deinit();
    const Failure = struct {
        fn end(_: ?*anyopaque, stream: grpc.ServerStream, _: *grpc.ServerContext) !void {
            try stream.send("", .{});
            try stream.send("last", .{});
            try stream.finish(.init(.invalid_argument, "rejected ☃"));
        }
    };
    try server.registerStream(method, .{
        .on_start = Echo.start,
        .on_message = PausedSink.message,
        .on_remote_end = Failure.end,
    });
    try server.start();
    var buffer: [32]u8 = undefined;
    var client = try rpc.Client.init(allocator, runtime.io(), try targetFor(&server, &buffer), .{});
    defer client.deinit();
    var stream = try client.openStream(allocator, method, .{});
    var owned = true;
    defer if (owned) stream.deinit();
    try stream.closeSend();
    var empty = (try stream.receive(allocator)).?;
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.payload.len);
    var last = (try stream.receive(allocator)).?;
    defer last.deinit();
    try std.testing.expectError(error.RpcFailed, stream.receive(allocator));
    var result = try stream.finish(allocator);
    defer result.deinit();
    stream.deinit();
    owned = false;
    try std.testing.expectEqualStrings("last", last.payload);
    try std.testing.expectEqual(grpc.StatusCode.invalid_argument, result.status.code);
    try std.testing.expectEqualStrings("rejected ☃", result.status.message);
    try std.testing.expectEqualStrings("\x00\xff", result.trailing_metadata.getFirst("trace-bin").?);
}

test "slow reader backpressures a bounded producer and resumes every message" {
    const runtime = try zio.Runtime.init(allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();
    const Burst = struct {
        io: std.Io,
        blocked: std.Io.Event = .unset,
        sent_all: std.Io.Event = .unset,
        next: usize = 0,
        const payload: [512]u8 = @splat('b');

        fn pump(self: *@This(), stream: grpc.ServerStream) !void {
            while (self.next < 100) {
                stream.send(&payload, .{}) catch |err| {
                    if (err != error.WouldBlock) return err;
                    self.blocked.set(self.io);
                    return;
                };
                self.next += 1;
            }
            try stream.finish(.ok);
            self.sent_all.set(self.io);
        }

        fn end(context: ?*anyopaque, stream: grpc.ServerStream, _: *grpc.ServerContext) !void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            try self.pump(stream);
        }

        fn writable(context: ?*anyopaque, stream: grpc.ServerStream, _: *grpc.ServerContext) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.pump(stream) catch stream.finish(.init(.internal, "producer failed")) catch {};
        }
    };
    var burst: Burst = .{ .io = io };
    var server = try grpc.Server.init(allocator, .{
        .initial_stream_window_size = 1024,
        .stream_limits = .{ .max_message_size = 512, .max_inbound_buffer_size = 1024, .max_outbound_buffer_size = 1024 },
    });
    defer server.deinit();
    try server.registerStream(method, .{
        .context = &burst,
        .on_start = Echo.start,
        .on_message = PausedSink.message,
        .on_remote_end = Burst.end,
        .on_writable = Burst.writable,
    });
    try server.start();
    var buffer: [32]u8 = undefined;
    var client = try rpc.Client.init(allocator, io, try targetFor(&server, &buffer), .{ .initial_stream_window_size = 1024 });
    defer client.deinit();
    var stream = try client.openStream(allocator, method, .{
        .limits = .{ .max_message_size = 512, .max_inbound_buffer_size = 4096, .max_outbound_buffer_size = 1024 },
    });
    defer stream.deinit();
    try stream.closeSend();
    try burst.blocked.wait(io);
    try io.sleep(.fromMilliseconds(5), .awake);
    try std.testing.expect(!burst.sent_all.isSet());
    var count: usize = 0;
    while (try stream.receive(allocator)) |value| {
        var message = value;
        defer message.deinit();
        try std.testing.expectEqualStrings(&Burst.payload, message.payload);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 100), count);
    try std.testing.expect(burst.sent_all.isSet());
    var result = try stream.finish(allocator);
    defer result.deinit();
    try std.testing.expect(result.status.isOk());
}
