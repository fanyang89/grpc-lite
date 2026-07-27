const std = @import("std");
const build_options = @import("grpc_lite_options");
const call = @import("call.zig");
const channel = @import("channel.zig");
const Compression = @import("compression.zig").Compression;
const metadata = @import("metadata.zig");
const Runtime = @import("runtime.zig").Runtime;
const version = @import("version.zig");

pub const abi_major: u16 = 1;
pub const abi_minor: u16 = 0;

pub const Error = enum(i32) {
    ok = 0,
    invalid_argument = 1,
    invalid_state = 2,
    out_of_memory = 3,
    unsupported = 4,
    unavailable = 5,
    out_of_range = 6,
    closed = 7,
    internal = 255,
};

pub const Feature = struct {
    pub const raw_unary: u64 = 1 << 0;
    pub const streaming: u64 = 1 << 1;
    pub const gzip: u64 = 1 << 2;
    pub const dns: u64 = 1 << 3;
    pub const tls: u64 = 1 << 4;
    pub const graceful_server_drain: u64 = 1 << 5;
};

pub const BytesView = extern struct {
    data: ?[*]const u8 = null,
    size: usize = 0,
};

pub const MetadataEntryView = extern struct {
    key: BytesView = .{},
    value: BytesView = .{},
};

pub const RuntimeHandle = opaque {};
pub const MetadataHandle = opaque {};
pub const ChannelHandle = opaque {};
pub const UnaryResultHandle = opaque {};

pub const UnaryOptions = extern struct {
    struct_size: usize = @sizeOf(UnaryOptions),
    metadata: ?*const MetadataHandle = null,
    has_timeout: u32 = 0,
    request_compression: u32 = 0,
    timeout_ns: u64 = 0,
    max_response_size: u64 = call.default_max_message_size,
};

const RuntimeStorage = struct {
    value: Runtime,
};

const MetadataStorage = struct {
    value: metadata.Metadata,
};

const ChannelStorage = struct { value: channel.Channel };
const UnaryResultStorage = struct { value: call.Result };

const allocator = std.heap.c_allocator;

pub fn grpc_lite_abi_version() callconv(.c) u32 {
    return (@as(u32, abi_major) << 16) | abi_minor;
}

pub fn grpc_lite_library_version() callconv(.c) [*:0]const u8 {
    return version.string ++ "\x00";
}

pub fn grpc_lite_features() callconv(.c) u64 {
    var features = Feature.raw_unary |
        Feature.streaming |
        Feature.gzip |
        Feature.dns |
        Feature.graceful_server_drain;
    if (build_options.tls) features |= Feature.tls;
    return features;
}

pub fn grpc_lite_error_string(error_code: i32) callconv(.c) [*:0]const u8 {
    const value = std.enums.fromInt(Error, error_code) orelse return "unknown error";
    return switch (value) {
        .ok => "ok",
        .invalid_argument => "invalid argument",
        .invalid_state => "invalid state",
        .out_of_memory => "out of memory",
        .unsupported => "unsupported",
        .unavailable => "unavailable",
        .out_of_range => "out of range",
        .closed => "closed",
        .internal => "internal error",
    };
}

pub fn grpc_lite_runtime_create(out_runtime: ?*?*RuntimeHandle) callconv(.c) Error {
    const output = out_runtime orelse return .invalid_argument;
    output.* = null;
    const storage = allocator.create(RuntimeStorage) catch return .out_of_memory;
    storage.value = Runtime.init() catch |err| {
        allocator.destroy(storage);
        return switch (err) {
            error.RuntimeAlreadyInitialized => .invalid_state,
            error.ResolverInitializationFailed => .unavailable,
            else => .internal,
        };
    };
    output.* = @ptrCast(storage);
    return .ok;
}

pub fn grpc_lite_runtime_destroy(runtime: ?*RuntimeHandle) callconv(.c) void {
    const handle = runtime orelse return;
    const storage: *RuntimeStorage = @ptrCast(@alignCast(handle));
    storage.value.deinit();
    allocator.destroy(storage);
}

pub fn grpc_lite_metadata_create(out_metadata: ?*?*MetadataHandle) callconv(.c) Error {
    const output = out_metadata orelse return .invalid_argument;
    output.* = null;
    const storage = allocator.create(MetadataStorage) catch return .out_of_memory;
    storage.value = metadata.Metadata.init(allocator);
    output.* = @ptrCast(storage);
    return .ok;
}

pub fn grpc_lite_metadata_destroy(metadata_handle: ?*MetadataHandle) callconv(.c) void {
    const handle = metadata_handle orelse return;
    const storage = metadataStorage(handle);
    storage.value.deinit();
    allocator.destroy(storage);
}

pub fn grpc_lite_metadata_add(
    metadata_handle: ?*MetadataHandle,
    key: BytesView,
    value: BytesView,
) callconv(.c) Error {
    const handle = metadata_handle orelse return .invalid_argument;
    const key_bytes = bytes(key) orelse return .invalid_argument;
    const value_bytes = bytes(value) orelse return .invalid_argument;
    metadataStorage(handle).value.append(key_bytes, value_bytes) catch |err| return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.InvalidMetadataKey, error.InvalidMetadataValue => .invalid_argument,
    };
    return .ok;
}

pub fn grpc_lite_metadata_count(metadata_handle: ?*const MetadataHandle) callconv(.c) usize {
    const handle = metadata_handle orelse return 0;
    return metadataStorageConst(handle).value.items().len;
}

pub fn grpc_lite_metadata_at(
    metadata_handle: ?*const MetadataHandle,
    index: usize,
    out_entry: ?*MetadataEntryView,
) callconv(.c) Error {
    const output = out_entry orelse return .invalid_argument;
    output.* = .{};
    const handle = metadata_handle orelse return .invalid_argument;
    const entries = metadataStorageConst(handle).value.items();
    if (index >= entries.len) return .out_of_range;
    output.* = .{
        .key = view(entries[index].key),
        .value = view(entries[index].value),
    };
    return .ok;
}

pub fn grpc_lite_channel_create(
    runtime_handle: ?*RuntimeHandle,
    target: BytesView,
    out_channel: ?*?*ChannelHandle,
) callconv(.c) Error {
    const output = out_channel orelse return .invalid_argument;
    output.* = null;
    const target_bytes = bytes(target) orelse return .invalid_argument;
    const storage = allocator.create(ChannelStorage) catch return .out_of_memory;
    errdefer allocator.destroy(storage);
    storage.value = channel.Channel.init(allocator, target_bytes, .{
        .runtime = if (runtime_handle) |handle| &runtimeStorage(handle).value else null,
    }) catch |err| return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.InvalidTarget => .invalid_argument,
        error.RuntimeRequired, error.RuntimeNotInitialized => .invalid_state,
        else => .unavailable,
    };
    output.* = @ptrCast(storage);
    return .ok;
}

pub fn grpc_lite_channel_destroy(channel_handle: ?*ChannelHandle) callconv(.c) void {
    const handle = channel_handle orelse return;
    const storage = channelStorage(handle);
    storage.value.deinit();
    allocator.destroy(storage);
}

pub fn grpc_lite_channel_call_unary(
    channel_handle: ?*ChannelHandle,
    full_method_path: BytesView,
    request: BytesView,
    options_pointer: ?*const UnaryOptions,
    out_result: ?*?*UnaryResultHandle,
) callconv(.c) Error {
    const output = out_result orelse return .invalid_argument;
    output.* = null;
    const handle = channel_handle orelse return .invalid_argument;
    const method = bytes(full_method_path) orelse return .invalid_argument;
    const request_bytes = bytes(request) orelse return .invalid_argument;
    const options = parseUnaryOptions(options_pointer) orelse return .invalid_argument;

    const storage = allocator.create(UnaryResultStorage) catch return .out_of_memory;
    errdefer allocator.destroy(storage);
    storage.value = channelStorage(handle).value.callUnary(
        allocator,
        method,
        request_bytes,
        options,
    ) catch |err| return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.InvalidMethodPath, error.InvalidMaxResponseSize, error.InvalidMetadataKey, error.InvalidMetadataValue => .invalid_argument,
        else => .internal,
    };
    output.* = @ptrCast(storage);
    return .ok;
}

pub fn grpc_lite_unary_result_destroy(result_handle: ?*UnaryResultHandle) callconv(.c) void {
    const handle = result_handle orelse return;
    const storage = unaryResultStorage(handle);
    storage.value.deinit();
    allocator.destroy(storage);
}

pub fn grpc_lite_unary_result_status_code(result_handle: ?*const UnaryResultHandle) callconv(.c) i32 {
    const handle = result_handle orelse return 2;
    return @intFromEnum(unaryResultStorageConst(handle).value.status.code);
}

pub fn grpc_lite_unary_result_status_message(result_handle: ?*const UnaryResultHandle) callconv(.c) BytesView {
    const handle = result_handle orelse return .{};
    return view(unaryResultStorageConst(handle).value.status.message);
}

pub fn grpc_lite_unary_result_payload(result_handle: ?*const UnaryResultHandle) callconv(.c) BytesView {
    const handle = result_handle orelse return .{};
    return view(unaryResultStorageConst(handle).value.payload);
}

pub fn grpc_lite_unary_result_response_compression(result_handle: ?*const UnaryResultHandle) callconv(.c) u32 {
    const handle = result_handle orelse return 0;
    return @intFromEnum(unaryResultStorageConst(handle).value.response_compression);
}

pub fn grpc_lite_unary_result_metadata_count(result_handle: ?*const UnaryResultHandle, trailing: u32) callconv(.c) usize {
    const handle = result_handle orelse return 0;
    return resultMetadata(unaryResultStorageConst(handle), trailing).items().len;
}

pub fn grpc_lite_unary_result_metadata_at(result_handle: ?*const UnaryResultHandle, trailing: u32, index: usize, out_entry: ?*MetadataEntryView) callconv(.c) Error {
    const output = out_entry orelse return .invalid_argument;
    output.* = .{};
    const handle = result_handle orelse return .invalid_argument;
    const entries = resultMetadata(unaryResultStorageConst(handle), trailing).items();
    if (index >= entries.len) return .out_of_range;
    output.* = .{ .key = view(entries[index].key), .value = view(entries[index].value) };
    return .ok;
}

fn metadataStorage(handle: *MetadataHandle) *MetadataStorage {
    return @ptrCast(@alignCast(handle));
}

fn runtimeStorage(handle: *RuntimeHandle) *RuntimeStorage {
    return @ptrCast(@alignCast(handle));
}

fn channelStorage(handle: *ChannelHandle) *ChannelStorage {
    return @ptrCast(@alignCast(handle));
}

fn unaryResultStorage(handle: *UnaryResultHandle) *UnaryResultStorage {
    return @ptrCast(@alignCast(handle));
}

fn unaryResultStorageConst(handle: *const UnaryResultHandle) *const UnaryResultStorage {
    return @ptrCast(@alignCast(handle));
}

fn resultMetadata(result: *const UnaryResultStorage, trailing: u32) *const metadata.Metadata {
    return if (trailing == 0) &result.value.initial_metadata else &result.value.trailing_metadata;
}

fn parseUnaryOptions(pointer: ?*const UnaryOptions) ?call.Options {
    const value = pointer orelse return .{};
    if (value.struct_size < @sizeOf(UnaryOptions) or value.has_timeout > 1) return null;
    const compression: Compression = switch (value.request_compression) {
        0 => .identity,
        1 => .gzip,
        else => return null,
    };
    if (value.max_response_size > std.math.maxInt(usize)) return null;
    return .{
        .metadata = if (value.metadata) |handle| metadataStorageConst(handle).value.items() else &.{},
        .timeout_ns = if (value.has_timeout == 1) value.timeout_ns else null,
        .max_response_size = @intCast(value.max_response_size),
        .request_compression = compression,
    };
}

fn metadataStorageConst(handle: *const MetadataHandle) *const MetadataStorage {
    return @ptrCast(@alignCast(handle));
}

fn bytes(value: BytesView) ?[]const u8 {
    if (value.size == 0) return &.{};
    const pointer = value.data orelse return null;
    return pointer[0..value.size];
}

fn view(value: []const u8) BytesView {
    return .{
        .data = if (value.len == 0) null else value.ptr,
        .size = value.len,
    };
}

test "C ABI reports version and build features" {
    try std.testing.expectEqual((@as(u32, abi_major) << 16) | abi_minor, grpc_lite_abi_version());
    try std.testing.expectEqualStrings(version.string, std.mem.span(grpc_lite_library_version()));
    try std.testing.expect(grpc_lite_features() & Feature.streaming != 0);
    try std.testing.expectEqualStrings(
        "invalid argument",
        std.mem.span(grpc_lite_error_string(@intFromEnum(Error.invalid_argument))),
    );
    try std.testing.expectEqualStrings("unknown error", std.mem.span(grpc_lite_error_string(-1)));
    try std.testing.expectEqual(2 * @sizeOf(usize), @sizeOf(BytesView));
    try std.testing.expectEqual(@alignOf(usize), @alignOf(BytesView));
    try std.testing.expectEqual(2 * @sizeOf(BytesView), @sizeOf(MetadataEntryView));
}

test "C metadata owns duplicate binary entries" {
    var handle: ?*MetadataHandle = null;
    try std.testing.expectEqual(Error.ok, grpc_lite_metadata_create(&handle));
    defer grpc_lite_metadata_destroy(handle);

    var value = [_]u8{ 0, 1, 2 };
    try std.testing.expectEqual(Error.ok, grpc_lite_metadata_add(
        handle,
        view("trace-bin"),
        view(&value),
    ));
    value[0] = 9;
    try std.testing.expectEqual(Error.ok, grpc_lite_metadata_add(
        handle,
        view("trace-bin"),
        view("second"),
    ));
    try std.testing.expectEqual(@as(usize, 2), grpc_lite_metadata_count(handle));

    var entry: MetadataEntryView = .{};
    try std.testing.expectEqual(Error.ok, grpc_lite_metadata_at(handle, 0, &entry));
    try std.testing.expectEqualStrings("trace-bin", bytes(entry.key).?);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2 }, bytes(entry.value).?);
    try std.testing.expectEqual(Error.out_of_range, grpc_lite_metadata_at(handle, 2, &entry));
}

test "C runtime has deterministic ownership" {
    var handle: ?*RuntimeHandle = null;
    try std.testing.expectEqual(Error.ok, grpc_lite_runtime_create(&handle));
    try std.testing.expect(handle != null);
    var duplicate: ?*RuntimeHandle = @ptrFromInt(1);
    try std.testing.expectEqual(Error.invalid_state, grpc_lite_runtime_create(&duplicate));
    try std.testing.expectEqual(null, duplicate);
    grpc_lite_runtime_destroy(handle);
    grpc_lite_runtime_destroy(null);
}

test "C ABI rejects invalid pointers and clears outputs" {
    try std.testing.expectEqual(Error.invalid_argument, grpc_lite_metadata_create(null));
    var handle: ?*MetadataHandle = null;
    try std.testing.expectEqual(Error.ok, grpc_lite_metadata_create(&handle));
    defer grpc_lite_metadata_destroy(handle);

    try std.testing.expectEqual(Error.invalid_argument, grpc_lite_metadata_add(
        handle,
        .{ .data = null, .size = 1 },
        view("value"),
    ));
    try std.testing.expectEqual(Error.invalid_argument, grpc_lite_metadata_add(
        null,
        view("key"),
        view("value"),
    ));
    try std.testing.expectEqual(Error.invalid_argument, grpc_lite_metadata_at(handle, 0, null));

    var entry: MetadataEntryView = .{
        .key = view("stale"),
        .value = view("stale"),
    };
    try std.testing.expectEqual(Error.out_of_range, grpc_lite_metadata_at(handle, 0, &entry));
    try std.testing.expectEqual(@as(usize, 0), entry.key.size);
    try std.testing.expectEqual(@as(usize, 0), entry.value.size);
    grpc_lite_metadata_destroy(null);
}

test "C unary ABI validates handles and extensible options" {
    var channel_handle: ?*ChannelHandle = @ptrFromInt(1);
    try std.testing.expectEqual(
        Error.invalid_argument,
        grpc_lite_channel_create(null, view("invalid"), &channel_handle),
    );
    try std.testing.expectEqual(null, channel_handle);

    var result_handle: ?*UnaryResultHandle = @ptrFromInt(1);
    try std.testing.expectEqual(
        Error.invalid_argument,
        grpc_lite_channel_call_unary(null, view("/test.Echo/Unary"), view("request"), null, &result_handle),
    );
    try std.testing.expectEqual(null, result_handle);
    try std.testing.expectEqual(@as(i32, 2), grpc_lite_unary_result_status_code(null));
    try std.testing.expectEqual(@as(usize, 0), grpc_lite_unary_result_payload(null).size);
    grpc_lite_channel_destroy(null);
    grpc_lite_unary_result_destroy(null);

    var options: UnaryOptions = .{};
    try std.testing.expect(parseUnaryOptions(&options) != null);
    options.struct_size = 0;
    try std.testing.expectEqual(null, parseUnaryOptions(&options));
    options = .{};
    options.request_compression = 2;
    try std.testing.expectEqual(null, parseUnaryOptions(&options));
}

test "C unary result exposes owned response data" {
    const storage = try allocator.create(UnaryResultStorage);
    storage.value = try call.Result.initWithCompression(
        allocator,
        .init(.permission_denied, "denied"),
        "response",
        .gzip,
    );
    const handle: *UnaryResultHandle = @ptrCast(storage);
    defer grpc_lite_unary_result_destroy(handle);
    try storage.value.initial_metadata.append("x-initial", "one");
    try storage.value.trailing_metadata.append("trace-bin", &.{ 0, 1 });

    try std.testing.expectEqual(@as(i32, 7), grpc_lite_unary_result_status_code(handle));
    try std.testing.expectEqualStrings("denied", bytes(grpc_lite_unary_result_status_message(handle)).?);
    try std.testing.expectEqualStrings("response", bytes(grpc_lite_unary_result_payload(handle)).?);
    try std.testing.expectEqual(@as(u32, 1), grpc_lite_unary_result_response_compression(handle));
    try std.testing.expectEqual(@as(usize, 1), grpc_lite_unary_result_metadata_count(handle, 0));
    try std.testing.expectEqual(@as(usize, 1), grpc_lite_unary_result_metadata_count(handle, 1));

    var entry: MetadataEntryView = .{};
    try std.testing.expectEqual(Error.ok, grpc_lite_unary_result_metadata_at(handle, 1, 0, &entry));
    try std.testing.expectEqualStrings("trace-bin", bytes(entry.key).?);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1 }, bytes(entry.value).?);
}
