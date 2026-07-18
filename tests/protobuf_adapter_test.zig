const std = @import("std");
const demo = @import("demo_proto");
const grpc = @import("grpc_lite");
const grpc_pb = @import("grpc_lite_protobuf");

const AppError = error{ Rejected, OutOfMemory };

const AppState = struct {
    allocator: std.mem.Allocator,
    context_hook_called: bool = false,

    fn echo(self: *AppState, request: demo.EchoRequest) AppError!demo.EchoReply {
        if (std.mem.eql(u8, request.message, "reject")) return error.Rejected;
        return .{ .message = try self.allocator.dupe(u8, request.message) };
    }
};

const EchoApi = demo.EchoService(AppState, AppError);

fn mapError(err: AppError) grpc.Status {
    return switch (err) {
        error.Rejected => .init(.invalid_argument, "request rejected"),
        error.OutOfMemory => .init(.resource_exhausted, "allocation failed"),
    };
}

fn configureContext(state: *AppState, context: *grpc.ServerContext) !void {
    state.context_hook_called = true;
    try context.addInitialMetadata("x-protobuf", "enabled");
    try context.addTrailingMetadata("x-service", "demo.EchoService");
}

test "generated service registers automatically and supports typed calls" {
    var state: AppState = .{ .allocator = std.testing.allocator };
    const vtable: EchoApi = .{ .Echo = AppState.echo };
    var registration = grpc_pb.ServiceRegistration(EchoApi).init(
        std.testing.allocator,
        &state,
        vtable,
        .{
            .map_error = mapError,
            .context_hook = configureContext,
        },
    );
    defer registration.deinit();

    var server = try grpc.Server.init(std.testing.allocator, .{});
    defer server.deinit();
    try registration.register(&server);
    try server.start();

    var target_buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buffer, "127.0.0.1:{d}", .{try server.port()});
    var channel = try grpc.Channel.init(std.testing.allocator, target, .{});
    defer channel.deinit();
    var client = grpc_pb.ServiceClient(EchoApi).init(&channel);

    var success = try client.callUnary(
        std.testing.allocator,
        "Echo",
        demo.EchoRequest{ .message = "hello protobuf" },
        .{},
    );
    defer success.deinit();
    try std.testing.expect(success.raw.status.isOk());
    try std.testing.expectEqualStrings("hello protobuf", success.response.?.message);
    try std.testing.expectEqualStrings("enabled", success.raw.initial_metadata.getFirst("x-protobuf").?);
    try std.testing.expectEqualStrings("demo.EchoService", success.raw.trailing_metadata.getFirst("x-service").?);
    try std.testing.expect(state.context_hook_called);

    var rejected = try client.callUnary(
        std.testing.allocator,
        "Echo",
        demo.EchoRequest{ .message = "reject" },
        .{},
    );
    defer rejected.deinit();
    try std.testing.expectEqual(grpc.StatusCode.invalid_argument, rejected.raw.status.code);
    try std.testing.expectEqualStrings("request rejected", rejected.raw.status.message);
    try std.testing.expectEqual(@as(?demo.EchoReply, null), rejected.response);
}

test "automatic method path includes package and service" {
    try std.testing.expectEqualStrings(
        "/demo.EchoService/Echo",
        grpc_pb.methodPath(EchoApi, "Echo"),
    );
}

test "malformed protobuf request is rejected before dispatch" {
    var state: AppState = .{ .allocator = std.testing.allocator };
    var registration = grpc_pb.ServiceRegistration(EchoApi).init(
        std.testing.allocator,
        &state,
        .{ .Echo = AppState.echo },
        .{},
    );
    defer registration.deinit();

    var server = try grpc.Server.init(std.testing.allocator, .{});
    defer server.deinit();
    try registration.register(&server);
    try server.start();

    var target_buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buffer, "127.0.0.1:{d}", .{try server.port()});
    var channel = try grpc.Channel.init(std.testing.allocator, target, .{});
    defer channel.deinit();
    var result = try channel.callUnary(
        std.testing.allocator,
        "/demo.EchoService/Echo",
        &.{ 0x0a, 0x05, 'x' },
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqual(grpc.StatusCode.invalid_argument, result.status.code);
}
