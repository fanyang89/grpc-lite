//! Structured task handlers over the callback-driven transport server.
const std = @import("std");
const grpc = @import("grpc_lite");
const Message = @import("async_stream.zig").Message;

pub const Options = struct {
    transport: grpc.ServerOptions = .{},
    /// Includes handlers still unwinding after the transport has terminated.
    max_calls: usize = 1024,
};

pub const Handler = struct {
    context: ?*anyopaque = null,
    invoke_fn: *const fn (?*anyopaque, *Call) anyerror!void,

    pub fn bind(comptime T: type, context: *T, comptime function: fn (*T, *Call) anyerror!void) Handler {
        return .{ .context = context, .invoke_fn = struct {
            fn invoke(raw: ?*anyopaque, call: *Call) !void {
                return function(@ptrCast(@alignCast(raw.?)), call);
            }
        }.invoke };
    }
};

pub const UnaryHandler = struct {
    context: ?*anyopaque = null,
    invoke_fn: *const fn (?*anyopaque, std.mem.Allocator, std.Io, *grpc.ServerContext, []const u8) anyerror!grpc.UnaryResponse,

    pub fn bind(
        comptime T: type,
        context: *T,
        comptime function: fn (*T, std.mem.Allocator, std.Io, *grpc.ServerContext, []const u8) anyerror!grpc.UnaryResponse,
    ) UnaryHandler {
        return .{ .context = context, .invoke_fn = struct {
            fn invoke(raw: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, ctx: *grpc.ServerContext, request: []const u8) !grpc.UnaryResponse {
                return function(@ptrCast(@alignCast(raw.?)), allocator, io, ctx, request);
            }
        }.invoke };
    }
};

/// Borrowed for the handler's lifetime. Join child reader/writer tasks before
/// returning. One reader and one writer may run concurrently; finish is a writer
/// operation. Terminal events cancel the handler, including unrelated Io waits.
pub const Call = struct {
    state: *CallState,

    pub fn io(self: *const Call) std.Io {
        return self.state.owner.io;
    }

    /// An owned snapshot, valid until the handler returns. Per-message compression
    /// is available on each received Message rather than in this snapshot.
    pub fn context(self: *const Call) *const grpc.ServerContext {
        return &self.state.context;
    }

    pub fn sendInitialMetadata(self: *Call, entries: []const grpc.MetadataEntry, compression: grpc.Compression) !void {
        const state = self.state;
        try state.enter(.send);
        defer state.leave(.send);
        try self.io().checkCancel();
        state.lock();
        defer state.unlock();
        try state.raw.sendInitialMetadata(entries, compression);
        state.headers_sent = true;
    }

    /// Copies bytes into the transport, suspending when outbound capacity is full.
    pub fn send(self: *Call, payload: []const u8, options: grpc.StreamSendOptions) !void {
        const state = self.state;
        try state.enter(.send);
        defer state.leave(.send);
        while (true) {
            try self.io().checkCancel();
            state.lock();
            state.ensureHeaders() catch |err| {
                state.unlock();
                return err;
            };
            state.writable.reset();
            state.raw.send(payload, options) catch |err| {
                state.unlock();
                if (err != error.WouldBlock) return err;
                try state.writable.wait(self.io());
                continue;
            };
            state.unlock();
            return;
        }
    }

    /// Returns an independently owned message; null means client half-close.
    /// Result allocation failure preserves the buffered message for a retry.
    pub fn receive(self: *Call, allocator: std.mem.Allocator) !?Message {
        const state = self.state;
        try state.enter(.receive);
        defer state.leave(.receive);
        while (true) {
            try self.io().checkCancel();
            state.lock();
            if (state.terminal) {
                state.unlock();
                return error.StreamClosed;
            }
            if (state.message) |message| {
                const payload = allocator.dupe(u8, message.payload) catch |err| {
                    state.unlock();
                    return err;
                };
                state.owner.allocator.free(message.payload);
                state.message = null;
                state.unlock();
                state.raw.resumeReceive() catch |err| {
                    allocator.free(payload);
                    return err;
                };
                return .{ .allocator = allocator, .payload = payload, .compression = message.compression };
            }
            if (state.remote_end) {
                state.unlock();
                return null;
            }
            state.readable.reset();
            state.unlock();
            try state.readable.wait(self.io());
        }
    }

    /// Queues final status after outbound messages. It does not wait for delivery.
    /// Returning from the handler without finishing is an INTERNAL application error.
    pub fn finish(self: *Call, status: grpc.Status, trailers: []const grpc.MetadataEntry) !void {
        const state = self.state;
        try state.enter(.send);
        defer state.leave(.send);
        try self.io().checkCancel();
        state.lock();
        defer state.unlock();
        try state.ensureHeaders();
        try state.raw.finish(status, trailers);
        state.finished = true;
    }

    /// Allocation-free local termination with an INTERNAL_ERROR stream reset.
    /// Terminal notification then cancels and joins the handler task.
    pub fn abort(self: *Call) void {
        self.state.raw.abort();
    }
};

/// Owns transport and handler tasks. The allocator must be thread-safe, and the
/// Io runtime and handler contexts must outlive deinit. Register before start;
/// lifecycle operations require exclusive access and must run outside handlers.
pub const Server = struct {
    impl: *Impl,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !Server {
        if (options.max_calls == 0) return error.InvalidMaxCalls;
        const impl = try allocator.create(Impl);
        errdefer allocator.destroy(impl);
        impl.* = .{
            .allocator = allocator,
            .io = io,
            .raw = try grpc.Server.initIo(allocator, io, options.transport),
            .max_calls = options.max_calls,
            .max_unary_request_size = options.transport.max_request_size,
        };
        return .{ .impl = impl };
    }

    pub fn registerUnary(self: *Server, path: []const u8, handler: UnaryHandler) !void {
        try self.register(path, .{ .unary = handler });
    }

    pub fn registerStream(self: *Server, path: []const u8, handler: Handler) !void {
        try self.register(path, .{ .stream = handler });
    }

    fn register(self: *Server, path: []const u8, handler: MethodHandler) !void {
        const impl = self.impl;
        const method = try impl.allocator.create(Method);
        errdefer impl.allocator.destroy(method);
        method.* = .{ .owner = impl, .handler = handler };
        try impl.methods.append(impl.allocator, method);
        errdefer _ = impl.methods.pop();
        try impl.raw.registerStream(path, .{
            .context = method,
            .initial_metadata_mode = .explicit,
            .on_start = Method.onStart,
            .on_message = Method.onMessage,
            .on_remote_end = Method.onRemoteEnd,
            .on_writable = Method.onWritable,
            .on_terminal = Method.onTerminal,
        });
    }

    pub fn start(self: *Server) !void {
        try self.impl.io.checkCancel();
        try self.impl.raw.start();
    }

    pub fn port(self: *const Server) !u16 {
        return self.impl.raw.port();
    }

    pub fn shutdown(self: *Server) void {
        self.impl.raw.shutdown();
    }

    pub fn shutdownGracefully(self: *Server, timeout_ns: u64) void {
        self.impl.raw.shutdownGracefully(timeout_ns);
    }

    /// Waits uncancelably for transport and joins all handler tasks. Request
    /// shutdown first, or arrange shutdown from another task.
    pub fn wait(self: *Server) void {
        const impl = self.impl;
        impl.raw.wait();
        // No callback can add another task after the transport has joined.
        impl.tasks.cancel(impl.io);
        std.debug.assert(impl.calls.count() == 0);
    }

    pub fn activeCalls(self: *Server) usize {
        self.impl.lock();
        defer self.impl.unlock();
        return self.impl.calls.count();
    }

    pub fn deinit(self: *Server) void {
        self.shutdown();
        self.wait();
        const impl = self.impl;
        impl.raw.deinit();
        for (impl.methods.items) |method| impl.allocator.destroy(method);
        impl.methods.deinit(impl.allocator);
        impl.calls.deinit(impl.allocator);
        impl.allocator.destroy(impl);
        self.* = undefined;
    }
};

const MethodHandler = union(enum) { unary: UnaryHandler, stream: Handler };
const Direction = enum { send, receive };

const Impl = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    raw: grpc.Server,
    max_calls: usize,
    max_unary_request_size: usize,
    mutex: std.Io.Mutex = .init,
    tasks: std.Io.Group = .init,
    calls: std.AutoHashMapUnmanaged(grpc.ServerCallId, *CallState) = .empty,
    methods: std.ArrayList(*Method) = .empty,

    fn lock(self: *Impl) void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    }

    fn unlock(self: *Impl) void {
        self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    }
};

const Method = struct {
    owner: *Impl,
    handler: MethodHandler,

    fn accept(self: *Method, raw: grpc.ServerStream, context: *grpc.ServerContext) !void {
        const owner = self.owner;
        owner.lock();
        defer owner.unlock();
        if (owner.calls.count() >= owner.max_calls) return error.CallLimitExceeded;
        const state = try owner.allocator.create(CallState);
        errdefer owner.allocator.destroy(state);
        state.* = .{
            .owner = owner,
            .handler = self.handler,
            .raw = try raw.retain(),
            .context = grpc.ServerContext.init(owner.allocator),
        };
        errdefer state.raw.deinit();
        errdefer state.context.deinit();
        state.context.deadline = context.deadline;
        state.context.request_compression = context.request_compression;
        for (context.request_metadata.items()) |entry| try state.context.request_metadata.append(entry.key, entry.value);
        try owner.calls.put(owner.allocator, raw.id(), state);
        errdefer _ = owner.calls.remove(raw.id());
        // concurrent must enqueue work, never run a suspending handler inline on
        // the transport thread (unlike Io.async's permitted inline fallback).
        try owner.tasks.concurrent(owner.io, CallState.supervise, .{state});
    }

    fn onStart(context: ?*anyopaque, raw: grpc.ServerStream, ctx: *grpc.ServerContext) !void {
        const self: *Method = @ptrCast(@alignCast(context.?));
        self.accept(raw, ctx) catch {
            var call = try raw.retain();
            defer call.deinit();
            call.sendInitialMetadata(&.{}, .identity) catch {
                call.abort();
                return;
            };
            call.finish(.init(.resource_exhausted, "task handler capacity unavailable"), &.{}) catch call.abort();
        };
    }

    fn onMessage(context: ?*anyopaque, raw: grpc.ServerStream, _: *grpc.ServerContext, payload: []const u8, compression: grpc.Compression) !grpc.StreamReceiveAction {
        const self: *Method = @ptrCast(@alignCast(context.?));
        const owner = self.owner;
        owner.lock();
        defer owner.unlock();
        const state = owner.calls.get(raw.id()) orelse return .pause;
        state.lock();
        defer state.unlock();
        std.debug.assert(state.message == null);
        state.message = .{ .allocator = owner.allocator, .payload = try owner.allocator.dupe(u8, payload), .compression = compression };
        state.readable.set(owner.io);
        return .pause;
    }

    fn onRemoteEnd(context: ?*anyopaque, raw: grpc.ServerStream, _: *grpc.ServerContext) !void {
        const self: *Method = @ptrCast(@alignCast(context.?));
        self.owner.lock();
        defer self.owner.unlock();
        const state = self.owner.calls.get(raw.id()) orelse return;
        state.lock();
        defer state.unlock();
        state.remote_end = true;
        state.readable.set(self.owner.io);
    }

    fn onWritable(context: ?*anyopaque, raw: grpc.ServerStream, _: *grpc.ServerContext) void {
        const self: *Method = @ptrCast(@alignCast(context.?));
        self.owner.lock();
        defer self.owner.unlock();
        const state = self.owner.calls.get(raw.id()) orelse return;
        state.lock();
        defer state.unlock();
        state.writable.set(self.owner.io);
    }

    fn onTerminal(context: ?*anyopaque, id: grpc.ServerCallId, _: grpc.ServerTerminalReason) void {
        const self: *Method = @ptrCast(@alignCast(context.?));
        self.owner.lock();
        defer self.owner.unlock();
        const state = self.owner.calls.get(id) orelse return;
        state.lock();
        defer state.unlock();
        state.terminal = true;
        state.readable.set(self.owner.io);
        state.writable.set(self.owner.io);
        state.completed.set(self.owner.io);
    }
};

const CallState = struct {
    owner: *Impl,
    handler: MethodHandler,
    raw: grpc.ServerCall,
    context: grpc.ServerContext,
    mutex: std.Io.Mutex = .init,
    readable: std.Io.Event = .unset,
    writable: std.Io.Event = .unset,
    completed: std.Io.Event = .unset,
    message: ?Message = null,
    sending: bool = false,
    receiving: bool = false,
    headers_sent: bool = false,
    remote_end: bool = false,
    finished: bool = false,
    terminal: bool = false,

    fn lock(self: *CallState) void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    }

    fn unlock(self: *CallState) void {
        self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    }

    fn enter(self: *CallState, direction: Direction) !void {
        self.lock();
        defer self.unlock();
        const active = if (direction == .send) &self.sending else &self.receiving;
        if (active.*) return if (direction == .send) error.ConcurrentSend else error.ConcurrentReceive;
        active.* = true;
    }

    fn leave(self: *CallState, direction: Direction) void {
        self.lock();
        defer self.unlock();
        if (direction == .send) self.sending = false else self.receiving = false;
    }

    fn ensureHeaders(self: *CallState) !void {
        if (self.headers_sent) return;
        try self.raw.sendInitialMetadata(&.{}, .identity);
        self.headers_sent = true;
    }

    fn destroy(self: *CallState) void {
        const owner = self.owner;
        owner.lock();
        // Fences the terminal callback, which is the last callback for this call.
        std.debug.assert(owner.calls.remove(self.raw.id()));
        owner.unlock();
        if (self.message) |*message| message.deinit();
        self.context.deinit();
        self.raw.deinit();
        owner.allocator.destroy(self);
    }

    fn supervise(self: *CallState) void {
        defer self.destroy();
        const io = self.owner.io;
        var handler = io.concurrent(CallState.run, .{self}) catch {
            self.raw.abort();
            self.completed.waitUncancelable(io);
            return;
        };
        // Terminal notification interrupts arbitrary handler Io waits, not only
        // send/receive. Joining also fences the handler's own deferred cleanup.
        self.completed.waitUncancelable(io);
        handler.cancel(io);
    }

    fn run(self: *CallState) void {
        var call: Call = .{ .state = self };
        self.invoke(&call) catch |err| {
            self.fail(if (err == error.OutOfMemory) .resource_exhausted else if (err == error.Canceled) .cancelled else .internal);
            return;
        };
        self.lock();
        const finished = self.finished or self.terminal;
        self.unlock();
        if (!finished) self.fail(.internal);
    }

    fn fail(self: *CallState, code: grpc.StatusCode) void {
        self.lock();
        defer self.unlock();
        if (self.finished or self.terminal) return;
        self.ensureHeaders() catch {
            self.raw.abort();
            return;
        };
        self.raw.finish(.init(code, "task handler failed"), &.{}) catch {
            self.raw.abort();
            return;
        };
        self.finished = true;
    }

    fn invoke(self: *CallState, call: *Call) !void {
        try self.owner.io.checkCancel();
        switch (self.handler) {
            .stream => |handler| try handler.invoke_fn(handler.context, call),
            .unary => |handler| {
                const allocator = self.owner.allocator;
                var request = (try call.receive(allocator)) orelse {
                    try call.finish(.init(.invalid_argument, "expected one request"), &.{});
                    return;
                };
                defer request.deinit();
                if (request.payload.len > self.owner.max_unary_request_size) {
                    try call.finish(.init(.resource_exhausted, "request message too large"), &.{});
                    return;
                }
                if (try call.receive(allocator)) |value| {
                    var extra = value;
                    extra.deinit();
                    try call.finish(.init(.invalid_argument, "expected one request"), &.{});
                    return;
                }
                self.context.request_compression = request.compression;
                var response = try handler.invoke_fn(handler.context, allocator, self.owner.io, &self.context, request.payload);
                defer response.deinit();
                try call.sendInitialMetadata(self.context.initial_metadata.items(), self.context.response_compression);
                if (response.status.isOk()) try call.send(response.payload, .{ .compression = self.context.response_compression });
                try call.finish(response.status, self.context.trailing_metadata.items());
            },
        }
    }
};
