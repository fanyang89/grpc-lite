const std = @import("std");
const c = @import("c.zig").api;
const call = @import("call.zig");
const Compression = @import("compression.zig").Compression;
const frame = @import("frame.zig");
const message = @import("message.zig");
const metadata = @import("metadata.zig");
const status = @import("status.zig");

const ChannelOptions = struct {
    user_agent: []const u8 = "grpc-lite/0.1.0",
};

pub const Options = ChannelOptions;

pub const Channel = struct {
    pub const Options = ChannelOptions;

    impl: *Impl,

    pub fn init(allocator: std.mem.Allocator, target: []const u8, options: ChannelOptions) !Channel {
        const parsed = try parseTarget(target);
        const impl = try allocator.create(Impl);
        errdefer allocator.destroy(impl);

        const host = try allocator.dupeZ(u8, parsed.host);
        errdefer allocator.free(host);
        const authority = try allocator.dupe(u8, target);
        errdefer allocator.free(authority);
        const user_agent = try allocator.dupe(u8, options.user_agent);
        errdefer allocator.free(user_agent);

        impl.* = .{
            .allocator = allocator,
            .host = host,
            .port = parsed.port,
            .authority = authority,
            .user_agent = user_agent,
        };
        if (c.uv_mutex_init(&impl.mutex) < 0) return error.SynchronizationInitializationFailed;
        errdefer c.uv_mutex_destroy(&impl.mutex);
        if (c.uv_cond_init(&impl.condition) < 0) return error.SynchronizationInitializationFailed;
        errdefer c.uv_cond_destroy(&impl.condition);
        impl.thread = try std.Thread.spawn(.{}, runLoop, .{impl});

        c.uv_mutex_lock(&impl.mutex);
        while (impl.state == .starting) c.uv_cond_wait(&impl.condition, &impl.mutex);
        const running = impl.state == .running;
        c.uv_mutex_unlock(&impl.mutex);
        if (!running) {
            impl.thread.?.join();
            impl.thread = null;
            impl.pending.deinit(allocator);
            c.uv_cond_destroy(&impl.condition);
            c.uv_mutex_destroy(&impl.mutex);
            allocator.free(user_agent);
            allocator.free(authority);
            allocator.free(host);
            allocator.destroy(impl);
            return error.ConnectionFailed;
        }

        return .{ .impl = impl };
    }

    pub fn callUnary(
        self: *Channel,
        allocator: std.mem.Allocator,
        full_method_path: []const u8,
        request: []const u8,
        options: call.Options,
    ) !call.Result {
        if (!isValidMethodPath(full_method_path)) return error.InvalidMethodPath;
        if (options.max_response_size > std.math.maxInt(u32)) return error.InvalidMaxResponseSize;

        const operation = try Operation.init(self.impl, full_method_path, request, options);
        defer operation.deinit();

        const queued = try self.impl.enqueue(operation);
        if (!queued) operation.setOutcome(.unavailable, "channel is unavailable") catch {};
        if (!queued) operation.complete();
        operation.wait();

        var result = try call.Result.initWithCompression(
            allocator,
            .init(operation.response_code, operation.response_message),
            if (operation.response_payload) |payload| payload else &.{},
            operation.response_compression,
        );
        errdefer result.deinit();
        try copyMetadata(&result.initial_metadata, &operation.initial_metadata);
        try copyMetadata(&result.trailing_metadata, &operation.trailing_metadata);
        return result;
    }

    pub fn shutdown(self: *Channel) void {
        const impl = self.impl;
        c.uv_mutex_lock(&impl.mutex);
        if (impl.state == .running) {
            impl.state = .stopping;
            _ = c.uv_async_send(&impl.async_handle);
        }
        c.uv_mutex_unlock(&impl.mutex);
    }

    pub fn wait(self: *Channel) void {
        const impl = self.impl;
        c.uv_mutex_lock(&impl.mutex);
        const thread = impl.thread;
        impl.thread = null;
        c.uv_mutex_unlock(&impl.mutex);
        if (thread) |running_thread| running_thread.join();
    }

    pub fn deinit(self: *Channel) void {
        const impl = self.impl;
        self.shutdown();
        self.wait();

        impl.pending.deinit(impl.allocator);
        impl.operations.deinit(impl.allocator);
        c.uv_cond_destroy(&impl.condition);
        c.uv_mutex_destroy(&impl.mutex);
        impl.allocator.free(impl.user_agent);
        impl.allocator.free(impl.authority);
        impl.allocator.free(impl.host);
        const allocator = impl.allocator;
        allocator.destroy(impl);
        self.* = undefined;
    }
};

const State = enum { starting, running, stopping, stopped };
const ConnectionState = enum { connecting, active, draining, closing };

const Impl = struct {
    allocator: std.mem.Allocator,
    host: [:0]u8,
    port: u16,
    authority: []u8,
    user_agent: []u8,
    mutex: c.uv_mutex_t = undefined,
    condition: c.uv_cond_t = undefined,
    state: State = .starting,
    thread: ?std.Thread = null,
    pending: std.ArrayList(*Operation) = .empty,
    operations: std.AutoHashMapUnmanaged(i32, *Operation) = .empty,
    loop: c.uv_loop_t = undefined,
    tcp: c.uv_tcp_t = undefined,
    connect_request: c.uv_connect_t = undefined,
    async_handle: c.uv_async_t = undefined,
    deadline_timer: c.uv_timer_t = undefined,
    session: ?*c.nghttp2_session = null,
    loop_initialized: bool = false,
    tcp_initialized: bool = false,
    async_initialized: bool = false,
    timer_initialized: bool = false,
    connected: bool = false,
    connection_state: ConnectionState = .connecting,
    connection_generation: usize = 0,
    stopping_on_loop: bool = false,
    connect_count: usize = 0,

    fn enqueue(self: *Impl, operation: *Operation) !bool {
        c.uv_mutex_lock(&self.mutex);
        defer c.uv_mutex_unlock(&self.mutex);
        if (self.state != .running) return false;
        try self.pending.append(self.allocator, operation);
        if (c.uv_async_send(&self.async_handle) < 0) {
            _ = self.pending.pop();
            return false;
        }
        return true;
    }

    fn signalStartup(self: *Impl, succeeded: bool) void {
        c.uv_mutex_lock(&self.mutex);
        if (self.state == .starting) self.state = if (succeeded) .running else .stopping;
        c.uv_cond_broadcast(&self.condition);
        c.uv_mutex_unlock(&self.mutex);
    }

    fn markStopped(self: *Impl) void {
        c.uv_mutex_lock(&self.mutex);
        self.state = .stopped;
        c.uv_cond_broadcast(&self.condition);
        c.uv_mutex_unlock(&self.mutex);
    }
};

const HeaderKind = enum { none, response, trailers };

const Operation = struct {
    impl: *Impl,
    path: []u8,
    request_frame: []u8,
    request_offset: usize = 0,
    request_metadata: metadata.Metadata,
    request_compression: Compression,
    max_response_size: usize,
    deadline_ns: ?u64,
    timeout_header: [16]u8 = undefined,
    timeout_header_len: usize = 0,
    stream_id: i32 = -1,
    mutex: c.uv_mutex_t = undefined,
    condition: c.uv_cond_t = undefined,
    done: bool = false,
    outcome_set: bool = false,
    deadline_expired: bool = false,
    response_code: status.Code = .unknown,
    response_message: []u8 = &.{},
    response_message_owned: bool = false,
    response_payload: ?[]u8 = null,
    response_compression: Compression = .identity,
    response_encoding_invalid: bool = false,
    response_body: std.ArrayList(u8) = .empty,
    response_too_large: bool = false,
    saw_response_headers: bool = false,
    http_status: ?u16 = null,
    content_type_grpc: bool = false,
    grpc_status: ?u32 = null,
    grpc_message: ?[]u8 = null,
    initial_metadata: metadata.Metadata,
    trailing_metadata: metadata.Metadata,
    block_kind: HeaderKind = .none,
    block_metadata: metadata.Metadata,
    block_grpc_status: ?u32 = null,
    block_grpc_message: ?[]u8 = null,

    fn init(impl: *Impl, path: []const u8, payload: []const u8, options: call.Options) !*Operation {
        const operation = try impl.allocator.create(Operation);
        errdefer impl.allocator.destroy(operation);
        const owned_path = try impl.allocator.dupe(u8, path);
        errdefer impl.allocator.free(owned_path);
        const request_frame = try frame.encodeWithCompression(
            impl.allocator,
            payload,
            options.request_compression,
        );
        errdefer impl.allocator.free(request_frame);

        operation.* = .{
            .impl = impl,
            .path = owned_path,
            .request_frame = request_frame,
            .request_metadata = metadata.Metadata.init(impl.allocator),
            .request_compression = options.request_compression,
            .max_response_size = options.max_response_size,
            .deadline_ns = if (options.timeout_ns) |timeout| c.uv_hrtime() +| timeout else null,
            .initial_metadata = metadata.Metadata.init(impl.allocator),
            .trailing_metadata = metadata.Metadata.init(impl.allocator),
            .block_metadata = metadata.Metadata.init(impl.allocator),
        };
        if (c.uv_mutex_init(&operation.mutex) < 0) return error.SynchronizationInitializationFailed;
        errdefer c.uv_mutex_destroy(&operation.mutex);
        if (c.uv_cond_init(&operation.condition) < 0) return error.SynchronizationInitializationFailed;
        errdefer c.uv_cond_destroy(&operation.condition);
        errdefer operation.request_metadata.deinit();
        errdefer operation.initial_metadata.deinit();
        errdefer operation.trailing_metadata.deinit();
        errdefer operation.block_metadata.deinit();

        for (options.metadata) |entry| {
            if (!isRequestMetadata(entry.key)) return error.InvalidMetadataKey;
            try operation.request_metadata.append(entry.key, entry.value);
        }
        return operation;
    }

    fn deinit(self: *Operation) void {
        const allocator = self.impl.allocator;
        allocator.free(self.path);
        allocator.free(self.request_frame);
        self.request_metadata.deinit();
        self.response_body.deinit(allocator);
        if (self.response_message_owned) allocator.free(self.response_message);
        if (self.response_payload) |payload| allocator.free(payload);
        if (self.grpc_message) |value| allocator.free(value);
        if (self.block_grpc_message) |value| allocator.free(value);
        self.initial_metadata.deinit();
        self.trailing_metadata.deinit();
        self.block_metadata.deinit();
        c.uv_cond_destroy(&self.condition);
        c.uv_mutex_destroy(&self.mutex);
        allocator.destroy(self);
    }

    fn setTimeoutHeader(self: *Operation, timeout_ns: u64) void {
        const units = [_]struct { divisor: u64, suffix: u8 }{
            .{ .divisor = 1, .suffix = 'n' },
            .{ .divisor = std.time.ns_per_us, .suffix = 'u' },
            .{ .divisor = std.time.ns_per_ms, .suffix = 'm' },
            .{ .divisor = std.time.ns_per_s, .suffix = 'S' },
            .{ .divisor = 60 * std.time.ns_per_s, .suffix = 'M' },
            .{ .divisor = 60 * 60 * std.time.ns_per_s, .suffix = 'H' },
        };
        for (units) |unit| {
            const value = @max(@as(u64, 1), std.math.divCeil(u64, timeout_ns, unit.divisor) catch 1);
            if (value <= 99_999_999 or unit.suffix == 'H') {
                const text = std.fmt.bufPrint(&self.timeout_header, "{d}{c}", .{ @min(value, 99_999_999), unit.suffix }) catch unreachable;
                self.timeout_header_len = text.len;
                return;
            }
        }
    }

    fn setOutcome(self: *Operation, code: status.Code, text: []const u8) !void {
        if (self.outcome_set) return;
        const owned = try self.impl.allocator.dupe(u8, text);
        if (self.response_message_owned) self.impl.allocator.free(self.response_message);
        self.response_message = owned;
        self.response_message_owned = true;
        self.response_code = code;
        self.outcome_set = true;
    }

    fn complete(self: *Operation) void {
        c.uv_mutex_lock(&self.mutex);
        self.done = true;
        c.uv_cond_broadcast(&self.condition);
        c.uv_mutex_unlock(&self.mutex);
    }

    fn wait(self: *Operation) void {
        c.uv_mutex_lock(&self.mutex);
        while (!self.done) c.uv_cond_wait(&self.condition, &self.mutex);
        c.uv_mutex_unlock(&self.mutex);
    }

    fn resetHeaderBlock(self: *Operation, kind: HeaderKind) void {
        self.block_metadata.deinit();
        self.block_metadata = metadata.Metadata.init(self.impl.allocator);
        if (self.block_grpc_message) |value| self.impl.allocator.free(value);
        self.block_grpc_message = null;
        self.block_grpc_status = null;
        self.block_kind = kind;
    }

    fn finishHeaderBlock(self: *Operation) !void {
        const trailers_only = self.block_kind == .response and self.block_grpc_status != null;
        const destination = if (self.block_kind == .trailers or trailers_only)
            &self.trailing_metadata
        else
            &self.initial_metadata;
        try copyMetadata(destination, &self.block_metadata);
        if (self.block_grpc_status) |code| self.grpc_status = code;
        if (self.block_grpc_message) |value| {
            if (self.grpc_message) |old| self.impl.allocator.free(old);
            self.grpc_message = value;
            self.block_grpc_message = null;
        }
        self.block_kind = .none;
    }

    fn finalize(self: *Operation, stream_error: u32) void {
        if (self.outcome_set) {
            self.complete();
            return;
        }
        if (stream_error != c.NGHTTP2_NO_ERROR) {
            self.setOutcome(.unavailable, "stream closed") catch {};
            self.complete();
            return;
        }
        if (!self.saw_response_headers) {
            self.setOutcome(.unknown, "missing response headers") catch {};
        } else if (self.http_status == null) {
            self.setOutcome(.unknown, "missing HTTP status") catch {};
        } else if (self.http_status.? != 200) {
            self.setOutcome(httpStatusCode(self.http_status.?), "HTTP request failed") catch {};
        } else if (!self.content_type_grpc) {
            self.setOutcome(.unknown, "invalid gRPC content-type") catch {};
        } else if (self.grpc_status == null) {
            self.setOutcome(.unknown, "missing grpc-status") catch {};
        } else if (self.response_encoding_invalid) {
            self.setOutcome(.unimplemented, "response compression is not supported") catch {};
        } else if (self.response_too_large) {
            self.setOutcome(.resource_exhausted, "response message too large") catch {};
        } else {
            const code = status.Code.fromInt(self.grpc_status.?);
            var decoded_message: ?[]u8 = null;
            defer if (decoded_message) |value| self.impl.allocator.free(value);
            if (self.grpc_message) |encoded| {
                decoded_message = message.decode(self.impl.allocator, encoded) catch {
                    self.setOutcome(.unknown, "invalid grpc-message") catch {};
                    self.complete();
                    return;
                };
            }
            if (code != .ok) {
                self.setOutcome(code, if (decoded_message) |value| value else "") catch {};
            } else {
                const payload = frame.decodeUnaryWithCompression(
                    self.impl.allocator,
                    self.response_body.items,
                    self.max_response_size,
                    self.response_compression,
                ) catch |err| {
                    const outcome: status.Status = switch (err) {
                        error.MessageTooLarge => .init(.resource_exhausted, "response message too large"),
                        else => .init(.internal, "malformed unary response"),
                    };
                    self.setOutcome(outcome.code, outcome.message) catch {};
                    self.complete();
                    return;
                };
                self.response_payload = payload;
                self.response_compression = if (self.response_body.items[0] == 1) .gzip else .identity;
                self.setOutcome(.ok, if (decoded_message) |value| value else "") catch {};
            }
        }
        if (!self.outcome_set) self.setOutcome(.unknown, "response failed") catch {};
        self.complete();
    }
};

const WriteRequest = struct {
    request: c.uv_write_t = undefined,
    impl: *Impl,
    bytes: []u8,
    generation: usize,
};

fn runLoop(impl: *Impl) void {
    if (c.uv_loop_init(&impl.loop) < 0) {
        impl.signalStartup(false);
        impl.markStopped();
        return;
    }
    impl.loop_initialized = true;

    setupLoop(impl) catch {
        impl.signalStartup(false);
        beginStop(impl, "connection failed");
    };
    _ = c.uv_run(&impl.loop, c.UV_RUN_DEFAULT);
    _ = c.uv_loop_close(&impl.loop);
    impl.loop_initialized = false;
    impl.markStopped();
}

fn setupLoop(impl: *Impl) !void {
    if (c.uv_async_init(&impl.loop, &impl.async_handle, onAsync) < 0) return error.AsyncInitializationFailed;
    impl.async_initialized = true;
    impl.async_handle.data = impl;

    if (c.uv_timer_init(&impl.loop, &impl.deadline_timer) < 0) return error.TimerInitializationFailed;
    impl.timer_initialized = true;
    impl.deadline_timer.data = impl;

    try startConnection(impl);
}

fn startConnection(impl: *Impl) !void {
    if (c.uv_tcp_init(&impl.loop, &impl.tcp) < 0) return error.TcpInitializationFailed;
    impl.tcp_initialized = true;
    impl.tcp.data = impl;
    impl.connected = false;
    impl.connection_state = .connecting;
    impl.connection_generation += 1;

    try initializeSession(impl);
    var address: c.struct_sockaddr_in = undefined;
    if (c.uv_ip4_addr(impl.host.ptr, impl.port, &address) < 0) return error.InvalidAddress;
    impl.connect_request.data = impl;
    if (c.uv_tcp_connect(&impl.connect_request, &impl.tcp, @ptrCast(&address), onConnect) < 0) return error.ConnectFailed;
}

fn initializeSession(impl: *Impl) !void {
    var callbacks: ?*c.nghttp2_session_callbacks = null;
    if (c.nghttp2_session_callbacks_new(&callbacks) != 0) return error.OutOfMemory;
    defer c.nghttp2_session_callbacks_del(callbacks);
    c.nghttp2_session_callbacks_set_on_begin_headers_callback(callbacks, onBeginHeaders);
    c.nghttp2_session_callbacks_set_on_header_callback(callbacks, onHeader);
    c.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, onDataChunk);
    c.nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, onFrameReceived);
    c.nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, onStreamClose);
    if (c.nghttp2_session_client_new(&impl.session, callbacks, impl) != 0) return error.OutOfMemory;
    if (c.nghttp2_submit_settings(impl.session, c.NGHTTP2_FLAG_NONE, null, 0) != 0) return error.NativeFailure;
}

fn onConnect(request: ?*c.uv_connect_t, connect_status: c_int) callconv(.c) void {
    const impl: *Impl = @ptrCast(@alignCast(request.?.*.data.?));
    if (connect_status < 0 or c.uv_read_start(@ptrCast(&impl.tcp), allocateReadBuffer, onRead) < 0) {
        impl.signalStartup(false);
        beginStop(impl, "connection failed");
        return;
    }
    c.uv_mutex_lock(&impl.mutex);
    const stopping = impl.state == .stopping or impl.state == .stopped;
    c.uv_mutex_unlock(&impl.mutex);
    if (stopping) {
        beginStop(impl, "channel closed");
        return;
    }
    impl.connected = true;
    impl.connect_count += 1;
    flush(impl) catch {
        impl.signalStartup(false);
        beginStop(impl, "connection failed");
        return;
    };
    impl.connection_state = .active;
    impl.signalStartup(true);
    processPending(impl);
}

fn onAsync(handle: ?*c.uv_async_t) callconv(.c) void {
    const impl: *Impl = @ptrCast(@alignCast(handle.?.*.data.?));
    c.uv_mutex_lock(&impl.mutex);
    const stopping = impl.state != .running;
    c.uv_mutex_unlock(&impl.mutex);
    if (stopping) {
        beginStop(impl, "channel closed");
        return;
    }
    switch (impl.connection_state) {
        .active => processPending(impl),
        .draining => {
            if (impl.operations.count() == 0) beginReconnect(impl);
            scheduleDeadlineTimer(impl);
        },
        .connecting, .closing => scheduleDeadlineTimer(impl),
    }
}

fn processPending(impl: *Impl) void {
    if (impl.connection_state != .active) {
        scheduleDeadlineTimer(impl);
        return;
    }
    var pending: std.ArrayList(*Operation) = .empty;
    c.uv_mutex_lock(&impl.mutex);
    std.mem.swap(std.ArrayList(*Operation), &pending, &impl.pending);
    c.uv_mutex_unlock(&impl.mutex);
    defer pending.deinit(impl.allocator);

    for (pending.items) |operation| {
        if (operation.deadline_ns) |deadline| {
            const now = c.uv_hrtime();
            if (deadline <= now) {
                operation.deadline_expired = true;
                operation.setOutcome(.deadline_exceeded, "deadline exceeded") catch {};
                operation.complete();
                continue;
            }
            operation.setTimeoutHeader(deadline - now);
        }
        submitOperation(impl, operation) catch {
            operation.setOutcome(.unavailable, "request submission failed") catch {};
            operation.complete();
            continue;
        };
    }
    flush(impl) catch {
        beginStop(impl, "connection failed");
        return;
    };
    scheduleDeadlineTimer(impl);
}

fn submitOperation(impl: *Impl, operation: *Operation) !void {
    try impl.operations.ensureUnusedCapacity(impl.allocator, 1);
    var headers: std.ArrayList(c.nghttp2_nv) = .empty;
    defer headers.deinit(impl.allocator);
    var encoded_values: std.ArrayList([]u8) = .empty;
    defer {
        for (encoded_values.items) |value| impl.allocator.free(value);
        encoded_values.deinit(impl.allocator);
    }
    try headers.append(impl.allocator, nativeHeader(":method", "POST"));
    try headers.append(impl.allocator, nativeHeader(":scheme", "http"));
    try headers.append(impl.allocator, nativeHeader(":path", operation.path));
    try headers.append(impl.allocator, nativeHeader(":authority", impl.authority));
    try headers.append(impl.allocator, nativeHeader("content-type", "application/grpc"));
    try headers.append(impl.allocator, nativeHeader("te", "trailers"));
    try headers.append(impl.allocator, nativeHeader("grpc-encoding", operation.request_compression.name()));
    try headers.append(impl.allocator, nativeHeader("grpc-accept-encoding", "identity,gzip"));
    try headers.append(impl.allocator, nativeHeader("user-agent", impl.user_agent));
    if (operation.timeout_header_len != 0) {
        try headers.append(impl.allocator, nativeHeader("grpc-timeout", operation.timeout_header[0..operation.timeout_header_len]));
    }
    for (operation.request_metadata.items()) |entry| {
        const value = try metadata.encodeValue(impl.allocator, entry.key, entry.value);
        encoded_values.append(impl.allocator, value) catch |err| {
            impl.allocator.free(value);
            return err;
        };
        try headers.append(impl.allocator, nativeHeader(entry.key, value));
    }

    var provider: c.nghttp2_data_provider2 = .{
        .source = .{ .ptr = operation },
        .read_callback = readRequestData,
    };
    const stream_id = c.nghttp2_submit_request2(
        impl.session,
        null,
        headers.items.ptr,
        headers.items.len,
        &provider,
        operation,
    );
    if (stream_id < 0) return error.NativeFailure;
    operation.stream_id = stream_id;
    impl.operations.putAssumeCapacity(stream_id, operation);
}

fn readRequestData(
    _: ?*c.nghttp2_session,
    _: i32,
    output: [*c]u8,
    output_length: usize,
    data_flags: ?*u32,
    source: ?*c.nghttp2_data_source,
    _: ?*anyopaque,
) callconv(.c) c.nghttp2_ssize {
    const operation: *Operation = @ptrCast(@alignCast(source.?.*.ptr.?));
    const remaining = operation.request_frame[operation.request_offset..];
    const length = @min(remaining.len, output_length);
    @memcpy(output[0..length], remaining[0..length]);
    operation.request_offset += length;
    if (operation.request_offset == operation.request_frame.len) data_flags.?.* |= c.NGHTTP2_DATA_FLAG_EOF;
    return @intCast(length);
}

fn flush(impl: *Impl) !void {
    while (!impl.stopping_on_loop) {
        var data: [*c]const u8 = null;
        const length = c.nghttp2_session_mem_send2(impl.session, &data);
        if (length < 0) return error.NativeFailure;
        if (length == 0) return;

        const write = try impl.allocator.create(WriteRequest);
        errdefer impl.allocator.destroy(write);
        const bytes = try impl.allocator.dupe(u8, data[0..@intCast(length)]);
        errdefer impl.allocator.free(bytes);
        write.* = .{
            .impl = impl,
            .bytes = bytes,
            .generation = impl.connection_generation,
        };
        write.request.data = write;
        var buffer = c.uv_buf_init(@ptrCast(bytes.ptr), @intCast(bytes.len));
        if (c.uv_write(&write.request, @ptrCast(&impl.tcp), &buffer, 1, onWrite) < 0) return error.WriteFailed;
    }
}

fn allocateReadBuffer(handle: ?*c.uv_handle_t, suggested_size: usize, buffer: ?*c.uv_buf_t) callconv(.c) void {
    const impl: *Impl = @ptrCast(@alignCast(handle.?.*.data.?));
    const bytes = impl.allocator.alloc(u8, @max(suggested_size, 1)) catch {
        buffer.?.* = c.uv_buf_init(null, 0);
        return;
    };
    buffer.?.* = c.uv_buf_init(@ptrCast(bytes.ptr), @intCast(bytes.len));
}

fn onRead(handle: ?*c.uv_stream_t, bytes_read: isize, buffer: ?*const c.uv_buf_t) callconv(.c) void {
    const impl: *Impl = @ptrCast(@alignCast(handle.?.*.data.?));
    defer if (buffer.?.*.base != null) {
        const bytes: [*]u8 = @ptrCast(buffer.?.*.base);
        impl.allocator.free(bytes[0..buffer.?.*.len]);
    };
    if (bytes_read < 0) {
        if (impl.connection_state == .closing) return;
        if (impl.connection_state == .draining and impl.operations.count() == 0) {
            beginReconnect(impl);
            return;
        }
        beginStop(impl, "connection closed");
        return;
    }
    if (bytes_read == 0) return;
    const input: [*]const u8 = @ptrCast(buffer.?.*.base);
    const consumed = c.nghttp2_session_mem_recv2(impl.session, input, @intCast(bytes_read));
    if (consumed < 0 or consumed != bytes_read) {
        beginStop(impl, "HTTP/2 connection failed");
        return;
    }
    flush(impl) catch beginStop(impl, "connection failed");
}

fn onWrite(request: ?*c.uv_write_t, write_status: c_int) callconv(.c) void {
    const write: *WriteRequest = @ptrCast(@alignCast(request.?.*.data.?));
    const impl = write.impl;
    const generation = write.generation;
    impl.allocator.free(write.bytes);
    impl.allocator.destroy(write);
    if (write_status < 0 and generation == impl.connection_generation and impl.connection_state != .closing) {
        beginStop(impl, "connection write failed");
    }
}

fn onBeginHeaders(session: ?*c.nghttp2_session, received_frame: ?*const c.nghttp2_frame, _: ?*anyopaque) callconv(.c) c_int {
    const native_frame = received_frame.?;
    if (native_frame.*.hd.type != c.NGHTTP2_HEADERS) return 0;
    const operation: *Operation = @ptrCast(@alignCast(c.nghttp2_session_get_stream_user_data(session, native_frame.*.hd.stream_id) orelse return 0));
    const kind: HeaderKind = switch (native_frame.*.headers.cat) {
        c.NGHTTP2_HCAT_RESPONSE => .response,
        c.NGHTTP2_HCAT_HEADERS => .trailers,
        else => return 0,
    };
    operation.resetHeaderBlock(kind);
    if (kind == .response) operation.saw_response_headers = true;
    return 0;
}

fn onHeader(
    session: ?*c.nghttp2_session,
    received_frame: ?*const c.nghttp2_frame,
    name_pointer: [*c]const u8,
    name_length: usize,
    value_pointer: [*c]const u8,
    value_length: usize,
    _: u8,
    _: ?*anyopaque,
) callconv(.c) c_int {
    const stream_id = received_frame.?.*.hd.stream_id;
    const operation: *Operation = @ptrCast(@alignCast(c.nghttp2_session_get_stream_user_data(session, stream_id) orelse return 0));
    const name = name_pointer[0..name_length];
    const value = value_pointer[0..value_length];
    if (std.mem.eql(u8, name, ":status")) {
        operation.http_status = std.fmt.parseInt(u16, value, 10) catch null;
    } else if (std.mem.eql(u8, name, "content-type")) {
        operation.content_type_grpc = std.mem.startsWith(u8, value, "application/grpc");
    } else if (std.mem.eql(u8, name, "grpc-status")) {
        operation.block_grpc_status = std.fmt.parseInt(u32, value, 10) catch std.math.maxInt(u32);
    } else if (std.mem.eql(u8, name, "grpc-message")) {
        if (operation.block_grpc_message) |old| operation.impl.allocator.free(old);
        operation.block_grpc_message = operation.impl.allocator.dupe(u8, value) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    } else if (std.mem.eql(u8, name, "grpc-encoding")) {
        operation.response_compression = Compression.parse(value) orelse {
            operation.response_encoding_invalid = true;
            return 0;
        };
    } else if (isResponseMetadata(name)) {
        operation.block_metadata.appendDecoded(name, value) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    }
    return 0;
}

fn onDataChunk(
    session: ?*c.nghttp2_session,
    _: u8,
    stream_id: i32,
    data_pointer: [*c]const u8,
    data_length: usize,
    _: ?*anyopaque,
) callconv(.c) c_int {
    const operation: *Operation = @ptrCast(@alignCast(c.nghttp2_session_get_stream_user_data(session, stream_id) orelse return 0));
    const limit = wireMessageLimit(operation.max_response_size);
    if (data_length > limit -| operation.response_body.items.len) {
        operation.response_too_large = true;
        return 0;
    }
    operation.response_body.appendSlice(operation.impl.allocator, data_pointer[0..data_length]) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    return 0;
}

fn onFrameReceived(session: ?*c.nghttp2_session, received_frame: ?*const c.nghttp2_frame, user_data: ?*anyopaque) callconv(.c) c_int {
    const native_frame = received_frame.?;
    if (native_frame.*.hd.type == c.NGHTTP2_GOAWAY) {
        const impl: *Impl = @ptrCast(@alignCast(user_data.?));
        if (impl.connection_state == .active) {
            impl.connection_state = .draining;
            _ = c.uv_async_send(&impl.async_handle);
        }
        return 0;
    }
    if (native_frame.*.hd.type != c.NGHTTP2_HEADERS) return 0;
    const operation: *Operation = @ptrCast(@alignCast(c.nghttp2_session_get_stream_user_data(session, native_frame.*.hd.stream_id) orelse return 0));
    operation.finishHeaderBlock() catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    return 0;
}

fn onStreamClose(_: ?*c.nghttp2_session, stream_id: i32, error_code: u32, user_data: ?*anyopaque) callconv(.c) c_int {
    const impl: *Impl = @ptrCast(@alignCast(user_data.?));
    if (impl.operations.fetchRemove(stream_id)) |entry| {
        entry.value.finalize(error_code);
        scheduleDeadlineTimer(impl);
        if (impl.connection_state == .draining and impl.operations.count() == 0) {
            _ = c.uv_async_send(&impl.async_handle);
        }
    }
    return 0;
}

fn scheduleDeadlineTimer(impl: *Impl) void {
    if (!impl.timer_initialized or impl.stopping_on_loop) return;
    var earliest: ?u64 = null;
    var iterator = impl.operations.valueIterator();
    while (iterator.next()) |operation_ptr| {
        const operation = operation_ptr.*;
        if (operation.deadline_expired) continue;
        if (operation.deadline_ns) |deadline| {
            if (earliest == null or deadline < earliest.?) earliest = deadline;
        }
    }
    c.uv_mutex_lock(&impl.mutex);
    for (impl.pending.items) |operation| {
        if (operation.deadline_ns) |deadline| {
            if (earliest == null or deadline < earliest.?) earliest = deadline;
        }
    }
    c.uv_mutex_unlock(&impl.mutex);
    if (earliest == null) {
        _ = c.uv_timer_stop(&impl.deadline_timer);
        return;
    }
    const remaining = earliest.? -| c.uv_hrtime();
    const timeout_ms = @max(@as(u64, 1), std.math.divCeil(u64, remaining, std.time.ns_per_ms) catch 1);
    _ = c.uv_timer_start(&impl.deadline_timer, onDeadlineTimer, timeout_ms, 0);
}

fn onDeadlineTimer(handle: ?*c.uv_timer_t) callconv(.c) void {
    const impl: *Impl = @ptrCast(@alignCast(handle.?.*.data.?));
    const now = c.uv_hrtime();
    c.uv_mutex_lock(&impl.mutex);
    var pending_index: usize = 0;
    while (pending_index < impl.pending.items.len) {
        const operation = impl.pending.items[pending_index];
        if (operation.deadline_ns != null and operation.deadline_ns.? <= now) {
            _ = impl.pending.orderedRemove(pending_index);
            operation.deadline_expired = true;
            operation.setOutcome(.deadline_exceeded, "deadline exceeded") catch {};
            operation.complete();
        } else {
            pending_index += 1;
        }
    }
    c.uv_mutex_unlock(&impl.mutex);

    var iterator = impl.operations.valueIterator();
    while (iterator.next()) |operation_ptr| {
        const operation = operation_ptr.*;
        if (operation.deadline_expired) continue;
        if (operation.deadline_ns) |deadline| {
            if (deadline <= now) {
                operation.deadline_expired = true;
                operation.setOutcome(.deadline_exceeded, "deadline exceeded") catch {};
                if (c.nghttp2_submit_rst_stream(impl.session, c.NGHTTP2_FLAG_NONE, operation.stream_id, c.NGHTTP2_CANCEL) != 0) {
                    beginStop(impl, "deadline cancellation failed");
                    return;
                }
            }
        }
    }
    if (impl.connected) {
        flush(impl) catch {
            beginStop(impl, "connection failed");
            return;
        };
    }
    scheduleDeadlineTimer(impl);
}

fn beginReconnect(impl: *Impl) void {
    if (impl.connection_state != .draining or impl.operations.count() != 0) return;
    impl.connection_state = .closing;
    impl.connected = false;
    _ = c.uv_read_stop(@ptrCast(&impl.tcp));
    if (impl.session) |session| {
        c.nghttp2_session_del(session);
        impl.session = null;
    }
    if (c.uv_is_closing(@ptrCast(&impl.tcp)) == 0) {
        c.uv_close(@ptrCast(&impl.tcp), onTcpClosed);
    }
}

fn onTcpClosed(handle: ?*c.uv_handle_t) callconv(.c) void {
    const impl: *Impl = @ptrCast(@alignCast(handle.?.*.data.?));
    impl.tcp_initialized = false;
    impl.connected = false;
    if (impl.stopping_on_loop or impl.connection_state != .closing) return;

    c.uv_mutex_lock(&impl.mutex);
    const running = impl.state == .running;
    c.uv_mutex_unlock(&impl.mutex);
    if (!running) return;

    startConnection(impl) catch beginStop(impl, "connection failed");
}

fn beginStop(impl: *Impl, reason: []const u8) void {
    if (impl.stopping_on_loop) return;
    impl.stopping_on_loop = true;
    c.uv_mutex_lock(&impl.mutex);
    if (impl.state == .starting) {
        impl.state = .stopping;
        c.uv_cond_broadcast(&impl.condition);
    } else if (impl.state == .running) {
        impl.state = .stopping;
    }
    var pending: std.ArrayList(*Operation) = .empty;
    std.mem.swap(std.ArrayList(*Operation), &pending, &impl.pending);
    c.uv_mutex_unlock(&impl.mutex);

    for (pending.items) |operation| {
        operation.setOutcome(.unavailable, reason) catch {};
        operation.complete();
    }
    pending.deinit(impl.allocator);

    if (impl.session) |session| {
        c.nghttp2_session_del(session);
        impl.session = null;
    }
    var iterator = impl.operations.valueIterator();
    while (iterator.next()) |operation_ptr| {
        const operation = operation_ptr.*;
        operation.setOutcome(.unavailable, reason) catch {};
        operation.complete();
    }
    impl.operations.clearRetainingCapacity();

    if (impl.timer_initialized) {
        _ = c.uv_timer_stop(&impl.deadline_timer);
        if (c.uv_is_closing(@ptrCast(&impl.deadline_timer)) == 0) c.uv_close(@ptrCast(&impl.deadline_timer), null);
    }
    if (impl.connected) _ = c.uv_read_stop(@ptrCast(&impl.tcp));
    if (impl.tcp_initialized and c.uv_is_closing(@ptrCast(&impl.tcp)) == 0) c.uv_close(@ptrCast(&impl.tcp), null);
    if (impl.async_initialized and c.uv_is_closing(@ptrCast(&impl.async_handle)) == 0) c.uv_close(@ptrCast(&impl.async_handle), null);
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

fn copyMetadata(destination: *metadata.Metadata, source: *const metadata.Metadata) !void {
    for (source.items()) |entry| try destination.append(entry.key, entry.value);
}

fn parseTarget(target: []const u8) !struct { host: []const u8, port: u16 } {
    const separator = std.mem.lastIndexOfScalar(u8, target, ':') orelse return error.InvalidTarget;
    const host = target[0..separator];
    if (host.len == 0 or std.mem.indexOfScalar(u8, host, ':') != null) return error.InvalidTarget;
    const port = std.fmt.parseInt(u16, target[separator + 1 ..], 10) catch return error.InvalidTarget;
    if (port == 0) return error.InvalidTarget;
    return .{ .host = host, .port = port };
}

fn isValidMethodPath(path: []const u8) bool {
    if (path.len < 4 or path[0] != '/') return false;
    const separator = std.mem.indexOfScalarPos(u8, path, 1, '/') orelse return false;
    return separator > 1 and separator + 1 < path.len and std.mem.indexOfScalarPos(u8, path, separator + 1, '/') == null;
}

fn isRequestMetadata(name: []const u8) bool {
    if (!metadata.isValidKey(name)) return false;
    const reserved = [_][]const u8{
        "content-type", "te", "grpc-encoding", "grpc-accept-encoding", "grpc-timeout", "user-agent",
    };
    for (reserved) |header| if (std.mem.eql(u8, name, header)) return false;
    return true;
}

fn isResponseMetadata(name: []const u8) bool {
    if (!metadata.isValidKey(name)) return false;
    const reserved = [_][]const u8{
        "content-type", "grpc-encoding", "grpc-accept-encoding", "grpc-status", "grpc-message",
    };
    for (reserved) |header| if (std.mem.eql(u8, name, header)) return false;
    return true;
}

fn httpStatusCode(http_status: u16) status.Code {
    return switch (http_status) {
        400 => .internal,
        401 => .unauthenticated,
        403 => .permission_denied,
        404 => .unimplemented,
        429, 502, 503, 504 => .unavailable,
        else => .unknown,
    };
}

fn wireMessageLimit(max_message_size: usize) usize {
    const overhead = std.math.add(usize, max_message_size / 8, 1024) catch return std.math.maxInt(usize);
    const total_overhead = std.math.add(usize, overhead, frame.header_size) catch return std.math.maxInt(usize);
    return std.math.add(usize, max_message_size, total_overhead) catch std.math.maxInt(usize);
}

test "target and timeout formatting" {
    const target = try parseTarget("127.0.0.1:50051");
    try std.testing.expectEqualStrings("127.0.0.1", target.host);
    try std.testing.expectEqual(@as(u16, 50051), target.port);
    try std.testing.expectError(error.InvalidTarget, parseTarget("localhost"));
    try std.testing.expectError(error.InvalidTarget, parseTarget("[::1]:50051"));
}

test "response headers with grpc-status are trailers-only metadata" {
    var host = [_:0]u8{'x'};
    var impl: Impl = .{
        .allocator = std.testing.allocator,
        .host = host[0..1 :0],
        .port = 1,
        .authority = &.{},
        .user_agent = &.{},
    };
    const operation = try Operation.init(&impl, "/test.Echo/Unary", "", .{});
    defer operation.deinit();

    operation.resetHeaderBlock(.response);
    try operation.block_metadata.append("x-trailers-only", "present");
    operation.block_grpc_status = @intFromEnum(status.Code.not_found);
    try operation.finishHeaderBlock();

    try std.testing.expectEqual(@as(usize, 0), operation.initial_metadata.items().len);
    try std.testing.expectEqualStrings("present", operation.trailing_metadata.getFirst("x-trailers-only").?);
    try std.testing.expectEqual(@as(?u32, @intFromEnum(status.Code.not_found)), operation.grpc_status);
}

test "binary request initial and trailing metadata round trip as raw duplicate values" {
    const server = @import("server.zig");
    const service = @import("service.zig");
    const binary_value = [_]u8{ 0xab, 0xab, 0xab };
    const second_value = [_]u8{0xab};

    const Handler = struct {
        request_matches: bool = false,

        fn handle(
            self: *@This(),
            allocator: std.mem.Allocator,
            context: *service.ServerContext,
            request: []const u8,
        ) !service.UnaryResponse {
            const entries = context.request_metadata.items();
            self.request_matches = entries.len == 3 and
                std.mem.eql(u8, entries[0].key, "x-request") and
                std.mem.eql(u8, entries[0].value, "plain") and
                std.mem.eql(u8, entries[1].key, "x-request-bin") and
                std.mem.eql(u8, entries[1].value, &binary_value) and
                std.mem.eql(u8, entries[2].key, "x-request-bin") and
                std.mem.eql(u8, entries[2].value, &second_value);

            try context.addInitialMetadata("x-initial", "plain");
            try context.addInitialMetadata("x-initial-bin", &binary_value);
            try context.addInitialMetadata("x-initial-bin", &second_value);
            try context.addTrailingMetadata("x-trailing", "plain");
            try context.addTrailingMetadata("x-trailing-bin", &binary_value);
            try context.addTrailingMetadata("x-trailing-bin", &second_value);
            return service.UnaryResponse.ok(allocator, request);
        }
    };

    var handler = Handler{};
    var test_server = try server.Server.init(std.testing.allocator, .{});
    defer test_server.deinit();
    try test_server.registerUnary(
        "/test.Metadata/Unary",
        service.UnaryHandler.bind(Handler, &handler, Handler.handle),
    );
    try test_server.start();

    var target_buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buffer, "127.0.0.1:{d}", .{try test_server.port()});
    var channel = try Channel.init(std.testing.allocator, target, .{});
    defer channel.deinit();

    var result = try channel.callUnary(
        std.testing.allocator,
        "/test.Metadata/Unary",
        "payload",
        .{ .metadata = &.{
            .{ .key = "x-request", .value = "plain" },
            .{ .key = "x-request-bin", .value = &binary_value },
            .{ .key = "x-request-bin", .value = &second_value },
        } },
    );
    defer result.deinit();

    try std.testing.expect(result.status.isOk());
    try std.testing.expect(handler.request_matches);
    const initial = result.initial_metadata.items();
    try std.testing.expectEqual(@as(usize, 3), initial.len);
    try std.testing.expectEqualStrings("plain", initial[0].value);
    try std.testing.expectEqualSlices(u8, &binary_value, initial[1].value);
    try std.testing.expectEqualSlices(u8, &second_value, initial[2].value);
    try std.testing.expectEqualStrings(initial[1].key, initial[2].key);

    const trailing = result.trailing_metadata.items();
    try std.testing.expectEqual(@as(usize, 3), trailing.len);
    try std.testing.expectEqualStrings("plain", trailing[0].value);
    try std.testing.expectEqualSlices(u8, &binary_value, trailing[1].value);
    try std.testing.expectEqualSlices(u8, &second_value, trailing[2].value);
    try std.testing.expectEqualStrings(trailing[1].key, trailing[2].key);
}

test "channel and server exchange gzip-compressed unary messages" {
    const server = @import("server.zig");
    const service = @import("service.zig");

    const Handler = struct {
        saw_gzip_request: bool = false,

        fn handle(
            self: *@This(),
            allocator: std.mem.Allocator,
            context: *service.ServerContext,
            request: []const u8,
        ) !service.UnaryResponse {
            self.saw_gzip_request = context.request_compression == .gzip;
            context.setResponseCompression(.gzip);
            return service.UnaryResponse.ok(allocator, request);
        }
    };

    var handler = Handler{};
    var test_server = try server.Server.init(std.testing.allocator, .{});
    defer test_server.deinit();
    try test_server.registerUnary(
        "/test.Compression/Unary",
        service.UnaryHandler.bind(Handler, &handler, Handler.handle),
    );
    try test_server.start();

    var target_buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buffer, "127.0.0.1:{d}", .{try test_server.port()});
    var channel = try Channel.init(std.testing.allocator, target, .{});
    defer channel.deinit();

    var result = try channel.callUnary(
        std.testing.allocator,
        "/test.Compression/Unary",
        "compressible compressible compressible",
        .{ .request_compression = .gzip },
    );
    defer result.deinit();
    try std.testing.expect(result.status.isOk());
    try std.testing.expect(handler.saw_gzip_request);
    try std.testing.expectEqual(Compression.gzip, result.response_compression);
    try std.testing.expectEqualStrings("compressible compressible compressible", result.payload);

    var limited = try channel.callUnary(
        std.testing.allocator,
        "/test.Compression/Unary",
        "123456789",
        .{ .request_compression = .gzip, .max_response_size = 8 },
    );
    defer limited.deinit();
    try std.testing.expectEqual(status.Code.resource_exhausted, limited.status.code);
}

test "channel replaces a connection after GOAWAY without replaying calls" {
    const server = @import("server.zig");
    const service = @import("service.zig");

    const Handler = struct {
        server: *server.Server,
        calls: usize = 0,

        fn handle(
            self: *@This(),
            allocator: std.mem.Allocator,
            _: *service.ServerContext,
            request: []const u8,
        ) !service.UnaryResponse {
            self.calls += 1;
            if (self.calls == 1) {
                const connection = self.server.impl.connections.items[0];
                if (c.nghttp2_submit_goaway(
                    connection.session,
                    c.NGHTTP2_FLAG_NONE,
                    1,
                    c.NGHTTP2_NO_ERROR,
                    null,
                    0,
                ) != 0) return error.GoAwaySubmissionFailed;
            }
            return service.UnaryResponse.ok(allocator, request);
        }
    };

    var test_server = try server.Server.init(std.testing.allocator, .{});
    defer test_server.deinit();
    var handler = Handler{ .server = &test_server };
    try test_server.registerUnary(
        "/test.GoAway/Unary",
        service.UnaryHandler.bind(Handler, &handler, Handler.handle),
    );
    try test_server.start();

    var target_buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buffer, "127.0.0.1:{d}", .{try test_server.port()});
    var channel = try Channel.init(std.testing.allocator, target, .{});
    defer channel.deinit();

    var first = try channel.callUnary(std.testing.allocator, "/test.GoAway/Unary", "first", .{});
    defer first.deinit();
    try std.testing.expect(first.status.isOk());
    try std.testing.expectEqualStrings("first", first.payload);

    var second = try channel.callUnary(std.testing.allocator, "/test.GoAway/Unary", "second", .{});
    defer second.deinit();
    try std.testing.expect(second.status.isOk());
    try std.testing.expectEqualStrings("second", second.payload);
    try std.testing.expectEqual(@as(usize, 2), channel.impl.connect_count);
    try std.testing.expectEqual(@as(usize, 2), handler.calls);
}

test "server drain finishes an accepted RPC and rejects a replacement connection" {
    const server = @import("server.zig");
    const service = @import("service.zig");

    const Handler = struct {
        server: *server.Server,
        local_address_available: bool = false,

        fn handle(
            self: *@This(),
            allocator: std.mem.Allocator,
            _: *service.ServerContext,
            request: []const u8,
        ) !service.UnaryResponse {
            self.server.shutdownGracefully(5 * std.time.ns_per_s);
            _ = try self.server.localAddress();
            self.local_address_available = true;
            return service.UnaryResponse.ok(allocator, request);
        }
    };

    var test_server = try server.Server.init(std.testing.allocator, .{});
    defer test_server.deinit();
    var handler = Handler{ .server = &test_server };
    try test_server.registerUnary(
        "/test.Drain/Unary",
        service.UnaryHandler.bind(Handler, &handler, Handler.handle),
    );
    try test_server.start();

    var target_buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buffer, "127.0.0.1:{d}", .{try test_server.port()});
    var channel = try Channel.init(std.testing.allocator, target, .{});
    defer channel.deinit();

    var accepted = try channel.callUnary(std.testing.allocator, "/test.Drain/Unary", "accepted", .{});
    defer accepted.deinit();
    try std.testing.expect(accepted.status.isOk());
    try std.testing.expectEqualStrings("accepted", accepted.payload);
    try std.testing.expect(handler.local_address_available);

    var rejected = try channel.callUnary(std.testing.allocator, "/test.Drain/Unary", "later", .{});
    defer rejected.deinit();
    try std.testing.expectEqual(status.Code.unavailable, rejected.status.code);
    try std.testing.expectEqual(@as(usize, 2), channel.impl.connection_generation);
    test_server.wait();
}

test "server drain timeout closes a transport-active stream" {
    const server = @import("server.zig");
    const service = @import("service.zig");

    const Handler = struct {
        server: *server.Server,
        called: bool = false,

        fn handle(
            self: *@This(),
            allocator: std.mem.Allocator,
            _: *service.ServerContext,
            _: []const u8,
        ) !service.UnaryResponse {
            self.called = true;
            const payload = try allocator.alloc(u8, 8 * 1024 * 1024);
            defer allocator.free(payload);
            @memset(payload, 'x');
            self.server.shutdownGracefully(0);
            return service.UnaryResponse.ok(allocator, payload);
        }
    };

    var test_server = try server.Server.init(std.testing.allocator, .{});
    defer test_server.deinit();
    var handler = Handler{ .server = &test_server };
    try test_server.registerUnary(
        "/test.Drain/Timeout",
        service.UnaryHandler.bind(Handler, &handler, Handler.handle),
    );
    try test_server.start();

    var target_buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buffer, "127.0.0.1:{d}", .{try test_server.port()});
    var channel = try Channel.init(std.testing.allocator, target, .{});
    defer channel.deinit();

    var result = try channel.callUnary(
        std.testing.allocator,
        "/test.Drain/Timeout",
        "request",
        .{ .max_response_size = 16 * 1024 * 1024 },
    );
    defer result.deinit();
    try std.testing.expect(handler.called);
    try std.testing.expectEqual(status.Code.unavailable, result.status.code);
    test_server.wait();
}

test "immediate shutdown escalates an active graceful drain" {
    const server = @import("server.zig");
    const service = @import("service.zig");

    const Handler = struct {
        fn handle(_: *@This(), allocator: std.mem.Allocator, _: *service.ServerContext, request: []const u8) !service.UnaryResponse {
            return service.UnaryResponse.ok(allocator, request);
        }
    };

    var handler = Handler{};
    var test_server = try server.Server.init(std.testing.allocator, .{});
    defer test_server.deinit();
    try test_server.registerUnary(
        "/test.Drain/Escalate",
        service.UnaryHandler.bind(Handler, &handler, Handler.handle),
    );
    try test_server.start();

    var target_buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buffer, "127.0.0.1:{d}", .{try test_server.port()});
    var channel = try Channel.init(std.testing.allocator, target, .{});
    defer channel.deinit();

    test_server.shutdownGracefully(std.time.ns_per_hour);
    test_server.shutdown();
    test_server.shutdown();
    test_server.wait();

    var result = try channel.callUnary(std.testing.allocator, "/test.Drain/Escalate", "later", .{});
    defer result.deinit();
    try std.testing.expectEqual(status.Code.unavailable, result.status.code);
}

test "channel performs reusable concurrent unary calls end to end" {
    const server = @import("server.zig");
    const service = @import("service.zig");

    const Handler = struct {
        calls: usize = 0,
        saw_request_metadata: bool = false,

        fn handle(
            self: *@This(),
            allocator: std.mem.Allocator,
            context: *service.ServerContext,
            request: []const u8,
        ) !service.UnaryResponse {
            self.calls += 1;
            if (context.request_metadata.getFirst("x-request-id")) |value| {
                self.saw_request_metadata = std.mem.eql(u8, value, "request-1");
            }
            try context.addInitialMetadata("x-initial", "present");
            try context.addTrailingMetadata("x-trailing", "present");
            if (std.mem.eql(u8, request, "fail")) {
                return service.UnaryResponse.fail(
                    allocator,
                    .init(.invalid_argument, "bad % value\n"),
                );
            }
            if (std.mem.eql(u8, request, "slow")) c.uv_sleep(50);
            return service.UnaryResponse.ok(allocator, request);
        }
    };

    var handler = Handler{};
    var test_server = try server.Server.init(std.testing.allocator, .{});
    defer test_server.deinit();
    try test_server.registerUnary(
        "/test.Echo/Unary",
        service.UnaryHandler.bind(Handler, &handler, Handler.handle),
    );
    try test_server.start();

    var target_buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buffer, "127.0.0.1:{d}", .{try test_server.port()});
    var channel = try Channel.init(std.testing.allocator, target, .{});
    defer channel.deinit();

    var success = try channel.callUnary(
        std.testing.allocator,
        "/test.Echo/Unary",
        "hello",
        .{ .metadata = &.{.{ .key = "x-request-id", .value = "request-1" }} },
    );
    defer success.deinit();
    try std.testing.expect(success.status.isOk());
    try std.testing.expectEqualStrings("hello", success.payload);
    try std.testing.expectEqualStrings("present", success.initial_metadata.getFirst("x-initial").?);
    try std.testing.expectEqualStrings("present", success.trailing_metadata.getFirst("x-trailing").?);
    try std.testing.expect(handler.saw_request_metadata);

    const binary_payload = [_]u8{ 0, 1, 0xff, 0, 42 };
    var binary = try channel.callUnary(std.testing.allocator, "/test.Echo/Unary", &binary_payload, .{});
    defer binary.deinit();
    try std.testing.expectEqualSlices(u8, &binary_payload, binary.payload);

    var application_error = try channel.callUnary(std.testing.allocator, "/test.Echo/Unary", "fail", .{});
    defer application_error.deinit();
    try std.testing.expectEqual(status.Code.invalid_argument, application_error.status.code);
    try std.testing.expectEqualStrings("bad % value\n", application_error.status.message);
    try std.testing.expectEqualStrings("present", application_error.trailing_metadata.getFirst("x-trailing").?);

    var missing_method = try channel.callUnary(std.testing.allocator, "/test.Echo/Missing", "request", .{});
    defer missing_method.deinit();
    try std.testing.expectEqual(status.Code.unimplemented, missing_method.status.code);

    var limited = try channel.callUnary(
        std.testing.allocator,
        "/test.Echo/Unary",
        "too large",
        .{ .max_response_size = 3 },
    );
    defer limited.deinit();
    try std.testing.expectEqual(status.Code.resource_exhausted, limited.status.code);

    var reused = try channel.callUnary(std.testing.allocator, "/test.Echo/Unary", "again", .{});
    defer reused.deinit();
    try std.testing.expectEqualStrings("again", reused.payload);
    try std.testing.expectEqual(@as(usize, 1), channel.impl.connect_count);

    const Worker = struct {
        channel: *Channel,
        index: usize,
        succeeded: bool = false,

        fn run(self: *@This()) void {
            var request_buffer: [16]u8 = undefined;
            const request = std.fmt.bufPrint(&request_buffer, "request-{d}", .{self.index}) catch return;
            var result = self.channel.callUnary(std.testing.allocator, "/test.Echo/Unary", request, .{}) catch return;
            defer result.deinit();
            self.succeeded = result.status.isOk() and std.mem.eql(u8, request, result.payload);
        }
    };
    var workers: [8]Worker = undefined;
    var threads: [8]std.Thread = undefined;
    for (&workers, &threads, 0..) |*worker, *thread, index| {
        worker.* = .{ .channel = &channel, .index = index };
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{worker});
    }
    for (&threads) |*thread| thread.join();
    for (&workers) |worker| try std.testing.expect(worker.succeeded);
    try std.testing.expectEqual(@as(usize, 1), channel.impl.connect_count);

    var deadline = try channel.callUnary(
        std.testing.allocator,
        "/test.Echo/Unary",
        "slow",
        .{ .timeout_ns = 5 * std.time.ns_per_ms },
    );
    defer deadline.deinit();
    try std.testing.expectEqual(status.Code.deadline_exceeded, deadline.status.code);

    test_server.shutdown();
    test_server.wait();
    var unavailable = try channel.callUnary(std.testing.allocator, "/test.Echo/Unary", "after-close", .{});
    defer unavailable.deinit();
    try std.testing.expectEqual(status.Code.unavailable, unavailable.status.code);
}
