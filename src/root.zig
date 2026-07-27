//! Lightweight gRPC core runtime for Zig.

const std = @import("std");
const build_options = @import("grpc_lite_options");

const c = @import("c.zig");
const c_api = @import("c_api.zig");
const cares_adapter = @import("cares_adapter.zig");
const deadline = @import("deadline.zig");
const fast_clock = @import("fast_clock.zig");
const version_info = @import("version.zig");
const runtime = @import("runtime.zig");

comptime {
    @export(&c_api.grpc_lite_abi_version, .{ .name = "grpc_lite_abi_version" });
    @export(&c_api.grpc_lite_library_version, .{ .name = "grpc_lite_library_version" });
    @export(&c_api.grpc_lite_features, .{ .name = "grpc_lite_features" });
    @export(&c_api.grpc_lite_error_string, .{ .name = "grpc_lite_error_string" });
    @export(&c_api.grpc_lite_runtime_create, .{ .name = "grpc_lite_runtime_create" });
    @export(&c_api.grpc_lite_runtime_destroy, .{ .name = "grpc_lite_runtime_destroy" });
    @export(&c_api.grpc_lite_metadata_create, .{ .name = "grpc_lite_metadata_create" });
    @export(&c_api.grpc_lite_metadata_destroy, .{ .name = "grpc_lite_metadata_destroy" });
    @export(&c_api.grpc_lite_metadata_add, .{ .name = "grpc_lite_metadata_add" });
    @export(&c_api.grpc_lite_metadata_count, .{ .name = "grpc_lite_metadata_count" });
    @export(&c_api.grpc_lite_metadata_at, .{ .name = "grpc_lite_metadata_at" });
}
pub const message = @import("message.zig");

pub const call = @import("call.zig");
pub const channel = @import("channel.zig");
pub const compression = @import("compression.zig");
pub const frame = @import("frame.zig");
pub const log = @import("log.zig");
pub const metadata = @import("metadata.zig");
pub const server = @import("server.zig");
pub const service = @import("service.zig");
pub const status = @import("status.zig");
pub const stream = @import("stream.zig");
pub const protobuf = @import("protobuf");
pub const xev = @import("xev");

pub const CallOptions = call.Options;
pub const CallResult = call.Result;
pub const AsyncCallResult = call.AsyncResult;
pub const UnaryCallCallbacks = call.Callbacks;
pub const Compression = compression.Compression;
pub const Channel = channel.Channel;
pub const ChannelOptions = channel.Options;
pub const ClientTlsOptions = channel.TlsOptions;
pub const Metadata = metadata.Metadata;
pub const MetadataEntry = metadata.Entry;
pub const Server = server.Server;
pub const ServerOptions = server.Options;
pub const ServerTlsOptions = server.TlsOptions;
pub const ServerLocalAddress = server.LocalAddress;
pub const ServerContext = service.ServerContext;
pub const Status = status.Status;
pub const StatusCode = status.Code;
pub const StreamBufferLimits = stream.BufferLimits;
pub const StreamOptions = stream.Options;
pub const StreamSendOptions = stream.SendOptions;
pub const StreamReceiveAction = stream.ReceiveAction;
pub const ClientStream = stream.ClientStream;
pub const ClientStreamCallbacks = stream.ClientCallbacks;
pub const ServerStream = stream.ServerStream;
pub const ServerCall = stream.ServerCall;
pub const ServerCallId = stream.ServerCallId;
pub const ServerTerminalReason = stream.ServerTerminalReason;
pub const ServerInitialMetadataMode = stream.InitialMetadataMode;
pub const ServerStreamHandler = stream.ServerHandler;
pub const UnaryHandler = service.UnaryHandler;
pub const UnaryResponse = service.UnaryResponse;
pub const Runtime = runtime.Runtime;

pub const version = version_info.string;

pub const internal = struct {
    pub const fastNowNs = fast_clock.now;
    pub const fastClockImplementation = fast_clock.implementation;
    pub const fastClockFallbackReason = fast_clock.fallbackReason;
    pub const fastClockUsesCpuCycles = fast_clock.usesCpuCycles;
};

test "version is available" {
    _ = try std.SemanticVersion.parse(version);
}

test {
    _ = c;
    _ = c_api;
    _ = cares_adapter;
    _ = call;
    _ = channel;
    _ = compression;
    _ = deadline;
    _ = frame;
    _ = fast_clock;
    _ = log;
    _ = metadata;
    _ = runtime;
    _ = message;
    _ = server;
    _ = service;
    _ = status;
    _ = stream;
    _ = protobuf;
    _ = xev;
    _ = version_info;
    if (build_options.tls) _ = @import("tls_record.zig");
}
