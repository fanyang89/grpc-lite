const std = @import("std");
const build_options = @import("grpc_lite_options");
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

const RuntimeStorage = struct {
    value: Runtime,
};

const MetadataStorage = struct {
    value: metadata.Metadata,
};

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

fn metadataStorage(handle: *MetadataHandle) *MetadataStorage {
    return @ptrCast(@alignCast(handle));
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
