//! Typed unary API using the same task-friendly transport as grpc_lite_async.
const std = @import("std");
const rpc = @import("grpc_lite_async");
const grpc = @import("grpc_lite");
const protobuf = @import("grpc_lite_protobuf");

pub const TypedResult = protobuf.TypedResult;

/// Borrows a client; generated service method names determine the wire path and
/// request/response types. Encoding and decoding use the calling task's allocator.
pub fn ServiceClient(comptime Service: type) type {
    return struct {
        client: *rpc.Client,

        pub fn init(client: *rpc.Client) @This() {
            return .{ .client = client };
        }

        pub fn callUnary(
            self: *@This(),
            allocator: std.mem.Allocator,
            comptime method: []const u8,
            request: protobuf.RequestType(Service, method),
            options: grpc.CallOptions,
        ) !TypedResult(protobuf.ResponseType(Service, method)) {
            comptime if (protobuf.methodKind(Service, method) != .unary) {
                @compileError("expected a unary protobuf method: " ++ method);
            };
            try self.client.io.checkCancel();
            var writer: std.Io.Writer.Allocating = .init(allocator);
            defer writer.deinit();
            request.encode(&writer.writer, allocator) catch |err| switch (err) {
                // Allocating.Writer has no external sink; WriteFailed is OOM.
                error.WriteFailed => return error.OutOfMemory,
                else => return err,
            };
            var raw = try self.client.callUnary(allocator, protobuf.methodPath(Service, method), writer.written(), options);
            errdefer raw.deinit();

            const Response = protobuf.ResponseType(Service, method);
            var arena: std.heap.ArenaAllocator = .init(allocator);
            errdefer arena.deinit();
            var response: ?Response = null;
            if (raw.status.isOk()) {
                var reader: std.Io.Reader = .fixed(raw.payload);
                response = try Response.decode(&reader, arena.allocator());
            }
            return .{
                .allocator = allocator,
                .raw = raw,
                .response = response,
                .response_arena = arena,
            };
        }
    };
}
