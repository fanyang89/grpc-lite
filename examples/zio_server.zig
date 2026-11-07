//! Task-based server and client sharing one zio executor.
const std = @import("std");
const zio = @import("zio");
const grpc = @import("grpc_lite");
const rpc = @import("grpc_lite_async");

pub const std_options_debug_io = zio.debug_io;
const method = "/example.Echo/Chat";

fn echo(_: ?*anyopaque, call: *rpc.ServerCall) !void {
    // This handler is a runtime task, so ordinary Io operations may suspend.
    while (try call.receive(std.heap.page_allocator)) |value| {
        var request = value;
        defer request.deinit();
        try call.io().sleep(.fromMilliseconds(10), .awake);
        try call.send(request.payload, .{});
    }
    try call.finish(.ok, &.{});
}

pub fn main(init: std.process.Init) !void {
    const runtime = try zio.Runtime.init(init.gpa, .{ .executors = .exact(1) });
    defer runtime.deinit();
    const io = runtime.io();
    var server = try rpc.Server.init(init.gpa, io, .{ .max_calls = 128 });
    defer server.deinit();
    try server.registerStream(method, .{ .invoke_fn = echo });
    try server.start();

    var buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&buffer, "127.0.0.1:{d}", .{try server.port()});
    var client = try rpc.Client.init(init.gpa, io, target, .{});
    defer client.deinit();
    var stream = try client.openStream(init.gpa, method, .{ .timeout_ns = 5 * std.time.ns_per_s });
    defer stream.deinit();
    // A protobuf string field; typed handlers can use ServiceServer instead.
    try stream.send("\x0a\x05hello", .{});
    try stream.closeSend();
    while (try stream.receive(init.gpa)) |value| {
        var response = value;
        defer response.deinit();
        std.log.info("task server echoed {d} protobuf bytes", .{response.payload.len});
    }
    var result = try stream.finish(init.gpa);
    defer result.deinit();
    if (!result.status.isOk()) return error.RpcFailed;
    server.shutdownGracefully(std.time.ns_per_s);
    server.wait();
    std.log.info("all server handlers joined", .{});
}
