const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig").api;
const xev = @import("xev");
const call = @import("call.zig");
const Compression = @import("compression.zig").Compression;
const deadline_wire = @import("deadline.zig");
const frame = @import("frame.zig");
const message = @import("message.zig");
const metadata = @import("metadata.zig");
const status = @import("status.zig");
const version = @import("version.zig");

const ChannelOptions = struct {
    user_agent: []const u8 = version.user_agent,
};

pub const Options = ChannelOptions;

const AllocatorOperation = enum { alloc, resize, remap, free };

const SerializedAllocator = struct {
    backing: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    test_hook_context: if (builtin.is_test) std.atomic.Value(?*anyopaque) else void = if (builtin.is_test) .init(null) else {},
    test_before_lock: if (builtin.is_test) std.atomic.Value(?*const fn (?*anyopaque, AllocatorOperation) void) else void = if (builtin.is_test) .init(null) else {},

    fn init(backing: std.mem.Allocator) SerializedAllocator {
        return .{ .backing = backing };
    }

    fn allocator(self: *SerializedAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn lock(self: *SerializedAllocator, operation: AllocatorOperation) void {
        if (comptime builtin.is_test) {
            if (self.test_before_lock.load(.acquire)) |hook| {
                hook(self.test_hook_context.load(.acquire), operation);
            }
        }
        self.mutex.lockUncancelable(syncIo());
    }

    fn unlock(self: *SerializedAllocator) void {
        self.mutex.unlock(syncIo());
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *SerializedAllocator = @ptrCast(@alignCast(context));
        self.lock(.alloc);
        defer self.unlock();
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *SerializedAllocator = @ptrCast(@alignCast(context));
        self.lock(.resize);
        defer self.unlock();
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *SerializedAllocator = @ptrCast(@alignCast(context));
        self.lock(.remap);
        defer self.unlock();
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *SerializedAllocator = @ptrCast(@alignCast(context));
        self.lock(.free);
        defer self.unlock();
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

pub const Channel = struct {
    pub const Options = ChannelOptions;

    impl: *Impl,

    pub fn init(allocator: std.mem.Allocator, target: []const u8, options: ChannelOptions) !Channel {
        const parsed = try parseTarget(target);
        const impl = try allocator.create(Impl);
        errdefer allocator.destroy(impl);

        impl.* = .{
            .backing_allocator = allocator,
            .serialized_allocator = .init(allocator),
            .allocator = undefined,
            .host = undefined,
            .port = parsed.port,
            .authority = undefined,
            .user_agent = undefined,
            .async_handle = undefined,
            .deadline_timer = undefined,
        };
        impl.allocator = impl.serialized_allocator.allocator();

        const host = try impl.allocator.dupeZ(u8, parsed.host);
        errdefer impl.allocator.free(host);
        const authority = try impl.allocator.dupe(u8, target);
        errdefer impl.allocator.free(authority);
        const user_agent = try impl.allocator.dupe(u8, options.user_agent);
        errdefer impl.allocator.free(user_agent);

        var async_handle = try xev.Async.init();
        errdefer async_handle.deinit();
        var deadline_timer = try xev.Timer.init();
        errdefer deadline_timer.deinit();

        impl.host = host;
        impl.authority = authority;
        impl.user_agent = user_agent;
        impl.async_handle = async_handle;
        impl.deadline_timer = deadline_timer;
        impl.thread = try std.Thread.spawn(.{}, runLoop, .{impl});

        impl.mutex.lockUncancelable(syncIo());
        while (impl.state == .starting) impl.condition.waitUncancelable(syncIo(), &impl.mutex);
        const running = impl.state == .running;
        impl.mutex.unlock(syncIo());
        if (!running) {
            impl.thread.?.join();
            impl.thread = null;
            impl.pending.deinit(impl.allocator);
            return error.ConnectionFailed;
        }

        return .{ .impl = impl };
    }

    /// May be called concurrently. Input slices are borrowed until this function returns.
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

    /// May be called concurrently with active calls and causes them to finish promptly.
    pub fn shutdown(self: *Channel) void {
        const impl = self.impl;
        impl.mutex.lockUncancelable(syncIo());
        var notify = false;
        if (impl.state == .running) {
            impl.state = .stopping;
            notify = true;
        }
        impl.mutex.unlock(syncIo());
        if (notify) impl.async_handle.notify() catch {};
    }

    /// Waits for the channel event loop after shutdown.
    pub fn wait(self: *Channel) void {
        const impl = self.impl;
        impl.mutex.lockUncancelable(syncIo());
        const thread = impl.thread;
        impl.thread = null;
        impl.mutex.unlock(syncIo());
        if (thread) |running_thread| running_thread.join();
    }

    /// Requires exclusive access after all concurrent calls have returned.
    pub fn deinit(self: *Channel) void {
        const impl = self.impl;
        self.shutdown();
        self.wait();

        impl.pending.deinit(impl.allocator);
        impl.operations.deinit(impl.allocator);
        impl.writes.deinit(impl.allocator);
        impl.async_handle.deinit();
        impl.deadline_timer.deinit();
        impl.allocator.free(impl.user_agent);
        impl.allocator.free(impl.authority);
        impl.allocator.free(impl.host);
        const backing_allocator = impl.backing_allocator;
        backing_allocator.destroy(impl);
        self.* = undefined;
    }
};

const State = enum { starting, running, stopping, stopped };
const ConnectionState = enum { connecting, active, draining, closing };

const TestObserver = if (builtin.is_test) struct {
    write_requested: std.atomic.Value(bool) = .init(false),
    write_observed: std.atomic.Value(bool) = .init(false),
    write_observed_sem: std.Io.Semaphore = .{},
    connect_requested: std.atomic.Value(bool) = .init(false),
    connect_observed: std.atomic.Value(bool) = .init(false),
    connect_observed_sem: std.Io.Semaphore = .{},
    connect_release: std.Io.Semaphore = .{},
    connect_cancel_confirmed: std.atomic.Value(bool) = .init(false),
    deadline_timer_callbacks: std.atomic.Value(usize) = .init(0),
    deadline_timer_armed: std.atomic.Value(bool) = .init(false),
    deadline_timer_target_ns: std.atomic.Value(u64) = .init(0),
} else struct {};

const Impl = struct {
    backing_allocator: std.mem.Allocator,
    serialized_allocator: SerializedAllocator,
    allocator: std.mem.Allocator,
    host: [:0]u8,
    port: u16,
    authority: []u8,
    user_agent: []u8,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    state: State = .starting,
    thread: ?std.Thread = null,
    pending: std.ArrayList(*Operation) = .empty,
    operations: std.AutoHashMapUnmanaged(i32, *Operation) = .empty,
    loop: xev.Loop = undefined,
    tcp: xev.TCP = undefined,
    connect_completion: xev.Completion = .{},
    connect_cancel_completion: xev.Completion = .{},
    read_completion: xev.Completion = .{},
    read_cancel_completion: xev.Completion = .{},
    write_cancel_completion: xev.Completion = .{},
    close_completion: xev.Completion = .{},
    async_handle: xev.Async = undefined,
    async_completion: xev.Completion = .{},
    deadline_timer: xev.Timer = undefined,
    deadline_completion: xev.Completion = .{},
    deadline_reset_completion: xev.Completion = .{},
    session: ?*c.nghttp2_session = null,
    loop_initialized: bool = false,
    tcp_initialized: bool = false,
    connect_active: bool = false,
    connect_cancel_submitted: bool = false,
    read_active: bool = false,
    read_cancel_submitted: bool = false,
    write_cancel_submitted: bool = false,
    close_submitted: bool = false,
    close_completed: bool = false,
    deadline_timer_armed: bool = false,
    deadline_timer_deadline_ns: ?u64 = null,
    connected: bool = false,
    connection_state: ConnectionState = .connecting,
    connection_generation: usize = 0,
    stopping_on_loop: bool = false,
    connect_count: usize = 0,
    read_buffer: [16 * 1024]u8 = undefined,
    write_queue: xev.WriteQueue = .{},
    writes: std.AutoHashMapUnmanaged(*WriteRequest, void) = .empty,
    test_observer: TestObserver = .{},

    fn enqueue(self: *Impl, operation: *Operation) !bool {
        self.mutex.lockUncancelable(syncIo());
        defer self.mutex.unlock(syncIo());
        if (self.state != .running) return false;
        try self.pending.append(self.allocator, operation);
        if (self.async_handle.notify()) |_| {} else |_| {
            _ = self.pending.pop();
            return false;
        }
        return true;
    }

    fn signalStartup(self: *Impl, succeeded: bool) void {
        self.mutex.lockUncancelable(syncIo());
        if (self.state == .starting) self.state = if (succeeded) .running else .stopping;
        self.condition.broadcast(syncIo());
        self.mutex.unlock(syncIo());
    }

    fn markStopped(self: *Impl) void {
        self.mutex.lockUncancelable(syncIo());
        self.state = .stopped;
        self.condition.broadcast(syncIo());
        self.mutex.unlock(syncIo());
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
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    done: bool = false,
    outcome_set: bool = false,
    deadline_expired: bool = false,
    response_code: status.Code = .unknown,
    response_message: []u8 = &.{},
    response_message_owned: bool = false,
    response_payload: ?[]u8 = null,
    response_compression: Compression = .identity,
    response_encoding_invalid: bool = false,
    response_metadata_invalid: bool = false,
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
            .deadline_ns = if (options.timeout_ns) |timeout| nowNs() +| timeout else null,
            .initial_metadata = metadata.Metadata.init(impl.allocator),
            .trailing_metadata = metadata.Metadata.init(impl.allocator),
            .block_metadata = metadata.Metadata.init(impl.allocator),
        };
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
        allocator.destroy(self);
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
        self.mutex.lockUncancelable(syncIo());
        self.done = true;
        self.condition.broadcast(syncIo());
        self.mutex.unlock(syncIo());
    }

    fn wait(self: *Operation) void {
        self.mutex.lockUncancelable(syncIo());
        while (!self.done) self.condition.waitUncancelable(syncIo(), &self.mutex);
        self.mutex.unlock(syncIo());
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
    request: xev.WriteRequest = undefined,
    impl: *Impl,
    bytes: []u8,
    generation: usize,
};

fn runLoop(impl: *Impl) void {
    impl.loop = xev.Loop.init(.{}) catch {
        impl.signalStartup(false);
        impl.markStopped();
        return;
    };
    impl.loop_initialized = true;
    impl.async_handle.wait(&impl.loop, &impl.async_completion, Impl, impl, onAsync);
    startConnection(impl) catch {
        impl.signalStartup(false);
        beginStop(impl, "connection failed");
    };
    impl.loop.run(.until_done) catch {
        beginStop(impl, "event loop failed");
        impl.loop.run(.until_done) catch @panic("event loop failed while stopping");
    };
    std.debug.assert(impl.writes.count() == 0);
    std.debug.assert(impl.write_queue.head == null);
    if (impl.session) |session| c.nghttp2_session_del(session);
    impl.session = null;
    impl.loop.deinit();
    impl.loop_initialized = false;
    impl.markStopped();
}

fn startConnection(impl: *Impl) !void {
    const address = try std.Io.net.IpAddress.parseIp4(impl.host, impl.port);
    impl.tcp = try xev.TCP.init(address);
    impl.tcp_initialized = true;
    impl.close_submitted = false;
    impl.close_completed = false;
    impl.connected = false;
    impl.connection_state = .connecting;
    impl.connection_generation += 1;

    try initializeSession(impl);
    impl.connect_active = true;
    impl.tcp.connect(&impl.loop, &impl.connect_completion, address, Impl, impl, onConnect);
    observeTestIo(impl);
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

fn onConnect(impl_: ?*Impl, loop: *xev.Loop, _: *xev.Completion, _: xev.TCP, result: xev.ConnectError!void) xev.CallbackAction {
    const impl = impl_.?;
    impl.connect_active = false;
    defer submitCloseIfReady(impl, loop);
    result catch {
        impl.signalStartup(false);
        beginStop(impl, "connection failed");
        return .disarm;
    };
    impl.mutex.lockUncancelable(syncIo());
    const stopping = impl.state == .stopping or impl.state == .stopped;
    impl.mutex.unlock(syncIo());
    if (stopping) {
        beginStop(impl, "channel closed");
        return .disarm;
    }
    impl.connected = true;
    impl.connect_count += 1;
    impl.read_active = true;
    impl.tcp.read(&impl.loop, &impl.read_completion, .{ .slice = &impl.read_buffer }, Impl, impl, onRead);
    flush(impl) catch {
        impl.signalStartup(false);
        beginStop(impl, "connection failed");
        return .disarm;
    };
    impl.connection_state = .active;
    impl.signalStartup(true);
    processPending(impl);
    return .disarm;
}

fn onAsync(impl_: ?*Impl, _: *xev.Loop, _: *xev.Completion, result: xev.Async.WaitError!void) xev.CallbackAction {
    const impl = impl_.?;
    result catch {
        beginStop(impl, "channel wakeup failed");
        return .disarm;
    };
    observeTestIo(impl);
    impl.mutex.lockUncancelable(syncIo());
    const stopping = impl.state != .running;
    impl.mutex.unlock(syncIo());
    if (stopping) {
        beginStop(impl, "channel closed");
        return .disarm;
    }
    switch (impl.connection_state) {
        .active => processPending(impl),
        .draining => {
            if (impl.operations.count() == 0) beginReconnect(impl);
            scheduleDeadlineTimer(impl);
        },
        .connecting, .closing => scheduleDeadlineTimer(impl),
    }
    return .rearm;
}

fn processPending(impl: *Impl) void {
    if (impl.connection_state != .active) {
        scheduleDeadlineTimer(impl);
        return;
    }
    var pending: std.ArrayList(*Operation) = .empty;
    impl.mutex.lockUncancelable(syncIo());
    std.mem.swap(std.ArrayList(*Operation), &pending, &impl.pending);
    impl.mutex.unlock(syncIo());
    defer pending.deinit(impl.allocator);

    for (pending.items) |operation| {
        if (operation.deadline_ns) |deadline| {
            const now = nowNs();
            if (deadline <= now) {
                operation.deadline_expired = true;
                operation.setOutcome(.deadline_exceeded, "deadline exceeded") catch {};
                operation.complete();
                continue;
            }
            operation.timeout_header_len = deadline_wire.formatTimeout(&operation.timeout_header, deadline - now).len;
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
        try impl.writes.put(impl.allocator, write, {});
        impl.tcp.queueWrite(
            &impl.loop,
            &impl.write_queue,
            &write.request,
            .{ .slice = bytes },
            WriteRequest,
            write,
            onWrite,
        );
    }
}

fn onRead(impl_: ?*Impl, loop: *xev.Loop, _: *xev.Completion, _: xev.TCP, _: xev.ReadBuffer, result: xev.ReadError!usize) xev.CallbackAction {
    const impl = impl_.?;
    impl.read_active = false;
    defer submitCloseIfReady(impl, loop);
    const bytes_read = result catch {
        if (impl.connection_state == .closing or impl.stopping_on_loop) return .disarm;
        if (impl.connection_state == .draining and impl.operations.count() == 0) {
            beginReconnect(impl);
            return .disarm;
        }
        beginStop(impl, "connection closed");
        return .disarm;
    };
    if (bytes_read == 0) {
        beginStop(impl, "connection closed");
        return .disarm;
    }
    if (impl.connection_state == .closing or impl.stopping_on_loop) return .disarm;
    const consumed = c.nghttp2_session_mem_recv2(impl.session, impl.read_buffer[0..bytes_read].ptr, bytes_read);
    if (consumed < 0 or consumed != @as(c.nghttp2_ssize, @intCast(bytes_read))) {
        beginStop(impl, "HTTP/2 connection failed");
        return .disarm;
    }
    flush(impl) catch {
        beginStop(impl, "connection failed");
        return .disarm;
    };
    impl.read_active = true;
    return .rearm;
}

fn onWrite(write_: ?*WriteRequest, loop: *xev.Loop, _: *xev.Completion, _: xev.TCP, _: xev.WriteBuffer, result: xev.WriteError!usize) xev.CallbackAction {
    const write = write_.?;
    const impl = write.impl;
    const generation = write.generation;
    _ = impl.writes.remove(write);
    impl.allocator.free(write.bytes);
    impl.allocator.destroy(write);
    if (result) |_| {} else |_| if (generation == impl.connection_generation and impl.connection_state != .closing) {
        beginStop(impl, "connection write failed");
    }
    if (impl.stopping_on_loop) discardQueuedWrites(impl);
    submitCloseIfReady(impl, loop);
    return .disarm;
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
    } else {
        processResponseMetadata(operation, name, value) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
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
            impl.async_handle.notify() catch {};
        }
        return 0;
    }
    if (native_frame.*.hd.type != c.NGHTTP2_HEADERS) return 0;
    const operation: *Operation = @ptrCast(@alignCast(c.nghttp2_session_get_stream_user_data(session, native_frame.*.hd.stream_id) orelse return 0));
    operation.finishHeaderBlock() catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    if (operation.response_metadata_invalid and !operation.outcome_set) {
        operation.setOutcome(.internal, "invalid response metadata") catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
        if (native_frame.*.hd.flags & c.NGHTTP2_FLAG_END_STREAM == 0 and
            c.nghttp2_submit_rst_stream(session, c.NGHTTP2_FLAG_NONE, native_frame.*.hd.stream_id, c.NGHTTP2_CANCEL) != 0)
        {
            return c.NGHTTP2_ERR_CALLBACK_FAILURE;
        }
    }
    return 0;
}

fn onStreamClose(_: ?*c.nghttp2_session, stream_id: i32, error_code: u32, user_data: ?*anyopaque) callconv(.c) c_int {
    const impl: *Impl = @ptrCast(@alignCast(user_data.?));
    if (impl.operations.fetchRemove(stream_id)) |entry| {
        entry.value.finalize(error_code);
        scheduleDeadlineTimer(impl);
        if (impl.connection_state == .draining and impl.operations.count() == 0) {
            impl.async_handle.notify() catch {};
        }
    }
    return 0;
}

fn scheduleDeadlineTimer(impl: *Impl) void {
    if (impl.stopping_on_loop) return;
    while (earliestDeadline(impl)) |earliest| {
        const delay_ms = deadlineDelayMs(earliest, nowNs()) orelse {
            expireDeadlines(impl, nowNs()) catch |err| {
                beginStop(impl, if (err == error.DeadlineCancellationFailed)
                    "deadline cancellation failed"
                else
                    "connection failed");
                return;
            };
            continue;
        };
        if (!impl.deadline_timer_armed) {
            impl.deadline_timer_armed = true;
            impl.deadline_timer_deadline_ns = earliest;
            observeDeadlineTimerScheduled(impl, earliest);
            impl.deadline_timer.run(
                &impl.loop,
                &impl.deadline_completion,
                delay_ms,
                Impl,
                impl,
                onDeadlineTimer,
            );
        } else if (impl.deadline_timer_deadline_ns != earliest) {
            impl.deadline_timer_deadline_ns = earliest;
            observeDeadlineTimerScheduled(impl, earliest);
            impl.deadline_timer.reset(
                &impl.loop,
                &impl.deadline_completion,
                &impl.deadline_reset_completion,
                delay_ms,
                Impl,
                impl,
                onDeadlineTimer,
            );
        }
        return;
    }
}

fn earliestDeadline(impl: *Impl) ?u64 {
    var earliest: ?u64 = null;
    var iterator = impl.operations.valueIterator();
    while (iterator.next()) |operation_ptr| {
        const operation = operation_ptr.*;
        if (operation.deadline_expired) continue;
        includeEarlierDeadline(&earliest, operation.deadline_ns);
    }
    impl.mutex.lockUncancelable(syncIo());
    for (impl.pending.items) |operation| {
        if (operation.deadline_expired) continue;
        includeEarlierDeadline(&earliest, operation.deadline_ns);
    }
    impl.mutex.unlock(syncIo());
    return earliest;
}

fn includeEarlierDeadline(earliest: *?u64, candidate: ?u64) void {
    const deadline = candidate orelse return;
    if (earliest.* == null or deadline < earliest.*.?) earliest.* = deadline;
}

fn deadlineDelayMs(deadline_ns: u64, now_ns: u64) ?u64 {
    const remaining_ns = deadline_ns -| now_ns;
    if (remaining_ns == 0) return null;
    return @max(
        @as(u64, 1),
        std.math.divCeil(u64, remaining_ns, std.time.ns_per_ms) catch 1,
    );
}

fn onDeadlineTimer(impl_: ?*Impl, _: *xev.Loop, _: *xev.Completion, result: xev.Timer.RunError!void) xev.CallbackAction {
    const impl = impl_.?;
    impl.deadline_timer_armed = false;
    impl.deadline_timer_deadline_ns = null;
    if (comptime builtin.is_test) {
        _ = impl.test_observer.deadline_timer_callbacks.fetchAdd(1, .release);
        impl.test_observer.deadline_timer_target_ns.store(0, .release);
        impl.test_observer.deadline_timer_armed.store(false, .release);
    }
    result catch |err| switch (err) {
        error.Canceled => {
            scheduleDeadlineTimer(impl);
            return .disarm;
        },
        else => {
            beginStop(impl, "deadline timer failed");
            return .disarm;
        },
    };
    expireDeadlines(impl, nowNs()) catch |err| {
        beginStop(impl, if (err == error.DeadlineCancellationFailed)
            "deadline cancellation failed"
        else
            "connection failed");
        return .disarm;
    };
    scheduleDeadlineTimer(impl);
    return .disarm;
}

fn expireDeadlines(impl: *Impl, now: u64) !void {
    impl.mutex.lockUncancelable(syncIo());
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
    impl.mutex.unlock(syncIo());

    var iterator = impl.operations.valueIterator();
    while (iterator.next()) |operation_ptr| {
        const operation = operation_ptr.*;
        if (operation.deadline_expired) continue;
        if (operation.deadline_ns) |deadline| {
            if (deadline <= now) {
                operation.deadline_expired = true;
                operation.setOutcome(.deadline_exceeded, "deadline exceeded") catch {};
                if (c.nghttp2_submit_rst_stream(impl.session, c.NGHTTP2_FLAG_NONE, operation.stream_id, c.NGHTTP2_CANCEL) != 0) {
                    return error.DeadlineCancellationFailed;
                }
            }
        }
    }
    if (impl.connected) try flush(impl);
}

fn beginReconnect(impl: *Impl) void {
    if (impl.connection_state != .draining or impl.operations.count() != 0) return;
    impl.connection_state = .closing;
    impl.connected = false;
    if (impl.session) |session| {
        c.nghttp2_session_del(session);
        impl.session = null;
    }
    if (impl.read_active and !impl.read_cancel_submitted) {
        impl.read_cancel_submitted = true;
        impl.loop.cancel(
            &impl.read_completion,
            &impl.read_cancel_completion,
            Impl,
            impl,
            onReadCanceled,
        );
    }
    submitCloseIfReady(impl, &impl.loop);
}

fn submitCloseIfReady(impl: *Impl, loop: *xev.Loop) void {
    if (!impl.tcp_initialized) {
        if (impl.stopping_on_loop and
            !impl.connect_active and
            !impl.connect_cancel_submitted and
            !impl.read_active and
            !impl.read_cancel_submitted and
            !impl.write_cancel_submitted and
            impl.writes.count() == 0)
        {
            loop.stop();
        }
        return;
    }
    if (impl.close_submitted or
        impl.connect_active or
        impl.connect_cancel_submitted or
        impl.read_active or
        impl.read_cancel_submitted or
        impl.write_cancel_submitted or
        impl.writes.count() != 0) return;
    impl.close_submitted = true;
    impl.tcp.close(loop, &impl.close_completion, Impl, impl, onTcpClosed);
}

fn onTcpClosed(impl_: ?*Impl, loop: *xev.Loop, _: *xev.Completion, _: xev.TCP, _: xev.CloseError!void) xev.CallbackAction {
    const impl = impl_.?;
    impl.close_completed = true;
    impl.tcp_initialized = false;
    impl.connected = false;
    if (impl.stopping_on_loop) {
        loop.stop();
        return .disarm;
    }
    if (impl.connection_state != .closing) return .disarm;

    impl.mutex.lockUncancelable(syncIo());
    const running = impl.state == .running;
    impl.mutex.unlock(syncIo());
    if (!running) return .disarm;

    startConnection(impl) catch beginStop(impl, "connection failed");
    return .disarm;
}

fn onConnectCanceled(impl_: ?*Impl, loop: *xev.Loop, _: *xev.Completion, _: xev.CancelError!void) xev.CallbackAction {
    const impl = impl_.?;
    impl.connect_cancel_submitted = false;
    if (comptime builtin.is_test) impl.test_observer.connect_cancel_confirmed.store(true, .release);
    submitCloseIfReady(impl, loop);
    return .disarm;
}

fn onReadCanceled(impl_: ?*Impl, loop: *xev.Loop, _: *xev.Completion, _: xev.CancelError!void) xev.CallbackAction {
    const impl = impl_.?;
    impl.read_cancel_submitted = false;
    submitCloseIfReady(impl, loop);
    return .disarm;
}

fn onWriteCanceled(impl_: ?*Impl, loop: *xev.Loop, _: *xev.Completion, _: xev.CancelError!void) xev.CallbackAction {
    const impl = impl_.?;
    impl.write_cancel_submitted = false;
    submitCloseIfReady(impl, loop);
    return .disarm;
}

fn beginStop(impl: *Impl, reason: []const u8) void {
    if (impl.stopping_on_loop) return;
    impl.stopping_on_loop = true;
    impl.connection_state = .closing;
    impl.connected = false;
    impl.mutex.lockUncancelable(syncIo());
    if (impl.state == .starting) {
        impl.state = .stopping;
        impl.condition.broadcast(syncIo());
    } else if (impl.state == .running) {
        impl.state = .stopping;
    }
    var pending: std.ArrayList(*Operation) = .empty;
    std.mem.swap(std.ArrayList(*Operation), &pending, &impl.pending);
    impl.mutex.unlock(syncIo());

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

    if (impl.connect_active and !impl.connect_cancel_submitted) {
        impl.connect_cancel_submitted = true;
        impl.loop.cancel(
            &impl.connect_completion,
            &impl.connect_cancel_completion,
            Impl,
            impl,
            onConnectCanceled,
        );
    }
    if (impl.read_active and !impl.read_cancel_submitted) {
        impl.read_cancel_submitted = true;
        impl.loop.cancel(
            &impl.read_completion,
            &impl.read_cancel_completion,
            Impl,
            impl,
            onReadCanceled,
        );
    }
    if (impl.write_queue.head) |request| {
        if (request.completion.state() == .active) {
            if (!impl.write_cancel_submitted) {
                impl.write_cancel_submitted = true;
                impl.loop.cancel(
                    &request.completion,
                    &impl.write_cancel_completion,
                    Impl,
                    impl,
                    onWriteCanceled,
                );
            }
        } else {
            discardQueuedWrites(impl);
        }
    }
    submitCloseIfReady(impl, &impl.loop);
}

fn discardQueuedWrites(impl: *Impl) void {
    while (impl.write_queue.pop()) |request| {
        const write: *WriteRequest = @fieldParentPtr("request", request);
        _ = impl.writes.remove(write);
        impl.allocator.free(write.bytes);
        impl.allocator.destroy(write);
    }
}

fn observeTestIo(impl: *Impl) void {
    if (comptime builtin.is_test) {
        if (impl.test_observer.write_requested.swap(false, .acq_rel)) {
            if (impl.write_queue.head) |request| {
                if (request.completion.state() == .active) {
                    impl.test_observer.write_observed.store(true, .release);
                    impl.test_observer.write_observed_sem.post(std.testing.io);
                }
            }
        }
        if (impl.test_observer.connect_requested.load(.acquire) and
            impl.connect_active and
            impl.connect_completion.state() == .active)
        {
            impl.test_observer.connect_requested.store(false, .release);
            impl.test_observer.connect_observed.store(true, .release);
            impl.test_observer.connect_observed_sem.post(std.testing.io);
            impl.test_observer.connect_release.waitUncancelable(std.testing.io);
        }
    }
}

fn observeDeadlineTimerScheduled(impl: *Impl, deadline_ns: u64) void {
    if (comptime builtin.is_test) {
        impl.test_observer.deadline_timer_target_ns.store(deadline_ns, .release);
        impl.test_observer.deadline_timer_armed.store(true, .release);
    }
}

fn syncIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn nowNs() u64 {
    return @intCast(std.Io.Clock.awake.now(syncIo()).nanoseconds);
}

fn waitForTestFlag(flag: *const std.atomic.Value(bool), timeout_ns: u64) bool {
    const deadline = nowNs() +| timeout_ns;
    while (!flag.load(.acquire)) {
        if (nowNs() >= deadline) return false;
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch return false;
    }
    return true;
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
    return metadata.isApplicationKey(name) and !isReservedRequestHeader(name);
}

fn isResponseMetadata(name: []const u8) bool {
    return metadata.isApplicationKey(name) and !isReservedResponseHeader(name);
}

fn isReservedRequestHeader(name: []const u8) bool {
    const protocol_headers = [_][]const u8{ "content-type", "te", "user-agent" };
    for (protocol_headers) |header| if (std.mem.eql(u8, name, header)) return true;
    return std.mem.startsWith(u8, name, "grpc-");
}

fn isReservedResponseHeader(name: []const u8) bool {
    if (std.mem.eql(u8, name, "content-type")) return true;
    return std.mem.startsWith(u8, name, "grpc-");
}

fn isMalformedResponseMetadataName(name: []const u8) bool {
    if (name.len == 0 or name[0] == ':' or isReservedResponseHeader(name)) return false;
    return !metadata.isValidKey(name);
}

fn processResponseMetadata(operation: *Operation, name: []const u8, value: []const u8) error{OutOfMemory}!void {
    if (isResponseMetadata(name)) {
        _ = operation.block_metadata.appendDecoded(name, value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                operation.response_metadata_invalid = true;
                return;
            },
        };
    } else if (isMalformedResponseMetadataName(name)) {
        operation.response_metadata_invalid = true;
    }
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

test "earliest deadline selection is order independent" {
    var earliest: ?u64 = null;
    includeEarlierDeadline(&earliest, null);
    try std.testing.expectEqual(@as(?u64, null), earliest);

    includeEarlierDeadline(&earliest, 300);
    includeEarlierDeadline(&earliest, 100);
    includeEarlierDeadline(&earliest, 200);
    try std.testing.expectEqual(@as(?u64, 100), earliest);

    earliest = null;
    includeEarlierDeadline(&earliest, 200);
    includeEarlierDeadline(&earliest, 300);
    includeEarlierDeadline(&earliest, 100);
    try std.testing.expectEqual(@as(?u64, 100), earliest);
}

test "deadline timer delay rounds up and handles boundaries" {
    try std.testing.expectEqual(@as(?u64, null), deadlineDelayMs(100, 100));
    try std.testing.expectEqual(@as(?u64, null), deadlineDelayMs(99, 100));
    try std.testing.expectEqual(@as(?u64, 1), deadlineDelayMs(101, 100));
    try std.testing.expectEqual(@as(?u64, 1), deadlineDelayMs(std.time.ns_per_ms, 0));
    try std.testing.expectEqual(@as(?u64, 2), deadlineDelayMs(std.time.ns_per_ms + 1, 0));
    try std.testing.expectEqual(
        @as(?u64, std.math.divCeil(u64, std.math.maxInt(u64), std.time.ns_per_ms) catch unreachable),
        deadlineDelayMs(std.math.maxInt(u64), 0),
    );
}

test "serialized allocator forwards every vtable operation" {
    const OperationKind = enum { none, alloc, resize, remap, free };
    const Probe = struct {
        storage: [64]u8 align(16) = undefined,
        operation: OperationKind = .none,
        len: usize = 0,
        memory_address: usize = 0,
        alignment: std.mem.Alignment = .@"1",
        new_len: usize = 0,
        ret_addr: usize = 0,

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = alloc,
                    .resize = resize,
                    .remap = remap,
                    .free = free,
                },
            };
        }

        fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.operation = .alloc;
            self.len = len;
            self.alignment = alignment;
            self.ret_addr = ret_addr;
            return self.storage[0..].ptr;
        }

        fn resize(
            context: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            new_len: usize,
            ret_addr: usize,
        ) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.operation = .resize;
            self.memory_address = @intFromPtr(memory.ptr);
            self.len = memory.len;
            self.alignment = alignment;
            self.new_len = new_len;
            self.ret_addr = ret_addr;
            return true;
        }

        fn remap(
            context: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            new_len: usize,
            ret_addr: usize,
        ) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.operation = .remap;
            self.memory_address = @intFromPtr(memory.ptr);
            self.len = memory.len;
            self.alignment = alignment;
            self.new_len = new_len;
            self.ret_addr = ret_addr;
            return self.storage[16..].ptr;
        }

        fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.operation = .free;
            self.memory_address = @intFromPtr(memory.ptr);
            self.len = memory.len;
            self.alignment = alignment;
            self.ret_addr = ret_addr;
        }
    };

    var probe = Probe{};
    var serialized = SerializedAllocator.init(probe.allocator());
    const allocator = serialized.allocator();
    const memory = probe.storage[0..8];

    const allocated = allocator.rawAlloc(8, .@"16", 11).?;
    try std.testing.expectEqual(@intFromPtr(probe.storage[0..].ptr), @intFromPtr(allocated));
    try std.testing.expectEqual(OperationKind.alloc, probe.operation);
    try std.testing.expectEqual(@as(usize, 8), probe.len);
    try std.testing.expectEqual(std.mem.Alignment.@"16", probe.alignment);
    try std.testing.expectEqual(@as(usize, 11), probe.ret_addr);

    try std.testing.expect(allocator.rawResize(memory, .@"8", 12, 22));
    try std.testing.expectEqual(OperationKind.resize, probe.operation);
    try std.testing.expectEqual(@intFromPtr(memory.ptr), probe.memory_address);
    try std.testing.expectEqual(memory.len, probe.len);
    try std.testing.expectEqual(std.mem.Alignment.@"8", probe.alignment);
    try std.testing.expectEqual(@as(usize, 12), probe.new_len);
    try std.testing.expectEqual(@as(usize, 22), probe.ret_addr);

    const remapped = allocator.rawRemap(memory, .@"4", 24, 33).?;
    try std.testing.expectEqual(@intFromPtr(probe.storage[16..].ptr), @intFromPtr(remapped));
    try std.testing.expectEqual(OperationKind.remap, probe.operation);
    try std.testing.expectEqual(@intFromPtr(memory.ptr), probe.memory_address);
    try std.testing.expectEqual(memory.len, probe.len);
    try std.testing.expectEqual(std.mem.Alignment.@"4", probe.alignment);
    try std.testing.expectEqual(@as(usize, 24), probe.new_len);
    try std.testing.expectEqual(@as(usize, 33), probe.ret_addr);

    allocator.rawFree(memory, .@"2", 44);
    try std.testing.expectEqual(OperationKind.free, probe.operation);
    try std.testing.expectEqual(@intFromPtr(memory.ptr), probe.memory_address);
    try std.testing.expectEqual(memory.len, probe.len);
    try std.testing.expectEqual(std.mem.Alignment.@"2", probe.alignment);
    try std.testing.expectEqual(@as(usize, 44), probe.ret_addr);
}

test "target parsing" {
    const target = try parseTarget("127.0.0.1:50051");
    try std.testing.expectEqualStrings("127.0.0.1", target.host);
    try std.testing.expectEqual(@as(u16, 50051), target.port);
    try std.testing.expectError(error.InvalidTarget, parseTarget("localhost"));
    try std.testing.expectError(error.InvalidTarget, parseTarget("[::1]:50051"));
}

test "outbound metadata rejects invalid application values before queuing" {
    var host = [_:0]u8{'x'};
    var impl: Impl = .{
        .backing_allocator = std.testing.allocator,
        .serialized_allocator = .init(std.testing.allocator),
        .allocator = undefined,
        .host = host[0..1 :0],
        .port = 1,
        .authority = &.{},
        .user_agent = &.{},
    };
    impl.allocator = impl.serialized_allocator.allocator();

    try std.testing.expectError(error.InvalidMetadataValue, Operation.init(
        &impl,
        "/test.Echo/Unary",
        "request",
        .{ .metadata = &.{.{ .key = "x-control", .value = "bad\tvalue" }} },
    ));
    try std.testing.expectError(error.InvalidMetadataKey, Operation.init(
        &impl,
        "/test.Echo/Unary",
        "request",
        .{ .metadata = &.{.{ .key = "grpc-future", .value = "value" }} },
    ));

    var binary = try Operation.init(
        &impl,
        "/test.Echo/Unary",
        "request",
        .{ .metadata = &.{.{ .key = "trace-bin", .value = "\x00\xff" }} },
    );
    binary.deinit();
}

test "malformed binary response metadata marks only the operation invalid" {
    var host = [_:0]u8{'x'};
    var impl: Impl = .{
        .backing_allocator = std.testing.allocator,
        .serialized_allocator = .init(std.testing.allocator),
        .allocator = undefined,
        .host = host[0..1 :0],
        .port = 1,
        .authority = &.{},
        .user_agent = &.{},
    };
    impl.allocator = impl.serialized_allocator.allocator();

    const operation = try Operation.init(&impl, "/test.Echo/Unary", "request", .{});
    defer operation.deinit();
    try processResponseMetadata(operation, "grpc-future", "ignored");
    try processResponseMetadata(operation, "x-control", "bad\tvalue");
    try std.testing.expect(!operation.response_metadata_invalid);
    try std.testing.expectEqual(@as(usize, 0), operation.block_metadata.items().len);
    try processResponseMetadata(operation, "trace-bin", "qw,not base64!");
    try std.testing.expect(operation.response_metadata_invalid);
    try std.testing.expectEqual(@as(usize, 0), operation.block_metadata.items().len);
}

test "response headers with grpc-status are trailers-only metadata" {
    var host = [_:0]u8{'x'};
    var impl: Impl = .{
        .backing_allocator = std.testing.allocator,
        .serialized_allocator = .init(std.testing.allocator),
        .allocator = undefined,
        .host = host[0..1 :0],
        .port = 1,
        .authority = &.{},
        .user_agent = &.{},
    };
    impl.allocator = impl.serialized_allocator.allocator();
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

test "channel connection refusal cleans up startup resources" {
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    const socket = try xev.TCP.init(address);
    defer _ = std.posix.system.close(socket.fd);
    try socket.bind(address);

    var local_address: std.posix.sockaddr.in = undefined;
    var address_length: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
    if (std.posix.errno(std.posix.system.getsockname(
        socket.fd,
        @ptrCast(&local_address),
        &address_length,
    )) != .SUCCESS) return error.AddressQueryFailed;

    var target_buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(
        &target_buffer,
        "127.0.0.1:{d}",
        .{std.mem.bigToNative(u16, local_address.port)},
    );
    for (0..4) |_| {
        try std.testing.expectError(
            error.ConnectionFailed,
            Channel.init(std.testing.allocator, target, .{}),
        );
    }
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

test "malformed response metadata fails one call and preserves the channel" {
    const server = @import("server.zig");
    const service = @import("service.zig");

    const Handler = struct {
        calls: usize = 0,

        fn appendUnchecked(target: *metadata.Metadata, key: []const u8, value: []const u8) !void {
            const owned_key = try target.allocator.dupe(u8, key);
            errdefer target.allocator.free(owned_key);
            const owned_value = try target.allocator.dupe(u8, value);
            errdefer target.allocator.free(owned_value);
            try target.entries.append(target.allocator, .{ .key = owned_key, .value = owned_value });
        }

        fn handle(
            self: *@This(),
            allocator: std.mem.Allocator,
            context: *service.ServerContext,
            request: []const u8,
        ) !service.UnaryResponse {
            self.calls += 1;
            if (std.mem.eql(u8, request, "bad-key")) {
                try appendUnchecked(&context.initial_metadata, "x!invalid", "value");
            } else if (std.mem.eql(u8, request, "bad-trailer")) {
                try appendUnchecked(&context.trailing_metadata, "x!invalid", "value");
            } else if (std.mem.eql(u8, request, "bad-ascii")) {
                try appendUnchecked(&context.initial_metadata, "x-control", "bad\tvalue");
            }
            return service.UnaryResponse.ok(allocator, request);
        }
    };

    var handler = Handler{};
    var test_server = try server.Server.init(std.testing.allocator, .{});
    defer test_server.deinit();
    try test_server.registerUnary(
        "/test.Metadata/InvalidResponse",
        service.UnaryHandler.bind(Handler, &handler, Handler.handle),
    );
    try test_server.start();

    var target_buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buffer, "127.0.0.1:{d}", .{try test_server.port()});
    var channel = try Channel.init(std.testing.allocator, target, .{});
    defer channel.deinit();

    const Worker = struct {
        channel: *Channel,
        request: []const u8,
        expected: status.Code,
        succeeded: bool = false,

        fn run(self: *@This()) void {
            var result = self.channel.callUnary(
                std.testing.allocator,
                "/test.Metadata/InvalidResponse",
                self.request,
                .{},
            ) catch return;
            defer result.deinit();
            self.succeeded = result.status.code == self.expected and
                (self.expected != .ok or std.mem.eql(u8, self.request, result.payload));
        }
    };
    var workers = [_]Worker{
        .{ .channel = &channel, .request = "bad-key", .expected = .internal },
        .{ .channel = &channel, .request = "concurrent", .expected = .ok },
    };
    var threads: [workers.len]std.Thread = undefined;
    for (&workers, &threads) |*worker, *thread| thread.* = try std.Thread.spawn(.{}, Worker.run, .{worker});
    for (&threads) |thread| thread.join();
    for (&workers) |worker| try std.testing.expect(worker.succeeded);

    var discarded = try channel.callUnary(std.testing.allocator, "/test.Metadata/InvalidResponse", "bad-ascii", .{});
    defer discarded.deinit();
    try std.testing.expect(discarded.status.isOk());
    try std.testing.expectEqualStrings("bad-ascii", discarded.payload);
    try std.testing.expect(discarded.initial_metadata.getFirst("x-control") == null);

    var bad_trailer = try channel.callUnary(std.testing.allocator, "/test.Metadata/InvalidResponse", "bad-trailer", .{});
    defer bad_trailer.deinit();
    try std.testing.expectEqual(status.Code.internal, bad_trailer.status.code);

    var reused = try channel.callUnary(std.testing.allocator, "/test.Metadata/InvalidResponse", "reused", .{});
    defer reused.deinit();
    try std.testing.expect(reused.status.isOk());
    try std.testing.expectEqualStrings("reused", reused.payload);
    try std.testing.expectEqual(@as(usize, 5), handler.calls);
    try std.testing.expectEqual(@as(usize, 1), channel.impl.connect_count);
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
                try connection.submitGoAway(1, c.NGHTTP2_NO_ERROR);
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

test "channel shutdown safely completes an active call before exclusive deinit" {
    const server = @import("server.zig");
    const service = @import("service.zig");

    const Handler = struct {
        entered: std.Io.Semaphore = .{},
        release: std.Io.Semaphore = .{},

        fn handle(
            self: *@This(),
            allocator: std.mem.Allocator,
            _: *service.ServerContext,
            request: []const u8,
        ) !service.UnaryResponse {
            self.entered.post(std.testing.io);
            self.release.waitUncancelable(std.testing.io);
            return service.UnaryResponse.ok(allocator, request);
        }
    };

    var handler = Handler{};
    var test_server = try server.Server.init(std.testing.allocator, .{});
    defer test_server.deinit();
    try test_server.registerUnary(
        "/test.Lifecycle/Unary",
        service.UnaryHandler.bind(Handler, &handler, Handler.handle),
    );
    try test_server.start();

    var target_buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buffer, "127.0.0.1:{d}", .{try test_server.port()});
    var channel = try Channel.init(std.testing.allocator, target, .{});
    defer channel.deinit();

    const Worker = struct {
        channel: *Channel,
        done: std.Io.Semaphore = .{},
        code: status.Code = .unknown,
        returned_result: bool = false,

        fn run(self: *@This()) void {
            var result = self.channel.callUnary(
                std.testing.allocator,
                "/test.Lifecycle/Unary",
                "request",
                .{},
            ) catch {
                self.done.post(std.testing.io);
                return;
            };
            defer result.deinit();
            self.code = result.status.code;
            self.returned_result = true;
            self.done.post(std.testing.io);
        }
    };

    var worker = Worker{ .channel = &channel };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    handler.entered.waitUncancelable(std.testing.io);
    channel.shutdown();
    worker.done.waitUncancelable(std.testing.io);
    handler.release.post(std.testing.io);
    thread.join();

    try std.testing.expect(worker.returned_result);
    try std.testing.expectEqual(status.Code.unavailable, worker.code);
}

test "channel shutdown cancels an active blocked write" {
    var listen_address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try listen_address.listen(std.testing.io, .{});
    defer listener.deinit(std.testing.io);

    var local_address: std.posix.sockaddr.in = undefined;
    var address_length: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
    if (std.posix.errno(std.posix.system.getsockname(
        listener.socket.handle,
        @ptrCast(&local_address),
        &address_length,
    )) != .SUCCESS) return error.AddressQueryFailed;

    var target_buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(
        &target_buffer,
        "127.0.0.1:{d}",
        .{std.mem.bigToNative(u16, local_address.port)},
    );
    var channel = try Channel.init(std.testing.allocator, target, .{});
    defer channel.deinit();

    var peer = try listener.accept(std.testing.io);
    var peer_open = true;
    defer if (peer_open) peer.close(std.testing.io);

    const send_buffer: c_int = 4096;
    try std.posix.setsockopt(
        channel.impl.tcp.fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.SNDBUF,
        std.mem.asBytes(&send_buffer),
    );

    const flow_control_frames = [_]u8{
        // SETTINGS_INITIAL_WINDOW_SIZE = 16 MiB - 1.
        0x00, 0x00, 0x06, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x04, 0x00, 0xff, 0xff, 0xff,
        // Increase the connection window by another 16 MiB - 1.
        0x00, 0x00, 0x04,
        0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff,
        0xff,
    };
    var peer_write_buffer: [64]u8 = undefined;
    var peer_writer = peer.writer(std.testing.io, &peer_write_buffer);
    try peer_writer.interface.writeAll(&flow_control_frames);
    try peer_writer.interface.flush();

    const payload = try std.testing.allocator.alloc(u8, 16 * 1024 * 1024);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');

    const Worker = struct {
        channel: *Channel,
        payload: []const u8,
        done: std.atomic.Value(bool) = .init(false),
        code: status.Code = .unknown,
        returned_result: bool = false,

        fn run(self: *@This()) void {
            var result = self.channel.callUnary(
                std.testing.allocator,
                "/test.Lifecycle/BlockedWrite",
                self.payload,
                .{},
            ) catch {
                self.done.store(true, .release);
                return;
            };
            defer result.deinit();
            self.code = result.status.code;
            self.returned_result = true;
            self.done.store(true, .release);
        }
    };
    const Waiter = struct {
        channel: *Channel,
        done: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.channel.wait();
            self.done.store(true, .release);
        }
    };

    var worker = Worker{ .channel = &channel, .payload = payload };
    const worker_thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});

    const observe_deadline = nowNs() +| 5 * std.time.ns_per_s;
    while (!channel.impl.test_observer.write_observed.load(.acquire) and nowNs() < observe_deadline) {
        channel.impl.test_observer.write_requested.store(true, .release);
        channel.impl.async_handle.notify() catch break;
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch break;
    }
    const write_observed = channel.impl.test_observer.write_observed.load(.acquire);
    if (!write_observed) {
        channel.shutdown();
        peer.close(std.testing.io);
        peer_open = false;
        worker_thread.join();
        channel.wait();
        try std.testing.expect(write_observed);
        return;
    }
    channel.impl.test_observer.write_observed_sem.waitUncancelable(std.testing.io);

    channel.shutdown();
    var waiter = Waiter{ .channel = &channel };
    const waiter_thread = std.Thread.spawn(.{}, Waiter.run, .{&waiter}) catch |err| {
        peer.close(std.testing.io);
        peer_open = false;
        worker_thread.join();
        channel.wait();
        return err;
    };
    const worker_finished = waitForTestFlag(&worker.done, 5 * std.time.ns_per_s);
    const waiter_finished = waitForTestFlag(&waiter.done, 5 * std.time.ns_per_s);
    if (!worker_finished or !waiter_finished) {
        peer.close(std.testing.io);
        peer_open = false;
    }
    worker_thread.join();
    waiter_thread.join();

    try std.testing.expect(worker_finished);
    try std.testing.expect(waiter_finished);
    try std.testing.expect(worker.returned_result);
    try std.testing.expectEqual(status.Code.unavailable, worker.code);
}

test "channel shutdown drains an active reconnect completion" {
    const server = @import("server.zig");
    const service = @import("service.zig");

    const Handler = struct {
        server: *server.Server,

        fn handle(
            self: *@This(),
            allocator: std.mem.Allocator,
            _: *service.ServerContext,
            request: []const u8,
        ) !service.UnaryResponse {
            const connection = self.server.impl.connections.items[0];
            try connection.submitGoAway(1, c.NGHTTP2_NO_ERROR);
            return service.UnaryResponse.ok(allocator, request);
        }
    };
    const Waiter = struct {
        channel: *Channel,
        done: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.channel.wait();
            self.done.store(true, .release);
        }
    };

    var test_server = try server.Server.init(std.testing.allocator, .{});
    defer test_server.deinit();
    var handler = Handler{ .server = &test_server };
    try test_server.registerUnary(
        "/test.Lifecycle/Reconnect",
        service.UnaryHandler.bind(Handler, &handler, Handler.handle),
    );
    try test_server.start();

    var target_buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buffer, "127.0.0.1:{d}", .{try test_server.port()});
    var channel = try Channel.init(std.testing.allocator, target, .{});
    defer channel.deinit();

    channel.impl.test_observer.connect_requested.store(true, .release);
    var connect_released = false;
    defer if (!connect_released) channel.impl.test_observer.connect_release.post(std.testing.io);
    var result = try channel.callUnary(
        std.testing.allocator,
        "/test.Lifecycle/Reconnect",
        "request",
        .{},
    );
    defer result.deinit();
    try std.testing.expect(result.status.isOk());

    const connect_observed = waitForTestFlag(
        &channel.impl.test_observer.connect_observed,
        5 * std.time.ns_per_s,
    );
    if (!connect_observed) {
        channel.shutdown();
        channel.impl.test_observer.connect_release.post(std.testing.io);
        connect_released = true;
        channel.wait();
        try std.testing.expect(connect_observed);
        return;
    }
    channel.impl.test_observer.connect_observed_sem.waitUncancelable(std.testing.io);

    channel.shutdown();
    channel.impl.test_observer.connect_release.post(std.testing.io);
    connect_released = true;
    var waiter = Waiter{ .channel = &channel };
    const waiter_thread = std.Thread.spawn(.{}, Waiter.run, .{&waiter}) catch |err| {
        channel.wait();
        return err;
    };
    const waiter_finished = waitForTestFlag(&waiter.done, 5 * std.time.ns_per_s);
    if (!waiter_finished) test_server.shutdown();
    waiter_thread.join();

    try std.testing.expect(waiter_finished);
    try std.testing.expect(channel.impl.test_observer.connect_cancel_confirmed.load(.acquire));
    try std.testing.expect(!channel.impl.connect_active);
    try std.testing.expect(!channel.impl.connect_cancel_submitted);
    try std.testing.expect(channel.impl.close_completed);
}

test "server context observes a wire deadline and overrides a late handler response" {
    const server = @import("server.zig");
    const service = @import("service.zig");

    const FakeClock = struct {
        now_ns: u64 = 100,

        fn now(context: ?*anyopaque) u64 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return self.now_ns;
        }
    };
    const Handler = struct {
        clock: *FakeClock,
        saw_deadline: bool = false,
        saw_no_deadline: bool = false,
        calls: usize = 0,

        fn handle(
            self: *@This(),
            allocator: std.mem.Allocator,
            context: *service.ServerContext,
            request: []const u8,
        ) !service.UnaryResponse {
            self.calls += 1;
            if (context.hasDeadline()) {
                self.saw_deadline = context.remainingTimeNs().? > 0 and !context.isDeadlineExceeded();
                self.clock.now_ns +|= 20 * std.time.ns_per_s;
            } else {
                self.saw_no_deadline = true;
            }
            return service.UnaryResponse.ok(allocator, request);
        }
    };

    var fake_clock = FakeClock{};
    var handler = Handler{ .clock = &fake_clock };
    var test_server = try server.Server.init(std.testing.allocator, .{});
    defer test_server.deinit();
    test_server.impl.clock = .{ .context = &fake_clock, .now_fn = FakeClock.now };
    try test_server.registerUnary(
        "/test.Deadline/Unary",
        service.UnaryHandler.bind(Handler, &handler, Handler.handle),
    );
    try test_server.start();

    var target_buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buffer, "127.0.0.1:{d}", .{try test_server.port()});
    var channel = try Channel.init(std.testing.allocator, target, .{});
    defer channel.deinit();

    var expired = try channel.callUnary(
        std.testing.allocator,
        "/test.Deadline/Unary",
        "late",
        .{ .timeout_ns = 10 * std.time.ns_per_s },
    );
    defer expired.deinit();
    try std.testing.expectEqual(status.Code.deadline_exceeded, expired.status.code);
    try std.testing.expect(handler.saw_deadline);

    var reused = try channel.callUnary(std.testing.allocator, "/test.Deadline/Unary", "reused", .{});
    defer reused.deinit();
    try std.testing.expect(reused.status.isOk());
    try std.testing.expectEqualStrings("reused", reused.payload);
    try std.testing.expect(handler.saw_no_deadline);
    try std.testing.expectEqual(@as(usize, 2), handler.calls);
    try std.testing.expectEqual(@as(usize, 1), channel.impl.connect_count);
}

test "channel deadline timer does not poll before a distant deadline" {
    const server = @import("server.zig");
    const service = @import("service.zig");

    const Handler = struct {
        entered: std.Io.Semaphore = .{},
        release: std.Io.Semaphore = .{},

        fn handle(
            self: *@This(),
            allocator: std.mem.Allocator,
            _: *service.ServerContext,
            request: []const u8,
        ) !service.UnaryResponse {
            self.entered.post(std.testing.io);
            self.release.waitUncancelable(std.testing.io);
            return service.UnaryResponse.ok(allocator, request);
        }
    };
    const Worker = struct {
        channel: *Channel,
        returned_result: bool = false,
        code: status.Code = .unknown,

        fn run(self: *@This()) void {
            var result = self.channel.callUnary(
                std.testing.allocator,
                "/test.Deadline/NoPolling",
                "request",
                .{ .timeout_ns = 2 * std.time.ns_per_s },
            ) catch return;
            defer result.deinit();
            self.returned_result = true;
            self.code = result.status.code;
        }
    };

    var handler = Handler{};
    var test_server = try server.Server.init(std.testing.allocator, .{});
    defer test_server.deinit();
    try test_server.registerUnary(
        "/test.Deadline/NoPolling",
        service.UnaryHandler.bind(Handler, &handler, Handler.handle),
    );
    try test_server.start();

    var target_buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buffer, "127.0.0.1:{d}", .{try test_server.port()});
    var channel = try Channel.init(std.testing.allocator, target, .{});
    defer channel.deinit();

    var worker = Worker{ .channel = &channel };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    handler.entered.waitUncancelable(std.testing.io);
    const armed = waitForTestFlag(
        &channel.impl.test_observer.deadline_timer_armed,
        5 * std.time.ns_per_s,
    );
    const baseline = channel.impl.test_observer.deadline_timer_callbacks.load(.acquire);
    std.Io.sleep(std.testing.io, .fromMilliseconds(100), .awake) catch {};
    const observed = channel.impl.test_observer.deadline_timer_callbacks.load(.acquire);
    handler.release.post(std.testing.io);
    thread.join();

    try std.testing.expect(armed);
    try std.testing.expectEqual(@as(usize, 0), observed - baseline);
    try std.testing.expect(worker.returned_result);
    try std.testing.expectEqual(status.Code.ok, worker.code);
}

test "channel resets its timer when an earlier deadline is added" {
    const server = @import("server.zig");
    const service = @import("service.zig");

    const Handler = struct {
        entered: std.Io.Semaphore = .{},
        release: std.Io.Semaphore = .{},

        fn handle(
            self: *@This(),
            allocator: std.mem.Allocator,
            _: *service.ServerContext,
            request: []const u8,
        ) !service.UnaryResponse {
            if (std.mem.eql(u8, request, "first")) {
                self.entered.post(std.testing.io);
                self.release.waitUncancelable(std.testing.io);
            }
            return service.UnaryResponse.ok(allocator, request);
        }
    };
    const Worker = struct {
        channel: *Channel,
        request: []const u8,
        timeout_ns: u64,
        returned_result: bool = false,
        code: status.Code = .unknown,

        fn run(self: *@This()) void {
            var result = self.channel.callUnary(
                std.testing.allocator,
                "/test.Deadline/Earlier",
                self.request,
                .{ .timeout_ns = self.timeout_ns },
            ) catch return;
            defer result.deinit();
            self.returned_result = true;
            self.code = result.status.code;
        }
    };

    var handler = Handler{};
    var test_server = try server.Server.init(std.testing.allocator, .{});
    defer test_server.deinit();
    try test_server.registerUnary(
        "/test.Deadline/Earlier",
        service.UnaryHandler.bind(Handler, &handler, Handler.handle),
    );
    try test_server.start();

    var target_buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buffer, "127.0.0.1:{d}", .{try test_server.port()});
    var channel = try Channel.init(std.testing.allocator, target, .{});
    defer channel.deinit();

    var first = Worker{
        .channel = &channel,
        .request = "first",
        .timeout_ns = 10 * std.time.ns_per_s,
    };
    const first_thread = try std.Thread.spawn(.{}, Worker.run, .{&first});
    handler.entered.waitUncancelable(std.testing.io);
    const initially_armed = waitForTestFlag(
        &channel.impl.test_observer.deadline_timer_armed,
        5 * std.time.ns_per_s,
    );
    const first_target = channel.impl.test_observer.deadline_timer_target_ns.load(.acquire);
    if (!initially_armed or first_target == 0) {
        handler.release.post(std.testing.io);
        first_thread.join();
        try std.testing.expect(initially_armed and first_target != 0);
        return;
    }

    var second = Worker{
        .channel = &channel,
        .request = "second",
        .timeout_ns = 200 * std.time.ns_per_ms,
    };
    const second_thread = std.Thread.spawn(.{}, Worker.run, .{&second}) catch |err| {
        handler.release.post(std.testing.io);
        first_thread.join();
        return err;
    };
    const reset_observe_deadline = nowNs() +| 5 * std.time.ns_per_s;
    var reset_observed = false;
    while (nowNs() < reset_observe_deadline) {
        const current_target = channel.impl.test_observer.deadline_timer_target_ns.load(.acquire);
        if (current_target != 0 and current_target < first_target) {
            reset_observed = true;
            break;
        }
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch break;
    }
    if (!reset_observed) {
        handler.release.post(std.testing.io);
        first_thread.join();
        second_thread.join();
        try std.testing.expect(reset_observed);
        return;
    }

    second_thread.join();
    handler.release.post(std.testing.io);
    first_thread.join();

    try std.testing.expect(second.returned_result);
    try std.testing.expectEqual(status.Code.deadline_exceeded, second.code);
    try std.testing.expect(first.returned_result);
    try std.testing.expectEqual(status.Code.ok, first.code);
}

test "completed deadline leaves at most one stale timer callback" {
    const server = @import("server.zig");
    const service = @import("service.zig");

    const Handler = struct {
        entered: std.Io.Semaphore = .{},
        release: std.Io.Semaphore = .{},

        fn handle(
            self: *@This(),
            allocator: std.mem.Allocator,
            _: *service.ServerContext,
            request: []const u8,
        ) !service.UnaryResponse {
            if (std.mem.eql(u8, request, "deadline")) {
                self.entered.post(std.testing.io);
                self.release.waitUncancelable(std.testing.io);
            }
            return service.UnaryResponse.ok(allocator, request);
        }
    };
    const Worker = struct {
        channel: *Channel,
        returned_result: bool = false,
        code: status.Code = .unknown,

        fn run(self: *@This()) void {
            var result = self.channel.callUnary(
                std.testing.allocator,
                "/test.Deadline/Stale",
                "deadline",
                .{ .timeout_ns = std.time.ns_per_s },
            ) catch return;
            defer result.deinit();
            self.returned_result = true;
            self.code = result.status.code;
        }
    };

    var handler = Handler{};
    var test_server = try server.Server.init(std.testing.allocator, .{});
    defer test_server.deinit();
    try test_server.registerUnary(
        "/test.Deadline/Stale",
        service.UnaryHandler.bind(Handler, &handler, Handler.handle),
    );
    try test_server.start();

    var target_buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buffer, "127.0.0.1:{d}", .{try test_server.port()});
    var channel = try Channel.init(std.testing.allocator, target, .{});
    defer channel.deinit();

    var worker = Worker{ .channel = &channel };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    handler.entered.waitUncancelable(std.testing.io);
    const armed = waitForTestFlag(
        &channel.impl.test_observer.deadline_timer_armed,
        5 * std.time.ns_per_s,
    );
    handler.release.post(std.testing.io);
    thread.join();

    const baseline = channel.impl.test_observer.deadline_timer_callbacks.load(.acquire);
    const stale_wait_deadline = nowNs() +| 5 * std.time.ns_per_s;
    while (channel.impl.test_observer.deadline_timer_armed.load(.acquire) and
        nowNs() < stale_wait_deadline)
    {
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch break;
    }
    const after_stale = channel.impl.test_observer.deadline_timer_callbacks.load(.acquire);
    std.Io.sleep(std.testing.io, .fromMilliseconds(100), .awake) catch {};
    const after_observation = channel.impl.test_observer.deadline_timer_callbacks.load(.acquire);

    var reused = try channel.callUnary(std.testing.allocator, "/test.Deadline/Stale", "reused", .{});
    defer reused.deinit();

    try std.testing.expect(armed);
    try std.testing.expect(worker.returned_result);
    try std.testing.expectEqual(status.Code.ok, worker.code);
    try std.testing.expect(!channel.impl.test_observer.deadline_timer_armed.load(.acquire));
    try std.testing.expect(after_stale - baseline <= 1);
    try std.testing.expectEqual(after_stale, after_observation);
    try std.testing.expect(reused.status.isOk());
    try std.testing.expectEqualStrings("reused", reused.payload);
    try std.testing.expectEqual(@as(usize, 1), channel.impl.connect_count);
}

test "channel serializes a non-thread-safe backing allocator" {
    const server = @import("server.zig");
    const service = @import("service.zig");

    const Probe = struct {
        backing: std.mem.Allocator,
        armed: std.atomic.Value(bool) = .init(false),
        active: std.atomic.Value(usize) = .init(0),
        max_active: std.atomic.Value(usize) = .init(0),
        alloc_count: std.atomic.Value(usize) = .init(0),
        first_alloc_blocked: std.atomic.Value(bool) = .init(false),
        first_alloc_entered: std.Io.Semaphore = .{},
        first_alloc_release: std.Io.Semaphore = .{},

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = alloc,
                    .resize = resize,
                    .remap = remap,
                    .free = free,
                },
            };
        }

        fn resetAndArm(self: *@This()) void {
            self.active.store(0, .release);
            self.max_active.store(0, .release);
            self.alloc_count.store(0, .release);
            self.first_alloc_blocked.store(false, .release);
            self.armed.store(true, .release);
        }

        fn enter(self: *@This(), is_alloc: bool) bool {
            if (!self.armed.load(.acquire)) return false;
            const active = self.active.fetchAdd(1, .acq_rel) + 1;
            _ = self.max_active.fetchMax(active, .acq_rel);
            if (is_alloc and self.alloc_count.fetchAdd(1, .acq_rel) == 0) {
                self.first_alloc_blocked.store(true, .release);
                self.first_alloc_entered.post(std.testing.io);
                self.first_alloc_release.waitUncancelable(std.testing.io);
            }
            return true;
        }

        fn leave(self: *@This()) void {
            _ = self.active.fetchSub(1, .acq_rel);
        }

        fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            const tracked = self.enter(true);
            defer if (tracked) self.leave();
            return self.backing.rawAlloc(len, alignment, ret_addr);
        }

        fn resize(
            context: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            new_len: usize,
            ret_addr: usize,
        ) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            const tracked = self.enter(false);
            defer if (tracked) self.leave();
            return self.backing.rawResize(memory, alignment, new_len, ret_addr);
        }

        fn remap(
            context: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            new_len: usize,
            ret_addr: usize,
        ) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            const tracked = self.enter(false);
            defer if (tracked) self.leave();
            return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
        }

        fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            const tracked = self.enter(false);
            defer if (tracked) self.leave();
            self.backing.rawFree(memory, alignment, ret_addr);
        }
    };
    const LockHook = struct {
        probe: *Probe,
        notified: std.atomic.Value(bool) = .init(false),
        second_before_lock: std.Io.Semaphore = .{},

        fn beforeLock(context: ?*anyopaque, operation: AllocatorOperation) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (operation == .alloc and
                self.probe.first_alloc_blocked.load(.acquire) and
                !self.notified.swap(true, .acq_rel))
            {
                self.second_before_lock.post(std.testing.io);
            }
        }
    };
    const Handler = struct {
        fn handle(
            _: *@This(),
            allocator: std.mem.Allocator,
            _: *service.ServerContext,
            request: []const u8,
        ) !service.UnaryResponse {
            return service.UnaryResponse.ok(allocator, request);
        }
    };
    const Worker = struct {
        channel: *Channel,
        index: usize,
        succeeded: bool = false,
        result_allocator_ok: bool = false,

        fn run(self: *@This()) void {
            var result_allocator: std.heap.DebugAllocator(.{ .thread_safe = false }) = .init;
            defer self.result_allocator_ok = result_allocator.deinit() == .ok;
            var request_buffer: [16]u8 = undefined;
            const request = std.fmt.bufPrint(&request_buffer, "request-{d}", .{self.index}) catch return;
            var result = self.channel.callUnary(
                result_allocator.allocator(),
                "/test.Allocator/Unary",
                request,
                .{},
            ) catch return;
            defer result.deinit();
            self.succeeded = result.status.isOk() and std.mem.eql(u8, request, result.payload);
        }
    };

    var backing_allocator: std.heap.DebugAllocator(.{ .thread_safe = false }) = .init;
    var backing_allocator_active = true;
    defer if (backing_allocator_active) {
        std.testing.expectEqual(std.heap.Check.ok, backing_allocator.deinit()) catch @panic("backing allocator leak");
    };
    var probe = Probe{ .backing = backing_allocator.allocator() };

    var handler = Handler{};
    var test_server = try server.Server.init(std.testing.allocator, .{});
    defer test_server.deinit();
    try test_server.registerUnary(
        "/test.Allocator/Unary",
        service.UnaryHandler.bind(Handler, &handler, Handler.handle),
    );
    try test_server.start();

    var target_buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buffer, "127.0.0.1:{d}", .{try test_server.port()});
    var channel = try Channel.init(probe.allocator(), target, .{});
    var channel_active = true;
    defer if (channel_active) channel.deinit();

    var lock_hook = LockHook{ .probe = &probe };
    channel.impl.serialized_allocator.test_hook_context.store(&lock_hook, .release);
    channel.impl.serialized_allocator.test_before_lock.store(LockHook.beforeLock, .release);
    probe.resetAndArm();

    var workers: [8]Worker = undefined;
    var threads: [8]std.Thread = undefined;
    for (&workers, 0..) |*worker, index| worker.* = .{ .channel = &channel, .index = index };

    threads[0] = try std.Thread.spawn(.{}, Worker.run, .{&workers[0]});
    probe.first_alloc_entered.waitUncancelable(std.testing.io);
    for (threads[1..], workers[1..]) |*thread, *worker| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{worker});
    }
    lock_hook.second_before_lock.waitUncancelable(std.testing.io);
    probe.first_alloc_release.post(std.testing.io);

    for (&threads) |*thread| thread.join();
    for (&workers) |worker| {
        try std.testing.expect(worker.succeeded);
        try std.testing.expect(worker.result_allocator_ok);
    }

    channel.deinit();
    channel_active = false;
    try std.testing.expect(lock_hook.notified.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), probe.active.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), probe.max_active.load(.acquire));
    try std.testing.expectEqual(std.heap.Check.ok, backing_allocator.deinit());
    backing_allocator_active = false;
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
            if (std.mem.eql(u8, request, "slow")) try std.Io.sleep(std.testing.io, .fromMilliseconds(50), .awake);
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
