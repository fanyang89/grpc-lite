const std = @import("std");
const c = @import("c.zig").api;
const Compression = @import("compression.zig").Compression;
const deadline = @import("deadline.zig");
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
        if (impl.state != .running and impl.state != .draining and impl.state != .stopping) return error.ServerNotRunning;
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
            .starting => impl.shutdown_request = .immediate,
            .running => {
                impl.shutdown_request = .immediate;
                impl.state = .stopping;
                _ = c.uv_async_send(&impl.shutdown_async);
            },
            .draining => {
                impl.shutdown_request = .immediate;
                impl.state = .stopping;
                _ = c.uv_async_send(&impl.shutdown_async);
            },
            .stopping, .stopped => {},
        }
    }

    pub fn shutdownGracefully(self: *Server, timeout_ns: u64) void {
        const impl = self.impl;
        impl.lock();
        defer impl.unlock();
        switch (impl.state) {
            .initialized => impl.state = .stopped,
            .starting => if (impl.shutdown_request == .none) {
                impl.shutdown_request = .graceful;
                impl.drain_timeout_ns = timeout_ns;
            },
            .running => {
                impl.shutdown_request = .graceful;
                impl.drain_timeout_ns = timeout_ns;
                impl.state = .draining;
                _ = c.uv_async_send(&impl.shutdown_async);
            },
            .draining, .stopping, .stopped => {},
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

const State = enum { initialized, starting, running, draining, stopping, stopped };
const ShutdownRequest = enum { none, graceful, immediate };
const StartupError = error{
    LoopInitializationFailed,
    InvalidAddress,
    ListenerInitializationFailed,
    BindFailed,
    ListenFailed,
    AddressQueryFailed,
    AsyncInitializationFailed,
    TimerInitializationFailed,
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
    shutdown_request: ShutdownRequest = .none,
    drain_timeout_ns: u64 = 0,
    startup_error: ?StartupError = null,
    thread: ?std.Thread = null,
    loop: c.uv_loop_t = undefined,
    listener: c.uv_tcp_t = undefined,
    shutdown_async: c.uv_async_t = undefined,
    drain_timer: c.uv_timer_t = undefined,
    deadline_timer: c.uv_timer_t = undefined,
    deadline_timer_initialized: bool = false,
    drain_started: bool = false,
    clock: deadline.Clock = .{ .now_fn = uvNow },
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
        self.startup_error = result;
        self.state = if (result != null)
            .stopped
        else switch (self.shutdown_request) {
            .none => .running,
            .graceful => .draining,
            .immediate => .stopping,
        };
        c.uv_cond_broadcast(&self.condition);
        const should_shutdown = result == null and self.shutdown_request != .none;
        self.unlock();
        if (should_shutdown) _ = c.uv_async_send(&self.shutdown_async);
    }
};

const Stream = struct {
    allocator: std.mem.Allocator,
    connection: *Connection,
    id: i32,
    path: ?[]u8 = null,
    method_post: bool = false,
    content_type_grpc: bool = false,
    request_compression: ?Compression = .identity,
    accepts_response_gzip: bool = false,
    response_compression: Compression = .identity,
    timeout_seen: bool = false,
    timeout_invalid: bool = false,
    deadline: ?deadline.Deadline = null,
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
    highest_accepted_stream_id: i32 = 0,
    pending_writes: usize = 0,
    draining: bool = false,
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
            self.pending_writes += 1;
            if (c.uv_write(&write.req, @ptrCast(&self.tcp), &buffer, 1, onWrite) < 0) {
                self.pending_writes -= 1;
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

    var listener_initialized = false;
    var async_initialized = false;
    var drain_timer_initialized = false;
    var deadline_timer_initialized = false;
    errdefer {
        if (deadline_timer_initialized) c.uv_close(@ptrCast(&server.deadline_timer), null);
        if (drain_timer_initialized) c.uv_close(@ptrCast(&server.drain_timer), null);
        if (async_initialized) c.uv_close(@ptrCast(&server.shutdown_async), null);
        if (listener_initialized) c.uv_close(@ptrCast(&server.listener), null);
        _ = c.uv_run(&server.loop, c.UV_RUN_DEFAULT);
    }

    if (c.uv_tcp_init(&server.loop, &server.listener) < 0) return error.ListenerInitializationFailed;
    listener_initialized = true;
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
    async_initialized = true;
    server.shutdown_async.data = server;

    if (c.uv_timer_init(&server.loop, &server.drain_timer) < 0) return error.TimerInitializationFailed;
    drain_timer_initialized = true;
    server.drain_timer.data = server;

    if (c.uv_timer_init(&server.loop, &server.deadline_timer) < 0) return error.TimerInitializationFailed;
    deadline_timer_initialized = true;
    server.deadline_timer_initialized = true;
    server.deadline_timer.data = server;
}

fn onConnection(listener: ?*c.uv_stream_t, connection_status: c_int) callconv(.c) void {
    if (connection_status < 0) return;
    const server: *Impl = @ptrCast(@alignCast(listener.?.*.data.?));
    server.lock();
    const accepting = server.state == .running;
    server.unlock();
    if (!accepting) return;

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
    connection.pending_writes -= 1;
    connection.server.allocator.free(write.bytes);
    connection.server.allocator.destroy(write);
    if (write_status < 0) {
        connection.close();
    } else {
        maybeCloseDrainedConnection(connection);
    }
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
    finishDrainIfIdle(server);
}

fn onShutdown(async_handle: ?*c.uv_async_t) callconv(.c) void {
    const server: *Impl = @ptrCast(@alignCast(async_handle.?.*.data.?));
    server.lock();
    const state = server.state;
    server.unlock();
    switch (state) {
        .draining => beginDrain(server),
        .stopping => stopImmediately(server),
        else => {},
    }
}

fn beginDrain(server: *Impl) void {
    if (!server.drain_started) {
        server.drain_started = true;
        if (c.uv_is_closing(@ptrCast(&server.listener)) == 0) c.uv_close(@ptrCast(&server.listener), null);

        const timeout_ms = if (server.drain_timeout_ns == 0)
            0
        else
            std.math.divCeil(u64, server.drain_timeout_ns, std.time.ns_per_ms) catch std.math.maxInt(u64);
        _ = c.uv_timer_start(&server.drain_timer, onDrainTimeout, timeout_ms, 0);

        for (server.connections.items) |connection| {
            if (connection.closing or connection.session == null) continue;
            connection.draining = true;
            if (c.nghttp2_submit_goaway(
                connection.session,
                c.NGHTTP2_FLAG_NONE,
                connection.highest_accepted_stream_id,
                c.NGHTTP2_NO_ERROR,
                null,
                0,
            ) != 0) {
                connection.close();
                continue;
            }
            connection.flush() catch connection.close();
        }
    }

    for (server.connections.items) |connection| maybeCloseDrainedConnection(connection);
    finishDrainIfIdle(server);
}

fn maybeCloseDrainedConnection(connection: *Connection) void {
    if (connection.draining and !connection.closing and connection.streams.count() == 0 and connection.pending_writes == 0) {
        connection.close();
    }
}

fn finishDrainIfIdle(server: *Impl) void {
    server.lock();
    const draining = server.state == .draining;
    server.unlock();
    if (!draining or server.connections.items.len != 0) return;
    closeControlHandles(server);
}

fn onDrainTimeout(handle: ?*c.uv_timer_t) callconv(.c) void {
    const server: *Impl = @ptrCast(@alignCast(handle.?.*.data.?));
    server.lock();
    if (server.state == .draining) server.state = .stopping;
    server.unlock();
    stopImmediately(server);
}

fn stopImmediately(server: *Impl) void {
    if (c.uv_is_closing(@ptrCast(&server.listener)) == 0) c.uv_close(@ptrCast(&server.listener), null);
    for (server.connections.items) |connection| connection.close();
    closeControlHandles(server);
}

fn closeControlHandles(server: *Impl) void {
    if (server.deadline_timer_initialized) {
        server.deadline_timer_initialized = false;
        _ = c.uv_timer_stop(&server.deadline_timer);
        if (c.uv_is_closing(@ptrCast(&server.deadline_timer)) == 0) c.uv_close(@ptrCast(&server.deadline_timer), null);
    }
    _ = c.uv_timer_stop(&server.drain_timer);
    if (c.uv_is_closing(@ptrCast(&server.drain_timer)) == 0) c.uv_close(@ptrCast(&server.drain_timer), null);
    if (c.uv_is_closing(@ptrCast(&server.shutdown_async)) == 0) c.uv_close(@ptrCast(&server.shutdown_async), null);
}

fn onBeginHeaders(session: ?*c.nghttp2_session, received_frame: ?*const c.nghttp2_frame, user_data: ?*anyopaque) callconv(.c) c_int {
    const native_frame = received_frame.?;
    if (native_frame.*.hd.type != c.NGHTTP2_HEADERS or native_frame.*.headers.cat != c.NGHTTP2_HCAT_REQUEST) return 0;
    const connection: *Connection = @ptrCast(@alignCast(user_data.?));
    if (connection.draining) {
        _ = c.nghttp2_submit_rst_stream(session, c.NGHTTP2_FLAG_NONE, native_frame.*.hd.stream_id, c.NGHTTP2_REFUSED_STREAM);
        return c.NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
    }
    const stream = connection.server.allocator.create(Stream) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    stream.* = Stream.init(connection.server.allocator, connection, native_frame.*.hd.stream_id);
    connection.streams.put(connection.server.allocator, stream.id, stream) catch {
        stream.deinit();
        connection.server.allocator.destroy(stream);
        return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    };
    connection.highest_accepted_stream_id = @max(connection.highest_accepted_stream_id, stream.id);
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
        stream.request_compression = Compression.parse(value);
    } else if (std.mem.eql(u8, name, "grpc-accept-encoding")) {
        stream.accepts_response_gzip = stream.accepts_response_gzip or acceptsEncoding(value, .gzip);
    } else if (std.mem.eql(u8, name, "grpc-timeout")) {
        if (stream.timeout_seen) {
            stream.timeout_invalid = true;
            stream.deadline = null;
        } else {
            stream.timeout_seen = true;
            const timeout_ns = deadline.parseTimeout(value) catch {
                stream.timeout_invalid = true;
                return 0;
            };
            stream.deadline = deadline.Deadline.initAfter(connection.server.clock, timeout_ns);
        }
        scheduleDeadlineTimer(connection.server);
    } else if (isRequestMetadata(name)) {
        stream.request_metadata.appendDecoded(name, value) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
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
    if (stream.responded) return 0;
    const body_limit = wireMessageLimit(connection.server.max_request_size);
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
    scheduleDeadlineTimer(stream.connection.server);
    if (stream.header_too_large or stream.request_too_large) {
        submitFailure(session, stream, .resource_exhausted, "request too large");
        return;
    }
    if (stream.timeout_invalid) {
        submitFailure(session, stream, .invalid_argument, "invalid grpc-timeout");
        return;
    }
    if (stream.deadline) |value| {
        if (value.isExceeded()) {
            submitFailure(session, stream, .deadline_exceeded, "deadline exceeded");
            return;
        }
    }
    if (!stream.method_post) {
        submitFailure(session, stream, .unimplemented, "POST required");
        return;
    }
    if (!stream.content_type_grpc) {
        submitFailure(session, stream, .invalid_argument, "invalid content-type");
        return;
    }
    const request_compression = stream.request_compression orelse {
        submitFailure(session, stream, .unimplemented, "request compression is not supported");
        return;
    };
    const path = stream.path orelse {
        submitFailure(session, stream, .unimplemented, "method path missing");
        return;
    };
    const handler = stream.connection.server.handlers.get(path) orelse {
        submitFailure(session, stream, .unimplemented, "method not found");
        return;
    };
    const request = frame.decodeUnaryWithCompression(
        stream.allocator,
        stream.request_body.items,
        stream.connection.server.max_request_size,
        request_compression,
    ) catch |err| {
        switch (err) {
            error.MessageTooLarge => submitFailure(session, stream, .resource_exhausted, "request message too large"),
            else => submitFailure(session, stream, .invalid_argument, "malformed unary request"),
        }
        return;
    };
    defer stream.allocator.free(request);

    var context = service.ServerContext.init(stream.allocator);
    defer context.deinit();
    context.deadline = stream.deadline;
    context.request_compression = if (stream.request_body.items[0] == 1) .gzip else .identity;
    for (stream.request_metadata.items()) |entry| context.request_metadata.append(entry.key, entry.value) catch {
        submitFailure(session, stream, .internal, "metadata allocation failed");
        return;
    };
    var response = handler.invoke(stream.allocator, &context, request) catch {
        submitFailure(session, stream, .internal, "handler failed");
        return;
    };
    defer response.deinit();
    if (context.isDeadlineExceeded()) {
        submitFailure(session, stream, .deadline_exceeded, "deadline exceeded");
        return;
    }
    stream.response_compression = if (context.response_compression == .gzip and stream.accepts_response_gzip)
        .gzip
    else
        .identity;
    for (context.trailing_metadata.items()) |entry| stream.trailing_metadata.append(entry.key, entry.value) catch {
        submitFailure(session, stream, .internal, "metadata allocation failed");
        return;
    };

    if (response.status.isOk()) {
        stream.response_body = frame.encodeWithCompression(
            stream.allocator,
            response.payload,
            stream.response_compression,
        ) catch {
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
    var encoded_values: std.ArrayList([]u8) = .empty;
    defer {
        for (encoded_values.items) |value| stream.allocator.free(value);
        encoded_values.deinit(stream.allocator);
    }
    try headers.append(stream.allocator, nativeHeader(":status", "200"));
    try headers.append(stream.allocator, nativeHeader("content-type", "application/grpc"));
    try headers.append(stream.allocator, nativeHeader("grpc-encoding", stream.response_compression.name()));
    try headers.append(stream.allocator, nativeHeader("grpc-accept-encoding", "identity,gzip"));
    for (initial_metadata) |entry| {
        if (!isReservedResponseHeader(entry.key)) {
            const value = try metadata.encodeValue(stream.allocator, entry.key, entry.value);
            encoded_values.append(stream.allocator, value) catch |err| {
                stream.allocator.free(value);
                return err;
            };
            try headers.append(stream.allocator, nativeHeader(entry.key, value));
        }
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
    var encoded_values: std.ArrayList([]u8) = .empty;
    defer {
        for (encoded_values.items) |value| stream.allocator.free(value);
        encoded_values.deinit(stream.allocator);
    }
    for (stream.trailing_metadata.items()) |entry| {
        if (!isReservedTrailer(entry.key)) {
            const value = try metadata.encodeValue(stream.allocator, entry.key, entry.value);
            encoded_values.append(stream.allocator, value) catch |err| {
                stream.allocator.free(value);
                return err;
            };
            try trailers.append(stream.allocator, nativeHeader(entry.key, value));
        }
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
    scheduleDeadlineTimer(connection.server);
    if (connection.draining) _ = c.uv_async_send(&connection.server.shutdown_async);
    return 0;
}

fn uvNow(_: ?*anyopaque) u64 {
    return c.uv_hrtime();
}

fn scheduleDeadlineTimer(server: *Impl) void {
    if (!server.deadline_timer_initialized or c.uv_is_closing(@ptrCast(&server.deadline_timer)) != 0) return;
    var earliest: ?u64 = null;
    for (server.connections.items) |connection| {
        var iterator = connection.streams.valueIterator();
        while (iterator.next()) |stream_ptr| {
            const stream = stream_ptr.*;
            if (stream.responded) continue;
            if (stream.deadline) |value| {
                if (earliest == null or value.expires_at_ns < earliest.?) earliest = value.expires_at_ns;
            }
        }
    }
    if (earliest == null) {
        _ = c.uv_timer_stop(&server.deadline_timer);
        return;
    }
    const remaining = earliest.? -| server.clock.now();
    const timeout_ms = @max(@as(u64, 1), std.math.divCeil(u64, remaining, std.time.ns_per_ms) catch 1);
    _ = c.uv_timer_start(&server.deadline_timer, onDeadlineTimer, timeout_ms, 0);
}

fn onDeadlineTimer(handle: ?*c.uv_timer_t) callconv(.c) void {
    const server: *Impl = @ptrCast(@alignCast(handle.?.*.data.?));
    const now = server.clock.now();
    expireDeadlines(server, now);
    for (server.connections.items) |connection| {
        if (connection.closing or connection.session == null) continue;
        connection.flush() catch connection.close();
    }
    scheduleDeadlineTimer(server);
}

fn expireDeadlines(server: *Impl, now: u64) void {
    for (server.connections.items) |connection| {
        if (connection.closing or connection.session == null) continue;
        var iterator = connection.streams.valueIterator();
        while (iterator.next()) |stream_ptr| {
            const stream = stream_ptr.*;
            if (stream.responded) continue;
            if (stream.deadline) |value| {
                if (value.expires_at_ns <= now) {
                    stream.responded = true;
                    submitFailure(connection.session.?, stream, .deadline_exceeded, "deadline exceeded");
                }
            }
        }
    }
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

fn acceptsEncoding(value: []const u8, encoding: Compression) bool {
    var values = std.mem.splitScalar(u8, value, ',');
    while (values.next()) |item| {
        if (std.mem.eql(u8, std.mem.trim(u8, item, " \t"), encoding.name())) return true;
    }
    return false;
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
        std.mem.eql(u8, name, "grpc-accept-encoding") or
        std.mem.eql(u8, name, "grpc-status") or
        std.mem.eql(u8, name, "grpc-message");
}

fn wireMessageLimit(max_message_size: usize) usize {
    const overhead = std.math.add(usize, max_message_size / 8, 1024) catch return std.math.maxInt(usize);
    const total_overhead = std.math.add(usize, overhead, frame.header_size) catch return std.math.maxInt(usize);
    return std.math.add(usize, max_message_size, total_overhead) catch std.math.maxInt(usize);
}

fn isReservedTrailer(name: []const u8) bool {
    return std.mem.eql(u8, name, "grpc-status") or std.mem.eql(u8, name, "grpc-message");
}

fn appendTestHeader(block: *std.ArrayList(u8), name: []const u8, value: []const u8) !void {
    try block.append(std.testing.allocator, 0);
    try block.append(std.testing.allocator, @intCast(name.len));
    try block.appendSlice(std.testing.allocator, name);
    try block.append(std.testing.allocator, @intCast(value.len));
    try block.appendSlice(std.testing.allocator, value);
}

fn feedTestRequest(connection: *Connection, timeout_values: []const []const u8, end_stream: bool) !void {
    var header_block: std.ArrayList(u8) = .empty;
    defer header_block.deinit(std.testing.allocator);
    try header_block.appendSlice(std.testing.allocator, &.{ 0x83, 0x86, 0x04, 0x10 });
    try header_block.appendSlice(std.testing.allocator, "/test.Echo/Unary");
    try header_block.appendSlice(std.testing.allocator, &.{ 0x01, 0x09 });
    try header_block.appendSlice(std.testing.allocator, "localhost");
    try appendTestHeader(&header_block, "content-type", "application/grpc");
    for (timeout_values) |value| try appendTestHeader(&header_block, "grpc-timeout", value);

    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try wire.appendSlice(std.testing.allocator, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n");
    try wire.appendSlice(std.testing.allocator, &.{ 0, 0, 0, c.NGHTTP2_SETTINGS, 0, 0, 0, 0, 0 });
    try wire.appendSlice(std.testing.allocator, &.{
        @intCast(header_block.items.len >> 16),
        @intCast(header_block.items.len >> 8),
        @intCast(header_block.items.len),
        c.NGHTTP2_HEADERS,
        @as(u8, @intCast(c.NGHTTP2_FLAG_END_HEADERS)) |
            if (end_stream) @as(u8, @intCast(c.NGHTTP2_FLAG_END_STREAM)) else 0,
        0,
        0,
        0,
        1,
    });
    try wire.appendSlice(std.testing.allocator, header_block.items);

    const consumed = c.nghttp2_session_mem_recv2(connection.session, wire.items.ptr, wire.items.len);
    try std.testing.expectEqual(@as(c.nghttp2_ssize, @intCast(wire.items.len)), consumed);
}

fn deinitTestConnection(connection: *Connection) void {
    if (connection.session) |session| c.nghttp2_session_del(session);
    var iterator = connection.streams.iterator();
    while (iterator.next()) |entry| {
        entry.value_ptr.*.deinit();
        std.testing.allocator.destroy(entry.value_ptr.*);
    }
    connection.streams.deinit(std.testing.allocator);
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

test "graceful shutdown exits when idle and is idempotent" {
    var server = try Server.init(std.testing.allocator, .{});
    defer server.deinit();
    try server.start();

    server.shutdownGracefully(std.time.ns_per_s);
    const address = try server.localAddress();
    try std.testing.expect(address.port != 0);
    server.shutdownGracefully(0);
    server.wait();

    server.shutdownGracefully(0);
    server.shutdown();
}

test "graceful shutdown before start is idempotent" {
    var server = try Server.init(std.testing.allocator, .{});
    defer server.deinit();
    server.shutdownGracefully(0);
    server.shutdownGracefully(std.time.ns_per_s);
    server.shutdown();
    server.wait();
    try std.testing.expectError(error.ServerAlreadyStarted, server.start());
}

test "raw HTTP/2 request routes unary data and ends with trailers" {
    const Handler = struct {
        saw_metadata: bool = false,

        fn handle(self: *@This(), allocator: std.mem.Allocator, context: *service.ServerContext, request: []const u8) !service.UnaryResponse {
            self.saw_metadata = std.mem.eql(u8, context.request_metadata.getFirst("x-test") orelse "", "value");
            try std.testing.expectEqualStrings("ping", request);
            context.setResponseCompression(.gzip);
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

test "response encoding list parsing" {
    try std.testing.expect(acceptsEncoding("gzip", .gzip));
    try std.testing.expect(acceptsEncoding("identity, gzip", .gzip));
    try std.testing.expect(acceptsEncoding("identity,unknown,\tgzip ", .gzip));
    try std.testing.expect(!acceptsEncoding("identity", .gzip));
    try std.testing.expect(!acceptsEncoding("xgzip", .gzip));
}

test "expired and malformed grpc-timeout values fail only their stream" {
    const Handler = struct {
        calls: usize = 0,

        fn handle(self: *@This(), allocator: std.mem.Allocator, _: *service.ServerContext, request: []const u8) !service.UnaryResponse {
            self.calls += 1;
            return service.UnaryResponse.ok(allocator, request);
        }
    };

    const cases = [_]struct {
        values: []const []const u8,
        expected: status.Code,
    }{
        .{ .values = &.{"0n"}, .expected = .deadline_exceeded },
        .{ .values = &.{""}, .expected = .invalid_argument },
        .{ .values = &.{"1"}, .expected = .invalid_argument },
        .{ .values = &.{"123456789n"}, .expected = .invalid_argument },
        .{ .values = &.{"1x"}, .expected = .invalid_argument },
        .{ .values = &.{ "1S", "2S" }, .expected = .invalid_argument },
    };

    var handler = Handler{};
    var server = try Server.init(std.testing.allocator, .{});
    defer server.deinit();
    try server.registerUnary(
        "/test.Echo/Unary",
        service.UnaryHandler.bind(Handler, &handler, Handler.handle),
    );

    for (cases) |case| {
        var connection = Connection{ .server = server.impl };
        try connection.initializeSession();
        defer deinitTestConnection(&connection);
        try feedTestRequest(&connection, case.values, true);
        const stream = connection.streams.get(1).?;
        try std.testing.expect(stream.timeout_seen);
        try std.testing.expect(stream.responded);
        if (case.expected == .deadline_exceeded) {
            try std.testing.expect(stream.deadline != null);
            try std.testing.expect(stream.deadline.?.isExceeded());
        }
        try std.testing.expectEqual(case.expected, stream.response_code);
        try std.testing.expect(!connection.closing);
    }
    try std.testing.expectEqual(@as(usize, 0), handler.calls);
}

test "deadline expiration completes a stream before request body end" {
    var server = try Server.init(std.testing.allocator, .{});
    defer server.deinit();
    var connection = Connection{ .server = server.impl };
    try connection.initializeSession();
    defer deinitTestConnection(&connection);
    try server.impl.connections.append(std.testing.allocator, &connection);
    defer _ = server.impl.connections.pop();

    try feedTestRequest(&connection, &.{"0n"}, false);
    const stream = connection.streams.get(1).?;
    try std.testing.expect(!stream.responded);
    expireDeadlines(server.impl, server.impl.clock.now());
    try std.testing.expect(stream.responded);
    try std.testing.expectEqual(status.Code.deadline_exceeded, stream.response_code);
    try std.testing.expect(!connection.closing);
}
