//! Leak-checking allocator for concurrent allocation tests.
const std = @import("std");
const builtin = @import("builtin");

pub fn init() std.heap.SafeAllocator {
    return .init(if (builtin.sanitize_thread) .{
        .ptr = std.heap.page_allocator.ptr,
        .vtable = &tsan_vtable,
    } else std.heap.page_allocator, .{});
}

// Zig 0.17's TSan intercepts mmap/munmap, but not mremap. Moving a mapping
// leaves stale shadow memory and reports races between unrelated allocations.
// Declining remap uses the normal allocate/copy/free fallback, without hiding
// accesses from TSan or changing the production allocator.
const tsan_vtable: std.mem.Allocator.VTable = blk: {
    var vtable = std.heap.page_allocator.vtable.*;
    vtable.remap = noRemap;
    break :blk vtable;
};

fn noRemap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
    return null;
}

test "concurrent independent buffers retain contents while growing" {
    const Worker = struct {
        fn run(allocator: std.mem.Allocator) void {
            for (0..64) |_| {
                var bytes: std.ArrayList(u8) = .empty;
                defer bytes.deinit(allocator);
                for (0..32) |i| {
                    const chunk: [4096]u8 = @splat(@intCast(i));
                    bytes.appendSlice(allocator, &chunk) catch @panic("out of memory");
                }
                for (bytes.items, 0..) |byte, i| {
                    std.debug.assert(byte == i / 4096);
                }
            }
        }
    };
    var state = init();
    defer std.testing.expectEqual(@as(usize, 0), state.deinit()) catch @panic("test allocator leak");
    const first = try std.Thread.spawn(.{}, Worker.run, .{state.allocator()});
    defer first.join();
    const second = try std.Thread.spawn(.{}, Worker.run, .{state.allocator()});
    defer second.join();
}
