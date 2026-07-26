const std = @import("std");
const xev = @import("xev");
const c = @import("c.zig").api;
const Compression = @import("compression.zig").Compression;
const deadline = @import("deadline.zig");
const frame = @import("frame.zig");
const message = @import("message.zig");
const metadata = @import("metadata.zig");
const service = @import("service.zig");
const socket_options = @import("socket_options.zig");
const status = @import("status.zig");
const raw_stream = @import("stream.zig");

pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 0,
    max_request_size: usize = 4 * 1024 * 1024,
    stream_limits: raw_stream.BufferLimits = .{},
    initial_stream_window_size: u32 = 64 * 1024,
    write_high_watermark_bytes: usize = 1024 * 1024,
    write_low_watermark_bytes: usize = 512 * 1024,
};

pub const LocalAddress = struct {
    host: []const u8,
    port: u16,
};

pub const Server = struct {
    impl: *Impl,

    pub fn init(allocator: std.mem.Allocator, options: Options) !Server {
        try options.stream_limits.validate();
        try validateTransportOptions(
            options.initial_stream_window_size,
            options.write_high_watermark_bytes,
            options.write_low_watermark_bytes,
        );
        if (options.stream_limits.max_inbound_buffer_size < options.initial_stream_window_size) {
            return error.InvalidInboundBufferSize;
        }
        const impl = try allocator.create(Impl);
        errdefer allocator.destroy(impl);
        const host = try allocator.dupeZ(u8, options.host);
        errdefer allocator.free(host);

        const io_threaded = std.Io.Threaded.init(allocator, .{});
        impl.* = .{
            .allocator = allocator,
            .host = host,
            .configured_port = options.port,
            .max_request_size = options.max_request_size,
            .stream_limits = options.stream_limits,
            .initial_stream_window_size = options.initial_stream_window_size,
            .write_high_watermark_bytes = options.write_high_watermark_bytes,
            .write_low_watermark_bytes = options.write_low_watermark_bytes,
            .io_threaded = io_threaded,
        };
        impl.clock = .{ .context = impl, .now_fn = ioNow };
        return .{ .impl = impl };
    }

    pub fn registerUnary(self: *Server, full_method_path: []const u8, handler: service.UnaryHandler) !void {
        const impl = self.impl;
        impl.lock();
        defer impl.unlock();
        if (impl.state != .initialized) return error.ServerAlreadyStarted;
        if (!isValidMethodPath(full_method_path)) return error.InvalidMethodPath;
        if (impl.handlers.contains(full_method_path) or impl.stream_handlers.contains(full_method_path)) return error.MethodAlreadyRegistered;

        const owned_path = try impl.allocator.dupe(u8, full_method_path);
        errdefer impl.allocator.free(owned_path);
        try impl.handlers.put(impl.allocator, owned_path, handler);
    }

    pub fn registerStream(self: *Server, full_method_path: []const u8, handler: raw_stream.ServerHandler) !void {
        const impl = self.impl;
        impl.lock();
        defer impl.unlock();
        if (impl.state != .initialized) return error.ServerAlreadyStarted;
        if (!isValidMethodPath(full_method_path)) return error.InvalidMethodPath;
        if (impl.handlers.contains(full_method_path) or impl.stream_handlers.contains(full_method_path)) return error.MethodAlreadyRegistered;

        const owned_path = try impl.allocator.dupe(u8, full_method_path);
        errdefer impl.allocator.free(owned_path);
        try impl.stream_handlers.put(impl.allocator, owned_path, handler);
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
                impl.notifyShutdown();
            },
            .draining => {
                impl.shutdown_request = .immediate;
                impl.state = .stopping;
                impl.notifyShutdown();
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
                impl.notifyShutdown();
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
        var stream_iterator = impl.stream_handlers.iterator();
        while (stream_iterator.next()) |entry| impl.allocator.free(entry.key_ptr.*);
        impl.stream_handlers.deinit(impl.allocator);
        for (impl.stream_commands.items) |*command| command.deinit(impl.allocator);
        impl.stream_commands.deinit(impl.allocator);
        impl.connections.deinit(impl.allocator);
        impl.allocator.free(impl.host);
        impl.io_threaded.deinit();
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
    stream_limits: raw_stream.BufferLimits,
    initial_stream_window_size: u32,
    write_high_watermark_bytes: usize,
    write_low_watermark_bytes: usize,
    handlers: std.StringHashMapUnmanaged(service.UnaryHandler) = .empty,
    stream_handlers: std.StringHashMapUnmanaged(raw_stream.ServerHandler) = .empty,
    stream_commands: std.ArrayList(StreamCommand) = .empty,
    connections: std.ArrayList(*Connection) = .empty,
    io_threaded: std.Io.Threaded,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    state: State = .initialized,
    shutdown_request: ShutdownRequest = .none,
    drain_timeout_ns: u64 = 0,
    startup_error: ?StartupError = null,
    thread: ?std.Thread = null,
    loop: xev.Loop = undefined,
    loop_initialized: bool = false,
    listener: xev.TCP = undefined,
    listener_initialized: bool = false,
    listener_accept_completion: xev.Completion = .{},
    listener_accept_cancel_completion: xev.Completion = .{},
    listener_accept_active: bool = false,
    listener_accept_cancel_submitted: bool = false,
    listener_close_completion: xev.Completion = .{},
    listener_close_submitted: bool = false,
    listener_closed: bool = false,
    shutdown_async: xev.Async = undefined,
    shutdown_async_initialized: bool = false,
    shutdown_completion: xev.Completion = .{},
    stream_async: xev.Async = undefined,
    stream_async_initialized: bool = false,
    stream_async_completion: xev.Completion = .{},
    drain_timer: xev.Timer = undefined,
    drain_timer_initialized: bool = false,
    drain_timer_completion: xev.Completion = .{},
    deadline_timer: xev.Timer = undefined,
    deadline_timer_initialized: bool = false,
    deadline_timer_completion: xev.Completion = .{},
    deadline_timer_cancel_completion: xev.Completion = .{},
    drain_started: bool = false,
    clock: deadline.Clock = undefined,
    local_host: [15]u8 = undefined,
    local_host_len: usize = 0,
    local_port: u16 = 0,

    fn lock(self: *Impl) void {
        self.mutex.lockUncancelable(self.io());
    }

    fn unlock(self: *Impl) void {
        self.mutex.unlock(self.io());
    }

    fn waitForSignal(self: *Impl) void {
        self.condition.waitUncancelable(self.io(), &self.mutex);
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
        self.condition.broadcast(self.io());
        const should_shutdown = result == null and self.shutdown_request != .none;
        self.unlock();
        if (should_shutdown) self.notifyShutdown();
    }

    fn io(self: *Impl) std.Io {
        return self.io_threaded.io();
    }

    fn notifyShutdown(self: *Impl) void {
        if (self.shutdown_async_initialized) self.shutdown_async.notify() catch {};
    }
};

const StreamCommand = struct {
    target: *Stream,
    action: union(enum) {
        send: []u8,
        finish: struct {
            code: status.Code,
            message: []const u8,
        },
        resume_receive,
    },

    fn deinit(self: *StreamCommand, allocator: std.mem.Allocator) void {
        switch (self.action) {
            .send => |bytes| allocator.free(bytes),
            .finish => |value| if (value.message.len != 0) allocator.free(value.message),
            .resume_receive => {},
        }
        self.* = undefined;
    }
};

const OutboundMessage = struct {
    bytes: []u8,
    offset: usize = 0,
};

const StreamingState = struct {
    handler: raw_stream.ServerHandler,
    decoder: frame.Decoder,
    context: service.ServerContext,
    outbound: std.ArrayList(OutboundMessage) = .empty,
    remote_end_received: bool = false,
    remote_end_called: bool = false,

    fn deinit(self: *StreamingState, allocator: std.mem.Allocator) void {
        self.decoder.deinit();
        self.context.deinit();
        for (self.outbound.items) |item| allocator.free(item.bytes);
        self.outbound.deinit(allocator);
        self.* = undefined;
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
    request_metadata_invalid: bool = false,
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
    streaming: ?StreamingState = null,
    streaming_active: bool = false,
    response_finished: bool = false,
    finish_queued: bool = false,
    receive_paused: bool = false,
    resume_queued: bool = false,
    deferred_stream_credit: usize = 0,
    response_gzip_requested: bool = false,
    response_headers_submitted: bool = false,
    outbound_reserved_bytes: usize = 0,
    writable_requested: bool = false,
    cancel_called: bool = false,
    reset_after_trailers: bool = false,
    reset_submitted: bool = false,
    // Queued and currently processing commands each retain this stream once.
    command_refs: usize = 0,
    transport_closed: bool = false,

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
        if (self.streaming) |*streaming| streaming.deinit(self.allocator);
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

    fn setOwnedStatus(self: *Stream, code: status.Code, owned_message: []const u8) void {
        if (self.response_message.len != 0) self.allocator.free(self.response_message);
        self.response_code = code;
        self.response_message = owned_message;
    }

    fn serverHandle(self: *Stream) raw_stream.ServerStream {
        return raw_stream.ServerStream.init(self, streamSend, streamFinish, streamResumeReceive);
    }
};

fn streamSend(context: *anyopaque, payload: []const u8, options: raw_stream.SendOptions) !void {
    const target: *Stream = @ptrCast(@alignCast(context));
    const server = target.connection.server;
    if (payload.len > server.stream_limits.max_message_size) return error.MessageTooLarge;
    if (options.compression == .gzip and !target.accepts_response_gzip) return error.CompressionNotAccepted;

    const encoded = try frame.encodeWithCompression(target.allocator, payload, options.compression);
    errdefer target.allocator.free(encoded);

    server.lock();
    defer server.unlock();
    if (!target.streaming_active or target.finish_queued) return error.StreamFinished;
    if (target.response_headers_submitted and options.compression == .gzip and target.response_compression != .gzip) {
        return error.ResponseCompressionNotEnabled;
    }
    const outbound_limit = server.stream_limits.max_outbound_buffer_size;
    if (encoded.len > outbound_limit) return error.OutboundBufferLimitExceeded;
    if (target.outbound_reserved_bytes > outbound_limit or encoded.len > outbound_limit - target.outbound_reserved_bytes) {
        target.writable_requested = true;
        return error.WouldBlock;
    }
    target.outbound_reserved_bytes += encoded.len;
    errdefer target.outbound_reserved_bytes -= encoded.len;
    if (options.compression == .gzip) target.response_gzip_requested = true;
    try server.stream_commands.append(server.allocator, .{
        .target = target,
        .action = .{ .send = encoded },
    });
    target.command_refs += 1;
    errdefer {
        _ = server.stream_commands.pop();
        target.command_refs -= 1;
    }
    try server.stream_async.notify();
}

fn streamFinish(context: *anyopaque, final_status: status.Status) !void {
    const target: *Stream = @ptrCast(@alignCast(context));
    const server = target.connection.server;
    const owned_message = if (final_status.message.len == 0)
        &.{}
    else
        try target.allocator.dupe(u8, final_status.message);
    errdefer if (owned_message.len != 0) target.allocator.free(owned_message);

    server.lock();
    defer server.unlock();
    if (!target.streaming_active or target.finish_queued) return error.StreamFinished;
    target.finish_queued = true;
    errdefer target.finish_queued = false;
    try server.stream_commands.append(server.allocator, .{
        .target = target,
        .action = .{ .finish = .{
            .code = final_status.code,
            .message = owned_message,
        } },
    });
    target.command_refs += 1;
    errdefer {
        _ = server.stream_commands.pop();
        target.command_refs -= 1;
    }
    try server.stream_async.notify();
}

fn streamResumeReceive(context: *anyopaque) !void {
    const target: *Stream = @ptrCast(@alignCast(context));
    const server = target.connection.server;
    server.lock();
    defer server.unlock();
    if (!target.streaming_active) return error.StreamFinished;
    if (!target.receive_paused or target.resume_queued) return error.ReceiveNotPaused;
    target.resume_queued = true;
    errdefer target.resume_queued = false;
    try server.stream_commands.append(server.allocator, .{
        .target = target,
        .action = .resume_receive,
    });
    target.command_refs += 1;
    errdefer {
        _ = server.stream_commands.pop();
        target.command_refs -= 1;
    }
    try server.stream_async.notify();
}

const Connection = struct {
    server: *Impl,
    tcp: xev.TCP = undefined,
    session: ?*c.nghttp2_session = null,
    streams: std.AutoHashMapUnmanaged(i32, *Stream) = .empty,
    highest_accepted_stream_id: i32 = 0,
    local_goaway_submitted: bool = false,
    pending_writes: usize = 0,
    queued_write_bytes: usize = 0,
    draining: bool = false,
    close_after_writes: bool = false,
    closing: bool = false,
    read_active: bool = false,
    read_cancel_submitted: bool = false,
    write_cancel_submitted: bool = false,
    close_submitted: bool = false,
    close_completed: bool = false,
    read_completion: xev.Completion = .{},
    read_cancel_completion: xev.Completion = .{},
    write_cancel_completion: xev.Completion = .{},
    close_completion: xev.Completion = .{},
    write_queue: xev.WriteQueue = .{},
    read_buffer: []u8 = &.{},

    fn initializeSession(self: *Connection) !void {
        var callbacks: ?*c.nghttp2_session_callbacks = null;
        if (c.nghttp2_session_callbacks_new(&callbacks) != 0) return error.OutOfMemory;
        defer c.nghttp2_session_callbacks_del(callbacks);
        var options: ?*c.nghttp2_option = null;
        if (c.nghttp2_option_new(&options) != 0) return error.OutOfMemory;
        defer c.nghttp2_option_del(options);
        c.nghttp2_option_set_no_auto_window_update(options, 1);

        c.nghttp2_session_callbacks_set_on_begin_headers_callback(callbacks, onBeginHeaders);
        c.nghttp2_session_callbacks_set_on_header_callback(callbacks, onHeader);
        c.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, onDataChunk);
        c.nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, onFrameReceived);
        c.nghttp2_session_callbacks_set_on_frame_send_callback(callbacks, onFrameSent);
        c.nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, onStreamClose);
        if (c.nghttp2_session_server_new2(&self.session, callbacks, self, options) != 0) return error.OutOfMemory;
        const settings = [_]c.nghttp2_settings_entry{.{
            .settings_id = c.NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE,
            .value = self.server.initial_stream_window_size,
        }};
        if (c.nghttp2_submit_settings(self.session, c.NGHTTP2_FLAG_NONE, &settings, settings.len) != 0) {
            return error.NativeFailure;
        }
    }

    fn flush(self: *Connection) !void {
        while (!self.closing) {
            if (!canFlushWrites(self.queued_write_bytes, self.server.write_high_watermark_bytes)) return;
            var data: [*c]const u8 = null;
            const length = c.nghttp2_session_mem_send2(self.session, &data);
            if (length < 0) return error.NativeFailure;
            if (length == 0) return;
            const byte_length: usize = @intCast(length);

            const write = try self.server.allocator.create(WriteRequest);
            errdefer self.server.allocator.destroy(write);
            const bytes = try self.server.allocator.dupe(u8, data[0..byte_length]);
            errdefer self.server.allocator.free(bytes);
            write.* = .{ .connection = self, .bytes = bytes };
            self.pending_writes = std.math.add(usize, self.pending_writes, 1) catch {
                return error.WriteQueueSizeOverflow;
            };
            errdefer self.pending_writes -= 1;
            self.queued_write_bytes = try addQueuedWriteBytes(self.queued_write_bytes, bytes.len);
            self.tcp.queueWrite(
                &self.server.loop,
                &self.write_queue,
                &write.request,
                .{ .slice = bytes },
                WriteRequest,
                write,
                onWrite,
            );
        }
    }

    fn startRead(self: *Connection, loop: *xev.Loop) !void {
        if (self.close_after_writes or self.closing or self.read_active) return;
        if (self.read_buffer.len == 0) self.read_buffer = try self.server.allocator.alloc(u8, 16 * 1024);
        self.read_active = true;
        self.tcp.read(loop, &self.read_completion, .{ .slice = self.read_buffer }, Connection, self, onRead);
    }

    fn closeTerminatedSession(self: *Connection, loop: *xev.Loop) void {
        if (self.local_goaway_submitted or
            self.closing or
            c.nghttp2_session_want_read(self.session) != 0 or
            c.nghttp2_session_want_write(self.session) != 0) return;
        self.close_after_writes = true;
        if (self.pending_writes == 0) self.closeOnLoop(loop);
    }

    pub fn submitGoAway(self: *Connection, last_stream_id: i32, error_code: u32) !void {
        self.local_goaway_submitted = true;
        if (c.nghttp2_submit_goaway(
            self.session,
            c.NGHTTP2_FLAG_NONE,
            last_stream_id,
            error_code,
            null,
            0,
        ) != 0) return error.NativeFailure;
    }

    fn close(self: *Connection) void {
        if (!self.server.loop_initialized) {
            self.closing = true;
            return;
        }
        self.closeOnLoop(&self.server.loop);
    }

    fn closeOnLoop(self: *Connection, loop: *xev.Loop) void {
        if (self.closing) return;
        self.closing = true;
        var stream_iterator = self.streams.valueIterator();
        while (stream_iterator.next()) |stream_ptr| {
            const stream = stream_ptr.*;
            if (stream.streaming != null and !stream.trailer_submitted) cancelStreaming(stream);
        }
        if (self.read_active) {
            self.read_cancel_submitted = true;
            loop.cancel(
                &self.read_completion,
                &self.read_cancel_completion,
                Connection,
                self,
                onReadCanceled,
            );
        }
        if (self.write_queue.head) |request| {
            if (request.completion.state() == .active) {
                self.write_cancel_submitted = true;
                loop.cancel(
                    &request.completion,
                    &self.write_cancel_completion,
                    Connection,
                    self,
                    onWriteCanceled,
                );
            } else {
                self.discardQueuedWrites();
            }
        }
        self.submitCloseIfReady(loop);
    }

    fn submitCloseIfReady(self: *Connection, loop: *xev.Loop) void {
        if (self.close_submitted or self.read_active or self.pending_writes != 0) return;
        self.close_submitted = true;
        self.tcp.close(loop, &self.close_completion, Connection, self, onConnectionClosed);
    }

    fn discardQueuedWrites(self: *Connection) void {
        while (self.write_queue.pop()) |request| {
            const write: *WriteRequest = @fieldParentPtr("request", request);
            self.pending_writes -= 1;
            self.queued_write_bytes = completeQueuedWrite(self.queued_write_bytes, write.bytes.len);
            self.server.allocator.free(write.bytes);
            self.server.allocator.destroy(write);
        }
    }

    fn finishCloseIfReady(self: *Connection) void {
        if (!self.close_completed or self.read_active or self.pending_writes != 0 or self.read_cancel_submitted or self.write_cancel_submitted) return;
        const server = self.server;
        var cancel_iterator = self.streams.valueIterator();
        while (cancel_iterator.next()) |stream_ptr| {
            const stream = stream_ptr.*;
            if (stream.streaming != null and !stream.trailer_submitted) cancelStreaming(stream);
        }
        if (self.session) |session| c.nghttp2_session_del(session);
        var iterator = self.streams.iterator();
        while (iterator.next()) |entry| {
            const stream = entry.value_ptr.*;
            if (stream.streaming != null and !stream.trailer_submitted) cancelStreaming(stream);
            std.debug.assert(retireStream(stream));
        }
        self.streams.deinit(server.allocator);
        if (self.read_buffer.len != 0) server.allocator.free(self.read_buffer);
        for (server.connections.items, 0..) |item, index| {
            if (item == self) {
                _ = server.connections.swapRemove(index);
                break;
            }
        }
        server.allocator.destroy(self);
        finishDrainIfIdle(server);
        maybeStopLoop(server);
    }
};

const WriteRequest = struct {
    request: xev.WriteRequest = undefined,
    connection: *Connection,
    bytes: []u8,
};

fn runLoop(server: *Impl) void {
    const setup_result = setupLoop(server);
    if (setup_result) |_| {
        server.signalStarted(null);
        server.loop.run(.until_done) catch {};
        server.stream_async.deinit();
        server.shutdown_async.deinit();
        server.loop.deinit();
        server.loop_initialized = false;
        server.lock();
        server.state = .stopped;
        server.condition.broadcast(server.io());
        server.unlock();
    } else |err| {
        server.signalStarted(err);
    }
}

fn setupLoop(server: *Impl) StartupError!void {
    server.loop = xev.Loop.init(.{}) catch return error.LoopInitializationFailed;
    server.loop_initialized = true;
    errdefer {
        server.loop.deinit();
        server.loop_initialized = false;
    }

    errdefer {
        if (server.stream_async_initialized) server.stream_async.deinit();
        if (server.shutdown_async_initialized) server.shutdown_async.deinit();
        if (server.listener_initialized) closeFd(server.listener.fd);
    }

    const address = std.Io.net.IpAddress.parseIp4(server.host, server.configured_port) catch return error.InvalidAddress;
    server.listener = xev.TCP.init(address) catch return error.ListenerInitializationFailed;
    server.listener_initialized = true;
    server.listener.bind(address) catch return error.BindFailed;
    server.listener.listen(128) catch return error.ListenFailed;

    var local_address: std.posix.sockaddr.in = undefined;
    var address_length: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
    if (std.posix.errno(std.posix.system.getsockname(server.listener.fd, @ptrCast(&local_address), &address_length)) != .SUCCESS) return error.AddressQueryFailed;
    @memcpy(server.local_host[0..server.host.len], server.host);
    server.local_host_len = server.host.len;
    server.local_port = std.mem.bigToNative(u16, local_address.port);

    server.shutdown_async = xev.Async.init() catch return error.AsyncInitializationFailed;
    server.shutdown_async_initialized = true;
    server.shutdown_async.wait(&server.loop, &server.shutdown_completion, Impl, server, onShutdown);
    server.stream_async = xev.Async.init() catch return error.AsyncInitializationFailed;
    server.stream_async_initialized = true;
    server.stream_async.wait(&server.loop, &server.stream_async_completion, Impl, server, onStreamAsync);
    server.drain_timer = xev.Timer.init() catch return error.TimerInitializationFailed;
    server.drain_timer_initialized = true;
    server.deadline_timer = xev.Timer.init() catch return error.TimerInitializationFailed;
    server.deadline_timer_initialized = true;
    server.listener_accept_active = true;
    server.listener.accept(&server.loop, &server.listener_accept_completion, Impl, server, onConnection);
}

fn onConnection(server: ?*Impl, loop: *xev.Loop, _: *xev.Completion, result: xev.AcceptError!xev.TCP) xev.CallbackAction {
    const impl = server orelse return .disarm;
    impl.listener_accept_active = false;
    const tcp = result catch {
        if (isAccepting(impl)) return rearmListener(impl);
        closeListener(impl);
        return .disarm;
    };
    const server_ptr = impl;
    if (!isAccepting(server_ptr)) {
        closeFd(tcp.fd);
        closeListener(server_ptr);
        return .disarm;
    }
    socket_options.enableTcpNoDelay(tcp.fd) catch {
        closeFd(tcp.fd);
        return rearmListener(server_ptr);
    };

    const connection = server_ptr.allocator.create(Connection) catch {
        closeFd(tcp.fd);
        return rearmListener(server_ptr);
    };
    connection.* = .{ .server = server_ptr, .tcp = tcp };
    connection.initializeSession() catch {
        connection.closeOnLoop(loop);
        return rearmListener(server_ptr);
    };
    server_ptr.connections.append(server_ptr.allocator, connection) catch {
        connection.closeOnLoop(loop);
        return rearmListener(server_ptr);
    };
    connection.startRead(loop) catch connection.closeOnLoop(loop);
    connection.flush() catch connection.closeOnLoop(loop);
    return rearmListener(server_ptr);
}

fn rearmListener(server: *Impl) xev.CallbackAction {
    server.listener_accept_active = true;
    return .rearm;
}

fn isAccepting(server: *Impl) bool {
    server.lock();
    defer server.unlock();
    return server.state == .running;
}

fn closeFd(fd: std.posix.fd_t) void {
    _ = std.posix.system.close(fd);
}

fn onRead(connection: ?*Connection, loop: *xev.Loop, _: *xev.Completion, _: xev.TCP, buffer: xev.ReadBuffer, result: xev.ReadError!usize) xev.CallbackAction {
    const conn = connection orelse return .disarm;
    conn.read_active = false;
    const length = result catch {
        conn.closeOnLoop(loop);
        conn.submitCloseIfReady(loop);
        conn.finishCloseIfReady();
        return .disarm;
    };
    const bytes = switch (buffer) {
        .slice => |slice| slice[0..length],
        .array => unreachable,
    };
    const consumed = c.nghttp2_session_mem_recv2(conn.session, bytes.ptr, bytes.len);
    if (consumed < 0 or consumed != bytes.len) {
        conn.closeOnLoop(loop);
    } else {
        conn.flush() catch conn.closeOnLoop(loop);
        conn.closeTerminatedSession(loop);
        if (!conn.close_after_writes) conn.startRead(loop) catch conn.closeOnLoop(loop);
    }
    if (conn.closing) conn.submitCloseIfReady(loop);
    conn.finishCloseIfReady();
    return .disarm;
}

fn onWrite(write: ?*WriteRequest, loop: *xev.Loop, _: *xev.Completion, _: xev.TCP, _: xev.WriteBuffer, result: xev.WriteError!usize) xev.CallbackAction {
    const request = write orelse return .disarm;
    const connection = request.connection;
    connection.pending_writes -= 1;
    connection.queued_write_bytes = completeQueuedWrite(connection.queued_write_bytes, request.bytes.len);
    // WriteQueue retries partial writes and calls back with the full buffer length.
    const completed: ?usize = result catch null;
    const write_succeeded = completed != null and completed.? == request.bytes.len;
    connection.server.allocator.free(request.bytes);
    connection.server.allocator.destroy(request);
    if (connection.closing) {
        connection.discardQueuedWrites();
        connection.submitCloseIfReady(loop);
        connection.finishCloseIfReady();
        return .disarm;
    }
    if (!write_succeeded) {
        connection.closeOnLoop(loop);
        connection.finishCloseIfReady();
        return .disarm;
    }
    if (connection.queued_write_bytes < connection.server.write_low_watermark_bytes) {
        // WriteQueue adds its next completion after this callback returns.
        // Wake the async callback so queueWrite cannot reenter that ordering.
        connection.server.stream_async.notify() catch {
            connection.closeOnLoop(loop);
            connection.finishCloseIfReady();
            return .disarm;
        };
        return .disarm;
    }
    if (connection.close_after_writes and connection.pending_writes == 0) {
        connection.closeOnLoop(loop);
        connection.finishCloseIfReady();
        return .disarm;
    }
    maybeCloseDrainedConnection(connection);
    connection.finishCloseIfReady();
    return .disarm;
}

fn onReadCanceled(connection: ?*Connection, loop: *xev.Loop, _: *xev.Completion, _: xev.CancelError!void) xev.CallbackAction {
    const conn = connection orelse return .disarm;
    conn.read_cancel_submitted = false;
    conn.submitCloseIfReady(loop);
    conn.finishCloseIfReady();
    return .disarm;
}

fn onWriteCanceled(connection: ?*Connection, loop: *xev.Loop, _: *xev.Completion, _: xev.CancelError!void) xev.CallbackAction {
    const conn = connection orelse return .disarm;
    conn.write_cancel_submitted = false;
    conn.submitCloseIfReady(loop);
    conn.finishCloseIfReady();
    return .disarm;
}

fn onConnectionClosed(connection: ?*Connection, _: *xev.Loop, _: *xev.Completion, _: xev.TCP, _: xev.CloseError!void) xev.CallbackAction {
    const conn = connection orelse return .disarm;
    conn.close_completed = true;
    conn.finishCloseIfReady();
    return .disarm;
}

fn onShutdown(server: ?*Impl, _: *xev.Loop, _: *xev.Completion, _: xev.Async.WaitError!void) xev.CallbackAction {
    const impl = server orelse return .disarm;
    impl.lock();
    const state = impl.state;
    impl.unlock();
    switch (state) {
        .draining => beginDrain(impl),
        .stopping => stopImmediately(impl),
        else => {},
    }
    return .rearm;
}

fn onStreamAsync(server: ?*Impl, _: *xev.Loop, _: *xev.Completion, result: xev.Async.WaitError!void) xev.CallbackAction {
    const impl = server orelse return .disarm;
    result catch {
        stopImmediately(impl);
        return .disarm;
    };
    processStreamCommands(impl);
    return .rearm;
}

fn processStreamCommands(server: *Impl) void {
    var commands: std.ArrayList(StreamCommand) = .empty;
    server.lock();
    std.mem.swap(std.ArrayList(StreamCommand), &commands, &server.stream_commands);
    server.unlock();
    defer commands.deinit(server.allocator);

    for (commands.items) |command| {
        processStreamCommand(server, command);
        releaseStreamCommand(command.target);
    }

    for (server.connections.items) |connection| {
        if (connection.closing or connection.session == null) continue;
        connection.flush() catch {
            connection.closeOnLoop(&server.loop);
            continue;
        };
        connection.closeTerminatedSession(&server.loop);
        if (!connection.closing) maybeCloseDrainedConnection(connection);
    }
}

fn processStreamCommand(server: *Impl, command: StreamCommand) void {
    const target = command.target;
    switch (command.action) {
        .send => |bytes| {
            server.lock();
            const active = target.streaming_active and !target.transport_closed;
            server.unlock();
            if (!active or target.streaming == null) {
                releaseOutboundReservation(target, bytes.len, false);
                server.allocator.free(bytes);
                return;
            }
            const streaming = &target.streaming.?;
            streaming.outbound.append(server.allocator, .{ .bytes = bytes }) catch {
                releaseOutboundReservation(target, bytes.len, false);
                server.allocator.free(bytes);
                failStreaming(target, .internal, "response allocation failed");
                return;
            };
            resumeStreamingResponse(target);
        },
        .finish => |value| {
            server.lock();
            const active = target.streaming_active and !target.transport_closed;
            if (active) target.response_finished = true;
            server.unlock();
            if (!active or target.streaming == null) {
                if (value.message.len != 0) server.allocator.free(value.message);
                return;
            }
            target.setOwnedStatus(value.code, value.message);
            copyStreamingTrailers(target) catch {
                target.setStatus(.init(.internal, "metadata allocation failed")) catch {
                    target.connection.close();
                    return;
                };
            };
            resumeStreamingResponse(target);
        },
        .resume_receive => {
            server.lock();
            const active = target.streaming_active and !target.transport_closed;
            target.resume_queued = false;
            if (active) target.receive_paused = false;
            server.unlock();
            if (active) {
                deliverStreamingMessages(target);
                server.lock();
                const return_credit = canReturnDeferredStreamCredit(
                    target.receive_paused,
                    target.transport_closed,
                ) and target.streaming_active;
                server.unlock();
                if (return_credit and target.deferred_stream_credit != 0) {
                    if (c.nghttp2_session_consume_stream(
                        target.connection.session,
                        target.id,
                        target.deferred_stream_credit,
                    ) != 0) {
                        target.connection.close();
                        return;
                    }
                    target.deferred_stream_credit = 0;
                }
            }
        },
    }
}

fn releaseStreamCommand(target: *Stream) void {
    const server = target.connection.server;
    server.lock();
    std.debug.assert(target.command_refs != 0);
    target.command_refs -= 1;
    const destroy = target.transport_closed and target.command_refs == 0;
    server.unlock();
    if (destroy) destroyStream(target);
}

fn releaseOutboundReservation(target: *Stream, length: usize, notify_writable: bool) void {
    const server = target.connection.server;
    server.lock();
    target.outbound_reserved_bytes -= length;
    const writable = notify_writable and
        target.writable_requested and
        target.streaming_active and
        !target.finish_queued and
        !target.transport_closed and
        target.outbound_reserved_bytes <= outboundLowWatermark(server);
    if (writable) target.writable_requested = false;
    server.unlock();
    if (writable) {
        const streaming = &(target.streaming orelse return);
        if (streaming.handler.on_writable) |callback| {
            callback(streaming.handler.context, target.serverHandle(), &streaming.context);
        }
    }
}

fn outboundLowWatermark(server: *const Impl) usize {
    return server.stream_limits.max_outbound_buffer_size / 2;
}

fn copyStreamingTrailers(target: *Stream) !void {
    const streaming = &(target.streaming orelse return);
    for (streaming.context.trailing_metadata.items()) |entry| {
        try target.trailing_metadata.append(entry.key, entry.value);
    }
}

fn resumeStreamingResponse(target: *Stream) void {
    if (!target.response_headers_submitted or target.connection.session == null or target.connection.closing) return;
    _ = c.nghttp2_session_resume_data(target.connection.session, target.id);
}

fn failStreaming(target: *Stream, code: status.Code, text: []const u8) void {
    if (target.streaming == null) return;
    const server = target.connection.server;
    server.lock();
    target.streaming_active = false;
    target.response_finished = true;
    target.finish_queued = true;
    target.reset_after_trailers = true;
    const trailers_submitted = target.trailer_submitted;
    server.unlock();
    if (trailers_submitted) {
        submitStreamingFailureReset(target) catch {};
        return;
    }
    target.setStatus(.init(code, text)) catch {
        target.connection.close();
        return;
    };
    copyStreamingTrailers(target) catch {};
    resumeStreamingResponse(target);
}

fn discardStreamCommands(target: *Stream) void {
    const server = target.connection.server;
    server.lock();
    defer server.unlock();
    var index: usize = 0;
    while (index < server.stream_commands.items.len) {
        if (server.stream_commands.items[index].target != target) {
            index += 1;
            continue;
        }
        var command = server.stream_commands.orderedRemove(index);
        std.debug.assert(target.command_refs != 0);
        target.command_refs -= 1;
        switch (command.action) {
            .send => |bytes| target.outbound_reserved_bytes -= bytes.len,
            else => {},
        }
        command.deinit(server.allocator);
    }
}

fn retireStream(target: *Stream) bool {
    discardStreamCommands(target);
    const server = target.connection.server;
    server.lock();
    target.transport_closed = true;
    const destroy = target.command_refs == 0;
    server.unlock();
    if (destroy) destroyStream(target);
    return destroy;
}

fn destroyStream(target: *Stream) void {
    const allocator = target.allocator;
    target.deinit();
    allocator.destroy(target);
}

fn cancelStreaming(target: *Stream) void {
    const streaming = &(target.streaming orelse return);
    const server = target.connection.server;
    server.lock();
    if (target.cancel_called) {
        server.unlock();
        return;
    }
    target.cancel_called = true;
    target.streaming_active = false;
    target.finish_queued = true;
    target.receive_paused = false;
    target.resume_queued = false;
    server.unlock();
    discardStreamCommands(target);
    for (streaming.outbound.items) |item| {
        releaseOutboundReservation(target, item.bytes.len - item.offset, false);
        target.allocator.free(item.bytes);
    }
    streaming.outbound.clearRetainingCapacity();
    if (streaming.handler.on_cancel) |callback| {
        callback(streaming.handler.context, target.serverHandle(), &streaming.context);
    }
}

fn beginDrain(server: *Impl) void {
    if (!server.drain_started) {
        server.drain_started = true;
        closeListener(server);

        const timeout_ms = if (server.drain_timeout_ns == 0)
            0
        else
            std.math.divCeil(u64, server.drain_timeout_ns, std.time.ns_per_ms) catch std.math.maxInt(u64);
        server.drain_timer.run(&server.loop, &server.drain_timer_completion, timeout_ms, Impl, server, onDrainTimeout);
    }

    // Do not advertise GOAWAY until replacement connections can no longer enter
    // the listener backlog and appear connected without ever being accepted.
    if (!server.listener_closed) return;

    for (server.connections.items) |connection| {
        if (connection.draining or connection.closing or connection.session == null) continue;
        connection.draining = true;
        connection.submitGoAway(
            connection.highest_accepted_stream_id,
            c.NGHTTP2_NO_ERROR,
        ) catch {
            connection.closeOnLoop(&server.loop);
            continue;
        };
        connection.flush() catch connection.closeOnLoop(&server.loop);
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
    server.lock();
    server.state = .stopping;
    server.unlock();
    maybeStopLoop(server);
}

fn onDrainTimeout(server: ?*Impl, _: *xev.Loop, _: *xev.Completion, result: xev.Timer.RunError!void) xev.CallbackAction {
    const impl = server orelse return .disarm;
    result catch return .disarm;
    impl.lock();
    if (impl.state == .draining) impl.state = .stopping;
    impl.unlock();
    stopImmediately(impl);
    return .disarm;
}

fn stopImmediately(server: *Impl) void {
    closeListener(server);
    for (server.connections.items) |connection| connection.closeOnLoop(&server.loop);
    maybeStopLoop(server);
}

fn closeListener(server: *Impl) void {
    if (!server.listener_initialized or server.listener_close_submitted) return;
    if (server.listener_accept_active) {
        if (server.listener_accept_cancel_submitted) return;
        server.listener_accept_cancel_submitted = true;
        server.loop.cancel(
            &server.listener_accept_completion,
            &server.listener_accept_cancel_completion,
            Impl,
            server,
            onListenerAcceptCanceled,
        );
        return;
    }
    server.listener_close_submitted = true;
    server.listener.close(&server.loop, &server.listener_close_completion, Impl, server, onListenerClosed);
}

fn onListenerAcceptCanceled(
    server: ?*Impl,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.CancelError!void,
) xev.CallbackAction {
    const impl = server orelse return .disarm;
    impl.listener_accept_active = false;
    impl.listener_accept_cancel_submitted = false;
    closeListener(impl);
    return .disarm;
}

fn onListenerClosed(server: ?*Impl, _: *xev.Loop, _: *xev.Completion, _: xev.TCP, _: xev.CloseError!void) xev.CallbackAction {
    const impl = server orelse return .disarm;
    impl.listener_closed = true;
    impl.lock();
    const draining = impl.state == .draining;
    impl.unlock();
    if (draining) beginDrain(impl) else maybeStopLoop(impl);
    return .disarm;
}

fn maybeStopLoop(server: *Impl) void {
    server.lock();
    const stopping = server.state == .stopping;
    server.unlock();
    if (stopping and server.listener_closed and server.connections.items.len == 0) server.loop.stop();
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
        _ = stream.request_metadata.appendDecoded(name, value) catch |err| switch (err) {
            error.OutOfMemory => return c.NGHTTP2_ERR_CALLBACK_FAILURE,
            else => {
                stream.request_metadata_invalid = true;
                return 0;
            },
        };
    } else if (isMalformedRequestMetadataName(name)) {
        stream.request_metadata_invalid = true;
    }
    return 0;
}

fn onDataChunk(
    session: ?*c.nghttp2_session,
    _: u8,
    stream_id: i32,
    data_pointer: [*c]const u8,
    data_length: usize,
    user_data: ?*anyopaque,
) callconv(.c) c_int {
    const connection: *Connection = @ptrCast(@alignCast(user_data.?));
    const stream = connection.streams.get(stream_id) orelse return 0;
    if (stream.streaming != null) {
        const copied = receiveStreamingData(stream, data_pointer[0..data_length]);
        if (c.nghttp2_session_consume_connection(session, data_length) != 0) {
            return c.NGHTTP2_ERR_CALLBACK_FAILURE;
        }
        if (copied and stream.streaming_active) {
            if (stream.receive_paused) {
                stream.deferred_stream_credit = std.math.add(
                    usize,
                    stream.deferred_stream_credit,
                    data_length,
                ) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
            } else if (c.nghttp2_session_consume_stream(session, stream_id, data_length) != 0) {
                return c.NGHTTP2_ERR_CALLBACK_FAILURE;
            }
        }
        return 0;
    }
    if (!stream.responded) {
        const body_limit = wireMessageLimit(connection.server.max_request_size);
        if (data_length > body_limit -| stream.request_body.items.len) {
            stream.request_too_large = true;
        } else {
            stream.request_body.appendSlice(stream.allocator, data_pointer[0..data_length]) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
        }
    }
    if (c.nghttp2_session_consume_connection(session, data_length) != 0 or
        c.nghttp2_session_consume_stream(session, stream_id, data_length) != 0)
    {
        return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    }
    return 0;
}

fn onFrameReceived(session: ?*c.nghttp2_session, received_frame: ?*const c.nghttp2_frame, user_data: ?*anyopaque) callconv(.c) c_int {
    const native_frame = received_frame.?;
    const connection: *Connection = @ptrCast(@alignCast(user_data.?));
    const stream = connection.streams.get(native_frame.*.hd.stream_id) orelse return 0;
    if (native_frame.*.hd.type == c.NGHTTP2_HEADERS and stream.request_metadata_invalid and !stream.responded) {
        stream.responded = true;
        scheduleDeadlineTimer(connection.server);
        submitFailure(session.?, stream, .invalid_argument, "invalid request metadata");
        return 0;
    }
    if (native_frame.*.hd.type == c.NGHTTP2_HEADERS and !stream.responded) {
        if (stream.path) |path| {
            if (connection.server.stream_handlers.get(path)) |handler| startStreaming(session.?, stream, handler);
        }
    }
    if ((native_frame.*.hd.type != c.NGHTTP2_HEADERS and native_frame.*.hd.type != c.NGHTTP2_DATA) or
        native_frame.*.hd.flags & c.NGHTTP2_FLAG_END_STREAM == 0)
    {
        return 0;
    }
    if (stream.streaming != null) {
        receiveStreamingEnd(stream);
    } else if (!stream.responded) {
        finishRequest(session.?, stream);
    }
    return 0;
}

fn startStreaming(session: *c.nghttp2_session, target: *Stream, handler: raw_stream.ServerHandler) void {
    target.responded = true;
    scheduleDeadlineTimer(target.connection.server);
    if (target.header_too_large) {
        submitFailure(session, target, .resource_exhausted, "request too large");
        return;
    }
    if (target.timeout_invalid) {
        submitFailure(session, target, .invalid_argument, "invalid grpc-timeout");
        return;
    }
    if (target.request_metadata_invalid) {
        submitFailure(session, target, .invalid_argument, "invalid request metadata");
        return;
    }
    if (target.deadline) |value| {
        if (value.isExceeded()) {
            submitFailure(session, target, .deadline_exceeded, "deadline exceeded");
            return;
        }
    }
    if (!target.method_post) {
        submitFailure(session, target, .unimplemented, "POST required");
        return;
    }
    if (!target.content_type_grpc) {
        submitFailure(session, target, .invalid_argument, "invalid content-type");
        return;
    }
    const request_compression = target.request_compression orelse {
        submitFailure(session, target, .unimplemented, "request compression is not supported");
        return;
    };

    var context = service.ServerContext.init(target.allocator);
    var context_owned = true;
    defer if (context_owned) context.deinit();
    context.deadline = target.deadline;
    context.request_compression = request_compression;
    for (target.request_metadata.items()) |entry| context.request_metadata.append(entry.key, entry.value) catch {
        submitFailure(session, target, .internal, "metadata allocation failed");
        return;
    };
    target.streaming = .{
        .handler = handler,
        .decoder = frame.Decoder.initWithCompression(target.allocator, target.connection.server.stream_limits.max_message_size, request_compression),
        .context = context,
    };
    context_owned = false;
    const server = target.connection.server;
    server.lock();
    target.streaming_active = true;
    server.unlock();

    const streaming = &target.streaming.?;
    handler.on_start(handler.context, target.serverHandle(), &streaming.context) catch {
        failStreaming(target, .internal, "handler failed");
    };
    server.lock();
    target.response_compression = if (target.accepts_response_gzip and
        (streaming.context.response_compression == .gzip or target.response_gzip_requested))
        .gzip
    else
        .identity;
    target.response_headers_submitted = true;
    server.unlock();
    submitStreamingResponse(session, target, streaming.context.initial_metadata.items()) catch target.connection.close();
}

fn receiveStreamingData(target: *Stream, bytes: []const u8) bool {
    const streaming = &(target.streaming orelse return false);
    const server = target.connection.server;
    server.lock();
    const active = target.streaming_active;
    server.unlock();
    if (!active) return false;
    streaming.decoder.feedBounded(bytes, server.stream_limits.max_inbound_buffer_size) catch |err| {
        switch (err) {
            error.BufferLimitExceeded => failStreaming(target, .resource_exhausted, "request message too large"),
            else => failStreaming(target, .invalid_argument, "malformed streaming request"),
        }
        return false;
    };
    deliverStreamingMessages(target);
    return true;
}

fn deliverStreamingMessages(target: *Stream) void {
    const streaming = &(target.streaming orelse return);
    const server = target.connection.server;
    while (true) {
        server.lock();
        const active = target.streaming_active;
        const paused = target.receive_paused;
        server.unlock();
        if (!active or paused) return;

        const decoded = streaming.decoder.nextMessage() catch |err| {
            switch (err) {
                error.MessageTooLarge => failStreaming(target, .resource_exhausted, "request message too large"),
                else => failStreaming(target, .invalid_argument, "malformed streaming request"),
            }
            return;
        } orelse break;
        const compression: Compression = if (decoded.compressed) .gzip else .identity;
        streaming.context.request_compression = compression;
        const action_result = streaming.handler.on_message(
            streaming.handler.context,
            target.serverHandle(),
            &streaming.context,
            decoded.payload,
            compression,
        );
        const action = action_result catch {
            target.allocator.free(decoded.payload);
            failStreaming(target, .internal, "handler failed");
            return;
        };
        target.allocator.free(decoded.payload);
        if (action == .pause) {
            server.lock();
            if (target.streaming_active) target.receive_paused = true;
            server.unlock();
            return;
        }
    }
    if (streaming.remote_end_received) completeStreamingRemoteEnd(target);
}

fn receiveStreamingEnd(target: *Stream) void {
    const streaming = &(target.streaming orelse return);
    if (streaming.remote_end_received) return;
    streaming.remote_end_received = true;
    deliverStreamingMessages(target);
}

fn completeStreamingRemoteEnd(target: *Stream) void {
    const streaming = &(target.streaming orelse return);
    if (streaming.remote_end_called) return;
    streaming.decoder.finish() catch {
        failStreaming(target, .invalid_argument, "malformed streaming request");
        return;
    };
    streaming.remote_end_called = true;
    streaming.handler.on_remote_end(
        streaming.handler.context,
        target.serverHandle(),
        &streaming.context,
    ) catch failStreaming(target, .internal, "handler failed");
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
    if (stream.request_metadata_invalid) {
        submitFailure(session, stream, .invalid_argument, "invalid request metadata");
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

fn submitStreamingResponse(session: *c.nghttp2_session, stream: *Stream, initial_metadata: []const metadata.Entry) !void {
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
        .read_callback = readStreamingResponseData,
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

fn readStreamingResponseData(
    session: ?*c.nghttp2_session,
    _: i32,
    output: [*c]u8,
    output_length: usize,
    data_flags: ?*u32,
    source: ?*c.nghttp2_data_source,
    _: ?*anyopaque,
) callconv(.c) c.nghttp2_ssize {
    const stream: *Stream = @ptrCast(@alignCast(source.?.*.ptr.?));
    const streaming = &(stream.streaming orelse return c.NGHTTP2_ERR_CALLBACK_FAILURE);
    if (streaming.outbound.items.len != 0) {
        const item = &streaming.outbound.items[0];
        const remaining = item.bytes[item.offset..];
        const length = @min(remaining.len, output_length);
        @memcpy(output[0..length], remaining[0..length]);
        item.offset += length;
        releaseOutboundReservation(stream, length, true);
        if (item.offset == item.bytes.len) {
            stream.allocator.free(item.bytes);
            _ = streaming.outbound.orderedRemove(0);
        }
        if (streaming.outbound.items.len == 0 and stream.response_finished) {
            data_flags.?.* |= c.NGHTTP2_DATA_FLAG_EOF | c.NGHTTP2_DATA_FLAG_NO_END_STREAM;
            if (!stream.trailer_submitted) {
                stream.trailer_submitted = true;
                submitStreamingTrailers(session.?, stream) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
            }
        }
        return @intCast(length);
    }
    if (!stream.response_finished) return c.NGHTTP2_ERR_DEFERRED;

    data_flags.?.* |= c.NGHTTP2_DATA_FLAG_EOF | c.NGHTTP2_DATA_FLAG_NO_END_STREAM;
    if (!stream.trailer_submitted) {
        stream.trailer_submitted = true;
        submitStreamingTrailers(session.?, stream) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    }
    return 0;
}

fn submitStreamingTrailers(session: *c.nghttp2_session, stream: *Stream) !void {
    try submitTrailers(session, stream);
}

fn submitStreamingFailureReset(stream: *Stream) !void {
    if (!stream.reset_after_trailers or stream.reset_submitted) return;
    const session = stream.connection.session orelse return;
    if (c.nghttp2_submit_rst_stream(session, c.NGHTTP2_FLAG_NONE, stream.id, c.NGHTTP2_CANCEL) != 0) {
        return error.NativeFailure;
    }
    stream.reset_submitted = true;
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

fn onFrameSent(session: ?*c.nghttp2_session, sent_frame: ?*const c.nghttp2_frame, user_data: ?*anyopaque) callconv(.c) c_int {
    const native_frame = sent_frame.?.*;
    if (native_frame.hd.type != c.NGHTTP2_HEADERS or native_frame.hd.flags & c.NGHTTP2_FLAG_END_STREAM == 0) return 0;
    const connection: *Connection = @ptrCast(@alignCast(user_data.?));
    const stream = connection.streams.get(native_frame.hd.stream_id) orelse return 0;
    if (!stream.reset_after_trailers or stream.reset_submitted) return 0;
    if (c.nghttp2_submit_rst_stream(session, c.NGHTTP2_FLAG_NONE, stream.id, c.NGHTTP2_CANCEL) != 0) {
        return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    }
    stream.reset_submitted = true;
    return 0;
}

fn onStreamClose(_: ?*c.nghttp2_session, stream_id: i32, stream_error: u32, user_data: ?*anyopaque) callconv(.c) c_int {
    const connection: *Connection = @ptrCast(@alignCast(user_data.?));
    if (connection.streams.fetchRemove(stream_id)) |entry| {
        if (entry.value.streaming != null and (stream_error != c.NGHTTP2_NO_ERROR or !entry.value.trailer_submitted)) {
            cancelStreaming(entry.value);
        }
        _ = retireStream(entry.value);
    }
    scheduleDeadlineTimer(connection.server);
    if (connection.draining) finishDrainIfIdle(connection.server);
    return 0;
}

fn ioNow(context: ?*anyopaque) u64 {
    const server: *Impl = @ptrCast(@alignCast(context.?));
    const nanoseconds = std.Io.Clock.awake.now(server.io()).nanoseconds;
    return std.math.cast(u64, @max(nanoseconds, @as(i96, 0))) orelse std.math.maxInt(u64);
}

fn scheduleDeadlineTimer(server: *Impl) void {
    if (!server.loop_initialized or !server.deadline_timer_initialized) return;
    var earliest: ?u64 = null;
    for (server.connections.items) |connection| {
        var iterator = connection.streams.valueIterator();
        while (iterator.next()) |stream_ptr| {
            const stream = stream_ptr.*;
            if (stream.responded and stream.streaming == null) continue;
            if (stream.streaming != null and !stream.streaming_active) continue;
            if (stream.deadline) |value| {
                if (earliest == null or value.expires_at_ns < earliest.?) earliest = value.expires_at_ns;
            }
        }
    }
    if (earliest == null) return;
    const remaining = earliest.? -| server.clock.now();
    const timeout_ms = @max(@as(u64, 1), std.math.divCeil(u64, remaining, std.time.ns_per_ms) catch 1);
    server.deadline_timer.reset(
        &server.loop,
        &server.deadline_timer_completion,
        &server.deadline_timer_cancel_completion,
        timeout_ms,
        Impl,
        server,
        onDeadlineTimer,
    );
}

fn onDeadlineTimer(server: ?*Impl, _: *xev.Loop, _: *xev.Completion, result: xev.Timer.RunError!void) xev.CallbackAction {
    const impl = server orelse return .disarm;
    result catch return .disarm;
    const now = impl.clock.now();
    expireDeadlines(impl, now);
    for (impl.connections.items) |connection| {
        if (connection.closing or connection.session == null) continue;
        connection.flush() catch connection.close();
    }
    scheduleDeadlineTimer(impl);
    return .disarm;
}

fn expireDeadlines(server: *Impl, now: u64) void {
    for (server.connections.items) |connection| {
        if (connection.closing or connection.session == null) continue;
        var iterator = connection.streams.valueIterator();
        while (iterator.next()) |stream_ptr| {
            const stream = stream_ptr.*;
            if (stream.responded and stream.streaming == null) continue;
            if (stream.streaming != null and !stream.streaming_active) continue;
            if (stream.deadline) |value| {
                if (value.expires_at_ns <= now) {
                    if (stream.streaming != null) {
                        cancelStreaming(stream);
                        failStreaming(stream, .deadline_exceeded, "deadline exceeded");
                    } else {
                        stream.responded = true;
                        submitFailure(connection.session.?, stream, .deadline_exceeded, "deadline exceeded");
                    }
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
    return metadata.isApplicationKey(name) and !isReservedRequestHeader(name);
}

fn isReservedRequestHeader(name: []const u8) bool {
    const protocol_headers = [_][]const u8{ "content-type", "te", "user-agent" };
    for (protocol_headers) |header| if (std.mem.eql(u8, name, header)) return true;
    return std.mem.startsWith(u8, name, "grpc-");
}

fn isMalformedRequestMetadataName(name: []const u8) bool {
    if (name.len == 0 or name[0] == ':' or isReservedRequestHeader(name)) return false;
    return !metadata.isValidKey(name);
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

fn validateTransportOptions(initial_stream_window_size: u32, high: usize, low: usize) !void {
    if (initial_stream_window_size == 0 or initial_stream_window_size > std.math.maxInt(i32)) {
        return error.InvalidInitialStreamWindowSize;
    }
    if (low == 0 or low >= high) return error.InvalidWriteWatermarks;
}

fn canFlushWrites(queued: usize, high: usize) bool {
    return queued < high;
}

fn addQueuedWriteBytes(queued: usize, length: usize) !usize {
    return std.math.add(usize, queued, length) catch error.WriteQueueSizeOverflow;
}

fn completeQueuedWrite(queued: usize, length: usize) usize {
    std.debug.assert(length <= queued);
    return queued - length;
}

fn canReturnDeferredStreamCredit(receive_paused: bool, transport_closed: bool) bool {
    return !receive_paused and !transport_closed;
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

fn appendRawTestHeaders(wire: *std.ArrayList(u8), stream_id: i32, path: []const u8, end_stream: bool) !void {
    var block: std.ArrayList(u8) = .empty;
    defer block.deinit(std.testing.allocator);
    try block.appendSlice(std.testing.allocator, &.{ 0x83, 0x86, 0x04 });
    try block.append(std.testing.allocator, @intCast(path.len));
    try block.appendSlice(std.testing.allocator, path);
    try block.appendSlice(std.testing.allocator, &.{ 0x01, 0x09 });
    try block.appendSlice(std.testing.allocator, "localhost");
    try appendTestHeader(&block, "content-type", "application/grpc");

    const id: u32 = @intCast(stream_id);
    try wire.appendSlice(std.testing.allocator, &.{
        @intCast(block.items.len >> 16),
        @intCast(block.items.len >> 8),
        @intCast(block.items.len),
        c.NGHTTP2_HEADERS,
        @as(u8, @intCast(c.NGHTTP2_FLAG_END_HEADERS)) |
            if (end_stream) @as(u8, @intCast(c.NGHTTP2_FLAG_END_STREAM)) else 0,
        @intCast((id >> 24) & 0x7f),
        @intCast(id >> 16),
        @intCast(id >> 8),
        @intCast(id),
    });
    try wire.appendSlice(std.testing.allocator, block.items);
}

fn appendRawTestData(wire: *std.ArrayList(u8), stream_id: i32, payload: []const u8, end_stream: bool) !void {
    const id: u32 = @intCast(stream_id);
    try wire.appendSlice(std.testing.allocator, &.{
        @intCast(payload.len >> 16),
        @intCast(payload.len >> 8),
        @intCast(payload.len),
        c.NGHTTP2_DATA,
        if (end_stream) @as(u8, @intCast(c.NGHTTP2_FLAG_END_STREAM)) else 0,
        @intCast((id >> 24) & 0x7f),
        @intCast(id >> 16),
        @intCast(id >> 8),
        @intCast(id),
    });
    try wire.appendSlice(std.testing.allocator, payload);
}

fn testOutputHasFrame(bytes: []const u8, stream_id: i32, frame_type: u8, required_flags: u8) bool {
    var offset: usize = 0;
    while (offset + 9 <= bytes.len) {
        const payload_length = (@as(usize, bytes[offset]) << 16) |
            (@as(usize, bytes[offset + 1]) << 8) |
            bytes[offset + 2];
        const end = offset + 9 + payload_length;
        if (end > bytes.len) return false;
        const id = (@as(i32, bytes[offset + 5] & 0x7f) << 24) |
            (@as(i32, bytes[offset + 6]) << 16) |
            (@as(i32, bytes[offset + 7]) << 8) |
            bytes[offset + 8];
        if (id == stream_id and bytes[offset + 3] == frame_type and bytes[offset + 4] & required_flags == required_flags) return true;
        offset = end;
    }
    return false;
}

const TestResponseCapture = struct {
    stream1_data: std.ArrayList(u8) = .empty,
    stream3_data: std.ArrayList(u8) = .empty,
    stream1_status: ?u32 = null,
    stream3_status: ?u32 = null,
    stream1_message_matches: bool = false,
    stream1_trailing_metadata_matches: bool = false,
    stream1_ended: bool = false,
    stream3_ended: bool = false,
    stream1_reset: bool = false,

    fn deinit(self: *@This()) void {
        self.stream1_data.deinit(std.testing.allocator);
        self.stream3_data.deinit(std.testing.allocator);
    }

    fn decode(self: *@This(), bytes: []const u8) !void {
        var inflater: ?*c.nghttp2_hd_inflater = null;
        if (c.nghttp2_hd_inflate_new(&inflater) != 0) return error.OutOfMemory;
        defer c.nghttp2_hd_inflate_del(inflater);

        var offset: usize = 0;
        while (offset + 9 <= bytes.len) {
            const payload_length = (@as(usize, bytes[offset]) << 16) |
                (@as(usize, bytes[offset + 1]) << 8) |
                bytes[offset + 2];
            const end = offset + 9 + payload_length;
            if (end > bytes.len) return error.TruncatedFrame;
            const frame_type = bytes[offset + 3];
            const flags = bytes[offset + 4];
            const stream_id = (@as(i32, bytes[offset + 5] & 0x7f) << 24) |
                (@as(i32, bytes[offset + 6]) << 16) |
                (@as(i32, bytes[offset + 7]) << 8) |
                bytes[offset + 8];
            const payload = bytes[offset + 9 .. end];
            if (frame_type == c.NGHTTP2_DATA) {
                const destination = if (stream_id == 1)
                    &self.stream1_data
                else if (stream_id == 3)
                    &self.stream3_data
                else
                    null;
                if (destination) |data| try data.appendSlice(std.testing.allocator, payload);
            } else if (frame_type == c.NGHTTP2_HEADERS) {
                if (flags & c.NGHTTP2_FLAG_END_HEADERS == 0) return error.TestHeaderContinuationUnsupported;
                try self.decodeHeaderBlock(inflater.?, stream_id, payload);
            } else if (frame_type == c.NGHTTP2_RST_STREAM and stream_id == 1) {
                self.stream1_reset = true;
            }
            if (flags & c.NGHTTP2_FLAG_END_STREAM != 0) {
                if (stream_id == 1) self.stream1_ended = true;
                if (stream_id == 3) self.stream3_ended = true;
            }
            offset = end;
        }
        if (offset != bytes.len) return error.TruncatedFrame;
    }

    fn decodeHeaderBlock(self: *@This(), inflater: *c.nghttp2_hd_inflater, stream_id: i32, block: []const u8) !void {
        var offset: usize = 0;
        while (true) {
            var nv: c.nghttp2_nv = undefined;
            var inflate_flags: c_int = 0;
            const consumed = c.nghttp2_hd_inflate_hd2(
                inflater,
                &nv,
                &inflate_flags,
                block[offset..].ptr,
                block.len - offset,
                1,
            );
            if (consumed < 0) return error.HeaderDecodeFailed;
            offset += @intCast(consumed);
            if (inflate_flags & c.NGHTTP2_HD_INFLATE_EMIT != 0) {
                self.captureHeader(stream_id, nv.name[0..nv.namelen], nv.value[0..nv.valuelen]) catch return error.InvalidHeader;
            }
            if (inflate_flags & c.NGHTTP2_HD_INFLATE_FINAL != 0) {
                if (c.nghttp2_hd_inflate_end_headers(inflater) != 0) return error.HeaderDecodeFailed;
                return;
            }
            if (consumed == 0 and inflate_flags & c.NGHTTP2_HD_INFLATE_EMIT == 0) return error.HeaderDecodeFailed;
        }
    }

    fn captureHeader(self: *@This(), stream_id: i32, name: []const u8, value: []const u8) !void {
        if (std.mem.eql(u8, name, "grpc-status")) {
            const code = try std.fmt.parseInt(u32, value, 10);
            if (stream_id == 1) self.stream1_status = code;
            if (stream_id == 3) self.stream3_status = code;
        } else if (stream_id == 1 and std.mem.eql(u8, name, "grpc-message")) {
            self.stream1_message_matches = std.mem.eql(u8, value, "complete");
        } else if (stream_id == 1 and std.mem.eql(u8, name, "x-stream-trailer")) {
            self.stream1_trailing_metadata_matches = std.mem.eql(u8, value, "yes");
        }
    }
};

const TestRequestOptions = struct {
    stream_id: i32 = 1,
    include_preface: bool = true,
    end_stream: bool = true,
    body: ?[]const u8 = null,
    timeout_values: []const []const u8 = &.{},
    metadata_entries: []const metadata.Entry = &.{},
};

fn feedTestRequest(connection: *Connection, options: TestRequestOptions) !void {
    var header_block: std.ArrayList(u8) = .empty;
    defer header_block.deinit(std.testing.allocator);
    try header_block.appendSlice(std.testing.allocator, &.{ 0x83, 0x86, 0x04, 0x10 });
    try header_block.appendSlice(std.testing.allocator, "/test.Echo/Unary");
    try header_block.appendSlice(std.testing.allocator, &.{ 0x01, 0x09 });
    try header_block.appendSlice(std.testing.allocator, "localhost");
    try appendTestHeader(&header_block, "content-type", "application/grpc");
    for (options.timeout_values) |value| try appendTestHeader(&header_block, "grpc-timeout", value);
    for (options.metadata_entries) |entry| try appendTestHeader(&header_block, entry.key, entry.value);

    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    if (options.include_preface) {
        try wire.appendSlice(std.testing.allocator, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n");
        try wire.appendSlice(std.testing.allocator, &.{ 0, 0, 0, c.NGHTTP2_SETTINGS, 0, 0, 0, 0, 0 });
    }
    const stream_id: u32 = @intCast(options.stream_id);
    const headers_end_stream = options.end_stream and options.body == null;
    try wire.appendSlice(std.testing.allocator, &.{
        @intCast(header_block.items.len >> 16),
        @intCast(header_block.items.len >> 8),
        @intCast(header_block.items.len),
        c.NGHTTP2_HEADERS,
        @as(u8, @intCast(c.NGHTTP2_FLAG_END_HEADERS)) |
            if (headers_end_stream) @as(u8, @intCast(c.NGHTTP2_FLAG_END_STREAM)) else 0,
        @intCast((stream_id >> 24) & 0x7f),
        @intCast(stream_id >> 16),
        @intCast(stream_id >> 8),
        @intCast(stream_id),
    });
    try wire.appendSlice(std.testing.allocator, header_block.items);
    if (options.body) |body| {
        const encoded = try frame.encode(std.testing.allocator, body);
        defer std.testing.allocator.free(encoded);
        try wire.appendSlice(std.testing.allocator, &.{
            @intCast(encoded.len >> 16),
            @intCast(encoded.len >> 8),
            @intCast(encoded.len),
            c.NGHTTP2_DATA,
            if (options.end_stream) @as(u8, @intCast(c.NGHTTP2_FLAG_END_STREAM)) else 0,
            @intCast((stream_id >> 24) & 0x7f),
            @intCast(stream_id >> 16),
            @intCast(stream_id >> 8),
            @intCast(stream_id),
        });
        try wire.appendSlice(std.testing.allocator, encoded);
    }

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

fn exchangeRawHttp2(server: *Server, input: []const u8) ![]u8 {
    const local_address = try server.localAddress();
    const address = try std.Io.net.IpAddress.parseIp4(local_address.host, local_address.port);
    var io_threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();
    const stream = try address.connect(io, .{
        .mode = .stream,
        .timeout = .none,
    });
    defer stream.close(io);

    var write_buffer: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    writer.interface.writeAll(input) catch |err| return writer.err orelse err;
    writer.interface.flush() catch |err| return writer.err orelse err;

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(std.testing.allocator);
    var read_buffer: [256]u8 = undefined;
    var reader = stream.reader(io, &.{});
    while (true) {
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = stream.socket.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&poll_fds, 1000) == 0) return error.TestTimeout;
        const length = reader.interface.readSliceShort(&read_buffer) catch return reader.err.?;
        try output.appendSlice(std.testing.allocator, read_buffer[0..length]);
        if (length == 0) break;
    }
    return output.toOwnedSlice(std.testing.allocator);
}

test "malformed HTTP/2 settings close the connection promptly" {
    var server = try Server.init(std.testing.allocator, .{});
    defer server.deinit();
    try server.start();

    const preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
    const cases = [_][]const u8{
        preface ++ [_]u8{ 0, 0, 1, c.NGHTTP2_SETTINGS, 0, 0, 0, 0, 0, 0 },
        preface ++ [_]u8{ 0, 0, 0, c.NGHTTP2_SETTINGS, 0, 0, 0, 0, 1 },
    };
    for (cases) |input| {
        const output = try exchangeRawHttp2(&server, input);
        defer std.testing.allocator.free(output);
        try std.testing.expect(output.len != 0);
    }
}

test "malformed HTTP/2 settings close after a completed unary stream" {
    const Handler = struct {
        fn handle(_: *@This(), allocator: std.mem.Allocator, _: *service.ServerContext, request: []const u8) !service.UnaryResponse {
            return service.UnaryResponse.ok(allocator, request);
        }
    };

    var handler = Handler{};
    var server = try Server.init(std.testing.allocator, .{});
    defer server.deinit();
    try server.registerUnary(
        "/test.Echo/Unary",
        service.UnaryHandler.bind(Handler, &handler, Handler.handle),
    );
    try server.start();

    const header_block = [_]u8{
        0x83, 0x86, // :method POST, :scheme http
        0x04, 0x10,
    } ++ "/test.Echo/Unary" ++ [_]u8{
        0x01, 0x09,
    } ++ "localhost" ++ [_]u8{
        0x0f, 0x10, 0x10,
    } ++ "application/grpc";
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
        0, 0, 9, c.NGHTTP2_DATA, c.NGHTTP2_FLAG_END_STREAM, 0, 0, 0, 1,
        0, 0, 0, 0,              4,
    } ++ "ping";
    const input = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" ++ [_]u8{
        0, 0, 0, c.NGHTTP2_SETTINGS, 0, 0, 0, 0, 0,
    } ++ headers_frame ++ data_frame;

    const local_address = try server.localAddress();
    const address = try std.Io.net.IpAddress.parseIp4(local_address.host, local_address.port);
    var io_threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();
    const stream = try address.connect(io, .{
        .mode = .stream,
        .timeout = .none,
    });
    defer stream.close(io);

    var write_buffer: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    writer.interface.writeAll(input) catch |err| return writer.err orelse err;
    writer.interface.flush() catch |err| return writer.err orelse err;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var read_buffer: [256]u8 = undefined;
    var parsed: usize = 0;
    var unary_complete = false;
    while (!unary_complete) {
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = stream.socket.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&poll_fds, 1000) == 0) return error.TestTimeout;
        const length = try std.posix.read(stream.socket.handle, &read_buffer);
        if (length == 0) return error.UnexpectedEof;
        try output.appendSlice(std.testing.allocator, read_buffer[0..length]);
        while (parsed + 9 <= output.items.len) {
            const payload_length = (@as(usize, output.items[parsed]) << 16) |
                (@as(usize, output.items[parsed + 1]) << 8) |
                output.items[parsed + 2];
            const end = parsed + 9 + payload_length;
            if (end > output.items.len) break;
            const stream_id = (@as(u32, output.items[parsed + 5] & 0x7f) << 24) |
                (@as(u32, output.items[parsed + 6]) << 16) |
                (@as(u32, output.items[parsed + 7]) << 8) |
                output.items[parsed + 8];
            if (stream_id == 1 and
                output.items[parsed + 3] == c.NGHTTP2_HEADERS and
                output.items[parsed + 4] & c.NGHTTP2_FLAG_END_STREAM != 0)
            {
                unary_complete = true;
            }
            parsed = end;
        }
    }
    const malformed_settings = [_]u8{
        0, 0, 0, c.NGHTTP2_SETTINGS, 0, 0, 0, 0, 1,
    };
    writer.interface.writeAll(&malformed_settings) catch |err| return writer.err orelse err;
    writer.interface.flush() catch |err| return writer.err orelse err;
    while (true) {
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = stream.socket.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&poll_fds, 1000) == 0) return error.TestTimeout;
        const length = try std.posix.read(stream.socket.handle, &read_buffer);
        if (length == 0) break;
    }
}

test "invalid HTTP/2 max frame size emits protocol error GOAWAY" {
    var server = try Server.init(std.testing.allocator, .{});
    defer server.deinit();
    try server.start();

    const input = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" ++ [_]u8{
        0, 0,                                 6, c.NGHTTP2_SETTINGS, 0,    0,    0, 0, 0,
        0, c.NGHTTP2_SETTINGS_MAX_FRAME_SIZE, 0, 0,                  0x3f, 0xff,
    };
    const output = try exchangeRawHttp2(&server, input);
    defer std.testing.allocator.free(output);

    var saw_protocol_error_goaway = false;
    var offset: usize = 0;
    while (offset + 9 <= output.len) {
        const payload_length = (@as(usize, output[offset]) << 16) |
            (@as(usize, output[offset + 1]) << 8) |
            output[offset + 2];
        const end = offset + 9 + payload_length;
        try std.testing.expect(end <= output.len);
        if (output[offset + 3] == c.NGHTTP2_GOAWAY and payload_length >= 8) {
            const payload = output[offset + 9 .. end];
            const error_code = (@as(u32, payload[4]) << 24) |
                (@as(u32, payload[5]) << 16) |
                (@as(u32, payload[6]) << 8) |
                payload[7];
            try std.testing.expectEqual(@as(u32, c.NGHTTP2_PROTOCOL_ERROR), error_code);
            saw_protocol_error_goaway = true;
        }
        offset = end;
    }
    try std.testing.expectEqual(output.len, offset);
    try std.testing.expect(saw_protocol_error_goaway);
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

test "manual receive credit isolates a paused stream and resumes on loop" {
    const Handler = struct {
        messages: usize = 0,

        fn onStart(_: ?*anyopaque, _: raw_stream.ServerStream, _: *service.ServerContext) !void {}

        fn onMessage(
            context: ?*anyopaque,
            _: raw_stream.ServerStream,
            _: *service.ServerContext,
            _: []const u8,
            _: Compression,
        ) !raw_stream.ReceiveAction {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.messages += 1;
            return if (self.messages <= 2) .pause else .continue_receiving;
        }

        fn onRemoteEnd(_: ?*anyopaque, _: raw_stream.ServerStream, _: *service.ServerContext) !void {}
    };

    var handler = Handler{};
    var server = try Server.init(std.testing.allocator, .{ .stream_limits = .{
        .max_message_size = 48 * 1024,
        .max_inbound_buffer_size = 64 * 1024,
        .max_outbound_buffer_size = 64 * 1024,
    } });
    defer server.deinit();
    try server.registerStream("/test.Flow/Pause", .{
        .context = &handler,
        .on_start = Handler.onStart,
        .on_message = Handler.onMessage,
        .on_remote_end = Handler.onRemoteEnd,
    });

    var connection = Connection{ .server = server.impl };
    try connection.initializeSession();
    defer deinitTestConnection(&connection);

    const first = try frame.encode(std.testing.allocator, "pause");
    defer std.testing.allocator.free(first);
    const payload = try std.testing.allocator.alloc(u8, 40 * 1024);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');
    const second = try frame.encode(std.testing.allocator, payload);
    defer std.testing.allocator.free(second);

    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try wire.appendSlice(std.testing.allocator, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n");
    try wire.appendSlice(std.testing.allocator, &.{ 0, 0, 0, c.NGHTTP2_SETTINGS, 0, 0, 0, 0, 0 });
    try appendRawTestHeaders(&wire, 1, "/test.Flow/Pause", false);
    try appendRawTestData(&wire, 1, first, false);
    var offset: usize = 0;
    while (offset < second.len) {
        const end = @min(offset + 255, second.len);
        try appendRawTestData(&wire, 1, second[offset..end], false);
        offset = end;
    }

    const consumed = c.nghttp2_session_mem_recv2(connection.session, wire.items.ptr, wire.items.len);
    try std.testing.expectEqual(@as(c.nghttp2_ssize, @intCast(wire.items.len)), consumed);
    const target = connection.streams.get(1).?;
    try std.testing.expect(target.receive_paused);
    try std.testing.expectEqual(@as(usize, 1), handler.messages);
    try std.testing.expectEqual(first.len + second.len, target.deferred_stream_credit);
    try std.testing.expect(
        c.nghttp2_session_get_local_window_size(connection.session) >
            c.nghttp2_session_get_stream_local_window_size(connection.session, 1),
    );

    processStreamCommand(server.impl, .{ .target = target, .action = .resume_receive });
    try std.testing.expect(target.receive_paused);
    try std.testing.expectEqual(first.len + second.len, target.deferred_stream_credit);
    try std.testing.expectEqual(@as(usize, 2), handler.messages);
    try std.testing.expect(
        c.nghttp2_session_get_stream_local_window_size(connection.session, 1) <
            c.NGHTTP2_INITIAL_WINDOW_SIZE,
    );

    processStreamCommand(server.impl, .{ .target = target, .action = .resume_receive });
    try std.testing.expect(!target.receive_paused);
    try std.testing.expectEqual(@as(usize, 0), target.deferred_stream_credit);
    try std.testing.expectEqual(@as(usize, 2), handler.messages);
    try std.testing.expectEqual(
        @as(i32, c.NGHTTP2_INITIAL_WINDOW_SIZE),
        c.nghttp2_session_get_stream_local_window_size(connection.session, 1),
    );
}

test "server occupied port startup cleans up deterministically" {
    const listen_address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try listen_address.listen(std.testing.io, .{});
    defer listener.deinit(std.testing.io);

    var local_address: std.posix.sockaddr.in = undefined;
    var address_length: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
    if (std.posix.errno(std.posix.system.getsockname(
        listener.socket.handle,
        @ptrCast(&local_address),
        &address_length,
    )) != .SUCCESS) return error.AddressQueryFailed;

    var server = try Server.init(std.testing.allocator, .{
        .port = std.mem.bigToNative(u16, local_address.port),
    });
    defer server.deinit();
    try std.testing.expectError(error.BindFailed, server.start());
    server.shutdown();
    server.wait();
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

test "raw HTTP/2 bidi stream incrementally exchanges messages" {
    const Handler = struct {
        starts: usize = 0,
        messages: usize = 0,
        remote_ends: usize = 0,
        writable_calls: usize = 0,
        cancels: usize = 0,
        callbacks_ordered: bool = true,
        compression_matches: bool = true,
        backpressure_seen: bool = false,
        pending_response: bool = false,
        writable_send_failed: bool = false,
        remote_ended: bool = false,

        const large_response = "0123456789abcdef" ** 4;

        fn onStart(context: ?*anyopaque, _: raw_stream.ServerStream, server_context: *service.ServerContext) !void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.starts += 1;
            server_context.setResponseCompression(.gzip);
        }

        fn onMessage(
            context: ?*anyopaque,
            server_stream: raw_stream.ServerStream,
            _: *service.ServerContext,
            payload: []const u8,
            compression: Compression,
        ) !raw_stream.ReceiveAction {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.callbacks_ordered = self.callbacks_ordered and self.starts == 1 and self.remote_ends == 0;
            const expected_payload = if (self.messages == 0) "one" else "two two two";
            const expected_compression: Compression = if (self.messages == 0) .identity else .gzip;
            self.compression_matches = self.compression_matches and
                std.mem.eql(u8, payload, expected_payload) and compression == expected_compression;
            self.messages += 1;
            if (self.messages == 1) {
                try server_stream.send(large_response, .{});
            } else {
                server_stream.send(payload, .{ .compression = .gzip }) catch |err| {
                    if (err != error.WouldBlock) return err;
                    self.backpressure_seen = true;
                    self.pending_response = true;
                };
            }
            return .continue_receiving;
        }

        fn onRemoteEnd(context: ?*anyopaque, server_stream: raw_stream.ServerStream, server_context: *service.ServerContext) !void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.remote_ends += 1;
            self.remote_ended = true;
            try server_context.addTrailingMetadata("x-stream-trailer", "yes");
            if (!self.pending_response) try server_stream.finish(.init(.ok, "complete"));
        }

        fn onWritable(context: ?*anyopaque, server_stream: raw_stream.ServerStream, _: *service.ServerContext) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.writable_calls += 1;
            if (!self.pending_response) return;
            server_stream.send("two two two", .{ .compression = .gzip }) catch {
                self.writable_send_failed = true;
                return;
            };
            self.pending_response = false;
            if (self.remote_ended) {
                server_stream.finish(.init(.ok, "complete")) catch {
                    self.writable_send_failed = true;
                };
            }
        }

        fn onCancel(context: ?*anyopaque, _: raw_stream.ServerStream, _: *service.ServerContext) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.cancels += 1;
        }
    };

    var handler = Handler{};
    var server = try Server.init(std.testing.allocator, .{ .stream_limits = .{
        .max_message_size = 64,
        .max_inbound_buffer_size = 256,
        .max_outbound_buffer_size = 69,
    }, .initial_stream_window_size = 256 });
    defer server.deinit();
    try server.registerStream("/test.Echo/Bidi", .{
        .context = &handler,
        .on_start = Handler.onStart,
        .on_message = Handler.onMessage,
        .on_remote_end = Handler.onRemoteEnd,
        .on_writable = Handler.onWritable,
        .on_cancel = Handler.onCancel,
    });
    try server.start();

    var header_block: std.ArrayList(u8) = .empty;
    defer header_block.deinit(std.testing.allocator);
    try header_block.appendSlice(std.testing.allocator, &.{ 0x83, 0x86, 0x04, 0x0f });
    try header_block.appendSlice(std.testing.allocator, "/test.Echo/Bidi");
    try header_block.appendSlice(std.testing.allocator, &.{ 0x01, 0x09 });
    try header_block.appendSlice(std.testing.allocator, "localhost");
    try appendTestHeader(&header_block, "content-type", "application/grpc");
    try appendTestHeader(&header_block, "grpc-encoding", "gzip");
    try appendTestHeader(&header_block, "grpc-accept-encoding", "identity,gzip");

    const first = try frame.encode(std.testing.allocator, "one");
    defer std.testing.allocator.free(first);
    const second = try frame.encodeWithCompression(std.testing.allocator, "two two two", .gzip);
    defer std.testing.allocator.free(second);
    var request_data: std.ArrayList(u8) = .empty;
    defer request_data.deinit(std.testing.allocator);
    try request_data.appendSlice(std.testing.allocator, first);
    try request_data.appendSlice(std.testing.allocator, second);

    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try wire.appendSlice(std.testing.allocator, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n");
    try wire.appendSlice(std.testing.allocator, &.{ 0, 0, 0, c.NGHTTP2_SETTINGS, 0, 0, 0, 0, 0 });
    try wire.appendSlice(std.testing.allocator, &.{
        @intCast(header_block.items.len >> 16),
        @intCast(header_block.items.len >> 8),
        @intCast(header_block.items.len),
        c.NGHTTP2_HEADERS,
        c.NGHTTP2_FLAG_END_HEADERS,
        0,
        0,
        0,
        1,
    });
    try wire.appendSlice(std.testing.allocator, header_block.items);
    const split = 3;
    try wire.appendSlice(std.testing.allocator, &.{ 0, 0, split, c.NGHTTP2_DATA, 0, 0, 0, 0, 1 });
    try wire.appendSlice(std.testing.allocator, request_data.items[0..split]);
    const remaining = request_data.items.len - split;
    try wire.appendSlice(std.testing.allocator, &.{
        @intCast(remaining >> 16),
        @intCast(remaining >> 8),
        @intCast(remaining),
        c.NGHTTP2_DATA,
        c.NGHTTP2_FLAG_END_STREAM,
        0,
        0,
        0,
        1,
    });
    try wire.appendSlice(std.testing.allocator, request_data.items[split..]);

    const local_address = try server.localAddress();
    const address = try std.Io.net.IpAddress.parseIp4(local_address.host, local_address.port);
    var io_threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();
    const socket = try address.connect(io, .{ .mode = .stream, .timeout = .none });
    defer socket.close(io);
    var write_buffer: [512]u8 = undefined;
    var writer = socket.writer(io, &write_buffer);
    writer.interface.writeAll(wire.items) catch |err| return writer.err orelse err;
    writer.interface.flush() catch |err| return writer.err orelse err;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var response_data: std.ArrayList(u8) = .empty;
    defer response_data.deinit(std.testing.allocator);
    var parsed: usize = 0;
    var saw_trailers = false;
    var read_buffer: [512]u8 = undefined;
    for (0..10) |_| {
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = socket.socket.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&poll_fds, 1000) == 0) return error.TestTimeout;
        const length = try std.posix.read(socket.socket.handle, &read_buffer);
        if (length == 0) return error.UnexpectedEof;
        try output.appendSlice(std.testing.allocator, read_buffer[0..length]);
        while (parsed + 9 <= output.items.len) {
            const payload_length = (@as(usize, output.items[parsed]) << 16) |
                (@as(usize, output.items[parsed + 1]) << 8) |
                output.items[parsed + 2];
            const end = parsed + 9 + payload_length;
            if (end > output.items.len) break;
            const stream_id = (@as(u32, output.items[parsed + 5] & 0x7f) << 24) |
                (@as(u32, output.items[parsed + 6]) << 16) |
                (@as(u32, output.items[parsed + 7]) << 8) |
                output.items[parsed + 8];
            if (stream_id == 1 and output.items[parsed + 3] == c.NGHTTP2_DATA) {
                try response_data.appendSlice(std.testing.allocator, output.items[parsed + 9 .. end]);
            }
            if (stream_id == 1 and
                output.items[parsed + 3] == c.NGHTTP2_HEADERS and
                output.items[parsed + 4] & c.NGHTTP2_FLAG_END_STREAM != 0)
            {
                saw_trailers = true;
            }
            parsed = end;
        }
        if (saw_trailers) break;
    }
    try std.testing.expect(saw_trailers);

    var capture = TestResponseCapture{};
    defer capture.deinit();
    try capture.decode(output.items);

    var decoder = frame.Decoder.initWithCompression(std.testing.allocator, 1024, .gzip);
    defer decoder.deinit();
    try decoder.feed(response_data.items);
    const echoed_first = (try decoder.nextMessage()).?;
    defer std.testing.allocator.free(echoed_first.payload);
    const echoed_second = (try decoder.nextMessage()).?;
    defer std.testing.allocator.free(echoed_second.payload);
    try decoder.finish();
    try std.testing.expectEqualStrings(Handler.large_response, echoed_first.payload);
    try std.testing.expect(!echoed_first.compressed);
    try std.testing.expectEqualStrings("two two two", echoed_second.payload);
    try std.testing.expect(echoed_second.compressed);
    try std.testing.expectEqual(@as(usize, 1), handler.starts);
    try std.testing.expectEqual(@as(usize, 2), handler.messages);
    try std.testing.expectEqual(@as(usize, 1), handler.remote_ends);
    try std.testing.expectEqual(@as(usize, 1), handler.writable_calls);
    try std.testing.expectEqual(@as(usize, 0), handler.cancels);
    try std.testing.expect(handler.callbacks_ordered);
    try std.testing.expect(handler.compression_matches);
    try std.testing.expect(handler.backpressure_seen);
    try std.testing.expect(!handler.pending_response);
    try std.testing.expect(!handler.writable_send_failed);
    try std.testing.expectEqual(@as(?u32, 0), capture.stream1_status);
    try std.testing.expect(capture.stream1_message_matches);
    try std.testing.expect(capture.stream1_trailing_metadata_matches);
    try std.testing.expect(capture.stream1_ended);
}

test "malformed streaming input resets only its stream and connection remains reusable" {
    const StreamingHandler = struct {
        messages: usize = 0,
        cancels: usize = 0,

        fn onStart(_: ?*anyopaque, _: raw_stream.ServerStream, context: *service.ServerContext) !void {
            try context.addTrailingMetadata("x-stream-trailer", "yes");
        }

        fn onMessage(
            context_ptr: ?*anyopaque,
            _: raw_stream.ServerStream,
            _: *service.ServerContext,
            payload: []const u8,
            _: Compression,
        ) !raw_stream.ReceiveAction {
            const self: *@This() = @ptrCast(@alignCast(context_ptr.?));
            try std.testing.expectEqualStrings("valid", payload);
            self.messages += 1;
            return .continue_receiving;
        }

        fn onRemoteEnd(_: ?*anyopaque, _: raw_stream.ServerStream, _: *service.ServerContext) !void {
            return error.UnexpectedRemoteEnd;
        }

        fn onCancel(context_ptr: ?*anyopaque, _: raw_stream.ServerStream, _: *service.ServerContext) void {
            const self: *@This() = @ptrCast(@alignCast(context_ptr.?));
            self.cancels += 1;
        }
    };
    const UnaryHandler = struct {
        fn handle(_: *@This(), allocator: std.mem.Allocator, _: *service.ServerContext, request: []const u8) !service.UnaryResponse {
            try std.testing.expectEqualStrings("reuse", request);
            return service.UnaryResponse.ok(allocator, "reused");
        }
    };

    var streaming_handler = StreamingHandler{};
    var unary_handler = UnaryHandler{};
    var server = try Server.init(std.testing.allocator, .{});
    defer server.deinit();
    try server.registerStream("/test.Echo/Bidi", .{
        .context = &streaming_handler,
        .on_start = StreamingHandler.onStart,
        .on_message = StreamingHandler.onMessage,
        .on_remote_end = StreamingHandler.onRemoteEnd,
        .on_cancel = StreamingHandler.onCancel,
    });
    try server.registerUnary(
        "/test.Echo/Unary",
        service.UnaryHandler.bind(UnaryHandler, &unary_handler, UnaryHandler.handle),
    );
    try server.start();

    const local_address = try server.localAddress();
    const address = try std.Io.net.IpAddress.parseIp4(local_address.host, local_address.port);
    var io_threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();
    const socket = try address.connect(io, .{ .mode = .stream, .timeout = .none });
    defer socket.close(io);
    var write_buffer: [512]u8 = undefined;
    var writer = socket.writer(io, &write_buffer);

    const valid = try frame.encode(std.testing.allocator, "valid");
    defer std.testing.allocator.free(valid);
    var first_request: std.ArrayList(u8) = .empty;
    defer first_request.deinit(std.testing.allocator);
    try first_request.appendSlice(std.testing.allocator, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n");
    try first_request.appendSlice(std.testing.allocator, &.{ 0, 0, 0, c.NGHTTP2_SETTINGS, 0, 0, 0, 0, 0 });
    try appendRawTestHeaders(&first_request, 1, "/test.Echo/Bidi", false);
    var malformed_body: std.ArrayList(u8) = .empty;
    defer malformed_body.deinit(std.testing.allocator);
    try malformed_body.appendSlice(std.testing.allocator, valid);
    try malformed_body.appendSlice(std.testing.allocator, &.{ 2, 0, 0, 0, 0 });
    try appendRawTestData(&first_request, 1, malformed_body.items, false);
    writer.interface.writeAll(first_request.items) catch |err| return writer.err orelse err;
    writer.interface.flush() catch |err| return writer.err orelse err;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var read_buffer: [512]u8 = undefined;
    for (0..10) |_| {
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = socket.socket.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&poll_fds, 1000) == 0) return error.TestTimeout;
        const length = try std.posix.read(socket.socket.handle, &read_buffer);
        if (length == 0) return error.UnexpectedEof;
        try output.appendSlice(std.testing.allocator, read_buffer[0..length]);
        if (testOutputHasFrame(output.items, 1, c.NGHTTP2_RST_STREAM, 0)) break;
    }
    try std.testing.expect(testOutputHasFrame(output.items, 1, c.NGHTTP2_RST_STREAM, 0));

    const unary_body = try frame.encode(std.testing.allocator, "reuse");
    defer std.testing.allocator.free(unary_body);
    var second_request: std.ArrayList(u8) = .empty;
    defer second_request.deinit(std.testing.allocator);
    try appendRawTestHeaders(&second_request, 3, "/test.Echo/Unary", false);
    try appendRawTestData(&second_request, 3, unary_body, true);
    writer.interface.writeAll(second_request.items) catch |err| return writer.err orelse err;
    writer.interface.flush() catch |err| return writer.err orelse err;

    for (0..10) |_| {
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = socket.socket.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&poll_fds, 1000) == 0) return error.TestTimeout;
        const length = try std.posix.read(socket.socket.handle, &read_buffer);
        if (length == 0) return error.UnexpectedEof;
        try output.appendSlice(std.testing.allocator, read_buffer[0..length]);
        if (testOutputHasFrame(output.items, 3, c.NGHTTP2_HEADERS, c.NGHTTP2_FLAG_END_STREAM)) break;
    }
    try std.testing.expect(testOutputHasFrame(output.items, 3, c.NGHTTP2_HEADERS, c.NGHTTP2_FLAG_END_STREAM));

    var capture = TestResponseCapture{};
    defer capture.deinit();
    try capture.decode(output.items);
    try std.testing.expectEqual(@as(?u32, @intFromEnum(status.Code.invalid_argument)), capture.stream1_status);
    try std.testing.expect(capture.stream1_trailing_metadata_matches);
    try std.testing.expect(capture.stream1_reset);
    try std.testing.expectEqual(@as(?u32, 0), capture.stream3_status);
    const unary_response = try frame.decodeUnary(std.testing.allocator, capture.stream3_data.items, 64);
    defer std.testing.allocator.free(unary_response);
    try std.testing.expectEqualStrings("reused", unary_response);
    try std.testing.expectEqual(@as(usize, 1), streaming_handler.messages);
    try std.testing.expectEqual(@as(usize, 1), streaming_handler.cancels);
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
        try feedTestRequest(&connection, .{ .timeout_values = case.values });
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

    try feedTestRequest(&connection, .{ .end_stream = false, .timeout_values = &.{"0n"} });
    const stream = connection.streams.get(1).?;
    try std.testing.expect(!stream.responded);
    expireDeadlines(server.impl, server.impl.clock.now());
    try std.testing.expect(stream.responded);
    try std.testing.expectEqual(status.Code.deadline_exceeded, stream.response_code);
    try std.testing.expect(!connection.closing);
}

test "malformed request metadata rejects one stream and preserves the connection" {
    const Handler = struct {
        calls: usize = 0,
        metadata_matches: bool = false,

        fn handle(self: *@This(), allocator: std.mem.Allocator, context: *service.ServerContext, request: []const u8) !service.UnaryResponse {
            self.calls += 1;
            const entries = context.request_metadata.items();
            self.metadata_matches = entries.len == 2 and
                std.mem.eql(u8, entries[0].key, "trace-bin") and
                std.mem.eql(u8, entries[0].value, &.{0xab}) and
                std.mem.eql(u8, entries[1].key, "trace-bin") and
                std.mem.eql(u8, entries[1].value, &.{ 0xab, 0xab, 0xab }) and
                context.request_metadata.getFirst("x-control") == null and
                context.request_metadata.getFirst("grpc-future") == null;
            return service.UnaryResponse.ok(allocator, request);
        }
    };

    var handler = Handler{};
    var server = try Server.init(std.testing.allocator, .{});
    defer server.deinit();
    try server.registerUnary(
        "/test.Echo/Unary",
        service.UnaryHandler.bind(Handler, &handler, Handler.handle),
    );
    var connection = Connection{ .server = server.impl };
    try connection.initializeSession();
    defer deinitTestConnection(&connection);

    try feedTestRequest(&connection, .{ .metadata_entries = &.{.{
        .key = "trace-bin",
        .value = "not base64!",
    }} });
    const rejected = connection.streams.get(1).?;
    try std.testing.expectEqual(status.Code.invalid_argument, rejected.response_code);
    try std.testing.expect(!connection.closing);

    try feedTestRequest(&connection, .{
        .stream_id = 3,
        .include_preface = false,
        .metadata_entries = &.{.{ .key = "x!invalid", .value = "value" }},
    });
    const invalid_key = connection.streams.get(3).?;
    try std.testing.expectEqual(status.Code.invalid_argument, invalid_key.response_code);
    try std.testing.expect(!connection.closing);

    try feedTestRequest(&connection, .{
        .stream_id = 5,
        .include_preface = false,
        .body = "ping",
        .metadata_entries = &.{
            .{ .key = "trace-bin", .value = "qw==,q6ur" },
            .{ .key = "x-control", .value = "bad\tvalue" },
            .{ .key = "grpc-future", .value = "ignored" },
        },
    });
    const accepted = connection.streams.get(5).?;
    try std.testing.expectEqual(status.Code.ok, accepted.response_code);
    try std.testing.expectEqual(@as(usize, 1), handler.calls);
    try std.testing.expect(handler.metadata_matches);
    try std.testing.expect(!connection.closing);
}
