const std = @import("std");
const grpc = @import("grpc_lite");

test "stable public API compiles for downstream consumers" {
    comptime {
        _ = grpc.Channel;
        _ = grpc.ChannelOptions;
        _ = grpc.ChannelOperationalStats;
        _ = grpc.ReconnectOptions;
        _ = grpc.ClientTlsOptions;
        _ = grpc.Runtime;
        _ = grpc.CallOptions;
        _ = grpc.CallResult;
        _ = grpc.Server;
        _ = grpc.ServerOptions;
        _ = grpc.ServerOperationalStats;
        _ = grpc.ServerTlsOptions;
        _ = grpc.ServerLocalAddress;
        _ = grpc.ServerContext;
        _ = grpc.UnaryHandler;
        _ = grpc.UnaryResponse;
        _ = grpc.Metadata;
        _ = grpc.MetadataEntry;
        _ = grpc.Status;
        _ = grpc.StatusCode;
        _ = grpc.Compression;
        _ = grpc.StreamBufferLimits;
        _ = grpc.StreamOptions;
        _ = grpc.StreamSendOptions;
        _ = grpc.StreamReceiveAction;
        _ = grpc.ClientStream;
        _ = grpc.ClientStreamCallbacks;
        _ = grpc.ServerStream;
        _ = grpc.ServerCall;
        _ = grpc.ServerCallId;
        _ = grpc.ServerTerminalReason;
        _ = grpc.ServerInitialMetadataMode;
        _ = grpc.ServerStreamHandler;
        _ = grpc.log;
        _ = grpc.xev;
    }

    _ = try std.SemanticVersion.parse(grpc.version);
    const channel_options: grpc.ChannelOptions = .{};
    try std.testing.expectEqualStrings("grpc-lite/" ++ grpc.version, channel_options.user_agent);
    try std.testing.expectEqualStrings("grpc-lite/" ++ grpc.version, channel_options.user_agent);
    try std.testing.expectEqual(@as(u32, 64 * 1024), channel_options.max_response_header_list_size);

    const server_options: grpc.ServerOptions = .{};
    try std.testing.expectEqual(@as(usize, 1024), server_options.max_connections);
    try std.testing.expectEqual(@as(u32, 100), server_options.max_concurrent_streams_per_connection);
    try std.testing.expectEqual(@as(u64, 10 * std.time.ns_per_s), server_options.cleartext_preface_timeout_ns);
    try std.testing.expectEqual(@as(u64, 5 * 60 * std.time.ns_per_s), server_options.connection_idle_timeout_ns);
}

test "ChannelOperationalStats exposes the Channel snapshot type and defaults" {
    comptime {
        const snapshot: *const fn (*grpc.Channel) grpc.ChannelOperationalStats = &grpc.Channel.operationalStats;
        _ = snapshot;
    }
    try std.testing.expect(grpc.ChannelOperationalStats == grpc.channel.OperationalStats);

    const stats: grpc.ChannelOperationalStats = .{};
    try std.testing.expectEqualDeep(grpc.UnaryAdmissionStats{}, stats.unary_admission);
    try std.testing.expectEqualDeep(grpc.StreamAdmissionStats{}, stats.stream_admission);
    try std.testing.expectEqual(@as(u64, 0), stats.active_unary_calls);
    try std.testing.expectEqual(@as(u64, 0), stats.active_streams);
    try std.testing.expectEqual(@as(u64, 0), stats.active_connections);
    try std.testing.expectEqual(@as(u64, 0), stats.pending_unary_calls_high_water);
    try std.testing.expectEqual(@as(u64, 0), stats.stream_inbound_bytes);
    try std.testing.expectEqual(@as(u64, 0), stats.stream_outbound_bytes);
    try std.testing.expectEqual(@as(u64, 0), stats.socket_write_bytes_high_water);
    try std.testing.expectEqual(@as(u64, 0), stats.terminal_cancelled);
    try std.testing.expectEqual(@as(u64, 0), stats.reconnect_attempts);
    try std.testing.expectEqual(@as(u64, 0), stats.reconnect_transport_failure);
}

test "ServerOperationalStats exposes the const Server snapshot type and defaults" {
    comptime {
        const snapshot: *const fn (*const grpc.Server) grpc.ServerOperationalStats = &grpc.Server.operationalStats;
        _ = snapshot;
    }
    try std.testing.expect(grpc.ServerOperationalStats == grpc.server.OperationalStats);

    const stats: grpc.ServerOperationalStats = .{};
    try std.testing.expectEqual(@as(u64, 0), stats.admitted_connections);
    try std.testing.expectEqual(@as(u64, 0), stats.active_rpcs);
    try std.testing.expectEqual(@as(u64, 0), stats.rejected_connections);
    try std.testing.expectEqual(@as(u64, 0), stats.pre_ack_rejected_streams);
    try std.testing.expectEqual(@as(u64, 0), stats.streaming_outbound_reserved_bytes);
    try std.testing.expectEqual(@as(u64, 0), stats.streaming_outbound_reserved_bytes_high_water_sum);
    try std.testing.expectEqual(@as(u64, 0), stats.socket_queued_write_bytes);
    try std.testing.expectEqual(@as(u64, 0), stats.socket_queued_write_bytes_high_water_sum);
    try std.testing.expectEqual(@as(u64, 0), stats.close_peer_transport);
    try std.testing.expectEqual(@as(u64, 0), stats.close_forced_shutdown);
}
