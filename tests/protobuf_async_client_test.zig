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

const TaskService = struct {
    const Call = async_pb.ServerCall(demo.EchoRequest, demo.EchoReply);

    fn unary(_: *TaskService, allocator: std.mem.Allocator, io: std.Io, ctx: *grpc.ServerContext, request: demo.EchoRequest) !demo.EchoReply {
        try io.sleep(.fromMilliseconds(1), .awake);
        if (std.mem.eql(u8, request.message, "reject")) return error.Rejected;
        try ctx.addTrailingMetadata("x-task", "typed");
        return .{ .message = try std.mem.concat(allocator, u8, &.{ "task:", request.message }) };
    }

    fn map(err: anyerror) grpc.Status {
        return .init(if (err == error.Rejected) .invalid_argument else .internal, "typed handler rejected");
    }

    fn serverStream(_: *TaskService, call: *Call) !void {
        var request = (try call.receive(std.testing.allocator)).?;
        defer request.deinit();
        try std.testing.expect(try call.receive(std.testing.allocator) == null);
        for (0..3) |_| {
            try call.io().sleep(.fromMilliseconds(1), .awake);
            try call.send(std.testing.allocator, .{ .message = request.value.message }, .{});
        }
        try call.finish(.ok, &.{});
    }

    fn clientStream(_: *TaskService, call: *Call) !void {
        var count: usize = 0;
        while (try call.receive(std.testing.allocator)) |value| {
            var request = value;
            request.deinit();
            count += 1;
        }
        try std.testing.expectEqual(@as(usize, 3), count);
        try call.send(std.testing.allocator, .{ .message = "three" }, .{});
        try call.finish(.ok, &.{});
    }

    fn chat(_: *TaskService, call: *Call) !void {
        try call.sendInitialMetadata(&.{.{ .key = "x-task", .value = "typed" }}, .gzip);
        while (try call.receive(std.testing.allocator)) |value| {
            var request = value;
            defer request.deinit();
            try call.io().sleep(.fromMilliseconds(1), .awake);
            try call.send(std.testing.allocator, .{ .message = request.value.message }, .{ .compression = .gzip });
        }
        try call.finish(.ok, &.{});
    }
};

test "typed task server handles unary and all streaming cardinalities" {
    const allocator = std.testing.allocator;
    const runtime = try zio.Runtime.init(allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();
    var handler: TaskService = .{};
    var server = try rpc.Server.init(allocator, runtime.io(), .{});
    defer server.deinit();
    var unary_service = async_pb.ServiceServer(Service).init(&server);
    try unary_service.registerUnary("Echo", &handler, TaskService.unary, .{ .map_error = TaskService.map });
    var stream_service = async_pb.ServiceServer(StreamingService).init(&server);
    try stream_service.registerStream("ServerEcho", &handler, TaskService.serverStream);
    try stream_service.registerStream("ClientEcho", &handler, TaskService.clientStream);
    try stream_service.registerStream("Chat", &handler, TaskService.chat);
    try server.start();
    var buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&buffer, "127.0.0.1:{d}", .{try server.port()});
    var client = try rpc.Client.init(allocator, runtime.io(), target, .{});
    defer client.deinit();
    var unary = async_pb.ServiceClient(Service).init(&client);
    var response = try unary.callUnary(allocator, "Echo", .{ .message = "hello" }, .{});
    defer response.deinit();
    try std.testing.expectEqualStrings("task:hello", response.response.?.message);
    try std.testing.expectEqualStrings("typed", response.raw.trailing_metadata.getFirst("x-task").?);
    var rejected = try unary.callUnary(allocator, "Echo", .{ .message = "reject" }, .{});
    defer rejected.deinit();
    try std.testing.expectEqual(grpc.StatusCode.invalid_argument, rejected.raw.status.code);

    var typed = async_pb.ServiceClient(StreamingService).init(&client);
    inline for (.{ "ServerEcho", "ClientEcho", "Chat" }) |method| {
        var stream = try typed.openStream(allocator, method, .{});
        defer stream.deinit();
        const count: usize = if (comptime std.mem.eql(u8, method, "ServerEcho")) 1 else 3;
        for (0..count) |_| try stream.send(allocator, .{ .message = "hello" }, .{});
        try stream.closeSend();
        var received: usize = 0;
        while (try stream.receive(allocator)) |value| {
            var message = value;
            defer message.deinit();
            try std.testing.expectEqualStrings(if (comptime std.mem.eql(u8, method, "ClientEcho")) "three" else "hello", message.value.message);
            received += 1;
        }
        try std.testing.expectEqual(@as(usize, if (comptime std.mem.eql(u8, method, "ClientEcho")) 1 else 3), received);
        var result = try stream.finish(allocator);
        defer result.deinit();
        try std.testing.expect(result.status.isOk());
    }
    inline for (.{ pb.methodPath(Service, "Echo"), pb.methodPath(StreamingService, "Chat") }) |path| {
        var malformed = try client.callUnary(allocator, path, "\x0a\x05x", .{});
        defer malformed.deinit();
        try std.testing.expectEqual(grpc.StatusCode.invalid_argument, malformed.status.code);
    }
}
