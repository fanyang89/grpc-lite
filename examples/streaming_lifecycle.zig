//! Raw loopback lifecycle: normal completion or cancellation during graceful drain.
//! Run through tests/run_streaming_lifecycle.sh for an external shutdown watchdog.
const std = @import("std");
const grpc = @import("grpc_lite");

const method = "/example.Lifecycle/Exchange";
// A valid protobuf varint field, without generated code or a protobuf dependency.
const payload = "\x08\x01";
const response_count = 2;
const window_size = 4096;
const limits: grpc.StreamBufferLimits = .{
    .max_message_size = payload.len,
    // Inbound capacity must cover the advertised initial HTTP/2 stream window.
    .max_inbound_buffer_size = window_size,
    .max_outbound_buffer_size = payload.len + 5,
};
const Mode = enum { normal, interrupt };

const Handler = struct {
    io: std.Io,
    call: ?grpc.ServerCall = null,
    responses_queued: std.Io.Event = .unset,
    requests: usize = 0,
    half_closes: usize = 0,
    sent: usize = 0,
    blocked: usize = 0,
    writable: usize = 0,
    terminals: usize = 0,
    reason: ?grpc.ServerTerminalReason = null,
    failed: bool = false,

    fn onStart(context: ?*anyopaque, stream: grpc.ServerStream, _: *grpc.ServerContext) !void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        errdefer self.responses_queued.set(self.io);
        // Only this owning handle may escape the callback, never ServerStream.
        self.call = try stream.retain();
    }

    fn onMessage(context: ?*anyopaque, _: grpc.ServerStream, _: *grpc.ServerContext, bytes: []const u8, compression: grpc.Compression) !grpc.StreamReceiveAction {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (self.requests != 0 or compression != .identity or !std.mem.eql(u8, bytes, payload))
            return error.UnexpectedRequest;
        self.requests += 1;
        return .continue_receiving;
    }

    fn onRemoteEnd(context: ?*anyopaque, stream: grpc.ServerStream, _: *grpc.ServerContext) !void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.half_closes += 1;
        if (self.requests != 1 or self.half_closes != 1) return error.UnexpectedHalfClose;
        try self.sendResponses(stream);
    }

    fn sendResponses(self: *@This(), stream: grpc.ServerStream) !void {
        // At most two attempts per callback. The reactor cannot drain the first
        // frame before this callback returns, so the second MUST hit WouldBlock.
        while (self.sent < response_count) {
            stream.send(payload, .{}) catch |err| {
                if (err != error.WouldBlock) return err;
                self.blocked += 1;
                return; // Keep the unsent index; resume only on readiness.
            };
            self.sent += 1;
        }
        // Publish the retained handle to main, but leave final status pending so
        // graceful drain starts with an active RPC in both modes.
        self.responses_queued.set(self.io);
    }

    fn onWritable(context: ?*anyopaque, stream: grpc.ServerStream, _: *grpc.ServerContext) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.writable += 1;
        self.sendResponses(stream) catch {
            self.failed = true;
            self.call.?.abort();
        };
    }

    fn onTerminal(context: ?*anyopaque, _: grpc.ServerCallId, reason: grpc.ServerTerminalReason) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.terminals += 1;
        self.reason = reason;
        // Also unblock main on failure, without retaining borrowed status data.
        self.responses_queued.set(self.io);
    }
};

const Capture = struct {
    io: std.Io,
    responses_received: std.Io.Event = .unset,
    terminal: std.Io.Event = .unset,
    messages: usize = 0,
    terminals: usize = 0,
    code: grpc.StatusCode = .unknown,
    valid: bool = true,

    fn onMessage(context: ?*anyopaque, _: grpc.ClientStream, bytes: []const u8, compression: grpc.Compression) grpc.StreamReceiveAction {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.valid = self.valid and self.terminals == 0 and
            compression == .identity and std.mem.eql(u8, bytes, payload);
        self.messages += 1;
        if (self.messages >= response_count) self.responses_received.set(self.io);
        return .continue_receiving;
    }

    fn onTerminal(context: ?*anyopaque, _: grpc.ClientStream, status: grpc.Status, _: *const grpc.Metadata) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.terminals += 1;
        self.code = status.code;
        self.terminal.set(self.io);
        self.responses_received.set(self.io);
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.ExpectedNormalOrInterrupt;
    const mode = std.meta.stringToEnum(Mode, args[1]) orelse return error.ExpectedNormalOrInterrupt;

    // These stack contexts and init.io/init.gpa outlive both joined loops, on
    // success AND every error path. Only main waits; callbacks only signal.
    var handler: Handler = .{ .io = init.io };
    var capture: Capture = .{ .io = init.io };
    var server = try grpc.Server.init(init.gpa, .{
        .host = "127.0.0.1",
        .port = 0,
        .reactor_count = 1,
        .max_connections = 1,
        .max_concurrent_streams_per_connection = 1,
        .max_request_size = payload.len,
        .stream_limits = limits,
        .initial_stream_window_size = window_size,
        .write_high_watermark_bytes = 16 * 1024,
        .write_low_watermark_bytes = 8 * 1024,
        .cleartext_preface_timeout_ns = 5 * std.time.ns_per_s,
        .connection_idle_timeout_ns = 10 * std.time.ns_per_s,
    });
    defer server.deinit();
    defer {
        // Error fallback also joins before inspecting/releasing callback state.
        server.shutdown();
        server.wait();
        if (handler.call) |*call| call.deinit();
    }
    try server.registerStream(method, .{
        .context = &handler,
        .on_start = Handler.onStart,
        .on_message = Handler.onMessage,
        .on_remote_end = Handler.onRemoteEnd,
        .on_writable = Handler.onWritable,
        .on_terminal = Handler.onTerminal,
    });
    try server.start();

    var target_buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buffer, "127.0.0.1:{d}", .{try server.port()});
    var channel = try grpc.Channel.init(init.gpa, target, .{
        .initial_stream_window_size = window_size,
        .stream_admission = .{
            .max_streams = 1,
            .max_buffer_bytes = limits.max_inbound_buffer_size + limits.max_outbound_buffer_size,
        },
        .unary_admission = .{ .max_calls = 1, .max_request_bytes = 1024 },
        .max_response_header_list_size = 4096,
        .write_high_watermark_bytes = 16 * 1024,
        .write_low_watermark_bytes = 8 * 1024,
    });
    defer channel.deinit();
    var stream = try channel.openStream(method, .{
        .limits = limits,
        .timeout_ns = 10 * std.time.ns_per_s,
    }, .{
        .context = &capture,
        .on_message = Capture.onMessage,
        .on_terminal = Capture.onTerminal,
    });
    var stream_owned = true;
    defer if (stream_owned) stream.deinit();
    try stream.send(payload, .{});
    try stream.closeSend(); // Ends requests, not the response direction.

    handler.responses_queued.waitUncancelable(init.io);
    capture.responses_received.waitUncancelable(init.io);
    const call = handler.call orelse return error.MissingRetainedCall;
    if (call.isTerminal() or capture.terminal.isSet()) return error.PrematureTermination;
    server.shutdownGracefully(5 * std.time.ns_per_s);
    switch (mode) {
        .normal => try call.finish(.ok, &.{}),
        .interrupt => stream.cancel(),
    }
    capture.terminal.waitUncancelable(init.io);
    // Keep the Channel alive to flush cancellation before joining the draining
    // Server. A forced drain timeout is NOT accepted as a successful cancellation.
    server.wait();
    channel.shutdown();
    channel.wait();

    // Callback-owned counters are read only after the loops have joined.
    const expected_code: grpc.StatusCode = if (mode == .normal) .ok else .cancelled;
    const expected_reason: grpc.ServerTerminalReason = if (mode == .normal) .completed else .peer_cancelled;
    if (handler.failed or handler.requests != 1 or handler.half_closes != 1 or
        handler.sent != response_count or handler.blocked != 1 or handler.writable != 1 or
        handler.terminals != 1 or handler.reason != expected_reason or !call.isTerminal() or
        !capture.valid or capture.messages != response_count or capture.terminals != 1 or
        capture.code != expected_code) return error.UnexpectedLifecycle;

    // Terminal notification alone does not release the retained admission slot.
    const retained = channel.streamAdmissionStats();
    if (retained.retained_streams != 1 or
        retained.reserved_buffer_bytes != limits.max_inbound_buffer_size + limits.max_outbound_buffer_size)
        return error.UnexpectedRetainedAdmission;
    stream.deinit();
    stream_owned = false;
    const released = channel.streamAdmissionStats();
    if (released.retained_streams != 0 or released.reserved_buffer_bytes != 0)
        return error.AdmissionNotReleased;
    handler.call.?.deinit();
    handler.call = null;

    // The smoke contract is emitted only after checking status, readiness, joins,
    // and both handle releases; a configured limit alone cannot produce PASS.
    std.debug.print("PASS streaming-lifecycle mode={s} status={s} backpressure=1 writable=1 half_close=1 messages=2 client_terminal=1 server_terminal=1 released=1 drained=1\n", .{ @tagName(mode), @tagName(expected_code) });
}
