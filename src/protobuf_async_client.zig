//! Typed API using the same task-friendly transport as grpc_lite_async.
const std = @import("std");
const rpc = @import("grpc_lite_async");
const grpc = @import("grpc_lite");
const protobuf = @import("grpc_lite_protobuf");

pub const TypedResult = protobuf.TypedResult;
pub const StreamResult = rpc.StreamResult;

pub const UnaryServerOptions = struct {
    map_error: ?*const fn (anyerror) grpc.Status = null,
};

/// Borrows a raw server. Method names and message types come from the generated
/// service; handlers receive Io explicitly rather than a synchronous vtable.
pub fn ServiceServer(comptime Service: type) type {
    return struct {
        server: *rpc.Server,

        pub fn init(server: *rpc.Server) @This() {
            return .{ .server = server };
        }

        /// function(context, arena_allocator, io, server_context, request) returns
        /// the generated Response. Request and response storage is call-scoped;
        /// use the supplied arena for response allocations, without deinit.
        pub fn registerUnary(self: *@This(), comptime method: []const u8, context: anytype, comptime function: anytype, comptime options: UnaryServerOptions) !void {
            comptime if (protobuf.methodKind(Service, method) != .unary) {
                @compileError("expected a unary protobuf method: " ++ method);
            };
            const Context = @TypeOf(context);
            const Request = protobuf.RequestType(Service, method);
            const Response = protobuf.ResponseType(Service, method);
            try self.server.registerUnary(protobuf.methodPath(Service, method), .{
                .context = context,
                .invoke_fn = struct {
                    fn invoke(raw: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, ctx: *grpc.ServerContext, bytes: []const u8) !grpc.UnaryResponse {
                        const userdata: Context = @ptrCast(@alignCast(raw.?));
                        var arena: std.heap.ArenaAllocator = .init(allocator);
                        defer arena.deinit();
                        var reader: std.Io.Reader = .fixed(bytes);
                        const request = Request.decode(&reader, arena.allocator()) catch |err| {
                            if (err == error.OutOfMemory) return err;
                            return grpc.UnaryResponse.fail(allocator, .init(.invalid_argument, "invalid protobuf request"));
                        };
                        const response: Response = function(userdata, arena.allocator(), io, ctx, request) catch |err| {
                            if (err == error.Canceled or err == error.OutOfMemory) return err;
                            const status = if (options.map_error) |mapper| mapper(err) else grpc.Status.init(.internal, "task handler failed");
                            return grpc.UnaryResponse.fail(allocator, status);
                        };
                        var writer: std.Io.Writer.Allocating = .init(allocator);
                        defer writer.deinit();
                        response.encode(&writer.writer, arena.allocator()) catch |err| switch (err) {
                            error.WriteFailed => return error.OutOfMemory,
                            else => return err,
                        };
                        return grpc.UnaryResponse.ok(allocator, writer.written());
                    }
                }.invoke,
            });
        }

        /// function(context, *ServerCall(Request, Response)) runs in a task and
        /// must finish the response and join any child tasks before returning.
        pub fn registerStream(self: *@This(), comptime method: []const u8, context: anytype, comptime function: anytype) !void {
            comptime if (protobuf.methodKind(Service, method) == .unary) {
                @compileError("expected a streaming protobuf method: " ++ method);
            };
            const Context = @TypeOf(context);
            const TypedCall = ServerCall(protobuf.RequestType(Service, method), protobuf.ResponseType(Service, method));
            try self.server.registerStream(protobuf.methodPath(Service, method), .{
                .context = context,
                .invoke_fn = struct {
                    fn invoke(raw: ?*anyopaque, call: *rpc.ServerCall) !void {
                        const userdata: Context = @ptrCast(@alignCast(raw.?));
                        var typed: TypedCall = .{ .raw = call };
                        try function(userdata, &typed);
                    }
                }.invoke,
            });
        }
    };
}

/// Borrowed typed server view, valid only inside the handler and its joined tasks.
pub fn ServerCall(comptime Request: type, comptime Response: type) type {
    return struct {
        raw: *rpc.ServerCall,

        pub fn io(self: *const @This()) std.Io {
            return self.raw.io();
        }

        pub fn context(self: *const @This()) *const grpc.ServerContext {
            return self.raw.context();
        }

        pub fn receive(self: *@This(), allocator: std.mem.Allocator) !?StreamMessage(Request) {
            var message = (try self.raw.receive(allocator)) orelse return null;
            defer message.deinit();
            var arena: std.heap.ArenaAllocator = .init(allocator);
            errdefer arena.deinit();
            var reader: std.Io.Reader = .fixed(message.payload);
            const value = Request.decode(&reader, arena.allocator()) catch |err| {
                // The wire message was consumed. End the RPC rather than allow
                // callers to continue after silently losing a request.
                self.raw.finish(.init(if (err == error.OutOfMemory) .resource_exhausted else .invalid_argument, "protobuf request decode failed"), &.{}) catch self.raw.abort();
                return err;
            };
            return .{ .value = value, .compression = message.compression, .arena = arena };
        }

        pub fn send(self: *@This(), allocator: std.mem.Allocator, response: Response, options: grpc.StreamSendOptions) !void {
            var writer: std.Io.Writer.Allocating = .init(allocator);
            defer writer.deinit();
            response.encode(&writer.writer, allocator) catch |err| switch (err) {
                error.WriteFailed => return error.OutOfMemory,
                else => return err,
            };
            try self.raw.send(writer.written(), options);
        }

        pub fn sendInitialMetadata(self: *@This(), entries: []const grpc.MetadataEntry, compression: grpc.Compression) !void {
            try self.raw.sendInitialMetadata(entries, compression);
        }

        pub fn finish(self: *@This(), status: grpc.Status, trailers: []const grpc.MetadataEntry) !void {
            try self.raw.finish(status, trailers);
        }

        pub fn abort(self: *@This()) void {
            self.raw.abort();
        }
    };
}

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
