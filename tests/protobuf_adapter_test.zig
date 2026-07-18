const std = @import("std");
const demo = @import("demo_proto");
const grpc = @import("grpc_lite");
const grpc_pb = @import("grpc_lite_protobuf");

const AppError = error{ Rejected, OutOfMemory };

const AppState = struct {
    response_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    context_hook_called: bool = false,

    fn echo(self: *AppState, request: demo.EchoRequest) AppError!demo.EchoReply {
        if (std.mem.eql(u8, request.message, "reject")) return error.Rejected;
        const scratch = try self.scratch_allocator.dupe(u8, request.message);
        defer self.scratch_allocator.free(scratch);
        return .{ .message = try self.response_allocator.dupe(u8, scratch) };
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

test "generated service isolates transport registration handler and client allocators" {
    var transport_gpa: std.heap.DebugAllocator(.{ .canary = 0x11_11_11_11 }) = .init;
    defer std.testing.expectEqual(std.heap.Check.ok, transport_gpa.deinit()) catch @panic("transport allocator leak");
    var registration_gpa: std.heap.DebugAllocator(.{ .canary = 0x22_22_22_22 }) = .init;
    defer std.testing.expectEqual(std.heap.Check.ok, registration_gpa.deinit()) catch @panic("registration allocator leak");
    var scratch_gpa: std.heap.DebugAllocator(.{ .canary = 0x33_33_33_33 }) = .init;
    defer std.testing.expectEqual(std.heap.Check.ok, scratch_gpa.deinit()) catch @panic("handler scratch allocator leak");
    var client_gpa: std.heap.DebugAllocator(.{ .canary = 0x44_44_44_44 }) = .init;
    defer std.testing.expectEqual(std.heap.Check.ok, client_gpa.deinit()) catch @panic("client allocator leak");

    const transport_allocator = transport_gpa.allocator();
    const registration_allocator = registration_gpa.allocator();
    const client_allocator = client_gpa.allocator();
    var state: AppState = .{
        .response_allocator = registration_allocator,
        .scratch_allocator = scratch_gpa.allocator(),
    };
    const vtable: EchoApi = .{ .Echo = AppState.echo };
    var registration = grpc_pb.ServiceRegistration(EchoApi).init(
        registration_allocator,
        &state,
        vtable,
        .{
            .map_error = mapError,
            .context_hook = configureContext,
        },
    );
    defer registration.deinit();

    var server = try grpc.Server.init(transport_allocator, .{});
    defer server.deinit();
    try registration.register(&server);
    try server.start();

    var target_buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buffer, "127.0.0.1:{d}", .{try server.port()});
    var channel = try grpc.Channel.init(transport_allocator, target, .{});
    defer channel.deinit();
    var client = grpc_pb.ServiceClient(EchoApi).init(&channel);

    var success = try client.callUnary(
        client_allocator,
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
        client_allocator,
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
    var state: AppState = .{
        .response_allocator = std.testing.allocator,
        .scratch_allocator = std.testing.allocator,
    };
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
