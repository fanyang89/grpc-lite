//! Staggered TCP establishment. No application bytes are sent before selection.
const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const fast_clock = @import("fast_clock.zig");

pub const Result = union(enum) {
    connected: struct { tcp: xev.TCP, address: std.Io.net.IpAddress },
    failed,
    cancelled,
};

pub const Race = struct {
    allocator: std.mem.Allocator,
    loop: *xev.Loop,
    attempts: []Attempt,
    timer: xev.Timer,
    timer_completion: xev.Completion = .{},
    timer_cancel: xev.Completion = .{},
    timer_active: bool = false,
    timer_cancelling: bool = false,
    next: usize = 0,
    pending: usize = 0,
    winner: ?xev.TCP = null,
    winner_address: std.Io.net.IpAddress = undefined,
    stopping: bool = false,
    cancelled: bool = false,
    context: ?*anyopaque,
    callback: *const fn (?*anyopaque, Result) void,
    on_attempt: *const fn (?*anyopaque) void,
    delay_ms: u64 = 250,
    next_launch_ns: u64 = 0,
    stall_first: if (builtin.is_test) bool else void = if (builtin.is_test) false else {},

    const Attempt = struct {
        owner: *Race,
        address: std.Io.net.IpAddress,
        tcp: ?xev.TCP = null,
        completion: xev.Completion = .{},
        cancel_completion: xev.Completion = .{},
        active: bool = false,
        cancelling: bool = false,
    };

    pub fn create(allocator: std.mem.Allocator, loop: *xev.Loop, addresses: []const std.Io.net.IpAddress, context: ?*anyopaque, callback: *const fn (?*anyopaque, Result) void, on_attempt: *const fn (?*anyopaque) void) !*Race {
        const self = try allocator.create(Race);
        errdefer allocator.destroy(self);
        const attempts = try allocator.alloc(Attempt, addresses.len);
        errdefer allocator.free(attempts);
        self.* = .{ .allocator = allocator, .loop = loop, .attempts = attempts, .timer = try xev.Timer.init(), .context = context, .callback = callback, .on_attempt = on_attempt };
        // Preserve order within each family, including the resolver's first choice.
        var cursors = [_]usize{ 0, 0 };
        var family: usize = if (addresses.len != 0 and addresses[0] == .ip6) 1 else 0;
        for (attempts) |*attempt| {
            var index = findNext(addresses, &cursors, family);
            if (index == null) {
                family = 1 - family;
                index = findNext(addresses, &cursors, family);
            }
            attempt.* = .{ .owner = self, .address = addresses[index.?] };
            family = 1 - family;
        }
        return self;
    }

    fn findNext(addresses: []const std.Io.net.IpAddress, cursors: *[2]usize, family: usize) ?usize {
        while (cursors[family] < addresses.len) {
            const index = cursors[family];
            cursors[family] += 1;
            if ((addresses[index] == .ip6) == (family == 1)) return index;
        }
        return null;
    }

    /// May complete synchronously when no sockets can be created.
    pub fn start(self: *Race) void {
        self.launch();
        self.finishIfReady();
    }

    fn launch(self: *Race) void {
        while (!self.stopping and self.next < self.attempts.len) {
            const attempt = &self.attempts[self.next];
            self.next += 1;
            const tcp = xev.TCP.init(attempt.address) catch continue;
            attempt.tcp = tcp;
            attempt.active = true;
            self.pending += 1;
            self.next_launch_ns = nowNs() +| (self.delay_ms *| std.time.ns_per_ms);
            self.on_attempt(self.context);
            if (comptime builtin.is_test) {
                if (self.stall_first and self.next == 1) {
                    self.timer.run(self.loop, &attempt.completion, 60_000, Attempt, attempt, onStalled);
                    break;
                }
            }
            tcp.connect(self.loop, &attempt.completion, attempt.address, Attempt, attempt, onConnect);
            break;
        }
        if (!self.stopping and self.next < self.attempts.len and !self.timer_active and !self.timer_cancelling) {
            self.timer_active = true;
            self.timer.run(self.loop, &self.timer_completion, self.delay_ms, Race, self, onTimer);
        }
    }

    fn onStalled(attempt: ?*Attempt, loop: *xev.Loop, completion: *xev.Completion, _: xev.Timer.RunError!void) xev.CallbackAction {
        return onConnect(attempt, loop, completion, attempt.?.tcp.?, error.Canceled);
    }

    fn onConnect(attempt_: ?*Attempt, _: *xev.Loop, _: *xev.Completion, _: xev.TCP, result: xev.ConnectError!void) xev.CallbackAction {
        const attempt = attempt_.?;
        const self = attempt.owner;
        attempt.active = false;
        self.pending -= 1;
        if (result) |_| {
            if (!self.stopping) {
                self.winner = attempt.tcp;
                self.winner_address = attempt.address;
                attempt.tcp = null;
                self.stop();
            }
        } else |_| {}
        closeAttempt(attempt);
        if (!self.stopping) self.launch();
        self.finishIfReady();
        return .disarm;
    }

    fn onTimer(self_: ?*Race, _: *xev.Loop, _: *xev.Completion, _: xev.Timer.RunError!void) xev.CallbackAction {
        const self = self_.?;
        self.timer_active = false;
        if (!self.stopping) {
            const remaining = self.next_launch_ns -| nowNs();
            if (remaining != 0) {
                self.timer_active = true;
                self.timer.run(self.loop, &self.timer_completion, std.math.divCeil(u64, remaining, std.time.ns_per_ms) catch unreachable, Race, self, onTimer);
            } else self.launch();
        }
        self.finishIfReady();
        return .disarm;
    }

    pub fn cancel(self: *Race) void {
        self.cancelled = true;
        self.stop();
        self.finishIfReady();
    }

    fn stop(self: *Race) void {
        self.stopping = true;
        if (self.timer_active and !self.timer_cancelling) {
            self.timer_cancelling = true;
            self.pending += 1;
            self.loop.cancel(&self.timer_completion, &self.timer_cancel, Race, self, onTimerCancelled);
        }
        for (self.attempts) |*attempt| {
            if (attempt.active and !attempt.cancelling) {
                attempt.cancelling = true;
                self.pending += 1;
                self.loop.cancel(&attempt.completion, &attempt.cancel_completion, Attempt, attempt, onCancelled);
            }
        }
    }

    fn onTimerCancelled(self_: ?*Race, _: *xev.Loop, _: *xev.Completion, _: xev.CancelError!void) xev.CallbackAction {
        const self = self_.?;
        self.timer_cancelling = false;
        self.pending -= 1;
        self.finishIfReady();
        return .disarm;
    }

    fn onCancelled(attempt_: ?*Attempt, _: *xev.Loop, _: *xev.Completion, _: xev.CancelError!void) xev.CallbackAction {
        const attempt = attempt_.?;
        const self = attempt.owner;
        attempt.cancelling = false;
        self.pending -= 1;
        closeAttempt(attempt);
        self.finishIfReady();
        return .disarm;
    }

    fn closeAttempt(attempt: *Attempt) void {
        if (attempt.active or attempt.cancelling) return;
        if (attempt.tcp) |tcp| _ = std.c.close(tcp.fd);
        attempt.tcp = null;
    }

    fn finishIfReady(self: *Race) void {
        if (!self.stopping and self.next == self.attempts.len and self.pending == 0) self.stop();
        if (self.pending != 0 or self.timer_active or self.timer_cancelling) return;
        if (!self.stopping and self.next < self.attempts.len) return;
        const result: Result = if (self.cancelled) .cancelled else if (self.winner) |tcp| .{
            .connected = .{ .tcp = tcp, .address = self.winner_address },
        } else .failed;
        if (self.cancelled) {
            if (self.winner) |tcp| _ = std.c.close(tcp.fd);
        }
        const callback = self.callback;
        const context = self.context;
        self.timer.deinit();
        self.allocator.free(self.attempts);
        self.allocator.destroy(self);
        callback(context, result);
    }
};

fn nowNs() u64 {
    return fast_clock.now(std.Io.Threaded.global_single_threaded.io());
}

test "staggered connector escapes a stalled family and drains cancellation" {
    const server = @import("server.zig");
    const Capture = struct {
        result: ?Result = null,
        calls: usize = 0,
        attempts: usize = 0,
        fn done(context: ?*anyopaque, result: Result) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            self.result = result;
        }
        fn started(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.attempts += 1;
        }
    };
    for (0..4) |scenario| {
        var listener = try server.Server.init(std.testing.allocator, .{
            .host = if (scenario == 1) "::1" else "127.0.0.1",
        });
        defer listener.deinit();
        try listener.start();
        var loop = try xev.Loop.init(.{});
        defer loop.deinit();
        var capture: Capture = .{};
        const addresses = [_]std.Io.net.IpAddress{
            if (scenario == 1) try .parseIp4("127.0.0.1", 0) else try .parseIp6("::1", 0),
            if (scenario == 1) try .parseIp6("::1", try listener.port()) else try .parseIp4("127.0.0.1", if (scenario == 3) 0 else try listener.port()),
        };
        const race = try Race.create(std.testing.allocator, &loop, &addresses, &capture, Capture.done, Capture.started);
        race.delay_ms = 1;
        race.stall_first = scenario != 3;
        const started_at = nowNs();
        race.start();
        if (scenario == 2) race.cancel();
        try loop.run(.until_done);
        // Success must come from the stagger, not the injected 60-second expiry.
        try std.testing.expect(nowNs() - started_at < 10 * std.time.ns_per_s);
        try std.testing.expectEqual(@as(usize, 1), capture.calls);
        const result = capture.result.?;
        if (result == .connected) _ = std.c.close(result.connected.tcp.fd);
        switch (scenario) {
            2 => try std.testing.expect(result == .cancelled),
            3 => try std.testing.expect(result == .failed),
            else => {
                try std.testing.expect(result == .connected);
                try std.testing.expectEqual(@as(usize, 2), capture.attempts);
            },
        }
    }
}

test "address racing interleaves families while preserving family order" {
    const Capture = struct {
        fn done(_: ?*anyopaque, result: Result) void {
            std.debug.assert(result == .cancelled);
        }
        fn started(_: ?*anyopaque) void {}
    };
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();
    const addresses = [_]std.Io.net.IpAddress{
        try .parseIp6("::1", 1),       try .parseIp6("::1", 2),       try .parseIp4("127.0.0.1", 3),
        try .parseIp4("127.0.0.1", 4), try .parseIp4("127.0.0.1", 5),
    };
    const race = try Race.create(std.testing.allocator, &loop, &addresses, null, Capture.done, Capture.started);
    for (race.attempts, [_]u16{ 1, 3, 2, 4, 5 }) |attempt, port| {
        try std.testing.expectEqual(port, attempt.address.getPort());
    }
    race.cancel();
}

test "connector allocation failures release partial state" {
    const Fixture = struct {
        fn done(_: ?*anyopaque, result: Result) void {
            std.debug.assert(result == .cancelled);
        }
        fn started(_: ?*anyopaque) void {}
        fn check(allocator: std.mem.Allocator) !void {
            var loop = try xev.Loop.init(.{});
            defer loop.deinit();
            const addresses = [_]std.Io.net.IpAddress{try .parseIp6("::1", 1)};
            const race = try Race.create(allocator, &loop, &addresses, null, done, started);
            race.cancel();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Fixture.check, .{});
}

test "simultaneous viable candidates deliver one owned winner" {
    const server = @import("server.zig");
    const Capture = struct {
        calls: usize = 0,
        winner: ?xev.TCP = null,
        fn done(context: ?*anyopaque, result: Result) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            if (result == .connected) self.winner = result.connected.tcp;
        }
        fn started(_: ?*anyopaque) void {}
    };
    var ipv4 = try server.Server.init(std.testing.allocator, .{ .host = "127.0.0.1" });
    defer ipv4.deinit();
    var ipv6 = try server.Server.init(std.testing.allocator, .{ .host = "::1" });
    defer ipv6.deinit();
    try ipv4.start();
    try ipv6.start();
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();
    const addresses = [_]std.Io.net.IpAddress{
        try .parseIp6("::1", try ipv6.port()), try .parseIp4("127.0.0.1", try ipv4.port()),
    };
    var capture: Capture = .{};
    const race = try Race.create(std.testing.allocator, &loop, &addresses, &capture, Capture.done, Capture.started);
    // Submit both before running the loop, exercising queued success/cancel races.
    race.launch();
    race.launch();
    try loop.run(.until_done);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    const winner = capture.winner orelse return error.NoWinner;
    _ = std.c.close(winner.fd);
}
