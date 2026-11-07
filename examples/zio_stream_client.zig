//! Self-contained duplex example: one executor, independent reader and writer.
const std = @import("std");
const zio = @import("zio");
const grpc = @import("grpc_lite");
const rpc = @import("grpc_lite_async");

pub const std_options_debug_io = zio.debug_io;
const method = "/example.Echo/Chat";

fn send(stream: *rpc.Stream) !void {
    for ([_][]const u8{ "first", "second", "third" }) |message| {
        // Raw APIs carry protobuf wire bytes. A protobuf string field is enough
        // for this example; generated services can use the typed adapter instead.
        var payload: [32]u8 = undefined;
        payload[0] = 0x0a;
        payload[1] = @intCast(message.len);
        @memcpy(payload[2..][0..message.len], message);
        try stream.send(payload[0 .. 2 + message.len], .{});
    }
    try stream.closeSend();
}

fn receive(stream: *rpc.Stream, allocator: std.mem.Allocator) !void {
    while (try stream.receive(allocator)) |value| {
        var message = value;
        defer message.deinit();
        std.log.info("received {d} protobuf bytes", .{message.payload.len});
    }
}

const Echo = struct {
    fn start(_: ?*anyopaque, _: grpc.ServerStream, _: *grpc.ServerContext) !void {}
    fn message(_: ?*anyopaque, stream: grpc.ServerStream, _: *grpc.ServerContext, payload: []const u8, _: grpc.Compression) !grpc.StreamReceiveAction {
        try stream.send(payload, .{});
        return .continue_receiving;
    }
    fn end(_: ?*anyopaque, stream: grpc.ServerStream, _: *grpc.ServerContext) !void {
        try stream.finish(.ok);
    }
};

pub fn main(init: std.process.Init) !void {
    var server = try grpc.Server.init(init.gpa, .{});
    defer server.deinit();
    try server.registerStream(method, .{ .on_start = Echo.start, .on_message = Echo.message, .on_remote_end = Echo.end });
    try server.start();

    const runtime = try zio.Runtime.init(init.gpa, .{ .executors = .exact(1) });
    defer runtime.deinit();
    const io = runtime.io();
    var buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&buffer, "127.0.0.1:{d}", .{try server.port()});
    var client = try rpc.Client.init(init.gpa, io, target, .{});
    defer client.deinit();
    var stream = try client.openStream(init.gpa, method, .{ .timeout_ns = 5 * std.time.ns_per_s });
    defer stream.deinit();
    var writer = try io.concurrent(send, .{&stream});
    defer writer.cancel(io) catch {};
    var reader = try io.concurrent(receive, .{ &stream, init.gpa });
    defer reader.cancel(io) catch {};
    try writer.await(io);
    try reader.await(io);
    var result = try stream.finish(init.gpa);
    defer result.deinit();
    std.log.info("stream finished: {s}", .{@tagName(result.status.code)});
    if (!result.status.isOk()) return error.RpcFailed;
}
