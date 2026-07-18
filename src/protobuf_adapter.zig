const std = @import("std");
const grpc = @import("grpc_lite");

pub fn TypedResult(comptime Response: type) type {
    return struct {
        allocator: std.mem.Allocator,
        raw: grpc.CallResult,
        response: ?Response,

        pub fn deinit(self: *@This()) void {
            if (self.response) |*response| response.deinit(self.allocator);
            self.raw.deinit();
            self.* = undefined;
        }
    };
}

pub fn ServiceClient(comptime Service: type) type {
    comptime validateService(Service);

    return struct {
        channel: *grpc.Channel,

        pub fn init(channel: *grpc.Channel) @This() {
            return .{ .channel = channel };
        }

        pub fn callUnary(
            self: *@This(),
            allocator: std.mem.Allocator,
            comptime method: []const u8,
            request: RequestType(Service, method),
            options: grpc.CallOptions,
        ) !TypedResult(ResponseType(Service, method)) {
            const Response = ResponseType(Service, method);
            var writer: std.Io.Writer.Allocating = .init(allocator);
            defer writer.deinit();
            try request.encode(&writer.writer, allocator);

            var raw = try self.channel.callUnary(
                allocator,
                methodPath(Service, method),
                writer.written(),
                options,
            );
            errdefer raw.deinit();

            var response: ?Response = null;
            if (raw.status.isOk()) {
                var reader: std.Io.Reader = .fixed(raw.payload);
                response = try Response.decode(&reader, allocator);
            }
            return .{
                .allocator = allocator,
                .raw = raw,
                .response = response,
            };
        }
    };
}

pub fn ServiceRegistration(comptime Service: type) type {
    comptime validateService(Service);
    const UserData = UserDataType(Service);
    const ServiceError = ErrorSetType(Service);

    return struct {
        pub const ErrorMapper = *const fn (ServiceError) grpc.Status;
        pub const ContextHook = *const fn (*UserData, *grpc.ServerContext) anyerror!void;
        pub const Options = struct {
            map_error: ?ErrorMapper = null,
            context_hook: ?ContextHook = null,
        };

        allocator: std.mem.Allocator,
        userdata: *UserData,
        vtable: Service,
        options: Options,

        pub fn init(
            allocator: std.mem.Allocator,
            userdata: *UserData,
            vtable: Service,
            options: Options,
        ) @This() {
            return .{
                .allocator = allocator,
                .userdata = userdata,
                .vtable = vtable,
                .options = options,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.* = undefined;
        }

        pub fn register(self: *@This(), server: *grpc.Server) !void {
            inline for (@typeInfo(Service).@"struct".fields) |field| {
                try server.registerUnary(
                    methodPath(Service, field.name),
                    handlerFor(field.name, self),
                );
            }
        }

        fn handlerFor(comptime method: []const u8, self: *@This()) grpc.UnaryHandler {
            const Registration = @This();
            return .{
                .context = self,
                .invoke_fn = struct {
                    fn invoke(
                        opaque_context: ?*anyopaque,
                        _: std.mem.Allocator,
                        server_context: *grpc.ServerContext,
                        request_bytes: []const u8,
                    ) anyerror!grpc.UnaryResponse {
                        const registration: *Registration = @ptrCast(@alignCast(opaque_context.?));
                        return registration.invokeMethod(method, server_context, request_bytes);
                    }
                }.invoke,
            };
        }

        fn invokeMethod(
            self: *@This(),
            comptime method: []const u8,
            server_context: *grpc.ServerContext,
            request_bytes: []const u8,
        ) !grpc.UnaryResponse {
            const Request = RequestType(Service, method);
            var reader: std.Io.Reader = .fixed(request_bytes);
            var request = Request.decode(&reader, self.allocator) catch {
                return grpc.UnaryResponse.fail(
                    self.allocator,
                    .init(.invalid_argument, "invalid protobuf request"),
                );
            };
            defer request.deinit(self.allocator);

            if (self.options.context_hook) |hook| {
                hook(self.userdata, server_context) catch {
                    return grpc.UnaryResponse.fail(
                        self.allocator,
                        .init(.internal, "protobuf context hook failed"),
                    );
                };
            }

            var response = @field(self.vtable, method)(self.userdata, request) catch |err| {
                const mapped = if (self.options.map_error) |mapper|
                    mapper(err)
                else
                    grpc.Status.init(.internal, @errorName(err));
                return grpc.UnaryResponse.fail(self.allocator, mapped);
            };
            defer response.deinit(self.allocator);

            var writer: std.Io.Writer.Allocating = .init(self.allocator);
            defer writer.deinit();
            try response.encode(&writer.writer, self.allocator);
            return grpc.UnaryResponse.ok(self.allocator, writer.written());
        }
    };
}

pub fn methodPath(comptime Service: type, comptime method: []const u8) []const u8 {
    comptime validateMethod(Service, method);
    if (Service.package.len == 0) return "/" ++ Service.service_name ++ "/" ++ method;
    return "/" ++ Service.package ++ "." ++ Service.service_name ++ "/" ++ method;
}

pub fn RequestType(comptime Service: type, comptime method: []const u8) type {
    const function = MethodFunction(Service, method);
    return @typeInfo(function).@"fn".params[1].type.?;
}

pub fn ResponseType(comptime Service: type, comptime method: []const u8) type {
    const function = MethodFunction(Service, method);
    const return_type = @typeInfo(function).@"fn".return_type.?;
    return @typeInfo(return_type).error_union.payload;
}

fn UserDataType(comptime Service: type) type {
    const fields = @typeInfo(Service).@"struct".fields;
    const function = @typeInfo(fields[0].type).pointer.child;
    const userdata_pointer = @typeInfo(function).@"fn".params[0].type.?;
    return @typeInfo(userdata_pointer).pointer.child;
}

fn ErrorSetType(comptime Service: type) type {
    const fields = @typeInfo(Service).@"struct".fields;
    const function = @typeInfo(fields[0].type).pointer.child;
    const return_type = @typeInfo(function).@"fn".return_type.?;
    return @typeInfo(return_type).error_union.error_set;
}

fn MethodFunction(comptime Service: type, comptime method: []const u8) type {
    comptime validateMethod(Service, method);
    return @typeInfo(@FieldType(Service, method)).pointer.child;
}

fn validateService(comptime Service: type) void {
    if (!@hasDecl(Service, "package") or !@hasDecl(Service, "service_name")) {
        @compileError("expected a zig-protobuf generated service type");
    }
    const fields = @typeInfo(Service).@"struct".fields;
    if (fields.len == 0) @compileError("protobuf service has no methods");

    const userdata = UserDataType(Service);
    const errors = ErrorSetType(Service);
    inline for (fields) |field| {
        validateMethod(Service, field.name);
        const function = @typeInfo(field.type).pointer.child;
        const info = @typeInfo(function).@"fn";
        const field_userdata = @typeInfo(info.params[0].type.?).pointer.child;
        const field_errors = @typeInfo(info.return_type.?).error_union.error_set;
        if (field_userdata != userdata or field_errors != errors) {
            @compileError("protobuf service methods must share userdata and error types");
        }
    }
}

fn validateMethod(comptime Service: type, comptime method: []const u8) void {
    if (!@hasField(Service, method)) @compileError("protobuf service has no method named " ++ method);
    const field_type = @FieldType(Service, method);
    if (@typeInfo(field_type) != .pointer or @typeInfo(@typeInfo(field_type).pointer.child) != .@"fn") {
        @compileError("protobuf service field is not a function pointer: " ++ method);
    }
    const info = @typeInfo(@typeInfo(field_type).pointer.child).@"fn";
    if (info.params.len != 2 or @typeInfo(info.params[1].type.?) == .pointer) {
        @compileError("grpc-lite currently supports unary protobuf methods only: " ++ method);
    }
    if (@typeInfo(info.return_type.?) != .error_union) {
        @compileError("protobuf unary method must return an error union: " ++ method);
    }
}
