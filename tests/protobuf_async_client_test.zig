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
const StreamingService = demo.StreamingEchoService(State, error{ OutOfMemory, Rejected });

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

const StreamingEcho = struct {
    fn start(_: ?*anyopaque, _: grpc.ServerStream, _: *grpc.ServerContext) !void {}

    fn message(_: ?*anyopaque, stream: grpc.ServerStream, _: *grpc.ServerContext, request: []const u8, _: grpc.Compression) !grpc.StreamReceiveAction {
        try stream.send(request, .{});
        return .continue_receiving;
    }

    fn end(_: ?*anyopaque, stream: grpc.ServerStream, _: *grpc.ServerContext) !void {
        try stream.finish(.ok);
    }

    fn malformed(_: ?*anyopaque, stream: grpc.ServerStream, _: *grpc.ServerContext, _: []const u8, _: grpc.Compression) !grpc.StreamReceiveAction {
        // A length-delimited string claiming five bytes but containing only one.
        try stream.send("\x0a\x05x", .{});
        return .continue_receiving;
    }
};

test "typed streaming methods infer message types and return independent owned values" {
    const runtime = try zio.Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();
    var server = try grpc.Server.init(std.testing.allocator, .{});
    defer server.deinit();
    inline for (.{ "ServerEcho", "ClientEcho", "Chat" }) |method| {
        try server.registerStream(pb.methodPath(StreamingService, method), .{
            .on_start = StreamingEcho.start,
            .on_message = StreamingEcho.message,
            .on_remote_end = StreamingEcho.end,
        });
    }
    try server.start();
    var buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&buffer, "127.0.0.1:{d}", .{try server.port()});
    var client = try rpc.Client.init(std.testing.allocator, runtime.io(), target, .{});
    defer client.deinit();
    var typed = async_pb.ServiceClient(StreamingService).init(&client);
    inline for (.{ "ServerEcho", "ClientEcho", "Chat" }) |method| {
        var stream = try typed.openStream(std.testing.allocator, method, .{});
        var owned = true;
        defer if (owned) stream.deinit();
        try stream.send(std.testing.allocator, .{ .message = method }, .{});
        try stream.closeSend();
        var response = (try stream.receive(std.testing.allocator)).?;
        defer response.deinit();
        try std.testing.expect(try stream.receive(std.testing.allocator) == null);
        var result = try stream.finish(std.testing.allocator);
        defer result.deinit();
        stream.deinit();
        owned = false;
        try std.testing.expect(result.status.isOk());
        try std.testing.expectEqualStrings(method, response.value.message);
    }
    const Check = struct {
        fn run(allocator: std.mem.Allocator, c: *async_pb.ServiceClient(StreamingService)) !void {
            var stream = try c.openStream(std.testing.allocator, "Chat", .{});
            defer stream.deinit();
            try stream.send(allocator, .{ .message = "allocation failures" }, .{});
            try stream.closeSend();
            var message = (try stream.receive(allocator)).?;
            defer message.deinit();
            try std.testing.expect(try stream.receive(allocator) == null);
            var result = try stream.finish(allocator);
            defer result.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{&typed});
}

test "typed streaming decode failures cancel the stream without leaking response storage" {
    const runtime = try zio.Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();
    var server = try grpc.Server.init(std.testing.allocator, .{});
    defer server.deinit();
    try server.registerStream(pb.methodPath(StreamingService, "Chat"), .{
        .on_start = StreamingEcho.start,
        .on_message = StreamingEcho.malformed,
        .on_remote_end = StreamingEcho.end,
    });
    try server.start();
    var buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&buffer, "127.0.0.1:{d}", .{try server.port()});
    var client = try rpc.Client.init(std.testing.allocator, runtime.io(), target, .{});
    defer client.deinit();
    var typed = async_pb.ServiceClient(StreamingService).init(&client);
    var stream = try typed.openStream(std.testing.allocator, "Chat", .{});
    defer stream.deinit();
    try stream.send(std.testing.allocator, .{ .message = "request" }, .{});
    try std.testing.expectError(error.EndOfStream, stream.receive(std.testing.allocator));
    var result = try stream.finish(std.testing.allocator);
    defer result.deinit();
    try std.testing.expectEqual(grpc.StatusCode.cancelled, result.status.code);
}
