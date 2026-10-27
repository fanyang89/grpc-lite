const std = @import("std");
const grpc = @import("grpc_lite");
const options = @import("consumer_options");

const wire = "\x08\x01";
const unary_method = "/consumer.Echo/Unary";
const stream_method = "/consumer.Echo/Stream";

const Handler = struct {
    retained: ?grpc.ServerCall = null,

    fn unary(_: *@This(), allocator: std.mem.Allocator, context: *grpc.ServerContext, request: []const u8) !grpc.UnaryResponse {
        try context.addInitialMetadata("x-consumer", "owned");
        return grpc.UnaryResponse.ok(allocator, request);
    }

    fn start(context: ?*anyopaque, stream: grpc.ServerStream, _: *grpc.ServerContext) !void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.retained = try stream.retain();
    }

    fn message(_: ?*anyopaque, stream: grpc.ServerStream, _: *grpc.ServerContext, bytes: []const u8, _: grpc.Compression) !grpc.StreamReceiveAction {
        try stream.send(bytes, .{});
        return .continue_receiving;
    }

    fn end(_: ?*anyopaque, stream: grpc.ServerStream, _: *grpc.ServerContext) !void {
        try stream.finish(.ok);
    }
};

const Capture = struct {
    io: std.Io,
    done: std.Io.Event = .unset,
    completions: usize = 0,
    messages: usize = 0,
    valid: bool = true,

    fn unary(context: ?*anyopaque, result: grpc.AsyncCallResult) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        // Borrowed bytes are inspected only inside the callback.
        self.valid = result.status.isOk() and std.mem.eql(u8, result.payload, wire);
        self.completions += 1;
        self.done.set(self.io);
    }

    fn message(context: ?*anyopaque, _: grpc.ClientStream, bytes: []const u8, _: grpc.Compression) grpc.StreamReceiveAction {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.valid = self.valid and std.mem.eql(u8, bytes, wire);
        self.messages += 1;
        return .continue_receiving;
    }

    fn terminal(context: ?*anyopaque, _: grpc.ClientStream, status: grpc.Status, _: *const grpc.Metadata) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.valid = self.valid and status.isOk();
        self.completions += 1;
        self.done.set(self.io);
    }
};

pub fn main(init: std.process.Init) !void {
    _ = grpc.version;
    _ = grpc.Channel;
    _ = grpc.ClientTlsOptions;
    _ = grpc.Server;
    _ = grpc.ServerTlsOptions;
    if (options.tls) {
        if (grpc.Server.init(std.heap.page_allocator, .{
            .tls = .{
                .certificate_chain_pem = "invalid",
                .private_key_pem = "invalid",
            },
        })) |server_value| {
            var server = server_value;
            server.deinit();
            return error.InvalidCertificateAccepted;
        } else |err| {
            if (err != error.InvalidCertificate) return err;
        }
    }

    var backing: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer if (backing.deinit() == .leak) @panic("consumer leaked storage");
    const allocator = backing.allocator();
    var handler: Handler = .{};
    var async_capture: Capture = .{ .io = init.io };
    var stream_capture: Capture = .{ .io = init.io };
    var server = try grpc.Server.init(allocator, .{ .port = 0 });
    defer server.deinit();
    defer {
        server.shutdown();
        server.wait();
        if (handler.retained) |*call| call.deinit();
    }
    try server.registerUnary(unary_method, grpc.UnaryHandler.bind(Handler, &handler, Handler.unary));
    try server.registerStream(stream_method, .{
        .context = &handler,
        .on_start = Handler.start,
        .on_message = Handler.message,
        .on_remote_end = Handler.end,
    });
    try server.start();
    var target_buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buffer, "127.0.0.1:{d}", .{try server.port()});
    var channel = try grpc.Channel.init(allocator, target, .{ .stream_admission = .{ .max_streams = 1 } });
    var channel_owned = true;
    defer if (channel_owned) channel.deinit();

    var result = try channel.callUnary(allocator, unary_method, wire, .{ .timeout_ns = std.time.ns_per_s * 5 });
    defer result.deinit();
    try std.testing.expect(result.status.isOk());
    try std.testing.expectEqualStrings(wire, result.payload);
    try std.testing.expectEqualStrings("owned", result.initial_metadata.getFirst("x-consumer").?);
    var missing = try channel.callUnary(allocator, "/consumer.Echo/Missing", wire, .{ .timeout_ns = std.time.ns_per_s * 5 });
    defer missing.deinit();
    try std.testing.expectEqual(grpc.StatusCode.unimplemented, missing.status.code);

    const unary_callbacks: grpc.UnaryCallCallbacks = .{ .context = &async_capture, .on_complete = Capture.unary };
    try std.testing.expectError(error.InvalidMethodPath, channel.callUnaryAsync("invalid", wire, .{}, unary_callbacks));
    try channel.callUnaryAsync(unary_method, wire, .{ .timeout_ns = std.time.ns_per_s * 5 }, unary_callbacks);
    async_capture.done.waitUncancelable(init.io);

    const callbacks: grpc.ClientStreamCallbacks = .{
        .context = &stream_capture,
        .on_message = Capture.message,
        .on_terminal = Capture.terminal,
    };
    var stream = try channel.openStream(stream_method, .{ .timeout_ns = std.time.ns_per_s * 5 }, callbacks);
    var stream_owned = true;
    defer if (stream_owned) stream.deinit();
    // A rejected open must not invoke callbacks or consume another reservation.
    try std.testing.expectError(error.StreamAdmissionRejected, channel.openStream(stream_method, .{}, callbacks));
    var request = wire.*;
    try stream.send(&request, .{});
    @memset(&request, 0); // send owns its copy after return.
    try stream.closeSend();
    stream_capture.done.waitUncancelable(init.io);
    channel.shutdown();
    channel.wait();
    server.shutdown();
    server.wait();

    try std.testing.expect(async_capture.valid and async_capture.completions == 1);
    try std.testing.expect(stream_capture.valid and stream_capture.completions == 1 and stream_capture.messages == 1);
    try std.testing.expect(handler.retained.?.isTerminal());
    try std.testing.expectError(error.CallClosed, handler.retained.?.send(wire, .{}));
    var clone = handler.retained.?.clone();
    clone.deinit();
    try std.testing.expectEqual(@as(usize, 1), channel.streamAdmissionStats().retained_streams);
    stream.deinit();
    stream_owned = false;
    try std.testing.expectEqual(@as(usize, 0), channel.streamAdmissionStats().retained_streams);
    channel.deinit();
    channel_owned = false;
    // Blocking unary results are independent of transport lifetime.
    try std.testing.expectEqualStrings(wire, result.payload);
    try std.testing.expectEqualStrings("owned", result.initial_metadata.getFirst("x-consumer").?);
    std.debug.print("PASS public Zig consumer: unary, async, streaming, ownership, rejection\n", .{});
}
