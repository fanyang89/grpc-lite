const std = @import("std");
const Compression = @import("compression.zig").Compression;
const metadata = @import("metadata.zig");
const status = @import("status.zig");

pub const ServerContext = struct {
    allocator: std.mem.Allocator,
    request_compression: Compression = .identity,
    response_compression: Compression = .identity,
    request_metadata: metadata.Metadata,
    initial_metadata: metadata.Metadata,
    trailing_metadata: metadata.Metadata,

    pub fn init(allocator: std.mem.Allocator) ServerContext {
        return .{
            .allocator = allocator,
            .request_metadata = metadata.Metadata.init(allocator),
            .initial_metadata = metadata.Metadata.init(allocator),
            .trailing_metadata = metadata.Metadata.init(allocator),
        };
    }

    pub fn deinit(self: *ServerContext) void {
        self.request_metadata.deinit();
        self.initial_metadata.deinit();
        self.trailing_metadata.deinit();
        self.* = undefined;
    }

    pub fn addInitialMetadata(self: *ServerContext, key: []const u8, value: []const u8) !void {
        try self.initial_metadata.append(key, value);
    }

    pub fn addTrailingMetadata(self: *ServerContext, key: []const u8, value: []const u8) !void {
        try self.trailing_metadata.append(key, value);
    }

    pub fn setResponseCompression(self: *ServerContext, response_compression: Compression) void {
        self.response_compression = response_compression;
    }
};

pub const UnaryResponse = struct {
    allocator: std.mem.Allocator,
    status: status.Status,
    payload: []u8,

    pub fn init(
        allocator: std.mem.Allocator,
        response_status: status.Status,
        payload: []const u8,
    ) !UnaryResponse {
        const owned_message = try allocator.dupe(u8, response_status.message);
        errdefer allocator.free(owned_message);
        return .{
            .allocator = allocator,
            .status = .{ .code = response_status.code, .message = owned_message },
            .payload = try allocator.dupe(u8, payload),
        };
    }

    pub fn ok(allocator: std.mem.Allocator, payload: []const u8) !UnaryResponse {
        return init(allocator, status.Status.ok, payload);
    }

    pub fn fail(allocator: std.mem.Allocator, response_status: status.Status) !UnaryResponse {
        return init(allocator, response_status, "");
    }

    pub fn deinit(self: *UnaryResponse) void {
        self.allocator.free(self.status.message);
        self.allocator.free(self.payload);
        self.* = undefined;
    }
};

pub const UnaryHandler = struct {
    context: ?*anyopaque,
    invoke_fn: *const fn (
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        server_context: *ServerContext,
        request: []const u8,
    ) anyerror!UnaryResponse,

    pub fn bind(
        comptime T: type,
        context: *T,
        comptime handler: fn (*T, std.mem.Allocator, *ServerContext, []const u8) anyerror!UnaryResponse,
    ) UnaryHandler {
        return .{
            .context = context,
            .invoke_fn = struct {
                fn invoke(
                    opaque_context: ?*anyopaque,
                    allocator: std.mem.Allocator,
                    server_context: *ServerContext,
                    request: []const u8,
                ) anyerror!UnaryResponse {
                    const typed_context: *T = @ptrCast(@alignCast(opaque_context.?));
                    return handler(typed_context, allocator, server_context, request);
                }
            }.invoke,
        };
    }

    pub fn invoke(
        self: UnaryHandler,
        allocator: std.mem.Allocator,
        server_context: *ServerContext,
        request: []const u8,
    ) !UnaryResponse {
        return self.invoke_fn(self.context, allocator, server_context, request);
    }
};

test "typed unary handler owns its response" {
    const Echo = struct {
        prefix: []const u8,

        fn handle(
            self: *@This(),
            allocator: std.mem.Allocator,
            context: *ServerContext,
            request: []const u8,
        ) !UnaryResponse {
            try context.addTrailingMetadata("x-handler", "echo");
            const payload = try std.mem.concat(allocator, u8, &.{ self.prefix, request });
            defer allocator.free(payload);
            return UnaryResponse.ok(allocator, payload);
        }
    };

    var echo = Echo{ .prefix = "echo:" };
    const handler = UnaryHandler.bind(Echo, &echo, Echo.handle);
    var context = ServerContext.init(std.testing.allocator);
    defer context.deinit();
    var response = try handler.invoke(std.testing.allocator, &context, "hello");
    defer response.deinit();

    try std.testing.expectEqualStrings("echo:hello", response.payload);
    try std.testing.expectEqualStrings("echo", context.trailing_metadata.getFirst("x-handler").?);
}

test "unary response owns its status message" {
    const message = try std.testing.allocator.dupe(u8, "dynamic status");
    var response = try UnaryResponse.fail(
        std.testing.allocator,
        status.Status.init(.unknown, message),
    );
    std.testing.allocator.free(message);
    defer response.deinit();

    try std.testing.expectEqualStrings("dynamic status", response.status.message);
}
