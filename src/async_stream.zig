//! A bounded, task-friendly bridge over the raw callback-driven client stream.
const std = @import("std");
const grpc = @import("grpc_lite");

pub const Message = struct {
    allocator: std.mem.Allocator,
    payload: []u8,
    compression: grpc.Compression,

    pub fn deinit(self: *Message) void {
        self.allocator.free(self.payload);
        self.* = undefined;
    }
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    status: grpc.Status,
    initial_metadata: grpc.Metadata,
    trailing_metadata: grpc.Metadata,

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.status.message);
        self.initial_metadata.deinit();
        self.trailing_metadata.deinit();
        self.* = undefined;
    }
};

/// One send (or closeSend) and one receive may run concurrently. Finish may wait
/// alongside them. Join all tasks before deinit. The runtime and stream allocator
/// must outlive this object; it may outlive its Client.
pub const Stream = struct {
    handle: grpc.ClientStream,
    state: *State,

    /// The allocator is used on both task and transport threads, serialized per
    /// stream. It must be thread-safe if shared with other streams or callers.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, channel: *grpc.Channel, method: []const u8, options: grpc.StreamOptions) !Stream {
        try io.checkCancel();
        const state = try allocator.create(State);
        state.* = .{
            .allocator = allocator,
            .io = io,
            .initial_metadata = grpc.Metadata.init(allocator),
            .trailing_metadata = grpc.Metadata.init(allocator),
        };
        errdefer state.destroy();
        const handle = try channel.openStream(method, options, .{
            .context = state,
            .on_headers = State.onHeaders,
            .on_message = State.onMessage,
            .on_writable = State.onWritable,
            .on_terminal = State.onTerminal,
        });
        return .{ .handle = handle, .state = state };
    }

    /// Waits for outbound capacity. Input bytes are borrowed until return.
    pub fn send(self: *Stream, payload: []const u8, options: grpc.StreamSendOptions) !void {
        const state = self.state;
        try state.enter(.send);
        defer state.leave(.send);
        while (true) {
            try self.checkCancel();
            state.lock();
            if (state.local_error) |err| {
                state.unlock();
                return err;
            }
            // Reset before trying send, under the callback's lock, so a writable
            // notification between WouldBlock and wait cannot be lost.
            state.writable.reset();
            self.handle.send(payload, options) catch |err| {
                state.unlock();
                if (err != error.WouldBlock) return err;
                try self.wait(&state.writable);
                continue;
            };
            state.unlock();
            return;
        }
    }

    /// Ends only the local send direction, after already queued messages drain.
    pub fn closeSend(self: *Stream) !void {
        try self.state.enter(.send);
        defer self.state.leave(.send);
        try self.checkCancel();
        self.state.lock();
        defer self.state.unlock();
        if (self.state.local_error) |err| return err;
        try self.handle.closeSend();
    }

    /// Returns an owned message, or null for successful end of stream. A non-OK
    /// terminal status returns RpcFailed; finish() provides its code and metadata.
    /// Allocation failure leaves the buffered message available for another call.
    pub fn receive(self: *Stream, allocator: std.mem.Allocator) !?Message {
        const state = self.state;
        try state.enter(.receive);
        defer state.leave(.receive);
        while (true) {
            try self.checkCancel();
            state.lock();
            if (state.local_error) |err| {
                state.unlock();
                return err;
            }
            if (state.message) |message| {
                const payload = allocator.dupe(u8, message.payload) catch |err| {
                    state.unlock();
                    return err;
                };
                state.allocator.free(message.payload);
                state.message = null;
                state.unlock();
                // A terminal callback can race consuming the last buffered message.
                self.handle.resumeReceive() catch |err| {
                    if (err != error.StreamClosed) {
                        allocator.free(payload);
                        self.cancel();
                        return err;
                    }
                };
                return .{ .allocator = allocator, .payload = payload, .compression = message.compression };
            }
            if (state.terminal) {
                const ok = state.status.isOk();
                state.unlock();
                return if (ok) null else error.RpcFailed;
            }
            state.readable.reset();
            state.unlock();
            try self.wait(&state.readable);
        }
    }

    /// Waits for final status. Close the send direction and drain responses (or
    /// run a receiving task) first: finish does not discard messages to bypass
    /// backpressure. The returned status and metadata are independently owned.
    pub fn finish(self: *Stream, allocator: std.mem.Allocator) !Result {
        const state = self.state;
        try self.checkCancel();
        try self.wait(&state.completed);
        state.lock();
        defer state.unlock();
        if (state.local_error) |err| return err;
        const message = try allocator.dupe(u8, state.status.message);
        errdefer allocator.free(message);
        var initial = try copyMetadata(allocator, &state.initial_metadata);
        errdefer initial.deinit();
        return .{
            .allocator = allocator,
            .status = .init(state.status.code, message),
            .initial_metadata = initial,
            .trailing_metadata = try copyMetadata(allocator, &state.trailing_metadata),
        };
    }

    /// Requests cancellation of both directions; finish reports the final status.
    pub fn cancel(self: *Stream) void {
        self.handle.cancel();
    }

    fn checkCancel(self: *Stream) std.Io.Cancelable!void {
        self.state.io.checkCancel() catch {
            self.cancelAndWait();
            return error.Canceled;
        };
    }

    fn wait(self: *Stream, event: *std.Io.Event) std.Io.Cancelable!void {
        event.wait(self.state.io) catch {
            self.cancelAndWait();
            return error.Canceled;
        };
    }

    fn cancelAndWait(self: *Stream) void {
        self.handle.cancel();
        self.state.completed.waitUncancelable(self.state.io);
        // Keep the event and runtime alive until the signaling callback returns.
        self.state.lock();
        self.state.unlock();
    }

    /// Requires exclusive access. Cancels unfinished work and suspends until the
    /// terminal callback, then fences all callbacks before freeing the bridge.
    pub fn deinit(self: *Stream) void {
        self.cancelAndWait();
        self.handle.deinit();
        self.state.destroy();
        self.* = undefined;
    }
};

const BufferedMessage = struct { payload: []u8, compression: grpc.Compression };
const Direction = enum { send, receive };

const State = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    sending: bool = false,
    receiving: bool = false,
    readable: std.Io.Event = .unset,
    writable: std.Io.Event = .unset,
    completed: std.Io.Event = .unset,
    message: ?BufferedMessage = null,
    initial_metadata: grpc.Metadata,
    trailing_metadata: grpc.Metadata,
    status: grpc.Status = .ok,
    status_message: ?[]u8 = null,
    terminal: bool = false,
    local_error: ?anyerror = null,

    fn lock(self: *State) void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    }

    fn unlock(self: *State) void {
        self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    }

    fn enter(self: *State, direction: Direction) !void {
        self.lock();
        defer self.unlock();
        const active = if (direction == .send) &self.sending else &self.receiving;
        if (active.*) return if (direction == .send) error.ConcurrentSend else error.ConcurrentReceive;
        active.* = true;
    }

    fn leave(self: *State, direction: Direction) void {
        self.lock();
        defer self.unlock();
        if (direction == .send) self.sending = false else self.receiving = false;
    }

    fn destroy(self: *State) void {
        if (self.message) |message| self.allocator.free(message.payload);
        if (self.status_message) |message| self.allocator.free(message);
        self.initial_metadata.deinit();
        self.trailing_metadata.deinit();
        self.allocator.destroy(self);
    }

    fn fail(self: *State, raw: grpc.ClientStream, err: anyerror) void {
        if (self.local_error == null) self.local_error = err;
        raw.cancel();
        self.readable.set(self.io);
        self.writable.set(self.io);
    }

    fn onHeaders(context: ?*anyopaque, raw: grpc.ClientStream, headers: *const grpc.Metadata) void {
        const self: *State = @ptrCast(@alignCast(context.?));
        self.lock();
        defer self.unlock();
        for (headers.items()) |entry| self.initial_metadata.append(entry.key, entry.value) catch |err| {
            self.fail(raw, err);
            return;
        };
    }

    fn onMessage(context: ?*anyopaque, raw: grpc.ClientStream, payload: []const u8, compression: grpc.Compression) grpc.StreamReceiveAction {
        const self: *State = @ptrCast(@alignCast(context.?));
        self.lock();
        defer self.unlock();
        std.debug.assert(self.message == null);
        const copy = self.allocator.dupe(u8, payload) catch |err| {
            self.fail(raw, err);
            return .pause;
        };
        self.message = .{ .payload = copy, .compression = compression };
        self.readable.set(self.io);
        // Exactly one message is retained outside transport buffers. Only the
        // reader consuming that message requests another callback.
        return .pause;
    }

    fn onWritable(context: ?*anyopaque, _: grpc.ClientStream) void {
        const self: *State = @ptrCast(@alignCast(context.?));
        self.lock();
        defer self.unlock();
        self.writable.set(self.io);
    }

    fn onTerminal(context: ?*anyopaque, _: grpc.ClientStream, status: grpc.Status, trailers: *const grpc.Metadata) void {
        const self: *State = @ptrCast(@alignCast(context.?));
        self.lock();
        defer self.unlock();
        self.status_message = self.allocator.dupe(u8, status.message) catch |err| failed: {
            if (self.local_error == null) self.local_error = err;
            break :failed null;
        };
        self.status = .init(status.code, self.status_message orelse "");
        for (trailers.items()) |entry| self.trailing_metadata.append(entry.key, entry.value) catch |err| {
            if (self.local_error == null) self.local_error = err;
            break;
        };
        self.terminal = true;
        self.readable.set(self.io);
        self.writable.set(self.io);
        self.completed.set(self.io);
    }
};

fn copyMetadata(allocator: std.mem.Allocator, source: *const grpc.Metadata) !grpc.Metadata {
    var result = grpc.Metadata.init(allocator);
    errdefer result.deinit();
    for (source.items()) |entry| try result.append(entry.key, entry.value);
    return result;
}
