const std = @import("std");
const grpc = @import("grpc_lite");
const rpc = @import("grpc_lite_async");
const zio = @import("zio");

const allocator = std.testing.allocator;
const unary_path = "/test.Lifecycle/Unary";
const stream_path = "/test.Lifecycle/Stream";
const timeout_ns = 5 * std.time.ns_per_s;
const reconnect: grpc.ReconnectOptions = .{
    .allow_initial_offline = true,
    .initial_backoff_ns = 10 * std.time.ns_per_ms,
    .max_backoff_ns = 10 * std.time.ns_per_ms,
    .jitter_percent = 0,
};

const Service = struct {
    entered: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    unary_calls: std.atomic.Value(usize) = .init(0),
    stream_calls: std.atomic.Value(usize) = .init(0),
    cancelled_handlers: std.atomic.Value(usize) = .init(0),

    fn unary(self: *Service, alloc: std.mem.Allocator, io: std.Io, _: *grpc.ServerContext, request: []const u8) !grpc.UnaryResponse {
        _ = self.unary_calls.fetchAdd(1, .monotonic);
        if (std.mem.eql(u8, request, "held")) {
            self.entered.set(io);
            self.release.wait(io) catch |err| {
                if (err == error.Canceled) _ = self.cancelled_handlers.fetchAdd(1, .monotonic);
                return err;
            };
        }
        return grpc.UnaryResponse.ok(alloc, request);
    }

    fn stream(self: *Service, call: *rpc.ServerCall) !void {
        _ = self.stream_calls.fetchAdd(1, .monotonic);
        while (call.receive(allocator) catch |err| {
            if (err == error.Canceled or err == error.StreamClosed) _ = self.cancelled_handlers.fetchAdd(1, .monotonic);
            return err;
        }) |value| {
            var message = value;
            defer message.deinit();
            try call.send(message.payload, .{});
        }
        try call.finish(.ok, &.{.{ .key = "x-lifecycle", .value = "complete" }});
    }

    fn start(self: *Service, io: std.Io, port: u16) !rpc.Server {
        var server = try rpc.Server.init(allocator, io, .{ .transport = .{ .port = port } });
        errdefer server.deinit();
        try server.registerUnary(unary_path, rpc.UnaryHandler.bind(Service, self, unary));
        try server.registerStream(stream_path, rpc.ServerHandler.bind(Service, self, stream));
        try server.start();
        return server;
    }
};

fn expectUnary(client: *rpc.Client, request: []const u8, code: grpc.StatusCode) !void {
    var result = try client.callUnary(allocator, unary_path, request, .{ .timeout_ns = timeout_ns });
    defer result.deinit();
    try std.testing.expectEqual(code, result.status.code);
    if (code == .ok) try std.testing.expectEqualStrings(request, result.payload);
}

fn exchange(stream: *rpc.Stream, payload: []const u8) !void {
    try stream.send(payload, .{});
    var response = (try stream.receive(allocator)) orelse return error.MissingResponse;
    defer response.deinit();
    try std.testing.expectEqualStrings(payload, response.payload);
}

fn expectEnd(stream: *rpc.Stream) !void {
    try stream.closeSend();
    try std.testing.expectEqual(null, try stream.receive(allocator));
    var result = try stream.finish(allocator);
    defer result.deinit();
    try std.testing.expect(result.status.isOk());
    try std.testing.expectEqualStrings("complete", result.trailing_metadata.getFirst("x-lifecycle").?);
}

fn expectBrokenStream(stream: *rpc.Stream) !void {
    try std.testing.expectError(error.RpcFailed, stream.receive(allocator));
    var result = try stream.finish(allocator);
    defer result.deinit();
    try std.testing.expectEqual(grpc.StatusCode.unavailable, result.status.code);
}

// Observe transport progress without blocking the executor or depending on a
// fixed sleep to order GOAWAY, queued calls, and reconnect activation.
fn waitForCounter(client: *rpc.Client, comptime field: []const u8, minimum: u64) !void {
    const io = client.io;
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + timeout_ns;
    while (@field(client.channel.operationalStats(), field) < minimum) {
        if (std.Io.Clock.awake.now(io).nanoseconds >= deadline) return error.TransportProgressTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn expectRecovered(client: *rpc.Client, service: *Service) !void {
    try expectUnary(client, "after restart", .ok);
    var stream = try client.openStream(allocator, stream_path, .{ .timeout_ns = timeout_ns });
    defer stream.deinit();
    try exchange(&stream, "new stream");
    try expectEnd(&stream);
    // Only explicit new calls may reach the replacement server.
    try std.testing.expectEqual(@as(usize, 1), service.unary_calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), service.stream_calls.load(.acquire));
    const stats = client.channel.operationalStats();
    try std.testing.expect(stats.reconnect_attempts >= 1);
    try std.testing.expect(stats.reconnect_successes >= 1);
    try std.testing.expectEqual(@as(u64, 1), stats.active_connections);
    try std.testing.expectEqual(@as(usize, 0), stats.unary_admission.retained_calls);
}

test "task GOAWAY drain preserves accepted calls and reconnects without replay" {
    const runtime = try zio.Runtime.init(allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();
    const io = runtime.io();
    var service: Service = .{};
    var server = try service.start(io, 0);
    defer server.deinit();
    const port = try server.port();
    var buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&buffer, "127.0.0.1:{d}", .{port});
    var client = try rpc.Client.init(allocator, io, target, .{ .reconnect = reconnect });
    defer client.deinit();
    var held = try io.concurrent(expectUnary, .{ &client, "held", .ok });
    defer held.cancel(io) catch {};
    try service.entered.wait(io);
    {
        var stream = try client.openStream(allocator, stream_path, .{ .timeout_ns = timeout_ns });
        defer stream.deinit();
        try exchange(&stream, "before drain");
        server.shutdownGracefully(timeout_ns);
        var waiter = try io.concurrent(rpc.Server.wait, .{&server});
        defer waiter.cancel(io);
        try waitForCounter(&client, "reconnect_goaway", 1);

        // New unary work queues during drain and remains task-cancelable.
        var queued = try io.concurrent(expectUnary, .{ &client, "cancel before submission", .ok });
        defer queued.cancel(io) catch {};
        try waitForCounter(&client, "pending_unary_calls", 1);
        try std.testing.expectError(error.Canceled, queued.cancel(io));
        try std.testing.expectEqual(@as(usize, 1), service.unary_calls.load(.acquire));

        // GOAWAY must leave both directions of the accepted stream usable.
        try exchange(&stream, "during drain");
        try expectEnd(&stream);
        service.release.set(io);
        try held.await(io);
        waiter.await(io);
    }
    try std.testing.expectEqual(@as(usize, 0), server.activeCalls());
    try std.testing.expectEqual(@as(usize, 0), service.cancelled_handlers.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), client.channel.streamAdmissionStats().retained_streams);

    var replacement: Service = .{};
    var restarted = try replacement.start(io, port);
    defer restarted.deinit();
    try expectRecovered(&client, &replacement);
    try std.testing.expectEqual(@as(usize, 1), service.unary_calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), service.stream_calls.load(.acquire));
}

test "task shutdown and drain expiry join suspended handlers before channel recovery" {
    const Mode = enum { immediate, drain_timeout, escalate };
    for ([_]Mode{ .immediate, .drain_timeout, .escalate }) |mode| {
        const runtime = try zio.Runtime.init(allocator, .{ .executors = .exact(1) });
        defer runtime.deinit();
        const io = runtime.io();
        var service: Service = .{};
        var server = try service.start(io, 0);
        defer server.deinit();
        const port = try server.port();
        var buffer: [32]u8 = undefined;
        const target = try std.fmt.bufPrint(&buffer, "127.0.0.1:{d}", .{port});
        var client = try rpc.Client.init(allocator, io, target, .{ .reconnect = reconnect });
        defer client.deinit();
        var held = try io.concurrent(expectUnary, .{ &client, "held", .unavailable });
        defer held.cancel(io) catch {};
        try service.entered.wait(io);
        var old_stream = try client.openStream(allocator, stream_path, .{ .timeout_ns = timeout_ns });
        var stream_owned = true;
        defer if (stream_owned) old_stream.deinit();
        try exchange(&old_stream, "accepted before shutdown");
        var reader = try io.concurrent(expectBrokenStream, .{&old_stream});
        defer reader.cancel(io) catch {};
        switch (mode) {
            .immediate => server.shutdown(),
            .drain_timeout => server.shutdownGracefully(50 * std.time.ns_per_ms),
            .escalate => {
                server.shutdownGracefully(std.time.ns_per_hour);
                try waitForCounter(&client, "reconnect_goaway", 1);
                server.shutdown();
            },
        }
        server.wait();
        try held.await(io);
        try reader.await(io);
        try std.testing.expectEqual(@as(usize, 0), server.activeCalls());
        try std.testing.expectEqual(@as(usize, 2), service.cancelled_handlers.load(.acquire));
        try std.testing.expectEqual(@as(usize, 1), client.channel.streamAdmissionStats().retained_streams);

        var replacement: Service = .{};
        var restarted = try replacement.start(io, port);
        defer restarted.deinit();
        try expectRecovered(&client, &replacement);
        // An old owning stream keeps its terminal status across reconnection and
        // holds admission only until destruction, independently of new calls.
        var result = try old_stream.finish(allocator);
        defer result.deinit();
        try std.testing.expectEqual(grpc.StatusCode.unavailable, result.status.code);
        old_stream.deinit();
        stream_owned = false;
        try std.testing.expectEqual(@as(usize, 0), client.channel.streamAdmissionStats().retained_streams);
        try std.testing.expectEqual(@as(usize, 1), service.unary_calls.load(.acquire));
        try std.testing.expectEqual(@as(usize, 1), service.stream_calls.load(.acquire));
    }
}

test "offline task unary cancellation and deadline never reach the restarted peer" {
    const runtime = try zio.Runtime.init(allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();
    const io = runtime.io();
    var original: Service = .{};
    var server = try original.start(io, 0);
    defer server.deinit();
    const port = try server.port();
    var buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&buffer, "127.0.0.1:{d}", .{port});
    server.shutdown();
    server.wait();
    var client = try rpc.Client.init(allocator, io, target, .{ .reconnect = reconnect });
    defer client.deinit();
    try std.testing.expectError(error.ChannelUnavailable, client.openStream(allocator, stream_path, .{}));
    try std.testing.expectEqual(@as(usize, 0), client.channel.streamAdmissionStats().retained_streams);
    var cancelled = try io.concurrent(expectUnary, .{ &client, "cancelled offline", .ok });
    defer cancelled.cancel(io) catch {};
    try waitForCounter(&client, "pending_unary_calls", 1);
    try std.testing.expectError(error.Canceled, cancelled.cancel(io));
    var expired = try client.callUnary(allocator, unary_path, "expired offline", .{ .timeout_ns = 50 * std.time.ns_per_ms });
    defer expired.deinit();
    try std.testing.expectEqual(grpc.StatusCode.deadline_exceeded, expired.status.code);
    try std.testing.expectEqual(@as(usize, 0), client.channel.unaryAdmissionStats().retained_calls);

    // A still-live queued call may be submitted once a connection is available.
    var queued = try io.concurrent(expectUnary, .{ &client, "queued offline", .ok });
    defer queued.cancel(io) catch {};
    try waitForCounter(&client, "pending_unary_calls", 1);
    var replacement: Service = .{};
    var restarted = try replacement.start(io, port);
    defer restarted.deinit();
    try queued.await(io);
    try std.testing.expectEqual(@as(usize, 1), replacement.unary_calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), original.unary_calls.load(.acquire));
    const stats = client.channel.operationalStats();
    try std.testing.expectEqual(@as(u64, 0), stats.pending_unary_calls);
    try std.testing.expectEqual(@as(u64, 1), stats.terminal_cancelled);
    try std.testing.expectEqual(@as(u64, 1), stats.terminal_deadline_exceeded);
    try std.testing.expectEqual(@as(u64, 1), stats.terminal_ok);
    try std.testing.expectEqual(@as(usize, 0), stats.unary_admission.retained_calls);
}
