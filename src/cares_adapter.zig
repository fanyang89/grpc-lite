const std = @import("std");
const c = @import("cares_c.zig").api;
const xev = @import("xev");

pub const ResolveResult = union(enum) {
    addresses: []std.Io.net.IpAddress,
    failed,
    cancelled,
};

pub const ResolveCallback = *const fn (?*anyopaque, ResolveResult) void;

pub const Adapter = struct {
    allocator: std.mem.Allocator,
    loop: *xev.Loop,
    channel: ?*c.ares_channel_t = null,
    watches: std.AutoHashMapUnmanaged(c.ares_socket_t, *Watch) = .empty,
    timer: xev.Timer,
    timer_completion: xev.Completion = .{},
    timer_reset_completion: xev.Completion = .{},
    timer_armed: bool = false,
    query_active: bool = false,
    destroying: bool = false,
    integration_failed: bool = false,
    force_failure: bool = false,
    port: u16 = 0,
    callback_context: ?*anyopaque = null,
    callback: ?ResolveCallback = null,

    const Watch = struct {
        adapter: *Adapter,
        fd: c.ares_socket_t,
        want_read: bool = false,
        want_write: bool = false,
        read_active: bool = false,
        write_active: bool = false,
        read_cancel_active: bool = false,
        write_cancel_active: bool = false,
        callback_active: bool = false,
        read_completion: xev.Completion = .{},
        write_completion: xev.Completion = .{},
        read_cancel_completion: xev.Completion = .{},
        write_cancel_completion: xev.Completion = .{},
    };

    pub fn init(self: *Adapter, allocator: std.mem.Allocator, loop: *xev.Loop) !void {
        var timer = try xev.Timer.init();
        errdefer timer.deinit();
        self.* = .{
            .allocator = allocator,
            .loop = loop,
            .timer = timer,
        };
        var options: c.ares_options = std.mem.zeroes(c.ares_options);
        options.sock_state_cb = onSocketState;
        options.sock_state_cb_data = self;
        options.qcache_max_ttl = 300;
        const mask = c.ARES_OPT_SOCK_STATE_CB | c.ARES_OPT_QUERY_CACHE;
        if (c.ares_init_options(&self.channel, &options, mask) != c.ARES_SUCCESS) {
            return error.ResolverInitializationFailed;
        }
    }

    pub fn resolve(
        self: *Adapter,
        host: [:0]const u8,
        port: u16,
        context: ?*anyopaque,
        callback: ResolveCallback,
    ) !void {
        if (self.destroying or self.channel == null) return error.ResolverClosed;
        if (self.query_active) return error.ResolveInProgress;
        self.port = port;
        self.callback_context = context;
        self.callback = callback;
        self.query_active = true;

        var hints: c.ares_addrinfo_hints = std.mem.zeroes(c.ares_addrinfo_hints);
        hints.ai_flags = c.ARES_AI_NOSORT | c.ARES_AI_NUMERICSERV;
        hints.ai_family = c.AF_UNSPEC;
        hints.ai_socktype = c.SOCK_STREAM;
        hints.ai_protocol = c.IPPROTO_TCP;
        var service_buffer: [6]u8 = undefined;
        const service = try std.fmt.bufPrintSentinel(&service_buffer, "{d}", .{port}, 0);
        c.ares_getaddrinfo(self.channel, host.ptr, service.ptr, &hints, onResolved, self);
        self.rescheduleTimeout();
    }

    pub fn cancel(self: *Adapter) void {
        if (!self.query_active) return;
        c.ares_cancel(self.channel);
        self.rescheduleTimeout();
    }

    pub fn shutdown(self: *Adapter) void {
        if (self.destroying) return;
        self.destroying = true;
        if (self.query_active) c.ares_cancel(self.channel);
        c.ares_destroy(self.channel);
        self.channel = null;
        self.stopTimer();
    }

    /// The owning xev loop must be deinitialized before this function.
    pub fn deinitAfterLoop(self: *Adapter) void {
        std.debug.assert(self.destroying);
        var iterator = self.watches.valueIterator();
        while (iterator.next()) |watch| self.allocator.destroy(watch.*);
        self.watches.deinit(self.allocator);
        self.timer.deinit();
    }

    fn rescheduleTimeout(self: *Adapter) void {
        if (self.destroying) return;
        if (self.integration_failed) {
            self.scheduleTimer(0);
            return;
        }
        var timeout: c.timeval = undefined;
        const value = c.ares_timeout(self.channel, null, &timeout);
        if (value == null) {
            self.stopTimer();
            return;
        }
        const seconds: u64 = @intCast(@max(timeout.tv_sec, 0));
        const microseconds: u64 = @intCast(@max(timeout.tv_usec, 0));
        const milliseconds = @max(
            @as(u64, 1),
            seconds * std.time.ms_per_s +
                (std.math.divCeil(u64, microseconds, std.time.us_per_ms) catch 1),
        );
        self.scheduleTimer(milliseconds);
    }

    fn scheduleTimer(self: *Adapter, milliseconds: u64) void {
        if (!self.timer_armed) {
            self.timer_armed = true;
            self.timer.run(self.loop, &self.timer_completion, milliseconds, Adapter, self, onTimer);
        } else {
            self.timer.reset(
                self.loop,
                &self.timer_completion,
                &self.timer_reset_completion,
                milliseconds,
                Adapter,
                self,
                onTimer,
            );
        }
    }

    fn stopTimer(self: *Adapter) void {
        if (!self.timer_armed) return;
        self.timer.reset(
            self.loop,
            &self.timer_completion,
            &self.timer_reset_completion,
            0,
            Adapter,
            self,
            onTimer,
        );
    }

    fn processFd(self: *Adapter, fd: c.ares_socket_t, event: c_uint) void {
        if (self.destroying) return;
        const events = c.ares_fd_events_t{ .fd = fd, .events = event };
        _ = c.ares_process_fds(self.channel, &events, 1, c.ARES_PROCESS_FLAG_NONE);
        self.rescheduleTimeout();
    }

    fn updateWatch(watch: *Watch) void {
        const adapter = watch.adapter;
        if (watch.want_read and !adapter.destroying and !watch.read_active and !watch.read_cancel_active) {
            watch.read_active = true;
            watch.read_completion = .{
                .op = .{ .poll = .{ .fd = watch.fd, .events = std.posix.POLL.IN } },
                .userdata = watch,
                .callback = onReadReady,
            };
            adapter.loop.add(&watch.read_completion);
        } else if (!watch.want_read and watch.read_active and !watch.read_cancel_active) {
            watch.read_cancel_active = true;
            adapter.loop.cancel(
                &watch.read_completion,
                &watch.read_cancel_completion,
                Watch,
                watch,
                onReadCancelled,
            );
        }
        if (watch.want_write and !adapter.destroying and !watch.write_active and !watch.write_cancel_active) {
            watch.write_active = true;
            watch.write_completion = .{
                .op = .{ .poll = .{ .fd = watch.fd, .events = std.posix.POLL.OUT } },
                .userdata = watch,
                .callback = onWriteReady,
            };
            adapter.loop.add(&watch.write_completion);
        } else if (!watch.want_write and watch.write_active and !watch.write_cancel_active) {
            watch.write_cancel_active = true;
            adapter.loop.cancel(
                &watch.write_completion,
                &watch.write_cancel_completion,
                Watch,
                watch,
                onWriteCancelled,
            );
        }
        maybeRetireWatch(watch);
    }

    fn maybeRetireWatch(watch: *Watch) void {
        if (watch.want_read or watch.want_write or
            watch.read_active or watch.write_active or
            watch.read_cancel_active or watch.write_cancel_active or
            watch.callback_active) return;
        const adapter = watch.adapter;
        const removed = adapter.watches.fetchRemove(watch.fd) orelse return;
        std.debug.assert(removed.value == watch);
        adapter.allocator.destroy(watch);
    }

    fn failIntegration(self: *Adapter) void {
        self.integration_failed = true;
        self.rescheduleTimeout();
    }

    fn onSocketState(data: ?*anyopaque, fd: c.ares_socket_t, readable: c_int, writable: c_int) callconv(.c) void {
        const self: *Adapter = @ptrCast(@alignCast(data.?));
        if (self.destroying) {
            const watch = self.watches.get(fd) orelse return;
            watch.want_read = false;
            watch.want_write = false;
            updateWatch(watch);
            return;
        }
        const result = self.watches.getOrPut(self.allocator, fd) catch {
            self.failIntegration();
            return;
        };
        if (!result.found_existing) {
            const watch = self.allocator.create(Watch) catch {
                _ = self.watches.remove(fd);
                self.failIntegration();
                return;
            };
            watch.* = .{ .adapter = self, .fd = fd };
            result.value_ptr.* = watch;
        }
        const watch = result.value_ptr.*;
        watch.want_read = readable != 0;
        watch.want_write = writable != 0;
        updateWatch(watch);
    }

    fn onReadReady(data: ?*anyopaque, _: *xev.Loop, _: *xev.Completion, result: xev.Result) xev.CallbackAction {
        const watch: *Watch = @ptrCast(@alignCast(data.?));
        watch.read_active = false;
        watch.callback_active = true;
        if (result.poll) |_| {
            if (watch.want_read) watch.adapter.processFd(watch.fd, c.ARES_FD_EVENT_READ);
        } else |_| {}
        watch.callback_active = false;
        updateWatch(watch);
        return .disarm;
    }

    fn onWriteReady(data: ?*anyopaque, _: *xev.Loop, _: *xev.Completion, result: xev.Result) xev.CallbackAction {
        const watch: *Watch = @ptrCast(@alignCast(data.?));
        watch.write_active = false;
        watch.callback_active = true;
        if (result.poll) |_| {
            if (watch.want_write) watch.adapter.processFd(watch.fd, c.ARES_FD_EVENT_WRITE);
        } else |_| {}
        watch.callback_active = false;
        updateWatch(watch);
        return .disarm;
    }

    fn onReadCancelled(watch_: ?*Watch, _: *xev.Loop, _: *xev.Completion, _: xev.CancelError!void) xev.CallbackAction {
        const watch = watch_.?;
        watch.read_cancel_active = false;
        updateWatch(watch);
        return .disarm;
    }

    fn onWriteCancelled(watch_: ?*Watch, _: *xev.Loop, _: *xev.Completion, _: xev.CancelError!void) xev.CallbackAction {
        const watch = watch_.?;
        watch.write_cancel_active = false;
        updateWatch(watch);
        return .disarm;
    }

    fn onTimer(self_: ?*Adapter, _: *xev.Loop, _: *xev.Completion, result: xev.Timer.RunError!void) xev.CallbackAction {
        const self = self_.?;
        self.timer_armed = false;
        result catch return .disarm;
        if (self.destroying) return .disarm;
        if (self.integration_failed) {
            self.integration_failed = false;
            self.force_failure = true;
            if (self.query_active) c.ares_cancel(self.channel);
            return .disarm;
        }
        _ = c.ares_process_fds(self.channel, null, 0, c.ARES_PROCESS_FLAG_NONE);
        self.rescheduleTimeout();
        return .disarm;
    }

    fn onResolved(data: ?*anyopaque, status: c_int, _: c_int, result: ?*c.ares_addrinfo) callconv(.c) void {
        const self: *Adapter = @ptrCast(@alignCast(data.?));
        self.query_active = false;
        defer if (result) |value| c.ares_freeaddrinfo(value);
        const callback = self.callback orelse return;
        const context = self.callback_context;
        self.callback = null;
        self.callback_context = null;

        if (self.force_failure) {
            self.force_failure = false;
            callback(context, .failed);
            return;
        }
        if (status == c.ARES_ECANCELLED or status == c.ARES_EDESTRUCTION) {
            callback(context, .cancelled);
            return;
        }
        if (status != c.ARES_SUCCESS or result == null) {
            callback(context, .failed);
            return;
        }

        const addresses = copyAddresses(self.allocator, result.?.nodes, self.port) catch {
            callback(context, .failed);
            return;
        };
        if (addresses.len == 0) {
            self.allocator.free(addresses);
            callback(context, .failed);
        } else {
            callback(context, .{ .addresses = addresses });
        }
    }
};

fn nodeAddress(node: *const c.ares_addrinfo_node, port: u16) !?std.Io.net.IpAddress {
    switch (node.ai_family) {
        c.AF_INET => {
            if (node.ai_addr == null or node.ai_addrlen < @sizeOf(std.posix.sockaddr.in)) return error.InvalidAddress;
            const native: *const std.posix.sockaddr.in = @ptrCast(@alignCast(node.ai_addr));
            return .{ .ip4 = .{ .bytes = @bitCast(native.addr), .port = port } };
        },
        c.AF_INET6 => {
            if (node.ai_addr == null or node.ai_addrlen < @sizeOf(std.posix.sockaddr.in6)) return error.InvalidAddress;
            const native: *const std.posix.sockaddr.in6 = @ptrCast(@alignCast(node.ai_addr));
            return .{ .ip6 = .{
                .bytes = native.addr,
                .port = port,
                .flow = native.flowinfo,
                .interface = .{ .index = native.scope_id },
            } };
        },
        else => return null,
    }
}

fn copyAddresses(allocator: std.mem.Allocator, first: [*c]c.ares_addrinfo_node, port: u16) ![]std.Io.net.IpAddress {
    var count: usize = 0;
    var node = first;
    while (node != null) : (node = node.*.ai_next) {
        if (try nodeAddress(node, port) != null) count += 1;
    }
    const addresses = try allocator.alloc(std.Io.net.IpAddress, count);
    errdefer allocator.free(addresses);
    var index: usize = 0;
    node = first;
    while (node != null) : (node = node.*.ai_next) {
        if (try nodeAddress(node, port)) |address| {
            addresses[index] = address;
            index += 1;
        }
    }
    return addresses;
}

test "resolves localhost without blocking the event loop" {
    const runtime = @import("runtime.zig").Runtime;
    var global = try runtime.init();
    defer global.deinit();

    var loop = try xev.Loop.init(.{});
    var adapter: Adapter = undefined;
    try adapter.init(std.testing.allocator, &loop);
    defer {
        adapter.shutdown();
        loop.run(.until_done) catch {};
        loop.deinit();
        adapter.deinitAfterLoop();
    }

    const Outcome = struct {
        result: ?ResolveResult = null,

        fn complete(context: ?*anyopaque, result: ResolveResult) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.result = result;
        }
    };
    var outcome: Outcome = .{};
    try adapter.resolve("localhost", 50051, &outcome, Outcome.complete);
    try loop.run(.until_done);
    const result = outcome.result orelse return error.ResolveDidNotComplete;
    switch (result) {
        .addresses => |addresses| {
            defer std.testing.allocator.free(addresses);
            try std.testing.expect(addresses.len != 0);
            for (addresses) |address| {
                try std.testing.expectEqual(@as(u16, 50051), address.getPort());
                switch (address) {
                    .ip4 => |ip| try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &ip.bytes),
                    .ip6 => |ip| try std.testing.expectEqualSlices(u8, &std.Io.net.Ip6Address.loopback(50051).bytes, &ip.bytes),
                }
            }
        },
        else => return error.ResolveFailed,
    }
}

test "DNS resolves AAAA-only and mixed A AAAA records and rejects empty answers" {
    const runtime = @import("runtime.zig").Runtime;
    var global = try runtime.init();
    defer global.deinit();
    const Outcome = struct {
        result: ?ResolveResult = null,
        fn complete(context: ?*anyopaque, result: ResolveResult) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.result = result;
        }
    };
    for (0..3) |scenario| {
        var dns = try @import("test_dns.zig").Server.init(scenario == 1, scenario != 2);
        defer dns.deinit();
        try dns.start();
        var loop = try xev.Loop.init(.{});
        var adapter: Adapter = undefined;
        try adapter.init(std.testing.allocator, &loop);
        defer {
            adapter.shutdown();
            loop.run(.until_done) catch {};
            loop.deinit();
            adapter.deinitAfterLoop();
        }
        var buffer: [32]u8 = undefined;
        const endpoint = try std.fmt.bufPrintSentinel(&buffer, "127.0.0.1:{d}", .{dns.port}, 0);
        try std.testing.expectEqual(c.ARES_SUCCESS, c.ares_set_servers_ports_csv(adapter.channel, endpoint));
        var outcome: Outcome = .{};
        try adapter.resolve("ipv6-fixture.test.", 50051, &outcome, Outcome.complete);
        try loop.run(.until_done);
        try std.testing.expect(!dns.failed.load(.acquire));
        try std.testing.expect(dns.queries4.load(.acquire) > 0);
        try std.testing.expect(dns.queries6.load(.acquire) > 0);
        const result = outcome.result orelse return error.MissingCallback;
        if (scenario == 2) {
            try std.testing.expect(result == .failed);
            continue;
        }
        const addresses = switch (result) {
            .addresses => |addresses| addresses,
            else => return error.ResolveFailed,
        };
        defer std.testing.allocator.free(addresses);
        try std.testing.expectEqual(@as(usize, if (scenario == 0) 1 else 2), addresses.len);
        var saw4 = false;
        var saw6 = false;
        for (addresses) |address| {
            try std.testing.expectEqual(@as(u16, 50051), address.getPort());
            switch (address) {
                .ip4 => |ip| {
                    saw4 = true;
                    try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &ip.bytes);
                },
                .ip6 => |ip| {
                    saw6 = true;
                    try std.testing.expectEqualSlices(u8, &std.Io.net.Ip6Address.loopback(0).bytes, &ip.bytes);
                },
            }
        }
        try std.testing.expect(saw6);
        try std.testing.expectEqual(scenario == 1, saw4);
    }
}

test "dual-family DNS cancellation and shutdown complete exactly once" {
    var runtime = try @import("runtime.zig").Runtime.init();
    defer runtime.deinit();
    const Outcome = struct {
        count: usize = 0,
        cancelled: bool = false,
        fn complete(context: ?*anyopaque, result: ResolveResult) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.count += 1;
            self.cancelled = result == .cancelled;
            if (result == .addresses) std.testing.allocator.free(result.addresses);
        }
    };
    for ([_]bool{ false, true }) |shutdown| {
        // Bound but deliberately not serviced: cancellation must drain pending I/O.
        var dns = try @import("test_dns.zig").Server.init(false, false);
        defer dns.deinit();
        var loop = try xev.Loop.init(.{});
        var adapter: Adapter = undefined;
        try adapter.init(std.testing.allocator, &loop);
        defer {
            adapter.shutdown();
            loop.run(.until_done) catch {};
            loop.deinit();
            adapter.deinitAfterLoop();
        }
        var buffer: [32]u8 = undefined;
        const endpoint = try std.fmt.bufPrintSentinel(&buffer, "127.0.0.1:{d}", .{dns.port}, 0);
        try std.testing.expectEqual(c.ARES_SUCCESS, c.ares_set_servers_ports_csv(adapter.channel, endpoint));
        var outcome: Outcome = .{};
        try adapter.resolve("cancel-fixture.test.", 50051, &outcome, Outcome.complete);
        try std.testing.expect(adapter.query_active);
        if (shutdown) adapter.shutdown() else adapter.cancel();
        try loop.run(.until_done);
        try std.testing.expectEqual(@as(usize, 1), outcome.count);
        try std.testing.expect(outcome.cancelled);
        try std.testing.expect(!adapter.query_active);
        try std.testing.expectEqual(@as(usize, 0), adapter.watches.count());
    }
}

test "address conversion preserves resolver order IPv6 fields and allocation ownership" {
    const Fixture = struct {
        fn check(allocator: std.mem.Allocator) !void {
            var ip6: std.posix.sockaddr.in6 = .{
                .addr = std.Io.net.Ip6Address.loopback(0).bytes,
                .port = std.mem.nativeToBig(u16, 99),
                .flowinfo = 123,
                .scope_id = 7,
            };
            var ip4: std.posix.sockaddr.in = .{ .addr = @bitCast([4]u8{ 127, 0, 0, 1 }), .port = 0 };
            var last = std.mem.zeroes(c.ares_addrinfo_node);
            last.ai_family = c.AF_INET;
            last.ai_addr = @ptrCast(&ip4);
            last.ai_addrlen = @sizeOf(@TypeOf(ip4));
            var ignored = std.mem.zeroes(c.ares_addrinfo_node);
            ignored.ai_family = c.AF_UNSPEC;
            ignored.ai_next = &last;
            var first = std.mem.zeroes(c.ares_addrinfo_node);
            first.ai_family = c.AF_INET6;
            first.ai_addr = @ptrCast(&ip6);
            first.ai_addrlen = @sizeOf(@TypeOf(ip6));
            first.ai_next = &ignored;
            const addresses = try copyAddresses(allocator, &first, 50051);
            defer allocator.free(addresses);
            try std.testing.expectEqual(@as(usize, 2), addresses.len);
            try std.testing.expect(addresses[0] == .ip6 and addresses[1] == .ip4);
            try std.testing.expectEqual(@as(u16, 50051), addresses[0].getPort());
            try std.testing.expectEqual(@as(u32, 123), addresses[0].ip6.flow);
            try std.testing.expectEqual(@as(u32, 7), addresses[0].ip6.interface.index);
            last.ai_addrlen = 1;
            try std.testing.expectError(error.InvalidAddress, copyAddresses(allocator, &first, 50051));
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Fixture.check, .{});
}
