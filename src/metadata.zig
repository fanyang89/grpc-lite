const std = @import("std");

pub const Entry = struct {
    key: []const u8,
    value: []const u8,
};

pub const Metadata = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator) Metadata {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Metadata) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn append(self: *Metadata, key: []const u8, value: []const u8) !void {
        if (!isValidKey(key)) return error.InvalidMetadataKey;

        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        try self.entries.append(self.allocator, .{
            .key = owned_key,
            .value = owned_value,
        });
    }

    pub fn appendDecoded(self: *Metadata, key: []const u8, value: []const u8) !void {
        if (!isBinaryKey(key)) return self.append(key, value);

        const decoder = if (std.mem.endsWith(u8, value, "="))
            std.base64.standard.Decoder
        else
            std.base64.standard_no_pad.Decoder;
        const decoded = try self.allocator.alloc(u8, try decoder.calcSizeForSlice(value));
        defer self.allocator.free(decoded);
        try decoder.decode(decoded, value);
        try self.append(key, decoded);
    }

    pub fn getFirst(self: *const Metadata, key: []const u8) ?[]const u8 {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }

    pub fn items(self: *const Metadata) []const Entry {
        return self.entries.items;
    }
};

pub fn isValidKey(key: []const u8) bool {
    if (key.len == 0 or key[0] == ':') return false;
    for (key) |byte| switch (byte) {
        'a'...'z', '0'...'9', '-', '_', '.' => {},
        else => return false,
    };
    return true;
}

pub fn isBinaryKey(key: []const u8) bool {
    return std.mem.endsWith(u8, key, "-bin");
}

pub fn encodeValue(allocator: std.mem.Allocator, key: []const u8, value: []const u8) ![]u8 {
    if (!isBinaryKey(key)) return allocator.dupe(u8, value);

    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(value.len));
    _ = std.base64.standard.Encoder.encode(encoded, value);
    return encoded;
}

test "metadata owns entries and preserves duplicates" {
    var metadata = Metadata.init(std.testing.allocator);
    defer metadata.deinit();

    try metadata.append("x-request-id", "one");
    try metadata.append("x-request-id", "two");
    try std.testing.expectEqual(@as(usize, 2), metadata.items().len);
    try std.testing.expectEqualStrings("one", metadata.getFirst("x-request-id").?);
}

test "metadata rejects invalid keys" {
    var metadata = Metadata.init(std.testing.allocator);
    defer metadata.deinit();

    try std.testing.expectError(error.InvalidMetadataKey, metadata.append("", "value"));
    try std.testing.expectError(error.InvalidMetadataKey, metadata.append(":path", "value"));
    try std.testing.expectError(error.InvalidMetadataKey, metadata.append("Upper", "value"));
}

test "binary metadata codec emits padded base64 and accepts padded or unpadded input" {
    const raw = [_]u8{0xab};
    const encoded = try encodeValue(std.testing.allocator, "trace-bin", &raw);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("qw==", encoded);

    var metadata = Metadata.init(std.testing.allocator);
    defer metadata.deinit();
    try metadata.appendDecoded("trace-bin", "q6ur");
    try metadata.appendDecoded("trace-bin", "qw==");
    try metadata.appendDecoded("trace-bin", "qw");
    try std.testing.expectEqualSlices(u8, &.{ 0xab, 0xab, 0xab }, metadata.items()[0].value);
    try std.testing.expectEqualSlices(u8, &raw, metadata.items()[1].value);
    try std.testing.expectEqualSlices(u8, &raw, metadata.items()[2].value);

    const ascii = try encodeValue(std.testing.allocator, "trace-bin-extra", "unchanged");
    defer std.testing.allocator.free(ascii);
    try std.testing.expectEqualStrings("unchanged", ascii);
}

test "binary metadata codec rejects invalid input without appending" {
    var metadata = Metadata.init(std.testing.allocator);
    defer metadata.deinit();

    try std.testing.expectError(error.InvalidCharacter, metadata.appendDecoded("trace-bin", "not base64!"));
    try std.testing.expectError(error.InvalidPadding, metadata.appendDecoded("trace-bin", "A"));
    try std.testing.expectEqual(@as(usize, 0), metadata.items().len);
}
