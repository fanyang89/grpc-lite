//! Run against examples/echo_server.zig on 127.0.0.1:50051.
const std = @import("std");
const zio = @import("zio");
const grpc = @import("grpc_lite");
const rpc = @import("grpc_lite_async");

fn echo(client: *rpc.Client, allocator: std.mem.Allocator) !void {
    // demo.EchoRequest { message: "hello" }, encoded as protobuf wire bytes.
    var result = try client.callUnary(allocator, "/demo.EchoService/Echo", "\x0a\x05hello", .{
        .timeout_ns = 2 * std.time.ns_per_s,
    });
    defer result.deinit();
    std.log.info("status={s}, response bytes={d}", .{ @tagName(result.status.code), result.payload.len });
    if (!result.status.isOk()) return error.RpcFailed;
}

pub fn main(init: std.process.Init) !void {
    // DNS initialization must precede creation of runtime/transport threads.
    var transport_runtime = try grpc.Runtime.init();
    defer transport_runtime.deinit();
    const runtime = try zio.Runtime.init(init.gpa, .{ .executors = .exact(1) });
    defer runtime.deinit();
    const io = runtime.io();
    var client = try rpc.Client.init(init.gpa, io, "127.0.0.1:50051", .{ .runtime = &transport_runtime });
    defer client.deinit();

    try echo(&client, init.gpa);

    var first = try io.concurrent(echo, .{ &client, init.gpa });
    defer first.cancel(io) catch {};
    var second = try io.concurrent(echo, .{ &client, init.gpa });
    defer second.cancel(io) catch {};
    try first.await(io);
    try second.await(io);

    var cancelled = try io.concurrent(echo, .{ &client, init.gpa });
    cancelled.cancel(io) catch |err| switch (err) {
        error.Canceled => std.log.info("RPC task cancelled", .{}),
        else => return err,
    };
}
