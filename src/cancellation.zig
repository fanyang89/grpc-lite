const std = @import("std");
fn syncIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Single-use unary cancellation source. Do not copy this owning value.
/// `cancel` is thread-safe and nonblocking with respect to RPC completion.
/// `deinit` releases ownership without cancelling; it must not race access to
/// this value. An accepted call retains the state until transport retirement.
/// The allocator must support cross-thread frees and outlive that retirement.
pub const Cancellation = struct {
    state: *State,

    pub fn init(allocator: std.mem.Allocator) !Cancellation {
        const state = try allocator.create(State);
        state.* = .{ .allocator = allocator };
        return .{ .state = state };
    }

    pub fn cancel(self: *Cancellation) void {
        const state = self.state;
        state.mutex.lockUncancelable(syncIo());
        defer state.mutex.unlock(syncIo());
        if (state.cancelled.swap(true, .acq_rel)) return;
        if (state.notify) |notify| notify(state.context.?);
    }

    pub fn deinit(self: *Cancellation) void {
        self.state.release();
        self.* = undefined;
    }

    /// Transport implementation detail; not an application API.
    pub const State = struct {
        allocator: std.mem.Allocator,
        references: std.atomic.Value(usize) = .init(1),
        mutex: std.Io.Mutex = .init,
        cancelled: std.atomic.Value(bool) = .init(false),
        used: bool = false,
        context: ?*anyopaque = null,
        notify: ?*const fn (*anyopaque) void = null,

        pub fn bind(self: *State, context: *anyopaque, notify: *const fn (*anyopaque) void) !void {
            self.mutex.lockUncancelable(syncIo());
            defer self.mutex.unlock(syncIo());
            if (self.used) return error.CancellationAlreadyUsed;
            self.used = true;
            _ = self.references.fetchAdd(1, .monotonic);
            self.context = context;
            self.notify = notify;
        }

        pub fn detach(self: *State) void {
            self.mutex.lockUncancelable(syncIo());
            defer self.mutex.unlock(syncIo());
            self.context = null;
            self.notify = null;
        }

        pub fn release(self: *State) void {
            if (self.references.fetchSub(1, .acq_rel) == 1) self.allocator.destroy(self);
        }
    };
};
