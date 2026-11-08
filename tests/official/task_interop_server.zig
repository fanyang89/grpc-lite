//! Official interop service implemented with sequential task handlers.
const std = @import("std");
const grpc = @import("grpc_lite");
const rpc = @import("grpc_lite_async");
const pb = @import("grpc_lite_protobuf_async");
const testing = @import("grpc_testing");
const zio = @import("zio");
const callback_peer = @import("interop_server.zig");

const OutputCall = pb.ServerCall(testing.StreamingOutputCallRequest, testing.StreamingOutputCallResponse);
const InputCall = pb.ServerCall(testing.StreamingInputCallRequest, testing.StreamingInputCallResponse);

const ResponseSpec = struct {
    size: usize,
    interval_us: i32,
    compression: grpc.Compression,
};

const Service = struct {
    allocator: std.mem.Allocator,
    unary: callback_peer.Service,

    fn empty(self: *Service, allocator: std.mem.Allocator, io: std.Io, context: *grpc.ServerContext, request: []const u8) !grpc.UnaryResponse {
        try io.checkCancel();
        return self.unary.emptyCall(allocator, context, request);
    }

    fn unaryCall(self: *Service, allocator: std.mem.Allocator, io: std.Io, context: *grpc.ServerContext, request: []const u8) !grpc.UnaryResponse {
        try io.checkCancel();
        if (context.request_metadata.getFirst("x-grpc-test-echo-initial")) |value| {
            try context.addInitialMetadata("x-grpc-test-echo-initial", value);
        }
        if (context.request_metadata.getFirst("x-grpc-test-echo-trailing-bin")) |value| {
            try context.addTrailingMetadata("x-grpc-test-echo-trailing-bin", value);
        }
        return self.unary.unaryCall(allocator, context, request);
    }

    fn input(self: *Service, call: *InputCall) !void {
        var total: usize = 0;
        while (try call.receive(self.allocator)) |value| {
            var request = value;
            defer request.deinit();
            if (request.value.expect_compressed) |expected| {
                if (expected.value != (request.compression == .gzip)) {
                    try call.finish(.init(.invalid_argument, "request compression did not match expectation"), &.{});
                    return;
                }
            }
            if (request.value.payload) |payload| {
                if (payload.body.len > std.math.maxInt(i32) - total) {
                    try call.finish(.init(.out_of_range, "aggregated payload size exceeds int32"), &.{});
                    return;
                }
                total += payload.body.len;
            }
        }
        try call.send(self.allocator, .{ .aggregated_payload_size = @intCast(total) }, .{});
        try call.finish(.ok, &.{});
    }

    fn output(self: *Service, call: *OutputCall) !void {
        var request = (try call.receive(self.allocator)) orelse {
            try call.finish(.init(.invalid_argument, "missing StreamingOutputCallRequest"), &.{});
            return;
        };
        defer request.deinit();
        if (try call.receive(self.allocator)) |value| {
            var extra = value;
            extra.deinit();
            try call.finish(.init(.invalid_argument, "multiple StreamingOutputCallRequest messages"), &.{});
            return;
        }
        try call.sendInitialMetadata(&.{}, .gzip);
        if (!try self.respond(call, request.value)) return;
        try call.finish(.ok, &.{});
    }

    fn fullDuplex(self: *Service, call: *OutputCall) !void {
        var initial = grpc.Metadata.init(self.allocator);
        defer initial.deinit();
        var trailing = grpc.Metadata.init(self.allocator);
        defer trailing.deinit();
        const request_metadata = &call.context().request_metadata;
        if (request_metadata.getFirst("x-grpc-test-echo-initial")) |value| {
            try initial.append("x-grpc-test-echo-initial", value);
        }
        if (request_metadata.getFirst("x-grpc-test-echo-trailing-bin")) |value| {
            try trailing.append("x-grpc-test-echo-trailing-bin", value);
        }
        try call.sendInitialMetadata(initial.items(), .gzip);
        while (try call.receive(self.allocator)) |value| {
            var request = value;
            defer request.deinit();
            if (request.value.response_status) |status| {
                if (status.code != 0) {
                    const code = if (status.code >= 0) grpc.StatusCode.fromInt(@intCast(status.code)) else .unknown;
                    try call.finish(.init(code, status.message), trailing.items());
                    return;
                }
            }
            if (!try self.respond(call, request.value)) return;
        }
        try call.finish(.ok, trailing.items());
    }

    fn halfDuplex(self: *Service, call: *OutputCall) !void {
        var responses: std.ArrayList(ResponseSpec) = .empty;
        defer responses.deinit(self.allocator);
        while (try call.receive(self.allocator)) |value| {
            var request = value;
            defer request.deinit();
            if (!try validateRequest(call, request.value)) return;
            // This interop fixture retains response specifications, not payloads,
            // and bounds application storage even before client half-close.
            if (request.value.response_parameters.items.len > 4096 - responses.items.len) {
                try call.finish(.init(.resource_exhausted, "too many response parameters"), &.{});
                return;
            }
            for (request.value.response_parameters.items) |parameter| try responses.append(self.allocator, responseSpec(parameter));
        }
        try call.sendInitialMetadata(&.{}, .gzip);
        for (responses.items) |spec| try self.sendResponse(call, spec);
        try call.finish(.ok, &.{});
    }

    fn respond(self: *Service, call: *OutputCall, request: testing.StreamingOutputCallRequest) !bool {
        if (!try validateRequest(call, request)) return false;
        for (request.response_parameters.items) |parameter| try self.sendResponse(call, responseSpec(parameter));
        return true;
    }

    fn sendResponse(self: *Service, call: *OutputCall, spec: ResponseSpec) !void {
        if (spec.interval_us != 0) try call.io().sleep(.fromMicroseconds(spec.interval_us), .awake);
        const body = try self.allocator.alloc(u8, spec.size);
        defer self.allocator.free(body);
        @memset(body, 0);
        try call.send(self.allocator, .{ .payload = .{ .type = .COMPRESSABLE, .body = body } }, .{ .compression = spec.compression });
    }

    fn validateRequest(call: *OutputCall, request: testing.StreamingOutputCallRequest) !bool {
        if (request.response_type != .COMPRESSABLE) {
            try call.finish(.init(.invalid_argument, "unsupported response payload type"), &.{});
            return false;
        }
        for (request.response_parameters.items) |parameter| {
            if (parameter.size < 0 or parameter.interval_us < 0) {
                try call.finish(.init(.invalid_argument, "negative response size or interval"), &.{});
                return false;
            }
            if (parameter.size > 4 * 1024 * 1024) {
                try call.finish(.init(.resource_exhausted, "response message too large"), &.{});
                return false;
            }
        }
        return true;
    }

    fn responseSpec(parameter: testing.ResponseParameters) ResponseSpec {
        return .{
            .size = @intCast(parameter.size),
            .interval_us = parameter.interval_us,
            .compression = if (parameter.compressed) |compressed| if (compressed.value) .gzip else .identity else .identity,
        };
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const config = try callback_peer.parseArgs(args);
    if (config.streaming_soak) return error.CallbackSoakStatisticsUnavailable;
    const certificate = if (config.use_tls)
        try std.Io.Dir.cwd().readFileAlloc(init.io, config.tls_cert_file, init.gpa, .limited(4 * 1024 * 1024))
    else
        null;
    defer if (certificate) |bytes| init.gpa.free(bytes);
    const private_key = if (config.use_tls)
        try std.Io.Dir.cwd().readFileAlloc(init.io, config.tls_key_file, init.gpa, .limited(4 * 1024 * 1024))
    else
        null;
    defer if (private_key) |bytes| init.gpa.free(bytes);
    const client_ca = if (config.client_ca_file.len != 0)
        try std.Io.Dir.cwd().readFileAlloc(init.io, config.client_ca_file, init.gpa, .limited(4 * 1024 * 1024))
    else
        null;
    defer if (client_ca) |bytes| init.gpa.free(bytes);

    const runtime = try zio.Runtime.init(init.gpa, .{ .executors = .exact(1) });
    defer runtime.deinit();
    var service: Service = .{ .allocator = init.gpa, .unary = .{ .allocator = init.gpa } };
    var server = try rpc.Server.init(init.gpa, runtime.io(), .{ .transport = .{
        .port = config.port,
        .tls = if (certificate) |cert| .{
            .certificate_chain_pem = cert,
            .private_key_pem = private_key.?,
            .client_ca_certificates_pem = client_ca,
        } else null,
    } });
    defer server.deinit();
    try server.registerUnary("/grpc.testing.TestService/EmptyCall", rpc.UnaryHandler.bind(Service, &service, Service.empty));
    try server.registerUnary("/grpc.testing.TestService/UnaryCall", rpc.UnaryHandler.bind(Service, &service, Service.unaryCall));
    var typed = pb.ServiceServer(testing.TestService(Service, anyerror)).init(&server);
    try typed.registerStream("StreamingInputCall", &service, Service.input);
    try typed.registerStream("StreamingOutputCall", &service, Service.output);
    try typed.registerStream("FullDuplexCall", &service, Service.fullDuplex);
    try typed.registerStream("HalfDuplexCall", &service, Service.halfDuplex);
    try server.start();
    std.debug.print("grpc-lite task interop server listening on 127.0.0.1:{d}\n", .{try server.port()});
    server.wait();
}
