const std = @import("std");
const grpc = @import("grpc_lite");

test "stable public API compiles for downstream consumers" {
    comptime {
        _ = grpc.Channel;
        _ = grpc.ChannelOptions;
        _ = grpc.CallOptions;
        _ = grpc.CallResult;
        _ = grpc.Server;
        _ = grpc.ServerOptions;
        _ = grpc.ServerLocalAddress;
        _ = grpc.ServerContext;
        _ = grpc.UnaryHandler;
        _ = grpc.UnaryResponse;
        _ = grpc.Metadata;
        _ = grpc.MetadataEntry;
        _ = grpc.Status;
        _ = grpc.StatusCode;
        _ = grpc.Compression;
    }

    _ = try std.SemanticVersion.parse(grpc.version);
    const channel_options: grpc.ChannelOptions = .{};
    try std.testing.expectEqualStrings("grpc-lite/" ++ grpc.version, channel_options.user_agent);
}
