//! Task-friendly RPC adapters. The supplied std.Io controls waiting and cancellation.
const std = @import("std");
const grpc = @import("grpc_lite");
const streaming = @import("async_stream.zig");

pub const Stream = streaming.Stream;
pub const StreamMessage = streaming.Message;
pub const StreamResult = streaming.Result;
const server = @import("async_server.zig");
pub const Server = server.Server;
pub const ServerOptions = server.Options;
pub const ServerCall = server.Call;
pub const ServerHandler = server.Handler;
pub const UnaryHandler = server.UnaryHandler;

/// Owning client. Join unary caller tasks before deinit. Streams have independent
/// ownership. The I/O runtime and allocators must outlive their clients/streams.
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

    pub fn openStream(self: *Client, allocator: std.mem.Allocator, method: []const u8, options: grpc.StreamOptions) !Stream {
        return Stream.open(allocator, self.io, &self.channel, method, options);
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
