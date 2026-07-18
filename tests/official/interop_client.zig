const std = @import("std");
const grpc = @import("grpc_lite");
const testing = @import("grpc_testing");

const large_request_size = 271828;
const large_response_size = 314159;
const special_status_message = "\t\ntest with whitespace\r\nand Unicode BMP \xE2\x98\xBA and non-BMP \xF0\x9F\x98\x88\t\n";

const Config = struct {
    server_host: []const u8 = "127.0.0.1",
    server_port: u16 = 10000,
    test_case: []const u8 = "large_unary",
    use_tls: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const config = parseArgs(args) catch |err| {
        std.debug.print("invalid arguments: {s}\n", .{@errorName(err)});
        return err;
    };
    if (config.use_tls) {
        std.debug.print("TLS is not supported by grpc-lite interop\n", .{});
        return error.TlsUnsupported;
    }

    const target = try std.fmt.allocPrint(init.gpa, "{s}:{d}", .{
        config.server_host,
        config.server_port,
    });
    defer init.gpa.free(target);
    var channel = try grpc.Channel.init(init.gpa, target, .{});
    defer channel.deinit();

    if (std.mem.eql(u8, config.test_case, "empty_unary")) {
        try emptyUnary(init.gpa, &channel);
    } else if (std.mem.eql(u8, config.test_case, "large_unary")) {
        try largeUnary(init.gpa, &channel);
    } else if (std.mem.eql(u8, config.test_case, "special_status_message")) {
        try specialStatusMessage(init.gpa, &channel);
    } else if (std.mem.eql(u8, config.test_case, "unimplemented_method")) {
        try expectUnimplemented(init.gpa, &channel, "/grpc.testing.TestService/UnimplementedCall");
    } else if (std.mem.eql(u8, config.test_case, "unimplemented_service")) {
        try expectUnimplemented(init.gpa, &channel, "/grpc.testing.UnimplementedService/UnimplementedCall");
    } else {
        std.debug.print("unsupported test case: {s}\n", .{config.test_case});
        return error.UnsupportedTestCase;
    }
    std.debug.print("interop case passed: {s}\n", .{config.test_case});
}

fn emptyUnary(allocator: std.mem.Allocator, channel: *grpc.Channel) !void {
    var result = try callMessage(
        allocator,
        channel,
        "/grpc.testing.TestService/EmptyCall",
        testing.Empty{},
    );
    defer result.deinit();
    try expectStatus(&result, .ok, "");

    var reader: std.Io.Reader = .fixed(result.payload);
    var response = try testing.Empty.decode(&reader, allocator);
    defer response.deinit(allocator);
}

fn largeUnary(allocator: std.mem.Allocator, channel: *grpc.Channel) !void {
    const body = try allocator.alloc(u8, large_request_size);
    defer allocator.free(body);
    @memset(body, 0);
    const request: testing.SimpleRequest = .{
        .response_type = .COMPRESSABLE,
        .response_size = large_response_size,
        .payload = .{
            .type = .COMPRESSABLE,
            .body = body,
        },
    };
    var result = try callMessage(
        allocator,
        channel,
        "/grpc.testing.TestService/UnaryCall",
        request,
    );
    defer result.deinit();
    try expectStatus(&result, .ok, "");

    var reader: std.Io.Reader = .fixed(result.payload);
    var response = try testing.SimpleResponse.decode(&reader, allocator);
    defer response.deinit(allocator);
    const payload = response.payload orelse return error.MissingPayload;
    if (payload.type != .COMPRESSABLE) return error.UnexpectedPayloadType;
    if (payload.body.len != large_response_size) return error.UnexpectedPayloadSize;
    for (payload.body) |byte| {
        if (byte != 0) return error.UnexpectedPayloadContents;
    }
}

fn specialStatusMessage(allocator: std.mem.Allocator, channel: *grpc.Channel) !void {
    const request: testing.SimpleRequest = .{
        .response_status = .{
            .code = @intFromEnum(grpc.StatusCode.unknown),
            .message = special_status_message,
        },
    };
    var result = try callMessage(
        allocator,
        channel,
        "/grpc.testing.TestService/UnaryCall",
        request,
    );
    defer result.deinit();
    try expectStatus(&result, .unknown, special_status_message);
}

fn expectUnimplemented(
    allocator: std.mem.Allocator,
    channel: *grpc.Channel,
    path: []const u8,
) !void {
    var result = try callMessage(allocator, channel, path, testing.Empty{});
    defer result.deinit();
    if (result.status.code != .unimplemented) {
        std.debug.print("expected UNIMPLEMENTED, got {t}: {s}\n", .{
            result.status.code,
            result.status.message,
        });
        return error.UnexpectedRpcStatus;
    }
}

fn callMessage(
    allocator: std.mem.Allocator,
    channel: *grpc.Channel,
    path: []const u8,
    request: anytype,
) !grpc.CallResult {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try request.encode(&writer.writer, allocator);
    return channel.callUnary(allocator, path, writer.written(), .{
        .timeout_ns = 10 * std.time.ns_per_s,
    });
}

fn expectStatus(result: *const grpc.CallResult, code: grpc.StatusCode, message: []const u8) !void {
    if (result.status.code != code or !std.mem.eql(u8, result.status.message, message)) {
        std.debug.print("unexpected RPC status: {t}: {s}\n", .{
            result.status.code,
            result.status.message,
        });
        return error.UnexpectedRpcStatus;
    }
}

fn parseArgs(args: []const []const u8) !Config {
    var config: Config = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.startsWith(u8, arg, "--server_host=")) {
            config.server_host = arg["--server_host=".len..];
        } else if (std.mem.eql(u8, arg, "--server_host")) {
            index += 1;
            if (index >= args.len) return error.MissingServerHost;
            config.server_host = args[index];
        } else if (std.mem.startsWith(u8, arg, "--server_port=")) {
            config.server_port = try std.fmt.parseInt(u16, arg["--server_port=".len..], 10);
        } else if (std.mem.eql(u8, arg, "--server_port")) {
            index += 1;
            if (index >= args.len) return error.MissingServerPort;
            config.server_port = try std.fmt.parseInt(u16, args[index], 10);
        } else if (std.mem.startsWith(u8, arg, "--test_case=")) {
            config.test_case = arg["--test_case=".len..];
        } else if (std.mem.eql(u8, arg, "--test_case")) {
            index += 1;
            if (index >= args.len) return error.MissingTestCase;
            config.test_case = args[index];
        } else if (std.mem.startsWith(u8, arg, "--use_tls=")) {
            config.use_tls = try parseBool(arg["--use_tls=".len..]);
        } else if (std.mem.eql(u8, arg, "--use_tls")) {
            config.use_tls = true;
        } else {
            return error.UnknownArgument;
        }
    }
    return config;
}

fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidBoolean;
}
