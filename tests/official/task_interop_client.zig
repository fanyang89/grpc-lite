//! Sequential task clients against the official grpc-go interop service.
const std = @import("std");
const grpc = @import("grpc_lite");
const rpc = @import("grpc_lite_async");
const pb = @import("grpc_lite_protobuf_async");
const testing = @import("grpc_testing");
const zio = @import("zio");
const peer = @import("interop_client.zig");

const TypedClient = pb.ServiceClient(testing.TestService(void, anyerror));
const OutputStream = pb.ClientStream(testing.StreamingOutputCallRequest, testing.StreamingOutputCallResponse);
const timeout_ns = 10 * std.time.ns_per_s;
const request_sizes = [_]usize{ 27182, 8, 1828, 45904 };
const response_sizes = [_]usize{ 31415, 9, 2653, 58979 };
const special_message = "\t\ntest with whitespace\r\nand Unicode BMP ☺ and non-BMP 😈\t\n";
const metadata = [_]grpc.MetadataEntry{
    .{ .key = "x-grpc-test-echo-initial", .value = "test_initial_metadata_value" },
    .{ .key = "x-grpc-test-echo-trailing-bin", .value = "\xab\xab\xab" },
};

const Cases = struct {
    allocator: std.mem.Allocator,
    client: *rpc.Client,

    fn typed(self: Cases) TypedClient {
        return TypedClient.init(self.client);
    }

    fn empty(self: Cases) !void {
        var result = try self.client.callUnary(self.allocator, "/grpc.testing.TestService/EmptyCall", "", .{ .timeout_ns = timeout_ns });
        defer result.deinit();
        try expectStatus(result.status, .ok, "");
        if (result.payload.len != 0) return error.UnexpectedPayload;
    }

    fn unary(self: Cases, deadline_ns: u64, compression: enum { identity, request, response }) !void {
        const body = try self.allocator.alloc(u8, 271828);
        defer self.allocator.free(body);
        @memset(body, 0);
        const request: testing.SimpleRequest = .{
            .response_size = 314159,
            .payload = .{ .body = body },
            .expect_compressed = if (compression == .request) .{ .value = true } else null,
            .response_compressed = if (compression == .response) .{ .value = true } else null,
        };
        var service = self.typed();
        if (compression == .request) {
            var rejected = try service.callUnary(self.allocator, "UnaryCall", request, .{ .timeout_ns = deadline_ns });
            defer rejected.deinit();
            if (rejected.raw.status.code != .invalid_argument) return error.UnexpectedRpcStatus;
        }
        var result = try service.callUnary(self.allocator, "UnaryCall", request, .{
            .timeout_ns = deadline_ns,
            .request_compression = if (compression == .request) .gzip else .identity,
        });
        defer result.deinit();
        try expectStatus(result.raw.status, .ok, "");
        try expectPayload((result.response orelse return error.MissingResponse).payload, 314159);
        if (result.raw.response_compression != (if (compression == .response) grpc.Compression.gzip else .identity)) return error.UnexpectedCompression;
    }

    fn status(self: Cases, message: []const u8, include_stream: bool) !void {
        var service = self.typed();
        const response_status: testing.EchoStatus = .{ .code = 2, .message = message };
        var result = try service.callUnary(self.allocator, "UnaryCall", .{ .response_status = response_status }, .{ .timeout_ns = timeout_ns });
        defer result.deinit();
        try expectStatus(result.raw.status, .unknown, message);
        if (include_stream) {
            var stream = try service.openStream(self.allocator, "FullDuplexCall", .{ .timeout_ns = timeout_ns });
            defer stream.deinit();
            try stream.send(self.allocator, .{ .response_status = response_status }, .{});
            try expectFailedReceive(self.allocator, &stream.raw);
            var terminal = try stream.finish(self.allocator);
            defer terminal.deinit();
            try expectStatus(terminal.status, .unknown, message);
        }
    }

    fn unimplemented(self: Cases, path: []const u8) !void {
        var result = try self.client.callUnary(self.allocator, path, "", .{ .timeout_ns = timeout_ns });
        defer result.deinit();
        if (result.status.code != .unimplemented) return error.UnexpectedRpcStatus;
    }

    fn input(self: Cases) !void {
        var service = self.typed();
        var stream = try service.openStream(self.allocator, "StreamingInputCall", .{ .timeout_ns = timeout_ns });
        defer stream.deinit();
        const body: [45904]u8 = @splat(0);
        for (request_sizes) |size| try stream.send(self.allocator, .{ .payload = .{ .body = body[0..size] } }, .{});
        try stream.closeSend();
        var response = (try stream.receive(self.allocator)) orelse return error.MissingResponse;
        defer response.deinit();
        if (response.value.aggregated_payload_size != 74922) return error.UnexpectedPayloadSize;
        try expectEnd(self.allocator, &stream.raw);
    }

    fn output(self: Cases) !void {
        var service = self.typed();
        var stream = try service.openStream(self.allocator, "StreamingOutputCall", .{ .timeout_ns = timeout_ns });
        defer stream.deinit();
        var parameters: [response_sizes.len]testing.ResponseParameters = undefined;
        for (&parameters, response_sizes) |*parameter, size| parameter.* = .{ .size = @intCast(size) };
        try stream.send(self.allocator, .{ .response_parameters = .fromOwnedSlice(&parameters) }, .{});
        try stream.closeSend();
        for (response_sizes) |size| try receivePayload(self.allocator, &stream, size);
        try expectEnd(self.allocator, &stream.raw);
    }

    fn duplex(self: Cases, comptime method: []const u8, empty_stream: bool) !void {
        var service = self.typed();
        var stream = try service.openStream(self.allocator, method, .{ .timeout_ns = timeout_ns });
        defer stream.deinit();
        if (!empty_stream) {
            for (request_sizes, response_sizes) |request_size, response_size| {
                try sendOutput(self.allocator, &stream, request_size, response_size);
                if (comptime std.mem.eql(u8, method, "FullDuplexCall")) try receivePayload(self.allocator, &stream, response_size);
            }
        }
        try stream.closeSend();
        if (comptime std.mem.eql(u8, method, "HalfDuplexCall")) {
            for (response_sizes) |size| try receivePayload(self.allocator, &stream, size);
        }
        try expectEnd(self.allocator, &stream.raw);
    }

    fn customMetadata(self: Cases) !void {
        var service = self.typed();
        var result = try service.callUnary(self.allocator, "UnaryCall", .{ .response_size = 1 }, .{ .timeout_ns = timeout_ns, .metadata = &metadata });
        defer result.deinit();
        try expectStatus(result.raw.status, .ok, "");
        try expectPayload(result.response.?.payload, 1);
        try expectMetadata(&result.raw.initial_metadata, &result.raw.trailing_metadata);
        var stream = try service.openStream(self.allocator, "FullDuplexCall", .{ .timeout_ns = timeout_ns, .metadata = &metadata });
        defer stream.deinit();
        try sendOutput(self.allocator, &stream, 1, 1);
        try receivePayload(self.allocator, &stream, 1);
        try stream.closeSend();
        try expectEnd(self.allocator, &stream.raw);
        var terminal = try stream.finish(self.allocator);
        defer terminal.deinit();
        try expectMetadata(&terminal.initial_metadata, &terminal.trailing_metadata);
    }

    fn lifecycle(self: Cases, mode: enum { begin, response, deadline }) !void {
        var service = self.typed();
        var stream = try service.openStream(self.allocator, "FullDuplexCall", .{
            .timeout_ns = if (mode == .deadline) 100 * std.time.ns_per_ms else timeout_ns,
        });
        defer stream.deinit();
        if (mode == .response) {
            try sendOutput(self.allocator, &stream, 27182, 31415);
            try receivePayload(self.allocator, &stream, 31415);
        }
        if (mode == .deadline) {
            // No response parameters and no half-close: the peer waits for input.
            try stream.send(self.allocator, .{}, .{});
        } else stream.cancel();
        try expectFailedReceive(self.allocator, &stream.raw);
        var terminal = try stream.finish(self.allocator);
        defer terminal.deinit();
        if (terminal.status.code != (if (mode == .deadline) grpc.StatusCode.deadline_exceeded else .cancelled)) return error.UnexpectedRpcStatus;
        try self.empty();
    }

    fn concurrentDuplex(self: Cases) !void {
        var service = self.typed();
        var stream = try service.openStream(self.allocator, "FullDuplexCall", .{
            .timeout_ns = timeout_ns,
            .limits = .{ .max_message_size = 128 * 1024, .max_inbound_buffer_size = 256 * 1024, .max_outbound_buffer_size = 128 * 1024 + 5 },
        });
        defer stream.deinit();
        const io = self.client.io;
        var writer = try io.concurrent(writeDuplex, .{ self.allocator, &stream });
        defer writer.cancel(io) catch {};
        var reader = try io.concurrent(readDuplex, .{ self.allocator, &stream });
        defer reader.cancel(io) catch {};
        try self.empty();
        try writer.await(io);
        try reader.await(io);
        var terminal = try stream.finish(self.allocator);
        defer terminal.deinit();
        try expectStatus(terminal.status, .ok, "");
    }

    fn taskCancellation(self: Cases) !void {
        var service = self.typed();
        var stream = try service.openStream(self.allocator, "FullDuplexCall", .{ .timeout_ns = timeout_ns });
        defer stream.deinit();
        // First exchange confirms that the peer has accepted the stream.
        try sendOutput(self.allocator, &stream, 1, 1);
        try receivePayload(self.allocator, &stream, 1);
        const io = self.client.io;
        var started: std.Io.Event = .unset;
        var reader = try io.concurrent(blockedReceive, .{ self.allocator, io, &stream.raw, &started });
        defer reader.cancel(io) catch {};
        try started.wait(io);
        // The blocked reader must not occupy the only executor.
        try self.empty();
        if (reader.cancel(io)) |_| return error.ExpectedTaskCancellation else |err| {
            if (err != error.Canceled) return err;
        }
        var terminal = try stream.finish(self.allocator);
        defer terminal.deinit();
        if (terminal.status.code != .cancelled) return error.UnexpectedRpcStatus;
        try self.empty();
    }
};

fn expectStatus(status: grpc.Status, code: grpc.StatusCode, message: []const u8) !void {
    if (status.code != code or !std.mem.eql(u8, status.message, message)) {
        std.debug.print("unexpected status: {s}: {s}\n", .{ @tagName(status.code), status.message });
        return error.UnexpectedRpcStatus;
    }
}

fn expectPayload(payload: ?testing.Payload, size: usize) !void {
    const value = payload orelse return error.MissingPayload;
    if (value.type != .COMPRESSABLE or value.body.len != size) return error.UnexpectedPayloadSize;
    for (value.body) |byte| if (byte != 0) return error.UnexpectedPayload;
}

fn expectMetadata(initial: *const grpc.Metadata, trailing: *const grpc.Metadata) !void {
    const first = initial.getFirst(metadata[0].key) orelse return error.MissingMetadata;
    const last = trailing.getFirst(metadata[1].key) orelse return error.MissingMetadata;
    if (!std.mem.eql(u8, first, metadata[0].value) or !std.mem.eql(u8, last, metadata[1].value)) return error.UnexpectedMetadata;
}

fn expectEnd(allocator: std.mem.Allocator, stream: *rpc.Stream) !void {
    if (try stream.receive(allocator)) |value| {
        var message = value;
        message.deinit();
        return error.UnexpectedResponse;
    }
    var terminal = try stream.finish(allocator);
    defer terminal.deinit();
    try expectStatus(terminal.status, .ok, "");
}

fn expectFailedReceive(allocator: std.mem.Allocator, stream: *rpc.Stream) !void {
    if (stream.receive(allocator)) |value| {
        if (value) |owned| {
            var message = owned;
            message.deinit();
        }
        return error.ExpectedRpcFailure;
    } else |err| {
        if (err != error.RpcFailed) return err;
    }
}

fn sendOutput(allocator: std.mem.Allocator, stream: *OutputStream, request_size: usize, response_size: usize) !void {
    const body = try allocator.alloc(u8, request_size);
    defer allocator.free(body);
    @memset(body, 0);
    var parameters = [_]testing.ResponseParameters{.{ .size = @intCast(response_size) }};
    try stream.send(allocator, .{
        .payload = .{ .body = body },
        .response_parameters = .fromOwnedSlice(&parameters),
    }, .{});
}

fn receivePayload(allocator: std.mem.Allocator, stream: *OutputStream, size: usize) !void {
    var response = (try stream.receive(allocator)) orelse return error.MissingResponse;
    defer response.deinit();
    try expectPayload(response.value.payload, size);
}

fn writeDuplex(allocator: std.mem.Allocator, stream: *OutputStream) anyerror!void {
    for (0..64) |index| try sendOutput(allocator, stream, 96 * 1024, 96 * 1024 + index);
    try stream.closeSend();
}

fn readDuplex(allocator: std.mem.Allocator, stream: *OutputStream) anyerror!void {
    for (0..64) |index| try receivePayload(allocator, stream, 96 * 1024 + index);
    try expectEnd(allocator, &stream.raw);
}

fn blockedReceive(allocator: std.mem.Allocator, io: std.Io, stream: *rpc.Stream, started: *std.Io.Event) anyerror!void {
    started.set(io);
    if (try stream.receive(allocator)) |value| {
        var message = value;
        message.deinit();
    }
    return error.ExpectedTaskCancellation;
}

fn run(allocator: std.mem.Allocator, io: std.Io, target: []const u8, config: peer.Config, options: grpc.ChannelOptions) !void {
    const name = config.test_case;
    const channel_soak = std.mem.eql(u8, name, "channel_soak");
    if (channel_soak or std.mem.eql(u8, name, "rpc_soak")) {
        const deadline = peer.soakDeadline(io, config.soak_overall_timeout_seconds);
        var failures: usize = 0;
        if (channel_soak) {
            for (0..config.soak_iterations) |iteration| {
                try peer.checkSoakDeadline(io, deadline);
                soakIteration(allocator, io, target, options, deadline) catch |err| {
                    try peer.handleSoakFailure(&failures, config.soak_max_failures, iteration, err);
                };
                try peer.checkSoakDeadline(io, deadline);
            }
        } else {
            var client = try rpc.Client.init(allocator, io, target, options);
            defer client.deinit();
            const cases: Cases = .{ .allocator = allocator, .client = &client };
            for (0..config.soak_iterations) |iteration| {
                const remaining = try peer.soakRpcTimeout(io, deadline);
                cases.unary(remaining, .identity) catch |err| {
                    try peer.handleSoakFailure(&failures, config.soak_max_failures, iteration, err);
                };
                try peer.checkSoakDeadline(io, deadline);
            }
        }
        return;
    }
    var client = try rpc.Client.init(allocator, io, target, options);
    defer client.deinit();
    const cases: Cases = .{ .allocator = allocator, .client = &client };
    if (std.mem.eql(u8, name, "empty_unary")) return cases.empty();
    if (std.mem.eql(u8, name, "large_unary")) return cases.unary(timeout_ns, .identity);
    if (std.mem.eql(u8, name, "client_compressed_unary")) return cases.unary(timeout_ns, .request);
    if (std.mem.eql(u8, name, "server_compressed_unary")) return cases.unary(timeout_ns, .response);
    if (std.mem.eql(u8, name, "special_status_message")) return cases.status(special_message, false);
    if (std.mem.eql(u8, name, "status_code_and_message")) return cases.status("test status message", true);
    if (std.mem.eql(u8, name, "unimplemented_method")) return cases.unimplemented("/grpc.testing.TestService/UnimplementedCall");
    if (std.mem.eql(u8, name, "unimplemented_service")) return cases.unimplemented("/grpc.testing.UnimplementedService/UnimplementedCall");
    if (std.mem.eql(u8, name, "client_streaming")) return cases.input();
    if (std.mem.eql(u8, name, "server_streaming")) return cases.output();
    if (std.mem.eql(u8, name, "ping_pong")) return cases.duplex("FullDuplexCall", false);
    if (std.mem.eql(u8, name, "empty_stream")) return cases.duplex("FullDuplexCall", true);
    if (std.mem.eql(u8, name, "half_duplex")) return cases.duplex("HalfDuplexCall", false);
    if (std.mem.eql(u8, name, "custom_metadata")) return cases.customMetadata();
    if (std.mem.eql(u8, name, "cancel_after_begin")) return cases.lifecycle(.begin);
    if (std.mem.eql(u8, name, "cancel_after_first_response")) return cases.lifecycle(.response);
    if (std.mem.eql(u8, name, "timeout_on_sleeping_server")) return cases.lifecycle(.deadline);
    if (std.mem.eql(u8, name, "concurrent_duplex")) return cases.concurrentDuplex();
    if (std.mem.eql(u8, name, "task_cancellation")) return cases.taskCancellation();
    return error.UnsupportedTestCase;
}

fn soakIteration(allocator: std.mem.Allocator, io: std.Io, target: []const u8, options: grpc.ChannelOptions, deadline: i96) !void {
    var client = try rpc.Client.init(allocator, io, target, options);
    defer client.deinit();
    const cases: Cases = .{ .allocator = allocator, .client = &client };
    try cases.unary(try peer.soakRpcTimeout(io, deadline), .identity);
}

pub fn main(init: std.process.Init) !void {
    const config = try peer.parseArgs(try init.minimal.args.toSlice(init.arena.allocator()));
    const ca = if (config.use_tls) try std.Io.Dir.cwd().readFileAlloc(init.io, config.ca_file, init.gpa, .limited(4 * 1024 * 1024)) else null;
    defer if (ca) |bytes| init.gpa.free(bytes);
    const cert = if (config.tls_cert_file.len != 0) try std.Io.Dir.cwd().readFileAlloc(init.io, config.tls_cert_file, init.gpa, .limited(4 * 1024 * 1024)) else null;
    defer if (cert) |bytes| init.gpa.free(bytes);
    const key = if (config.tls_key_file.len != 0) try std.Io.Dir.cwd().readFileAlloc(init.io, config.tls_key_file, init.gpa, .limited(4 * 1024 * 1024)) else null;
    defer if (key) |bytes| init.gpa.free(bytes);
    const options: grpc.ChannelOptions = .{
        .initial_stream_window_size = 4096,
        .tls = if (ca) |bytes| .{
            .ca_certificates_pem = bytes,
            .identity = if (cert) |pem| .{ .certificate_chain_pem = pem, .private_key_pem = key.? } else null,
        } else null,
    };
    const target = try std.fmt.allocPrint(init.gpa, "{s}:{d}", .{ config.server_host, config.server_port });
    defer init.gpa.free(target);
    const runtime = try zio.Runtime.init(init.gpa, .{ .executors = .exact(1) });
    defer runtime.deinit();
    const io = runtime.io();
    var task = try io.concurrent(run, .{ init.gpa, io, target, config, options });
    defer task.cancel(io) catch {};
    try task.await(io);
    std.debug.print("task interop case passed: {s}\n", .{config.test_case});
}
