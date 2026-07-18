const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const grpc_lite = b.addModule("grpc_lite", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    grpc_lite.addIncludePath(b.path("third_party/libuv/include"));
    grpc_lite.addIncludePath(b.path("third_party/nghttp2/lib/includes"));
    grpc_lite.addObjectFile(b.path(".zig-cache/native/libuv/libuv.a"));
    grpc_lite.addObjectFile(b.path(".zig-cache/native/nghttp2/lib/libnghttp2.a"));

    if (target.result.os.tag == .linux) {
        grpc_lite.linkSystemLibrary("pthread", .{});
        grpc_lite.linkSystemLibrary("dl", .{});
        grpc_lite.linkSystemLibrary("rt", .{});
    }

    const native_deps = addNativeDependencies(b);

    const library = b.addLibrary(.{
        .name = "grpc_lite",
        .root_module = grpc_lite,
    });
    library.step.dependOn(native_deps);
    b.installArtifact(library);

    const unit_tests = b.addTest(.{
        .root_module = grpc_lite,
    });
    unit_tests.step.dependOn(native_deps);
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

fn addNativeDependencies(b: *std.Build) *std.Build.Step {
    const native_deps = b.step("native-deps", "Build native dependencies");
    const cc = b.fmt("{s} cc", .{b.graph.zig_exe});

    const configure_libuv = b.addSystemCommand(&.{
        "cmake",
        "-S",
        "third_party/libuv",
        "-B",
        ".zig-cache/native/libuv",
        "-G",
        "Ninja",
        "-DCMAKE_BUILD_TYPE=Debug",
        "-DBUILD_SHARED_LIBS=OFF",
        "-DLIBUV_BUILD_SHARED=OFF",
        "-DLIBUV_BUILD_TESTS=OFF",
        "-DLIBUV_BUILD_BENCH=OFF",
    });
    configure_libuv.setEnvironmentVariable("CC", cc);

    const build_libuv = b.addSystemCommand(&.{
        "cmake",
        "--build",
        ".zig-cache/native/libuv",
    });
    build_libuv.step.dependOn(&configure_libuv.step);

    const configure_nghttp2 = b.addSystemCommand(&.{
        "cmake",
        "-S",
        "third_party/nghttp2",
        "-B",
        ".zig-cache/native/nghttp2",
        "-G",
        "Ninja",
        "-DCMAKE_BUILD_TYPE=Debug",
        "-DENABLE_LIB_ONLY=ON",
        "-DENABLE_APP=OFF",
        "-DENABLE_EXAMPLES=OFF",
        "-DENABLE_HPACK_TOOLS=OFF",
        "-DENABLE_DOC=OFF",
        "-DBUILD_TESTING=OFF",
        "-DBUILD_SHARED_LIBS=OFF",
        "-DBUILD_STATIC_LIBS=ON",
    });
    configure_nghttp2.setEnvironmentVariable("CC", cc);

    const build_nghttp2 = b.addSystemCommand(&.{
        "cmake",
        "--build",
        ".zig-cache/native/nghttp2",
    });
    build_nghttp2.step.dependOn(&configure_nghttp2.step);

    native_deps.dependOn(&build_libuv.step);
    native_deps.dependOn(&build_nghttp2.step);
    return native_deps;
}
