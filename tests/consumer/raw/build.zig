const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sanitize_thread = b.option(bool, "sanitize-thread", "Enable ThreadSanitizer") orelse false;
    const sanitize_c = b.option(bool, "sanitize-c", "Enable C undefined behavior detection") orelse false;
    const grpc_lite = b.dependency("grpc_lite", .{
        .target = target,
        .optimize = optimize,
        .@"sanitize-thread" = sanitize_thread,
        .@"sanitize-c" = sanitize_c,
    });
    const executable = b.addExecutable(.{
        .name = "grpc-lite-raw-consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
            .sanitize_c = if (sanitize_c) .full else .off,
            .omit_frame_pointer = if (sanitize_thread or sanitize_c) false else null,
            .imports = &.{.{ .name = "grpc_lite", .module = grpc_lite.module("grpc_lite") }},
        }),
    });
    b.installArtifact(executable);
}
