//! Lightweight gRPC core runtime for Zig.

const std = @import("std");

const c = @import("c.zig");

pub const call = @import("call.zig");
pub const frame = @import("frame.zig");
pub const metadata = @import("metadata.zig");
pub const status = @import("status.zig");

pub const CallOptions = call.Options;
pub const CallResult = call.Result;
pub const Metadata = metadata.Metadata;
pub const MetadataEntry = metadata.Entry;
pub const Status = status.Status;
pub const StatusCode = status.Code;

pub const version = "0.1.0";

test "version is available" {
    try std.testing.expectEqualStrings("0.1.0", version);
}

test {
    _ = c;
    _ = call;
    _ = frame;
    _ = metadata;
    _ = status;
}
