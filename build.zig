const std = @import("std");
const protobuf_build = @import("protobuf");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const protobuf_dependency = b.dependency("protobuf", .{
        .target = target,
        .optimize = optimize,
    });

    const generate_proto = protobuf_build.RunProtocStep.create(
        protobuf_dependency.builder,
        target,
        .{
            .destination_directory = b.path(".zig-cache/generated"),
            .source_files = &.{b.path("proto/echo.proto")},
            .include_directories = &.{b.path("proto")},
        },
    );
    const generate_proto_step = b.step("gen-proto", "Generate Zig protobuf sources");
    generate_proto_step.dependOn(&generate_proto.step);

    const protobuf = protobuf_dependency.module("protobuf");
    const demo_proto = b.createModule(.{
        .root_source_file = b.path(".zig-cache/generated/demo.pb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "protobuf", .module = protobuf }},
    });

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

    const grpc_lite_protobuf = b.addModule("grpc_lite_protobuf", .{
        .root_source_file = b.path("src/protobuf_adapter.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "grpc_lite", .module = grpc_lite },
            .{ .name = "protobuf", .module = protobuf },
        },
    });

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

    const protobuf_tests = b.addTest(.{
        .name = "protobuf-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/protobuf_codegen_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "demo_proto", .module = demo_proto }},
        }),
    });
    protobuf_tests.step.dependOn(&generate_proto.step);
    const run_protobuf_tests = b.addRunArtifact(protobuf_tests);

    const protobuf_adapter_tests = b.addTest(.{
        .name = "protobuf-adapter",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/protobuf_adapter_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "grpc_lite", .module = grpc_lite },
                .{ .name = "grpc_lite_protobuf", .module = grpc_lite_protobuf },
                .{ .name = "demo_proto", .module = demo_proto },
            },
        }),
    });
    protobuf_adapter_tests.step.dependOn(&generate_proto.step);
    protobuf_adapter_tests.step.dependOn(native_deps);
    const run_protobuf_adapter_tests = b.addRunArtifact(protobuf_adapter_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_protobuf_tests.step);
    test_step.dependOn(&run_protobuf_adapter_tests.step);

    const echo_server = addExample(
        b,
        "grpc-lite-echo-server",
        "examples/echo_server.zig",
        grpc_lite,
        native_deps,
    );
    const echo_client = addExample(
        b,
        "grpc-lite-echo-client",
        "examples/echo_client.zig",
        grpc_lite,
        native_deps,
    );
    b.installArtifact(echo_server);
    b.installArtifact(echo_client);
}

fn addExample(
    b: *std.Build,
    name: []const u8,
    source: []const u8,
    grpc_lite: *std.Build.Module,
    native_deps: *std.Build.Step,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path(source),
        .target = grpc_lite.resolved_target,
        .optimize = grpc_lite.optimize,
        .imports = &.{.{ .name = "grpc_lite", .module = grpc_lite }},
    });
    const executable = b.addExecutable(.{
        .name = name,
        .root_module = module,
    });
    executable.step.dependOn(native_deps);
    return executable;
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
        "-DCMAKE_C_FLAGS=-fno-sanitize=undefined",
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
        "-DCMAKE_C_FLAGS=-fno-sanitize=undefined",
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
