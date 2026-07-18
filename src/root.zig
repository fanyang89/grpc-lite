//! Lightweight gRPC core runtime for Zig.

const std = @import("std");

pub const version = "0.1.0";

test "version is available" {
    try std.testing.expectEqualStrings("0.1.0", version);
}
