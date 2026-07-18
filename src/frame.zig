const std = @import("std");
const Compression = @import("compression.zig").Compression;

pub const header_size = 5;

pub fn encode(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    return encodeWithCompression(allocator, payload, .identity);
}

pub fn encodeWithCompression(
    allocator: std.mem.Allocator,
    payload: []const u8,
    compression: Compression,
) ![]u8 {
    if (compression == .identity) return encodePayload(allocator, payload, false);

    var output = try std.Io.Writer.Allocating.initCapacity(allocator, 64);
    defer output.deinit();
    const history = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(history);
    var compressor = std.compress.flate.Compress.init(
        &output.writer,
        history,
        .gzip,
        .default,
    ) catch return error.OutOfMemory;
    compressor.writer.writeAll(payload) catch return error.OutOfMemory;
    compressor.finish() catch return error.OutOfMemory;
    return encodePayload(allocator, output.written(), true);
}

fn encodePayload(allocator: std.mem.Allocator, payload: []const u8, compressed: bool) ![]u8 {
    if (payload.len > std.math.maxInt(u32)) return error.MessageTooLarge;

    const frame = try allocator.alloc(u8, header_size + payload.len);
    frame[0] = @intFromBool(compressed);
    const length: u32 = @intCast(payload.len);
    frame[1] = @truncate(length >> 24);
    frame[2] = @truncate(length >> 16);
    frame[3] = @truncate(length >> 8);
    frame[4] = @truncate(length);
    @memcpy(frame[header_size..], payload);
    return frame;
}

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    max_message_size: usize,
    compression: Compression,
    buffer: std.ArrayList(u8) = .empty,
    offset: usize = 0,

    pub fn init(allocator: std.mem.Allocator, max_message_size: usize) Decoder {
        return initWithCompression(allocator, max_message_size, .identity);
    }

    pub fn initWithCompression(
        allocator: std.mem.Allocator,
        max_message_size: usize,
        compression: Compression,
    ) Decoder {
        return .{
            .allocator = allocator,
            .max_message_size = max_message_size,
            .compression = compression,
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
        if (available[0] > 1) return error.InvalidCompressedFlag;
        const compressed = available[0] == 1;
        if (compressed and self.compression != .gzip) return error.CompressionMismatch;

        const length = (@as(u32, available[1]) << 24) |
            (@as(u32, available[2]) << 16) |
            (@as(u32, available[3]) << 8) |
            @as(u32, available[4]);
        if (!compressed and length > self.max_message_size) return error.MessageTooLarge;

        const end = header_size + @as(usize, length);
        if (available.len < end) return null;

        const payload = if (compressed)
            try decompressGzip(
                self.allocator,
                available[header_size..end],
                self.max_message_size,
            )
        else
            try self.allocator.dupe(u8, available[header_size..end]);
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
    return decodeUnaryWithCompression(allocator, bytes, max_message_size, .identity);
}

pub fn decodeUnaryWithCompression(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    max_message_size: usize,
    compression: Compression,
) ![]u8 {
    var decoder = Decoder.initWithCompression(allocator, max_message_size, compression);
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

fn decompressGzip(
    allocator: std.mem.Allocator,
    payload: []const u8,
    max_message_size: usize,
) ![]u8 {
    var input: std.Io.Reader = .fixed(payload);
    const history = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(history);
    var decompressor: std.compress.flate.Decompress = .init(&input, .gzip, history);
    const limit: std.Io.Limit = if (max_message_size == std.math.maxInt(usize))
        .unlimited
    else
        .limited(max_message_size + 1);
    const decompressed = decompressor.reader.allocRemaining(allocator, limit) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.MessageTooLarge,
        else => return error.MalformedCompressedMessage,
    };
    errdefer allocator.free(decompressed);
    if (decompressed.len > max_message_size) return error.MessageTooLarge;
    if (input.seek != input.end) return error.MalformedCompressedMessage;
    return decompressed;
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

test "frame round trips a multi-byte payload length" {
    const payload = try std.testing.allocator.alloc(u8, 70_000);
    defer std.testing.allocator.free(payload);
    @memset(payload, 0x5a);

    const encoded = try encode(std.testing.allocator, payload);
    defer std.testing.allocator.free(encoded);
    const decoded = try decodeUnary(std.testing.allocator, encoded, payload.len);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, payload, decoded);
}

test "gzip frame round trips and marks compressed payload" {
    const encoded = try encodeWithCompression(std.testing.allocator, "compress me compress me", .gzip);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqual(@as(u8, 1), encoded[0]);

    const decoded = try decodeUnaryWithCompression(std.testing.allocator, encoded, 1024, .gzip);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("compress me compress me", decoded);
}

test "gzip decoding rejects malformed data and compression mismatches" {
    try std.testing.expectError(
        error.MalformedCompressedMessage,
        decodeUnaryWithCompression(
            std.testing.allocator,
            &.{ 1, 0, 0, 0, 3, 1, 2, 3 },
            1024,
            .gzip,
        ),
    );
    try std.testing.expectError(
        error.CompressionMismatch,
        decodeUnaryWithCompression(std.testing.allocator, &.{ 1, 0, 0, 0, 0 }, 1024, .identity),
    );
    const uncompressed = try decodeUnaryWithCompression(
        std.testing.allocator,
        &.{ 0, 0, 0, 0, 0 },
        1024,
        .gzip,
    );
    defer std.testing.allocator.free(uncompressed);
    try std.testing.expectEqual(@as(usize, 0), uncompressed.len);
}

test "gzip decoding enforces decompressed message size" {
    const encoded = try encodeWithCompression(std.testing.allocator, "123456789", .gzip);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectError(
        error.MessageTooLarge,
        decodeUnaryWithCompression(std.testing.allocator, encoded, 8, .gzip),
    );
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
    try std.testing.expectError(error.CompressionMismatch, decoder.next());

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
