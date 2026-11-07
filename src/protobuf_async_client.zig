//! Typed API using the same task-friendly transport as grpc_lite_async.
const std = @import("std");
const rpc = @import("grpc_lite_async");
const grpc = @import("grpc_lite");
const protobuf = @import("grpc_lite_protobuf");

pub const TypedResult = protobuf.TypedResult;
pub const StreamResult = rpc.StreamResult;

/// A decoded streaming message, owned independently of the stream.
pub fn StreamMessage(comptime Response: type) type {
    return struct {
        value: Response,
        compression: grpc.Compression,
        arena: std.heap.ArenaAllocator,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

pub fn ClientStream(comptime Request: type, comptime Response: type) type {
    return struct {
        raw: rpc.Stream,

        pub fn send(self: *@This(), allocator: std.mem.Allocator, request: Request, options: grpc.StreamSendOptions) !void {
            var writer: std.Io.Writer.Allocating = .init(allocator);
            defer writer.deinit();
            request.encode(&writer.writer, allocator) catch |err| switch (err) {
                error.WriteFailed => return error.OutOfMemory,
                else => return err,
            };
            try self.raw.send(writer.written(), options);
        }

        pub fn receive(self: *@This(), allocator: std.mem.Allocator) !?StreamMessage(Response) {
            var message = (try self.raw.receive(allocator)) orelse return null;
            defer message.deinit();
            // A consumed malformed/undecodable message cannot be retried. Stop
            // both directions instead of silently skipping part of the stream.
            errdefer self.raw.cancel();
            var arena: std.heap.ArenaAllocator = .init(allocator);
            errdefer arena.deinit();
            var reader: std.Io.Reader = .fixed(message.payload);
            return .{
                .value = try Response.decode(&reader, arena.allocator()),
                .compression = message.compression,
                .arena = arena,
            };
        }

        pub fn closeSend(self: *@This()) !void {
            try self.raw.closeSend();
        }

        pub fn finish(self: *@This(), allocator: std.mem.Allocator) !StreamResult {
            return self.raw.finish(allocator);
        }

        pub fn cancel(self: *@This()) void {
            self.raw.cancel();
        }

        pub fn deinit(self: *@This()) void {
            self.raw.deinit();
            self.* = undefined;
        }
    };
}

/// Borrows a client; generated service method names determine the wire path and
/// request/response types. Encoding and decoding use the calling task's allocator.
pub fn ServiceClient(comptime Service: type) type {
    return struct {
        client: *rpc.Client,

        pub fn init(client: *rpc.Client) @This() {
            return .{ .client = client };
        }

        pub fn openStream(
            self: *@This(),
            allocator: std.mem.Allocator,
            comptime method: []const u8,
            options: grpc.StreamOptions,
        ) !ClientStream(protobuf.RequestType(Service, method), protobuf.ResponseType(Service, method)) {
            comptime if (protobuf.methodKind(Service, method) == .unary) {
                @compileError("expected a streaming protobuf method: " ++ method);
            };
            return .{ .raw = try self.client.openStream(allocator, protobuf.methodPath(Service, method), options) };
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
