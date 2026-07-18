const std = @import("std");

pub const header_size = 5;

pub fn encode(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    if (payload.len > std.math.maxInt(u32)) return error.MessageTooLarge;

    const frame = try allocator.alloc(u8, header_size + payload.len);
    frame[0] = 0;
    const length: u32 = @intCast(payload.len);
    frame[1] = @intCast(length >> 24);
    frame[2] = @intCast(length >> 16);
    frame[3] = @intCast(length >> 8);
    frame[4] = @intCast(length);
    @memcpy(frame[header_size..], payload);
    return frame;
}

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    max_message_size: usize,
    buffer: std.ArrayList(u8) = .empty,
    offset: usize = 0,

    pub fn init(allocator: std.mem.Allocator, max_message_size: usize) Decoder {
        return .{
            .allocator = allocator,
            .max_message_size = max_message_size,
        };
    }

    pub fn deinit(self: *Decoder) void {
        self.buffer.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn feed(self: *Decoder, bytes: []const u8) !void {
        if (self.offset == self.buffer.items.len) {
            self.buffer.clearRetainingCapacity();
            self.offset = 0;
        } else if (self.offset > 0 and self.offset >= self.buffer.items.len / 2) {
            const remaining = self.buffer.items[self.offset..];
            std.mem.copyForwards(u8, self.buffer.items[0..remaining.len], remaining);
            self.buffer.shrinkRetainingCapacity(remaining.len);
            self.offset = 0;
        }
        try self.buffer.appendSlice(self.allocator, bytes);
    }

    pub fn next(self: *Decoder) !?[]u8 {
        const available = self.buffer.items[self.offset..];
        if (available.len < header_size) return null;
        if (available[0] != 0) return error.CompressionUnsupported;

        const length = (@as(u32, available[1]) << 24) |
            (@as(u32, available[2]) << 16) |
            (@as(u32, available[3]) << 8) |
            @as(u32, available[4]);
        if (length > self.max_message_size) return error.MessageTooLarge;

        const end = header_size + @as(usize, length);
        if (available.len < end) return null;

        const payload = try self.allocator.dupe(u8, available[header_size..end]);
        self.offset += end;
        return payload;
    }

    pub fn finish(self: *const Decoder) !void {
        if (self.offset != self.buffer.items.len) return error.TruncatedFrame;
    }
};

pub fn decodeUnary(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    max_message_size: usize,
) ![]u8 {
    var decoder = Decoder.init(allocator, max_message_size);
    defer decoder.deinit();

    try decoder.feed(bytes);
    const payload = try decoder.next() orelse return error.TruncatedFrame;
    errdefer allocator.free(payload);
    if (try decoder.next()) |extra| {
        allocator.free(extra);
        return error.ExpectedUnaryMessage;
    }
    try decoder.finish();
    return payload;
}

test "frame round trips empty and binary payloads" {
    for ([_][]const u8{ "", "abc\x00xyz" }) |payload| {
        const encoded = try encode(std.testing.allocator, payload);
        defer std.testing.allocator.free(encoded);
        const decoded = try decodeUnary(std.testing.allocator, encoded, 1024);
        defer std.testing.allocator.free(decoded);
        try std.testing.expectEqualSlices(u8, payload, decoded);
    }
}

test "decoder accepts fragmented input and multiple messages" {
    const first = try encode(std.testing.allocator, "first");
    defer std.testing.allocator.free(first);
    const second = try encode(std.testing.allocator, "second");
    defer std.testing.allocator.free(second);

    var decoder = Decoder.init(std.testing.allocator, 1024);
    defer decoder.deinit();
    try decoder.feed(first[0..2]);
    try std.testing.expectEqual(@as(?[]u8, null), try decoder.next());
    try decoder.feed(first[2..]);
    try decoder.feed(second);

    const first_payload = (try decoder.next()).?;
    defer std.testing.allocator.free(first_payload);
    const second_payload = (try decoder.next()).?;
    defer std.testing.allocator.free(second_payload);
    try std.testing.expectEqualStrings("first", first_payload);
    try std.testing.expectEqualStrings("second", second_payload);
    try decoder.finish();
}

test "decoder reports malformed frames" {
    var decoder = Decoder.init(std.testing.allocator, 3);
    defer decoder.deinit();

    try decoder.feed(&.{ 1, 0, 0, 0, 0 });
    try std.testing.expectError(error.CompressionUnsupported, decoder.next());

    decoder.buffer.clearRetainingCapacity();
    decoder.offset = 0;
    try decoder.feed(&.{ 0, 0, 0, 0, 4 });
    try std.testing.expectError(error.MessageTooLarge, decoder.next());
}

test "unary decoding rejects truncated and repeated messages" {
    try std.testing.expectError(
        error.TruncatedFrame,
        decodeUnary(std.testing.allocator, &.{ 0, 0, 0, 0, 1 }, 1024),
    );

    const first = try encode(std.testing.allocator, "one");
    defer std.testing.allocator.free(first);
    const second = try encode(std.testing.allocator, "two");
    defer std.testing.allocator.free(second);
    const combined = try std.mem.concat(std.testing.allocator, u8, &.{ first, second });
    defer std.testing.allocator.free(combined);
    try std.testing.expectError(
        error.ExpectedUnaryMessage,
        decodeUnary(std.testing.allocator, combined, 1024),
    );
}
