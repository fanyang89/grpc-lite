const std = @import("std");
const metadata = @import("metadata.zig");
const status = @import("status.zig");

pub const default_max_message_size = 4 * 1024 * 1024;

pub const Options = struct {
    metadata: []const metadata.Entry = &.{},
    timeout_ns: ?u64 = null,
    max_response_size: usize = default_max_message_size,
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    status: status.Status,
    payload: []u8,
    initial_metadata: metadata.Metadata,
    trailing_metadata: metadata.Metadata,

    pub fn init(
        allocator: std.mem.Allocator,
        result_status: status.Status,
        payload: []const u8,
    ) !Result {
        const owned_message = try allocator.dupe(u8, result_status.message);
        errdefer allocator.free(owned_message);
        const owned_payload = try allocator.dupe(u8, payload);
        errdefer allocator.free(owned_payload);

        return .{
            .allocator = allocator,
            .status = .{ .code = result_status.code, .message = owned_message },
            .payload = owned_payload,
            .initial_metadata = metadata.Metadata.init(allocator),
            .trailing_metadata = metadata.Metadata.init(allocator),
        };
    }

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.status.message);
        self.allocator.free(self.payload);
        self.initial_metadata.deinit();
        self.trailing_metadata.deinit();
        self.* = undefined;
    }
};

test "call result owns payload status and metadata" {
    var result = try Result.init(
        std.testing.allocator,
        status.Status.init(.invalid_argument, "bad request"),
        "response",
    );
    defer result.deinit();

    try result.initial_metadata.append("x-test", "value");
    try std.testing.expectEqual(status.Code.invalid_argument, result.status.code);
    try std.testing.expectEqualStrings("bad request", result.status.message);
    try std.testing.expectEqualStrings("response", result.payload);
}
