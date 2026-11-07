const std = @import("std");
const grpc = @import("grpc_lite");
const rpc = @import("grpc_lite_async");
const pb = @import("grpc_lite_protobuf");
const async_pb = @import("grpc_lite_protobuf_async");
const demo = @import("demo_proto");
const zio = @import("zio");

const State = struct {
    fn echo(_: *State, request: demo.EchoRequest) error{ OutOfMemory, Rejected }!demo.EchoReply {
        if (std.mem.eql(u8, request.message, "reject")) return error.Rejected;
        return .{ .message = try std.testing.allocator.dupe(u8, request.message) };
    }
};
const Service = demo.EchoService(State, error{ OutOfMemory, Rejected });

fn mapError(err: error{ OutOfMemory, Rejected }) grpc.Status {
    return .init(if (err == error.Rejected) .invalid_argument else .resource_exhausted, "request rejected");
}

test "typed task client owns decoded response and preserves non-OK status" {
    const runtime = try zio.Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();
    var state: State = .{};
    var registration = pb.ServiceRegistration(Service).init(std.testing.allocator, &state, .{ .Echo = State.echo }, .{ .map_error = mapError });
    defer registration.deinit();
    var server = try grpc.Server.init(std.testing.allocator, .{});
    defer server.deinit();
    try registration.register(&server);
    try server.start();
    var buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&buffer, "127.0.0.1:{d}", .{try server.port()});
    var client = try rpc.Client.init(std.testing.allocator, runtime.io(), target, .{});
    defer client.deinit();
    var typed = async_pb.ServiceClient(Service).init(&client);
    var result = try typed.callUnary(std.testing.allocator, "Echo", .{ .message = "hello zio" }, .{});
    defer result.deinit();
    try std.testing.expect(result.raw.status.isOk());
    try std.testing.expectEqualStrings("hello zio", result.response.?.message);
    var rejected = try typed.callUnary(std.testing.allocator, "Echo", .{ .message = "reject" }, .{});
    defer rejected.deinit();
    try std.testing.expectEqual(grpc.StatusCode.invalid_argument, rejected.raw.status.code);
    try std.testing.expect(rejected.response == null);

    const Check = struct {
        fn run(allocator: std.mem.Allocator, c: *async_pb.ServiceClient(Service)) !void {
            var response = try c.callUnary(allocator, "Echo", .{ .message = "allocation failures" }, .{});
            defer response.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{&typed});
}
