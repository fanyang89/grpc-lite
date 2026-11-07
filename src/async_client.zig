//! Task-friendly unary client. The supplied std.Io controls waiting and cancellation.
const std = @import("std");
const grpc = @import("grpc_lite");

/// Owning client. Finish or cancel all caller tasks before deinit. The supplied
/// I/O runtime and transport allocator must outlive this client and its calls.
pub const Client = struct {
    channel: grpc.Channel,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, target: []const u8, options: grpc.ChannelOptions) !Client {
        return .{ .channel = try grpc.Channel.initIo(allocator, io, target, options), .io = io };
    }

    pub fn callUnary(
        self: *Client,
        allocator: std.mem.Allocator,
        method: []const u8,
        request: []const u8,
        options: grpc.CallOptions,
    ) !grpc.CallResult {
        return self.channel.callUnaryIo(allocator, self.io, method, request, options);
    }

    /// Stops admission and completes outstanding calls with an unavailable status.
    pub fn shutdown(self: *Client) void {
        self.channel.shutdown();
    }

    /// Uncancelable teardown suspends through the same I/O runtime used by init.
    pub fn deinit(self: *Client) void {
        self.channel.deinit();
        self.* = undefined;
    }
};
