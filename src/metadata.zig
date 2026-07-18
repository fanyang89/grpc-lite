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
