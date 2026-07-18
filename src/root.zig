//! Lightweight gRPC core runtime for Zig.

const std = @import("std");

const c = @import("c.zig");
pub const message = @import("message.zig");

pub const call = @import("call.zig");
pub const channel = @import("channel.zig");
pub const compression = @import("compression.zig");
pub const frame = @import("frame.zig");
pub const metadata = @import("metadata.zig");
pub const server = @import("server.zig");
pub const service = @import("service.zig");
pub const status = @import("status.zig");

pub const CallOptions = call.Options;
pub const CallResult = call.Result;
pub const Compression = compression.Compression;
pub const Channel = channel.Channel;
pub const ChannelOptions = channel.Options;
pub const Metadata = metadata.Metadata;
pub const MetadataEntry = metadata.Entry;
pub const Server = server.Server;
pub const ServerOptions = server.Options;
pub const ServerLocalAddress = server.LocalAddress;
pub const ServerContext = service.ServerContext;
pub const Status = status.Status;
pub const StatusCode = status.Code;
pub const UnaryHandler = service.UnaryHandler;
pub const UnaryResponse = service.UnaryResponse;

pub const version = "0.1.0";

test "version is available" {
    try std.testing.expectEqualStrings("0.1.0", version);
}

test {
    _ = c;
    _ = call;
    _ = channel;
    _ = compression;
    _ = frame;
    _ = metadata;
    _ = message;
    _ = server;
    _ = service;
    _ = status;
}
