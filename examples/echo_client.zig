const std = @import("std");
const grpc = @import("grpc_lite");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const target = if (args.len > 1) args[1] else "127.0.0.1:50051";
    const request = if (args.len > 2) args[2] else "hello grpc-lite";

    var channel = try grpc.Channel.init(init.gpa, target, .{});
    defer channel.deinit();
    var result = try channel.callUnary(
        init.gpa,
        "/demo.EchoService/Echo",
        request,
        .{ .timeout_ns = 5 * std.time.ns_per_s },
    );
    defer result.deinit();

    if (!result.status.isOk()) {
        std.debug.print("RPC failed: {t}: {s}\n", .{ result.status.code, result.status.message });
        return error.RpcFailed;
    }
    std.debug.print("response: {s}\n", .{result.payload});
}
