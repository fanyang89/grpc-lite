const std = @import("std");
const c = @import("c.zig").api;
const frame = @import("frame.zig");
const message = @import("message.zig");
const metadata = @import("metadata.zig");
const service = @import("service.zig");
const status = @import("status.zig");

pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 0,
    max_request_size: usize = 4 * 1024 * 1024,
};

pub const LocalAddress = struct {
    host: []const u8,
    port: u16,
};

pub const Server = struct {
    impl: *Impl,

    pub fn init(allocator: std.mem.Allocator, options: Options) !Server {
        const impl = try allocator.create(Impl);
        errdefer allocator.destroy(impl);
        const host = try allocator.dupeZ(u8, options.host);
        errdefer allocator.free(host);

        impl.* = .{
            .allocator = allocator,
            .host = host,
            .configured_port = options.port,
            .max_request_size = options.max_request_size,
        };
        if (c.uv_mutex_init(&impl.mutex) < 0) return error.SynchronizationInitializationFailed;
        errdefer c.uv_mutex_destroy(&impl.mutex);
        if (c.uv_cond_init(&impl.condition) < 0) return error.SynchronizationInitializationFailed;
        return .{ .impl = impl };
    }

    pub fn registerUnary(self: *Server, full_method_path: []const u8, handler: service.UnaryHandler) !void {
        const impl = self.impl;
        impl.lock();
        defer impl.unlock();
        if (impl.state != .initialized) return error.ServerAlreadyStarted;
        if (!isValidMethodPath(full_method_path)) return error.InvalidMethodPath;
        if (impl.handlers.contains(full_method_path)) return error.MethodAlreadyRegistered;

        const owned_path = try impl.allocator.dupe(u8, full_method_path);
        errdefer impl.allocator.free(owned_path);
        try impl.handlers.put(impl.allocator, owned_path, handler);
    }

    pub fn start(self: *Server) !void {
        const impl = self.impl;
        impl.lock();
        defer impl.unlock();
        if (impl.state != .initialized) return error.ServerAlreadyStarted;

        impl.state = .starting;
        impl.thread = std.Thread.spawn(.{}, runLoop, .{impl}) catch |err| {
            impl.state = .initialized;
            return err;
        };
        while (impl.state == .starting) impl.waitForSignal();
        if (impl.startup_error) |err| return err;
    }

    pub fn localAddress(self: *const Server) !LocalAddress {
        const impl = self.impl;
        impl.lock();
        defer impl.unlock();
        if (impl.state != .running and impl.state != .stopping) return error.ServerNotRunning;
        return .{
            .host = impl.local_host[0..impl.local_host_len],
            .port = impl.local_port,
        };
    }

    pub fn port(self: *const Server) !u16 {
        return (try self.localAddress()).port;
    }

    pub fn shutdown(self: *Server) void {
        const impl = self.impl;
        impl.lock();
        defer impl.unlock();
        switch (impl.state) {
            .initialized => impl.state = .stopped,
            .running => {
                impl.state = .stopping;
                _ = c.uv_async_send(&impl.shutdown_async);
            },
            .starting, .stopping, .stopped => {},
        }
    }

    pub fn wait(self: *Server) void {
        const impl = self.impl;
        impl.lock();
        const thread = impl.thread;
        impl.thread = null;
        impl.unlock();
        if (thread) |running_thread| running_thread.join();
    }

    pub fn deinit(self: *Server) void {
        const impl = self.impl;
        self.shutdown();
        self.wait();

        var iterator = impl.handlers.iterator();
        while (iterator.next()) |entry| impl.allocator.free(entry.key_ptr.*);
        impl.handlers.deinit(impl.allocator);
        impl.connections.deinit(impl.allocator);
        impl.allocator.free(impl.host);
        c.uv_cond_destroy(&impl.condition);
        c.uv_mutex_destroy(&impl.mutex);
        const allocator = impl.allocator;
        allocator.destroy(impl);
        self.* = undefined;
    }
};

const State = enum { initialized, starting, running, stopping, stopped };
const StartupError = error{
    LoopInitializationFailed,
    InvalidAddress,
    ListenerInitializationFailed,
    BindFailed,
    ListenFailed,
    AddressQueryFailed,
    AsyncInitializationFailed,
};

const Impl = struct {
    allocator: std.mem.Allocator,
    host: [:0]u8,
    configured_port: u16,
    max_request_size: usize,
    handlers: std.StringHashMapUnmanaged(service.UnaryHandler) = .empty,
    connections: std.ArrayList(*Connection) = .empty,
    mutex: c.uv_mutex_t = undefined,
    condition: c.uv_cond_t = undefined,
    state: State = .initialized,
    startup_error: ?StartupError = null,
    thread: ?std.Thread = null,
    loop: c.uv_loop_t = undefined,
    listener: c.uv_tcp_t = undefined,
    shutdown_async: c.uv_async_t = undefined,
    local_host: [15]u8 = undefined,
    local_host_len: usize = 0,
    local_port: u16 = 0,

    fn lock(self: *Impl) void {
        c.uv_mutex_lock(&self.mutex);
    }

    fn unlock(self: *Impl) void {
        c.uv_mutex_unlock(&self.mutex);
    }

    fn waitForSignal(self: *Impl) void {
        c.uv_cond_wait(&self.condition, &self.mutex);
    }

    fn signalStarted(self: *Impl, result: ?StartupError) void {
        self.lock();
        defer self.unlock();
        self.startup_error = result;
        self.state = if (result == null) .running else .stopped;
        c.uv_cond_broadcast(&self.condition);
    }
};

const Stream = struct {
    allocator: std.mem.Allocator,
    connection: *Connection,
    id: i32,
    path: ?[]u8 = null,
    method_post: bool = false,
    content_type_grpc: bool = false,
    identity_encoding: bool = true,
    header_too_large: bool = false,
    request_too_large: bool = false,
    responded: bool = false,
    trailer_submitted: bool = false,
    header_bytes: usize = 0,
    request_body: std.ArrayList(u8) = .empty,
    request_metadata: metadata.Metadata,
    response_body: []u8 = &.{},
    response_offset: usize = 0,
    trailing_metadata: metadata.Metadata,
    response_code: status.Code = .ok,
    response_message: []const u8 = &.{},

    fn init(allocator: std.mem.Allocator, connection: *Connection, id: i32) Stream {
        return .{
            .allocator = allocator,
            .connection = connection,
            .id = id,
            .request_metadata = metadata.Metadata.init(allocator),
            .trailing_metadata = metadata.Metadata.init(allocator),
        };
    }

    fn deinit(self: *Stream) void {
        if (self.path) |path| self.allocator.free(path);
        self.request_body.deinit(self.allocator);
        self.request_metadata.deinit();
        if (self.response_body.len != 0) self.allocator.free(self.response_body);
        if (self.response_message.len != 0) self.allocator.free(self.response_message);
        self.trailing_metadata.deinit();
        self.* = undefined;
    }

    fn setStatus(self: *Stream, response_status: status.Status) !void {
        const owned_message = if (response_status.message.len == 0)
            &.{}
        else
            try self.allocator.dupe(u8, response_status.message);
        if (self.response_message.len != 0) self.allocator.free(self.response_message);
        self.response_code = response_status.code;
        self.response_message = owned_message;
    }
};

const Connection = struct {
    server: *Impl,
    tcp: c.uv_tcp_t = undefined,
    session: ?*c.nghttp2_session = null,
    streams: std.AutoHashMapUnmanaged(i32, *Stream) = .empty,
    closing: bool = false,

    fn initializeSession(self: *Connection) !void {
        var callbacks: ?*c.nghttp2_session_callbacks = null;
        if (c.nghttp2_session_callbacks_new(&callbacks) != 0) return error.OutOfMemory;
        defer c.nghttp2_session_callbacks_del(callbacks);

        c.nghttp2_session_callbacks_set_on_begin_headers_callback(callbacks, onBeginHeaders);
        c.nghttp2_session_callbacks_set_on_header_callback(callbacks, onHeader);
        c.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, onDataChunk);
        c.nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, onFrameReceived);
        c.nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, onStreamClose);
        if (c.nghttp2_session_server_new(&self.session, callbacks, self) != 0) return error.OutOfMemory;
        if (c.nghttp2_submit_settings(self.session, c.NGHTTP2_FLAG_NONE, null, 0) != 0) return error.NativeFailure;
    }

    fn flush(self: *Connection) !void {
        while (!self.closing) {
            var data: [*c]const u8 = null;
            const length = c.nghttp2_session_mem_send2(self.session, &data);
            if (length < 0) return error.NativeFailure;
            if (length == 0) return;

            const write = try self.server.allocator.create(WriteRequest);
            errdefer self.server.allocator.destroy(write);
            const bytes = try self.server.allocator.dupe(u8, data[0..@intCast(length)]);
            errdefer self.server.allocator.free(bytes);
            write.* = .{ .connection = self, .bytes = bytes };
            write.req.data = write;
            var buffer = c.uv_buf_init(@ptrCast(bytes.ptr), @intCast(bytes.len));
            if (c.uv_write(&write.req, @ptrCast(&self.tcp), &buffer, 1, onWrite) < 0) {
                self.server.allocator.free(bytes);
                self.server.allocator.destroy(write);
                return error.WriteFailed;
            }
        }
    }

    fn close(self: *Connection) void {
        if (self.closing) return;
        self.closing = true;
        _ = c.uv_read_stop(@ptrCast(&self.tcp));
        if (c.uv_is_closing(@ptrCast(&self.tcp)) == 0) c.uv_close(@ptrCast(&self.tcp), onConnectionClosed);
    }
};

const WriteRequest = struct {
    req: c.uv_write_t = undefined,
    connection: *Connection,
    bytes: []u8,
};

fn runLoop(server: *Impl) void {
    const setup_result = setupLoop(server);
    if (setup_result) |_| {
        server.signalStarted(null);
        _ = c.uv_run(&server.loop, c.UV_RUN_DEFAULT);
        _ = c.uv_loop_close(&server.loop);
        server.lock();
        server.state = .stopped;
        c.uv_cond_broadcast(&server.condition);
        server.unlock();
    } else |err| {
        server.signalStarted(err);
    }
}

fn setupLoop(server: *Impl) StartupError!void {
    if (c.uv_loop_init(&server.loop) < 0) return error.LoopInitializationFailed;
    errdefer _ = c.uv_loop_close(&server.loop);

    if (c.uv_tcp_init(&server.loop, &server.listener) < 0) return error.ListenerInitializationFailed;
    var listener_initialized = true;
    errdefer if (listener_initialized) {
        c.uv_close(@ptrCast(&server.listener), null);
        _ = c.uv_run(&server.loop, c.UV_RUN_DEFAULT);
        listener_initialized = false;
    };
    server.listener.data = server;

    var bind_address: c.struct_sockaddr_in = undefined;
    if (c.uv_ip4_addr(server.host.ptr, server.configured_port, &bind_address) < 0) return error.InvalidAddress;
    if (c.uv_tcp_bind(&server.listener, @ptrCast(&bind_address), 0) < 0) return error.BindFailed;
    if (c.uv_listen(@ptrCast(&server.listener), 128, onConnection) < 0) return error.ListenFailed;

    var local_address: c.struct_sockaddr_in = undefined;
    var address_length: c_int = @sizeOf(c.struct_sockaddr_in);
    if (c.uv_tcp_getsockname(&server.listener, @ptrCast(&local_address), &address_length) < 0) return error.AddressQueryFailed;
    var host_buffer: [16]u8 = undefined;
    if (c.uv_ip4_name(&local_address, &host_buffer, host_buffer.len) < 0) return error.AddressQueryFailed;
    const host = std.mem.sliceTo(&host_buffer, 0);
    @memcpy(server.local_host[0..host.len], host);
    server.local_host_len = host.len;
    server.local_port = std.mem.bigToNative(u16, local_address.sin_port);

    if (c.uv_async_init(&server.loop, &server.shutdown_async, onShutdown) < 0) return error.AsyncInitializationFailed;
    server.shutdown_async.data = server;
    listener_initialized = false;
}

fn onConnection(listener: ?*c.uv_stream_t, connection_status: c_int) callconv(.c) void {
    if (connection_status < 0) return;
    const server: *Impl = @ptrCast(@alignCast(listener.?.*.data.?));
    const connection = server.allocator.create(Connection) catch return;
    connection.* = .{ .server = server };

    if (c.uv_tcp_init(&server.loop, &connection.tcp) < 0) {
        server.allocator.destroy(connection);
        return;
    }
    connection.tcp.data = connection;
    if (c.uv_accept(listener, @ptrCast(&connection.tcp)) < 0) {
        connection.close();
        return;
    }
    connection.initializeSession() catch {
        connection.close();
        return;
    };
    server.connections.append(server.allocator, connection) catch {
        connection.close();
        return;
    };
    if (c.uv_read_start(@ptrCast(&connection.tcp), allocateReadBuffer, onRead) < 0) {
        connection.close();
        return;
    }
    connection.flush() catch connection.close();
}

fn allocateReadBuffer(handle: ?*c.uv_handle_t, suggested_size: usize, buffer: ?*c.uv_buf_t) callconv(.c) void {
    const connection: *Connection = @ptrCast(@alignCast(handle.?.*.data.?));
    const size = @max(suggested_size, 1);
    const bytes = connection.server.allocator.alloc(u8, size) catch {
        buffer.?.* = c.uv_buf_init(null, 0);
        return;
    };
    buffer.?.* = c.uv_buf_init(@ptrCast(bytes.ptr), @intCast(bytes.len));
}

fn onRead(stream_handle: ?*c.uv_stream_t, bytes_read: isize, buffer: ?*const c.uv_buf_t) callconv(.c) void {
    const connection: *Connection = @ptrCast(@alignCast(stream_handle.?.*.data.?));
    defer if (buffer.?.*.base != null) {
        const bytes: [*]u8 = @ptrCast(buffer.?.*.base);
        connection.server.allocator.free(bytes[0..buffer.?.*.len]);
    };
    if (bytes_read < 0) {
        connection.close();
        return;
    }
    if (bytes_read == 0) return;

    const input: [*]const u8 = @ptrCast(buffer.?.*.base);
    const consumed = c.nghttp2_session_mem_recv2(connection.session, input, @intCast(bytes_read));
    if (consumed < 0 or consumed != bytes_read) {
        connection.close();
        return;
    }
    connection.flush() catch connection.close();
}

fn onWrite(request: ?*c.uv_write_t, write_status: c_int) callconv(.c) void {
    const write: *WriteRequest = @ptrCast(@alignCast(request.?.*.data.?));
    const connection = write.connection;
    connection.server.allocator.free(write.bytes);
    connection.server.allocator.destroy(write);
    if (write_status < 0) connection.close();
}

fn onConnectionClosed(handle: ?*c.uv_handle_t) callconv(.c) void {
    const connection: *Connection = @ptrCast(@alignCast(handle.?.*.data.?));
    const server = connection.server;
    if (connection.session) |session| c.nghttp2_session_del(session);
    var iterator = connection.streams.iterator();
    while (iterator.next()) |entry| {
        entry.value_ptr.*.deinit();
        server.allocator.destroy(entry.value_ptr.*);
    }
    connection.streams.deinit(server.allocator);
    for (server.connections.items, 0..) |item, index| {
        if (item == connection) {
            _ = server.connections.swapRemove(index);
            break;
        }
    }
    server.allocator.destroy(connection);
}

fn onShutdown(async_handle: ?*c.uv_async_t) callconv(.c) void {
    const server: *Impl = @ptrCast(@alignCast(async_handle.?.*.data.?));
    if (c.uv_is_closing(@ptrCast(&server.listener)) == 0) c.uv_close(@ptrCast(&server.listener), null);
    for (server.connections.items) |connection| connection.close();
    if (c.uv_is_closing(@ptrCast(&server.shutdown_async)) == 0) c.uv_close(@ptrCast(&server.shutdown_async), null);
}

fn onBeginHeaders(_: ?*c.nghttp2_session, received_frame: ?*const c.nghttp2_frame, user_data: ?*anyopaque) callconv(.c) c_int {
    const native_frame = received_frame.?;
    if (native_frame.*.hd.type != c.NGHTTP2_HEADERS or native_frame.*.headers.cat != c.NGHTTP2_HCAT_REQUEST) return 0;
    const connection: *Connection = @ptrCast(@alignCast(user_data.?));
    const stream = connection.server.allocator.create(Stream) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    stream.* = Stream.init(connection.server.allocator, connection, native_frame.*.hd.stream_id);
    connection.streams.put(connection.server.allocator, stream.id, stream) catch {
        stream.deinit();
        connection.server.allocator.destroy(stream);
        return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    };
    return 0;
}

fn onHeader(
    _: ?*c.nghttp2_session,
    received_frame: ?*const c.nghttp2_frame,
    name_pointer: [*c]const u8,
    name_length: usize,
    value_pointer: [*c]const u8,
    value_length: usize,
    _: u8,
    user_data: ?*anyopaque,
) callconv(.c) c_int {
    const native_frame = received_frame.?;
    if (native_frame.*.headers.cat != c.NGHTTP2_HCAT_REQUEST) return 0;
    const connection: *Connection = @ptrCast(@alignCast(user_data.?));
    const stream = connection.streams.get(native_frame.*.hd.stream_id) orelse return 0;
    const name = name_pointer[0..name_length];
    const value = value_pointer[0..value_length];
    const field_size = std.math.add(usize, name.len, value.len) catch {
        stream.header_too_large = true;
        return 0;
    };
    stream.header_bytes = std.math.add(usize, stream.header_bytes, field_size) catch {
        stream.header_too_large = true;
        return 0;
    };
    if (stream.header_bytes > 64 * 1024) {
        stream.header_too_large = true;
        return 0;
    }

    if (std.mem.eql(u8, name, ":path")) {
        if (stream.path) |old_path| stream.allocator.free(old_path);
        stream.path = stream.allocator.dupe(u8, value) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    } else if (std.mem.eql(u8, name, ":method")) {
        stream.method_post = std.mem.eql(u8, value, "POST");
    } else if (std.mem.eql(u8, name, "content-type")) {
        stream.content_type_grpc = std.mem.startsWith(u8, value, "application/grpc");
    } else if (std.mem.eql(u8, name, "grpc-encoding")) {
        stream.identity_encoding = std.mem.eql(u8, value, "identity");
    } else if (isRequestMetadata(name)) {
        stream.request_metadata.append(name, value) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    }
    return 0;
}

fn onDataChunk(
    _: ?*c.nghttp2_session,
    _: u8,
    stream_id: i32,
    data_pointer: [*c]const u8,
    data_length: usize,
    user_data: ?*anyopaque,
) callconv(.c) c_int {
    const connection: *Connection = @ptrCast(@alignCast(user_data.?));
    const stream = connection.streams.get(stream_id) orelse return 0;
    const body_limit = std.math.add(usize, connection.server.max_request_size, frame.header_size) catch std.math.maxInt(usize);
    if (data_length > body_limit -| stream.request_body.items.len) {
        stream.request_too_large = true;
        return 0;
    }
    stream.request_body.appendSlice(stream.allocator, data_pointer[0..data_length]) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    return 0;
}

fn onFrameReceived(session: ?*c.nghttp2_session, received_frame: ?*const c.nghttp2_frame, user_data: ?*anyopaque) callconv(.c) c_int {
    const native_frame = received_frame.?;
    if ((native_frame.*.hd.type != c.NGHTTP2_HEADERS and native_frame.*.hd.type != c.NGHTTP2_DATA) or
        native_frame.*.hd.flags & c.NGHTTP2_FLAG_END_STREAM == 0)
    {
        return 0;
    }
    const connection: *Connection = @ptrCast(@alignCast(user_data.?));
    const stream = connection.streams.get(native_frame.*.hd.stream_id) orelse return 0;
    if (!stream.responded) finishRequest(session.?, stream);
    return 0;
}

fn finishRequest(session: *c.nghttp2_session, stream: *Stream) void {
    stream.responded = true;
    if (stream.header_too_large or stream.request_too_large) {
        submitFailure(session, stream, .resource_exhausted, "request too large");
        return;
    }
    if (!stream.method_post) {
        submitFailure(session, stream, .unimplemented, "POST required");
        return;
    }
    if (!stream.content_type_grpc) {
        submitFailure(session, stream, .invalid_argument, "invalid content-type");
        return;
    }
    if (!stream.identity_encoding) {
        submitFailure(session, stream, .unimplemented, "compression is not supported");
        return;
    }
    const path = stream.path orelse {
        submitFailure(session, stream, .unimplemented, "method path missing");
        return;
    };
    const handler = stream.connection.server.handlers.get(path) orelse {
        submitFailure(session, stream, .unimplemented, "method not found");
        return;
    };
    const request = frame.decodeUnary(stream.allocator, stream.request_body.items, stream.connection.server.max_request_size) catch |err| {
        switch (err) {
            error.MessageTooLarge => submitFailure(session, stream, .resource_exhausted, "request message too large"),
            error.CompressionUnsupported => submitFailure(session, stream, .unimplemented, "compression is not supported"),
            else => submitFailure(session, stream, .invalid_argument, "malformed unary request"),
        }
        return;
    };
    defer stream.allocator.free(request);

    var context = service.ServerContext.init(stream.allocator);
    defer context.deinit();
    for (stream.request_metadata.items()) |entry| context.request_metadata.append(entry.key, entry.value) catch {
        submitFailure(session, stream, .internal, "metadata allocation failed");
        return;
    };
    var response = handler.invoke(stream.allocator, &context, request) catch {
        submitFailure(session, stream, .internal, "handler failed");
        return;
    };
    defer response.deinit();
    for (context.trailing_metadata.items()) |entry| stream.trailing_metadata.append(entry.key, entry.value) catch {
        submitFailure(session, stream, .internal, "metadata allocation failed");
        return;
    };

    if (response.status.isOk()) {
        stream.response_body = frame.encode(stream.allocator, response.payload) catch {
            submitFailure(session, stream, .internal, "response allocation failed");
            return;
        };
    }
    stream.setStatus(response.status) catch {
        stream.connection.close();
        return;
    };
    submitResponse(session, stream, context.initial_metadata.items()) catch stream.connection.close();
}

fn submitFailure(session: *c.nghttp2_session, stream: *Stream, code: status.Code, text: []const u8) void {
    stream.setStatus(status.Status.init(code, text)) catch {
        stream.connection.close();
        return;
    };
    submitResponse(session, stream, &.{}) catch stream.connection.close();
}

fn submitResponse(session: *c.nghttp2_session, stream: *Stream, initial_metadata: []const metadata.Entry) !void {
    var headers: std.ArrayList(c.nghttp2_nv) = .empty;
    defer headers.deinit(stream.allocator);
    try headers.append(stream.allocator, nativeHeader(":status", "200"));
    try headers.append(stream.allocator, nativeHeader("content-type", "application/grpc"));
    try headers.append(stream.allocator, nativeHeader("grpc-encoding", "identity"));
    for (initial_metadata) |entry| {
        if (!isReservedResponseHeader(entry.key)) try headers.append(stream.allocator, nativeHeader(entry.key, entry.value));
    }
    var provider: c.nghttp2_data_provider2 = .{
        .source = .{ .ptr = stream },
        .read_callback = readResponseData,
    };
    if (c.nghttp2_submit_response2(session, stream.id, headers.items.ptr, headers.items.len, &provider) != 0) return error.NativeFailure;
}

fn readResponseData(
    session: ?*c.nghttp2_session,
    _: i32,
    output: [*c]u8,
    output_length: usize,
    data_flags: ?*u32,
    source: ?*c.nghttp2_data_source,
    _: ?*anyopaque,
) callconv(.c) c.nghttp2_ssize {
    const stream: *Stream = @ptrCast(@alignCast(source.?.*.ptr.?));
    const remaining = stream.response_body[stream.response_offset..];
    const length = @min(remaining.len, output_length);
    if (length != 0) {
        @memcpy(output[0..length], remaining[0..length]);
        stream.response_offset += length;
    }
    if (stream.response_offset == stream.response_body.len) {
        data_flags.?.* |= c.NGHTTP2_DATA_FLAG_EOF | c.NGHTTP2_DATA_FLAG_NO_END_STREAM;
        if (!stream.trailer_submitted) {
            stream.trailer_submitted = true;
            submitTrailers(session.?, stream) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
        }
    }
    return @intCast(length);
}

fn submitTrailers(session: *c.nghttp2_session, stream: *Stream) !void {
    var trailers: std.ArrayList(c.nghttp2_nv) = .empty;
    defer trailers.deinit(stream.allocator);
    for (stream.trailing_metadata.items()) |entry| {
        if (!isReservedTrailer(entry.key)) try trailers.append(stream.allocator, nativeHeader(entry.key, entry.value));
    }
    var code_buffer: [3]u8 = undefined;
    const code = try std.fmt.bufPrint(&code_buffer, "{d}", .{@intFromEnum(stream.response_code)});
    try trailers.append(stream.allocator, nativeHeader("grpc-status", code));
    const encoded = try message.encode(stream.allocator, stream.response_message);
    defer stream.allocator.free(encoded);
    try trailers.append(stream.allocator, nativeHeader("grpc-message", encoded));
    if (c.nghttp2_submit_trailer(session, stream.id, trailers.items.ptr, trailers.items.len) != 0) return error.NativeFailure;
}

fn onStreamClose(_: ?*c.nghttp2_session, stream_id: i32, _: u32, user_data: ?*anyopaque) callconv(.c) c_int {
    const connection: *Connection = @ptrCast(@alignCast(user_data.?));
    if (connection.streams.fetchRemove(stream_id)) |entry| {
        entry.value.deinit();
        connection.server.allocator.destroy(entry.value);
    }
    return 0;
}

fn nativeHeader(name: []const u8, value: []const u8) c.nghttp2_nv {
    return .{
        .name = @ptrCast(@constCast(name.ptr)),
        .value = @ptrCast(@constCast(value.ptr)),
        .namelen = name.len,
        .valuelen = value.len,
        .flags = c.NGHTTP2_NV_FLAG_NONE,
    };
}

fn isValidMethodPath(path: []const u8) bool {
    if (path.len < 4 or path[0] != '/') return false;
    const separator = std.mem.indexOfScalarPos(u8, path, 1, '/') orelse return false;
    return separator > 1 and separator + 1 < path.len and std.mem.indexOfScalarPos(u8, path, separator + 1, '/') == null;
}

fn isRequestMetadata(name: []const u8) bool {
    if (name.len == 0 or name[0] == ':') return false;
    const protocol_headers = [_][]const u8{
        "content-type", "te", "grpc-encoding", "grpc-accept-encoding", "grpc-timeout", "user-agent",
    };
    for (protocol_headers) |header| if (std.mem.eql(u8, name, header)) return false;
    return metadata.isValidKey(name);
}

fn isReservedResponseHeader(name: []const u8) bool {
    return std.mem.eql(u8, name, "content-type") or
        std.mem.eql(u8, name, "grpc-encoding") or
        std.mem.eql(u8, name, "grpc-status") or
        std.mem.eql(u8, name, "grpc-message");
}

fn isReservedTrailer(name: []const u8) bool {
    return std.mem.eql(u8, name, "grpc-status") or std.mem.eql(u8, name, "grpc-message");
}

test "server validates registration and has deterministic lifecycle" {
    const Handler = struct {
        fn handle(_: *@This(), allocator: std.mem.Allocator, _: *service.ServerContext, request: []const u8) !service.UnaryResponse {
            return service.UnaryResponse.ok(allocator, request);
        }
    };

    var handler_context = Handler{};
    var server = try Server.init(std.testing.allocator, .{});
    defer server.deinit();
    try std.testing.expectError(error.InvalidMethodPath, server.registerUnary("invalid", service.UnaryHandler.bind(Handler, &handler_context, Handler.handle)));
    try server.registerUnary("/test.Echo/Unary", service.UnaryHandler.bind(Handler, &handler_context, Handler.handle));
    try std.testing.expectError(error.MethodAlreadyRegistered, server.registerUnary("/test.Echo/Unary", service.UnaryHandler.bind(Handler, &handler_context, Handler.handle)));

    try server.start();
    const address = try server.localAddress();
    try std.testing.expectEqualStrings("127.0.0.1", address.host);
    try std.testing.expect(address.port != 0);
    try std.testing.expectEqual(address.port, try server.port());
    server.shutdown();
    server.wait();
}

test "raw HTTP/2 request routes unary data and ends with trailers" {
    const Handler = struct {
        saw_metadata: bool = false,

        fn handle(self: *@This(), allocator: std.mem.Allocator, context: *service.ServerContext, request: []const u8) !service.UnaryResponse {
            self.saw_metadata = std.mem.eql(u8, context.request_metadata.getFirst("x-test") orelse "", "value");
            try std.testing.expectEqualStrings("ping", request);
            try context.addInitialMetadata("x-initial", "yes");
            try context.addTrailingMetadata("x-trailing", "yes");
            return service.UnaryResponse.ok(allocator, "pong");
        }
    };

    var handler_context = Handler{};
    var server = try Server.init(std.testing.allocator, .{});
    defer server.deinit();
    try server.registerUnary(
        "/test.Echo/Unary",
        service.UnaryHandler.bind(Handler, &handler_context, Handler.handle),
    );

    var connection = Connection{ .server = server.impl };
    try connection.initializeSession();
    defer {
        if (connection.session) |session| c.nghttp2_session_del(session);
        var iterator = connection.streams.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.*.deinit();
            std.testing.allocator.destroy(entry.value_ptr.*);
        }
        connection.streams.deinit(std.testing.allocator);
    }

    const header_block = [_]u8{
        0x83, 0x86, // :method POST, :scheme http
        0x04, 0x10,
    } ++ "/test.Echo/Unary" ++ [_]u8{
        0x01, 0x09,
    } ++ "localhost" ++ [_]u8{
        0x0f, 0x10, 0x10,
    } ++ "application/grpc" ++ [_]u8{
        0x00, 0x02,
    } ++ "te" ++ [_]u8{
        0x08,
    } ++ "trailers" ++ [_]u8{
        0x00, 0x06,
    } ++ "x-test" ++ [_]u8{
        0x05,
    } ++ "value";
    const headers_frame = [_]u8{
        @intCast(header_block.len >> 16),
        @intCast(header_block.len >> 8),
        @intCast(header_block.len),
        c.NGHTTP2_HEADERS,
        c.NGHTTP2_FLAG_END_HEADERS,
        0,
        0,
        0,
        1,
    } ++ header_block;
    const data_frame = [_]u8{
        0,
        0,
        9,
        c.NGHTTP2_DATA,
        c.NGHTTP2_FLAG_END_STREAM,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        4,
    } ++ "ping";
    const wire = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" ++ [_]u8{
        0, 0, 0, c.NGHTTP2_SETTINGS, 0, 0, 0, 0, 0,
    } ++ headers_frame ++ data_frame;

    const fragments = [_][]const u8{ wire[0..7], wire[7..31], wire[31..68], wire[68..] };
    for (fragments) |fragment| {
        const consumed = c.nghttp2_session_mem_recv2(connection.session, fragment.ptr, fragment.len);
        try std.testing.expectEqual(@as(c.nghttp2_ssize, @intCast(fragment.len)), consumed);
    }

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    while (true) {
        var bytes: [*c]const u8 = null;
        const length = c.nghttp2_session_mem_send2(connection.session, &bytes);
        try std.testing.expect(length >= 0);
        if (length == 0) break;
        try output.appendSlice(std.testing.allocator, bytes[0..@intCast(length)]);
    }

    var response_data: std.ArrayList(u8) = .empty;
    defer response_data.deinit(std.testing.allocator);
    var saw_final_trailers = false;
    var offset: usize = 0;
    while (offset + 9 <= output.items.len) {
        const payload_length = (@as(usize, output.items[offset]) << 16) |
            (@as(usize, output.items[offset + 1]) << 8) |
            output.items[offset + 2];
        const end = offset + 9 + payload_length;
        try std.testing.expect(end <= output.items.len);
        const frame_type = output.items[offset + 3];
        const flags = output.items[offset + 4];
        const stream_id = (@as(u32, output.items[offset + 5] & 0x7f) << 24) |
            (@as(u32, output.items[offset + 6]) << 16) |
            (@as(u32, output.items[offset + 7]) << 8) |
            output.items[offset + 8];
        if (stream_id == 1 and frame_type == c.NGHTTP2_DATA) {
            try response_data.appendSlice(std.testing.allocator, output.items[offset + 9 .. end]);
        }
        if (stream_id == 1 and frame_type == c.NGHTTP2_HEADERS and flags & c.NGHTTP2_FLAG_END_STREAM != 0) {
            saw_final_trailers = true;
        }
        offset = end;
    }
    try std.testing.expectEqual(output.items.len, offset);
    const expected_response = try frame.encode(std.testing.allocator, "pong");
    defer std.testing.allocator.free(expected_response);
    try std.testing.expectEqualSlices(u8, expected_response, response_data.items);
    try std.testing.expect(saw_final_trailers);
    try std.testing.expect(handler_context.saw_metadata);
}
