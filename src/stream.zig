//! Raw event-driven streaming contracts.

const std = @import("std");
const call = @import("call.zig");
const Compression = @import("compression.zig").Compression;
const metadata = @import("metadata.zig");
const service = @import("service.zig");
const status = @import("status.zig");

pub const ReceiveAction = enum {
    continue_receiving,
    pause,
};

pub const BufferLimits = struct {
    max_message_size: usize = call.default_max_message_size,
    max_inbound_buffer_size: usize = 8 * 1024 * 1024,
    max_outbound_buffer_size: usize = 8 * 1024 * 1024,

    pub fn validate(self: BufferLimits) !void {
        if (self.max_message_size == 0) return error.InvalidMaxMessageSize;
        const minimum_wire_size = std.math.add(usize, self.max_message_size, 5) catch
            return error.InvalidMaxMessageSize;
        if (self.max_inbound_buffer_size < minimum_wire_size) return error.InvalidInboundBufferSize;
        if (self.max_outbound_buffer_size < minimum_wire_size) return error.InvalidOutboundBufferSize;
    }
};

pub const Options = struct {
    metadata: []const metadata.Entry = &.{},
    timeout_ns: ?u64 = null,
    limits: BufferLimits = .{},
};

pub const SendOptions = struct {
    compression: Compression = .identity,
};

/// Thread-safe command handle for one client-side stream.
///
/// Copies passed to callbacks are borrowed command views and must not be deinitialized.
/// The application-owned handle must be deinitialized exactly once. Deinitializing an
/// active stream cancels it and suppresses future application callbacks.
pub const ClientStream = struct {
    context: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        send: *const fn (*anyopaque, []const u8, SendOptions) anyerror!void,
        close_send: *const fn (*anyopaque) anyerror!void,
        cancel: *const fn (*anyopaque) void,
        resume_receive: *const fn (*anyopaque) anyerror!void,
        release: *const fn (*anyopaque) void,
    };

    pub fn init(
        context: *anyopaque,
        comptime send_fn: *const fn (*anyopaque, []const u8, SendOptions) anyerror!void,
        comptime close_send_fn: *const fn (*anyopaque) anyerror!void,
        comptime cancel_fn: *const fn (*anyopaque) void,
        comptime resume_receive_fn: *const fn (*anyopaque) anyerror!void,
        comptime release_fn: *const fn (*anyopaque) void,
    ) ClientStream {
        const Functions = struct {
            var value: VTable = .{
                .send = send_fn,
                .close_send = close_send_fn,
                .cancel = cancel_fn,
                .resume_receive = resume_receive_fn,
                .release = release_fn,
            };
        };
        return .{ .context = context, .vtable = &Functions.value };
    }

    /// Copies and queues one raw protobuf message.
    pub fn send(self: ClientStream, payload: []const u8, options: SendOptions) !void {
        return self.vtable.send(self.context, payload, options);
    }

    /// Half-closes only the local send direction after queued messages drain.
    pub fn closeSend(self: ClientStream) !void {
        return self.vtable.close_send(self.context);
    }

    /// Terminates both directions with RST_STREAM(CANCEL).
    pub fn cancel(self: ClientStream) void {
        self.vtable.cancel(self.context);
    }

    /// Resumes inbound delivery after an onMessage callback returned pause.
    pub fn resumeReceive(self: ClientStream) !void {
        return self.vtable.resume_receive(self.context);
    }

    pub fn deinit(self: *ClientStream) void {
        self.vtable.release(self.context);
        self.* = undefined;
    }
};

/// Client callbacks run sequentially on the Channel event-loop thread and must not block.
/// All metadata, payload, status-message, and stream values are borrowed for the callback.
pub const ClientCallbacks = struct {
    context: ?*anyopaque = null,
    on_headers: ?*const fn (?*anyopaque, ClientStream, *const metadata.Metadata) void = null,
    on_message: *const fn (?*anyopaque, ClientStream, []const u8, Compression) ReceiveAction,
    on_remote_end: ?*const fn (?*anyopaque, ClientStream) void = null,
    on_writable: ?*const fn (?*anyopaque, ClientStream) void = null,
    on_terminal: *const fn (
        ?*anyopaque,
        ClientStream,
        status.Status,
        *const metadata.Metadata,
    ) void,
};

/// Borrowed command handle valid only while its server stream is active.
pub const ServerStream = struct {
    context: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        send: *const fn (*anyopaque, []const u8, SendOptions) anyerror!void,
        finish: *const fn (*anyopaque, status.Status) anyerror!void,
        resume_receive: *const fn (*anyopaque) anyerror!void,
    };

    pub fn init(
        context: *anyopaque,
        comptime send_fn: *const fn (*anyopaque, []const u8, SendOptions) anyerror!void,
        comptime finish_fn: *const fn (*anyopaque, status.Status) anyerror!void,
        comptime resume_receive_fn: *const fn (*anyopaque) anyerror!void,
    ) ServerStream {
        const Functions = struct {
            var value: VTable = .{
                .send = send_fn,
                .finish = finish_fn,
                .resume_receive = resume_receive_fn,
            };
        };
        return .{ .context = context, .vtable = &Functions.value };
    }

    /// Copies and queues one raw protobuf response message.
    pub fn send(self: ServerStream, payload: []const u8, options: SendOptions) !void {
        return self.vtable.send(self.context, payload, options);
    }

    /// Ends the response after queued messages drain and submits final status trailers.
    pub fn finish(self: ServerStream, final_status: status.Status) !void {
        return self.vtable.finish(self.context, final_status);
    }

    pub fn resumeReceive(self: ServerStream) !void {
        return self.vtable.resume_receive(self.context);
    }
};

/// Server callbacks run sequentially on the Server event-loop thread and must not block.
/// Returning an error fails the stream with INTERNAL.
pub const ServerHandler = struct {
    context: ?*anyopaque = null,
    on_start: *const fn (?*anyopaque, ServerStream, *service.ServerContext) anyerror!void,
    on_message: *const fn (
        ?*anyopaque,
        ServerStream,
        *service.ServerContext,
        []const u8,
        Compression,
    ) anyerror!ReceiveAction,
    on_remote_end: *const fn (?*anyopaque, ServerStream, *service.ServerContext) anyerror!void,
    on_writable: ?*const fn (?*anyopaque, ServerStream, *service.ServerContext) void = null,
    on_cancel: ?*const fn (?*anyopaque, ServerStream, *service.ServerContext) void = null,
};

test "buffer limits reject impossible bounded queues" {
    try (BufferLimits{}).validate();
    try std.testing.expectError(error.InvalidMaxMessageSize, (BufferLimits{ .max_message_size = 0 }).validate());
    try std.testing.expectError(
        error.InvalidInboundBufferSize,
        (BufferLimits{ .max_message_size = 10, .max_inbound_buffer_size = 14 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidOutboundBufferSize,
        (BufferLimits{ .max_message_size = 10, .max_outbound_buffer_size = 14 }).validate(),
    );
}

test "client command handle dispatches lifecycle operations" {
    const State = struct {
        sends: usize = 0,
        close_sends: usize = 0,
        cancels: usize = 0,
        resumes: usize = 0,
        releases: usize = 0,

        fn send(context: *anyopaque, payload: []const u8, _: SendOptions) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.sends += payload.len;
        }
        fn closeSend(context: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.close_sends += 1;
        }
        fn cancel(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.cancels += 1;
        }
        fn resumeReceive(context: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.resumes += 1;
        }
        fn release(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.releases += 1;
        }
    };

    var state = State{};
    var client = ClientStream.init(&state, State.send, State.closeSend, State.cancel, State.resumeReceive, State.release);
    try client.send("abc", .{});
    try client.closeSend();
    client.cancel();
    try client.resumeReceive();
    client.deinit();
    try std.testing.expectEqual(@as(usize, 3), state.sends);
    try std.testing.expectEqual(@as(usize, 1), state.close_sends);
    try std.testing.expectEqual(@as(usize, 1), state.cancels);
    try std.testing.expectEqual(@as(usize, 1), state.resumes);
    try std.testing.expectEqual(@as(usize, 1), state.releases);
}
