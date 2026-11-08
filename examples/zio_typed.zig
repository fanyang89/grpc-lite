//! Typed unary and all streaming cardinalities on one zio executor.
const std = @import("std");
const grpc = @import("grpc_lite");
const rpc = @import("grpc_lite_async");
const pb = @import("grpc_lite_protobuf_async");
const demo = @import("demo_proto");
const zio = @import("zio");

const EchoApi = demo.EchoService(void, anyerror);
const StreamingApi = demo.StreamingEchoService(void, anyerror);
const ServerCall = pb.ServerCall(demo.EchoRequest, demo.EchoReply);
const ClientStream = pb.ClientStream(demo.EchoRequest, demo.EchoReply);
const messages = [_][]const u8{ "first", "second", "third" };
const timeout_ns = 5 * std.time.ns_per_s;
const limits: grpc.StreamBufferLimits = .{
    .max_message_size = 1024,
    .max_inbound_buffer_size = 4096,
    .max_outbound_buffer_size = 1029,
};

const Service = struct {
    allocator: std.mem.Allocator,

    fn echo(_: *Service, arena: std.mem.Allocator, io: std.Io, context: *grpc.ServerContext, request: demo.EchoRequest) !demo.EchoReply {
        if (request.message.len == 0) return error.EmptyMessage;
        try io.sleep(.fromMilliseconds(1), .awake);
        try context.addTrailingMetadata("x-handler", "typed-task");
        // Unary request/response fields use the handler's call-scoped arena.
        return .{ .message = try std.fmt.allocPrint(arena, "echo: {s}", .{request.message}) };
    }

    fn mapError(err: anyerror) grpc.Status {
        return if (err == error.EmptyMessage)
            .init(.invalid_argument, "message is empty")
        else
            .init(.internal, "echo failed");
    }

    fn serverEcho(self: *Service, call: *ServerCall) !void {
        var request = (try call.receive(self.allocator)) orelse {
            try call.finish(.init(.invalid_argument, "expected one request"), &.{});
            return;
        };
        defer request.deinit();
        if (try call.receive(self.allocator)) |value| {
            var extra = value;
            extra.deinit();
            try call.finish(.init(.invalid_argument, "expected one request"), &.{});
            return;
        }
        for (0..3) |index| {
            try call.io().sleep(.fromMilliseconds(1), .awake);
            const reply = try std.fmt.allocPrint(self.allocator, "{d}: {s}", .{ index + 1, request.value.message });
            defer self.allocator.free(reply);
            try call.send(self.allocator, .{ .message = reply }, .{});
        }
        try call.finish(.ok, &.{});
    }

    fn clientEcho(self: *Service, call: *ServerCall) !void {
        var count: usize = 0;
        while (try call.receive(self.allocator)) |value| {
            var request = value;
            defer request.deinit();
            count += 1;
        }
        const reply = try std.fmt.allocPrint(self.allocator, "received {d} messages", .{count});
        defer self.allocator.free(reply);
        try call.send(self.allocator, .{ .message = reply }, .{});
        try call.finish(.ok, &.{});
    }

    fn chat(self: *Service, call: *ServerCall) !void {
        try call.sendInitialMetadata(&.{}, .gzip);
        while (try call.receive(self.allocator)) |value| {
            var request = value;
            defer request.deinit();
            // send encodes before returning, so borrowing this message is safe.
            try call.send(self.allocator, .{ .message = request.value.message }, .{ .compression = .gzip });
        }
        try call.finish(.ok, &.{});
    }
};

fn unary(client: *rpc.Client, allocator: std.mem.Allocator) !void {
    var typed = pb.ServiceClient(EchoApi).init(client);
    var result = try typed.callUnary(allocator, "Echo", .{ .message = "hello" }, .{ .timeout_ns = timeout_ns });
    defer result.deinit();
    try requireOk(result.raw.status);
    if (!std.mem.eql(u8, result.response.?.message, "echo: hello")) return error.UnexpectedResponse;
    std.log.info("unary: {s}", .{result.response.?.message});

    var rejected = try typed.callUnary(allocator, "Echo", .{ .message = "" }, .{ .timeout_ns = timeout_ns });
    defer rejected.deinit();
    if (rejected.raw.status.code != .invalid_argument or rejected.response != null) return error.UnexpectedStatus;
    std.log.info("unary rejection: {s}", .{rejected.raw.status.message});
}

fn serverStreaming(client: *rpc.Client, allocator: std.mem.Allocator) !void {
    var typed = pb.ServiceClient(StreamingApi).init(client);
    var stream = try typed.openStream(allocator, "ServerEcho", .{ .timeout_ns = timeout_ns, .limits = limits });
    defer stream.deinit();
    try stream.send(allocator, .{ .message = "hello" }, .{});
    try stream.closeSend();
    var count: usize = 0;
    while (try stream.receive(allocator)) |value| {
        var response = value;
        defer response.deinit();
        count += 1;
        var buffer: [32]u8 = undefined;
        const expected = try std.fmt.bufPrint(&buffer, "{d}: hello", .{count});
        if (!std.mem.eql(u8, response.value.message, expected)) return error.UnexpectedResponse;
        std.log.info("server stream: {s}", .{response.value.message});
    }
    try finish(&stream, allocator);
    if (count != 3) return error.UnexpectedResponseCount;
}

fn clientStreaming(client: *rpc.Client, allocator: std.mem.Allocator) !void {
    var typed = pb.ServiceClient(StreamingApi).init(client);
    var stream = try typed.openStream(allocator, "ClientEcho", .{ .timeout_ns = timeout_ns, .limits = limits });
    defer stream.deinit();
    try writeMessages(&stream, allocator);
    var count: usize = 0;
    while (try stream.receive(allocator)) |value| {
        var response = value;
        defer response.deinit();
        count += 1;
        if (!std.mem.eql(u8, response.value.message, "received 3 messages")) return error.UnexpectedResponse;
        std.log.info("client stream: {s}", .{response.value.message});
    }
    try finish(&stream, allocator);
    if (count != 1) return error.UnexpectedResponseCount;
}

fn writeMessages(stream: *ClientStream, allocator: std.mem.Allocator) !void {
    for (messages) |message| try stream.send(allocator, .{ .message = message }, .{});
    try stream.closeSend();
}

fn readMessages(stream: *ClientStream, allocator: std.mem.Allocator) !void {
    var count: usize = 0;
    while (try stream.receive(allocator)) |value| {
        var response = value;
        defer response.deinit();
        if (count >= messages.len or !std.mem.eql(u8, response.value.message, messages[count])) return error.UnexpectedResponse;
        if (response.compression != .gzip) return error.UnexpectedCompression;
        std.log.info("duplex: {s}", .{response.value.message});
        count += 1;
    }
    if (count != messages.len) return error.UnexpectedResponseCount;
}

fn duplex(client: *rpc.Client, allocator: std.mem.Allocator) !void {
    var typed = pb.ServiceClient(StreamingApi).init(client);
    var stream = try typed.openStream(allocator, "Chat", .{ .timeout_ns = timeout_ns, .limits = limits });
    defer stream.deinit();
    const io = client.io;
    // Join both children, including on error, before releasing the stream.
    var writer = try io.concurrent(writeMessages, .{ &stream, allocator });
    defer writer.cancel(io) catch {};
    var reader = try io.concurrent(readMessages, .{ &stream, allocator });
    defer reader.cancel(io) catch {};
    try writer.await(io);
    try reader.await(io);
    try finish(&stream, allocator);
}

fn finish(stream: *ClientStream, allocator: std.mem.Allocator) !void {
    var result = try stream.finish(allocator);
    defer result.deinit();
    try requireOk(result.status);
}

fn requireOk(status: grpc.Status) !void {
    if (status.isOk()) return;
    std.log.err("RPC failed: {s}: {s}", .{ @tagName(status.code), status.message });
    return error.RpcFailed;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const runtime = try zio.Runtime.init(allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();
    const io = runtime.io();
    var service: Service = .{ .allocator = allocator };
    var server = try rpc.Server.init(allocator, io, .{
        .transport = .{ .initial_stream_window_size = 1024, .stream_limits = limits },
        .max_calls = 16,
    });
    defer server.deinit();
    var unary_service = pb.ServiceServer(EchoApi).init(&server);
    try unary_service.registerUnary("Echo", &service, Service.echo, .{ .map_error = Service.mapError });
    var stream_service = pb.ServiceServer(StreamingApi).init(&server);
    try stream_service.registerStream("ServerEcho", &service, Service.serverEcho);
    try stream_service.registerStream("ClientEcho", &service, Service.clientEcho);
    try stream_service.registerStream("Chat", &service, Service.chat);
    try server.start();

    var address: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&address, "127.0.0.1:{d}", .{try server.port()});
    var client = try rpc.Client.init(allocator, io, target, .{ .initial_stream_window_size = 1024 });
    defer client.deinit();
    try unary(&client, allocator);
    try serverStreaming(&client, allocator);
    try clientStreaming(&client, allocator);
    try duplex(&client, allocator);
    server.shutdownGracefully(timeout_ns);
    server.wait();
    std.log.info("typed RPCs complete; all handler tasks joined", .{});
}
