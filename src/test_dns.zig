//! Loopback-only DNS fixture. Answers A/AAAA questions without external DNS.
const std = @import("std");

pub const Server = struct {
    fd: std.posix.fd_t,
    port: u16,
    ipv4: bool,
    ipv6: bool,
    stopped: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    queries4: std.atomic.Value(usize) = .init(0),
    queries6: std.atomic.Value(usize) = .init(0),
    thread: ?std.Thread = null,

    pub fn init(ipv4: bool, ipv6: bool) !Server {
        const fd = std.c.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = std.c.close(fd);
        var address: std.posix.sockaddr.in = .{ .port = 0, .addr = @bitCast([4]u8{ 127, 0, 0, 1 }) };
        if (std.c.bind(fd, @ptrCast(&address), @sizeOf(@TypeOf(address))) != 0) return error.BindFailed;
        var length: std.posix.socklen_t = @sizeOf(@TypeOf(address));
        if (std.c.getsockname(fd, @ptrCast(&address), &length) != 0) return error.AddressQueryFailed;
        return .{ .fd = fd, .port = std.mem.bigToNative(u16, address.port), .ipv4 = ipv4, .ipv6 = ipv6 };
    }

    pub fn start(self: *Server) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn deinit(self: *Server) void {
        self.stopped.store(true, .release);
        if (self.thread) |thread| thread.join();
        _ = std.c.close(self.fd);
    }

    fn run(self: *Server) void {
        while (!self.stopped.load(.acquire)) {
            self.respond() catch {
                self.failed.store(true, .release);
                return;
            };
        }
    }

    fn respond(self: *Server) !void {
        var poll_fd = std.posix.pollfd{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 };
        const ready = std.c.poll(@ptrCast(&poll_fd), 1, 20);
        if (ready == 0) return;
        if (ready < 0) return error.PollFailed;
        var bytes: [512]u8 = undefined;
        var peer: std.posix.sockaddr.storage = undefined;
        var length: std.posix.socklen_t = @sizeOf(@TypeOf(peer));
        const received = std.c.recvfrom(self.fd, &bytes, bytes.len, 0, @ptrCast(&peer), &length);
        if (received < 12) return error.InvalidQuery;
        const size: usize = @intCast(received);
        var end: usize = 12;
        while (end < size and bytes[end] != 0) {
            if (bytes[end] > 63) return error.InvalidQuery;
            end += 1 + @as(usize, bytes[end]);
        }
        end += 5; // Root label, QTYPE and QCLASS.
        if (end > size) return error.InvalidQuery;
        const qtype = std.mem.readInt(u16, bytes[end - 4 ..][0..2], .big);
        if (qtype == 1) _ = self.queries4.fetchAdd(1, .monotonic);
        if (qtype == 28) _ = self.queries6.fetchAdd(1, .monotonic);
        const answer = (qtype == 1 and self.ipv4) or (qtype == 28 and self.ipv6);
        bytes[2] = 0x81;
        bytes[3] = 0x80;
        @memcpy(bytes[4..12], &[_]u8{ 0, 1, 0, @intFromBool(answer), 0, 0, 0, 0 });
        if (answer) {
            const payload: []const u8 = if (qtype == 1) &.{ 127, 0, 0, 1 } else &std.Io.net.Ip6Address.loopback(0).bytes;
            @memcpy(bytes[end..][0..12], &[_]u8{ 0xc0, 0x0c, 0, @intCast(qtype), 0, 1, 0, 0, 0, 0, 0, @intCast(payload.len) });
            end += 12;
            @memcpy(bytes[end..][0..payload.len], payload);
            end += payload.len;
        }
        if (std.c.sendto(self.fd, &bytes, end, 0, @ptrCast(&peer), length) != end) return error.SendFailed;
    }
};
