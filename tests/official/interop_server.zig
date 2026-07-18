const std = @import("std");
const grpc = @import("grpc_lite");
const testing = @import("grpc_testing");

const Config = struct {
    port: u16 = 10000,
    use_tls: bool = false,
};

const Service = struct {
    fn emptyCall(
        _: *@This(),
        allocator: std.mem.Allocator,
        _: *grpc.ServerContext,
        request_bytes: []const u8,
    ) !grpc.UnaryResponse {
        var reader: std.Io.Reader = .fixed(request_bytes);
        var request = testing.Empty.decode(&reader, allocator) catch {
            return grpc.UnaryResponse.fail(
                allocator,
                .init(.invalid_argument, "invalid Empty request"),
            );
        };
        defer request.deinit(allocator);
        return grpc.UnaryResponse.ok(allocator, "");
    }

    fn unaryCall(
        _: *@This(),
        allocator: std.mem.Allocator,
        _: *grpc.ServerContext,
        request_bytes: []const u8,
    ) !grpc.UnaryResponse {
        var reader: std.Io.Reader = .fixed(request_bytes);
        var request = testing.SimpleRequest.decode(&reader, allocator) catch {
            return grpc.UnaryResponse.fail(
                allocator,
                .init(.invalid_argument, "invalid SimpleRequest"),
            );
        };
        defer request.deinit(allocator);

        if (request.response_status) |response_status| {
            const code = if (response_status.code >= 0)
                grpc.StatusCode.fromInt(@intCast(response_status.code))
            else
                .unknown;
            return grpc.UnaryResponse.fail(
                allocator,
                .init(code, response_status.message),
            );
        }
        if (request.response_size < 0) {
            return grpc.UnaryResponse.fail(
                allocator,
                .init(.invalid_argument, "negative response size"),
            );
        }

        const body = try allocator.alloc(u8, @intCast(request.response_size));
        defer allocator.free(body);
        @memset(body, 0);
        const response: testing.SimpleResponse = .{
            .payload = .{
                .type = request.response_type,
                .body = body,
            },
        };
        var writer: std.Io.Writer.Allocating = .init(allocator);
        defer writer.deinit();
        try response.encode(&writer.writer, allocator);
        return grpc.UnaryResponse.ok(allocator, writer.written());
    }
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

    var service: Service = .{};
    var server = try grpc.Server.init(init.gpa, .{
        .host = "127.0.0.1",
        .port = config.port,
    });
    defer server.deinit();
    try server.registerUnary(
        "/grpc.testing.TestService/EmptyCall",
        grpc.UnaryHandler.bind(Service, &service, Service.emptyCall),
    );
    try server.registerUnary(
        "/grpc.testing.TestService/UnaryCall",
        grpc.UnaryHandler.bind(Service, &service, Service.unaryCall),
    );
    try server.start();
    std.debug.print("grpc-lite interop server listening on 127.0.0.1:{d}\n", .{try server.port()});
    server.wait();
}

fn parseArgs(args: []const []const u8) !Config {
    var config: Config = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.startsWith(u8, arg, "--port=")) {
            config.port = try std.fmt.parseInt(u16, arg["--port=".len..], 10);
        } else if (std.mem.eql(u8, arg, "--port")) {
            index += 1;
            if (index >= args.len) return error.MissingPort;
            config.port = try std.fmt.parseInt(u16, args[index], 10);
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
