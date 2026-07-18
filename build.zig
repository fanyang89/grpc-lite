const std = @import("std");
const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const libuv_dependency = b.dependency("libuv", .{});
    const nghttp2_dependency = b.dependency("nghttp2", .{});
    const enable_protobuf = b.option(
        bool,
        "protobuf",
        "Enable the typed protobuf adapter, examples, and tests",
    ) orelse (b.pkg_hash.len == 0);
    const grpc_lite_options = b.addOptions();
    grpc_lite_options.addOption([]const u8, "version", manifest.version);
    const native = addNativeDependencies(
        b,
        libuv_dependency.path(""),
        nghttp2_dependency.path(""),
        optimize,
    );

    const grpc_lite = b.addModule("grpc_lite", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    grpc_lite.addOptions("grpc_lite_options", grpc_lite_options);
    grpc_lite.addIncludePath(libuv_dependency.path("include"));
    grpc_lite.addIncludePath(nghttp2_dependency.path("lib/includes"));
    grpc_lite.addIncludePath(native.nghttp2_include);
    grpc_lite.addObjectFile(native.libuv_archive);
    grpc_lite.addObjectFile(native.nghttp2_archive);

    if (target.result.os.tag == .linux) {
        grpc_lite.linkSystemLibrary("pthread", .{});
        grpc_lite.linkSystemLibrary("dl", .{});
        grpc_lite.linkSystemLibrary("rt", .{});
    }

    const library = b.addLibrary(.{
        .name = "grpc_lite",
        .root_module = grpc_lite,
    });
    b.installArtifact(library);

    const unit_tests = b.addTest(.{
        .root_module = grpc_lite,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const public_api_tests = b.addTest(.{
        .name = "public-api",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/public_api_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "grpc_lite", .module = grpc_lite }},
        }),
    });
    const run_public_api_tests = b.addRunArtifact(public_api_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_public_api_tests.step);

    if (!enable_protobuf) return;
    const protobuf_build = b.lazyImport(@This(), "protobuf") orelse return;
    const protobuf_dependency = b.lazyDependency("protobuf", .{
        .target = target,
        .optimize = optimize,
    }) orelse return;
    addProtobufSupport(
        b,
        protobuf_build,
        protobuf_dependency,
        grpc_lite,
        test_step,
        target,
        optimize,
    );
}

fn addProtobufSupport(
    b: *std.Build,
    comptime protobuf_build: type,
    protobuf_dependency: *std.Build.Dependency,
    grpc_lite: *std.Build.Module,
    test_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
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

    const generate_interop_proto = protobuf_build.RunProtocStep.create(
        protobuf_dependency.builder,
        target,
        .{
            .destination_directory = b.path(".zig-cache/generated-interop"),
            .source_files = &.{
                b.path("third_party/grpc-proto/grpc/testing/empty.proto"),
                b.path("third_party/grpc-proto/grpc/testing/messages.proto"),
                b.path("third_party/grpc-proto/grpc/testing/test.proto"),
            },
            .include_directories = &.{b.path("third_party/grpc-proto")},
        },
    );
    const generate_interop_proto_step = b.step(
        "gen-interop-proto",
        "Generate official gRPC interop protobuf sources",
    );
    generate_interop_proto_step.dependOn(&generate_interop_proto.step);

    const protobuf = protobuf_dependency.module("protobuf");
    const demo_proto = b.createModule(.{
        .root_source_file = b.path(".zig-cache/generated/demo.pb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "protobuf", .module = protobuf }},
    });
    const interop_proto = b.createModule(.{
        .root_source_file = b.path(".zig-cache/generated-interop/grpc/testing.pb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "protobuf", .module = protobuf }},
    });
    const grpc_lite_protobuf = b.addModule("grpc_lite_protobuf", .{
        .root_source_file = b.path("src/protobuf_adapter.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "grpc_lite", .module = grpc_lite },
            .{ .name = "protobuf", .module = protobuf },
        },
    });

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
    const run_protobuf_adapter_tests = b.addRunArtifact(protobuf_adapter_tests);

    const official_proto_tests = b.addTest(.{
        .name = "official-protobuf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/official/protobuf_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "grpc_testing", .module = interop_proto }},
        }),
    });
    official_proto_tests.step.dependOn(&generate_interop_proto.step);
    const run_official_proto_tests = b.addRunArtifact(official_proto_tests);

    test_step.dependOn(&run_protobuf_tests.step);
    test_step.dependOn(&run_protobuf_adapter_tests.step);
    test_step.dependOn(&run_official_proto_tests.step);

    const echo_server = addExample(b, "grpc-lite-echo-server", "examples/echo_server.zig", grpc_lite);
    echo_server.root_module.addImport("grpc_lite_protobuf", grpc_lite_protobuf);
    echo_server.root_module.addImport("demo_proto", demo_proto);
    echo_server.step.dependOn(&generate_proto.step);
    const echo_client = addExample(b, "grpc-lite-echo-client", "examples/echo_client.zig", grpc_lite);
    echo_client.root_module.addImport("grpc_lite_protobuf", grpc_lite_protobuf);
    echo_client.root_module.addImport("demo_proto", demo_proto);
    echo_client.step.dependOn(&generate_proto.step);
    b.installArtifact(echo_server);
    b.installArtifact(echo_client);

    const interop_server = addExample(
        b,
        "grpc-lite-interop-server",
        "tests/official/interop_server.zig",
        grpc_lite,
    );
    interop_server.root_module.addImport("grpc_testing", interop_proto);
    interop_server.step.dependOn(&generate_interop_proto.step);
    const interop_client = addExample(
        b,
        "grpc-lite-interop-client",
        "tests/official/interop_client.zig",
        grpc_lite,
    );
    interop_client.root_module.addImport("grpc_testing", interop_proto);
    interop_client.step.dependOn(&generate_interop_proto.step);
    b.installArtifact(interop_server);
    b.installArtifact(interop_client);
}

fn addExample(
    b: *std.Build,
    name: []const u8,
    source: []const u8,
    grpc_lite: *std.Build.Module,
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
    return executable;
}

const NativeDependencies = struct {
    libuv_archive: std.Build.LazyPath,
    nghttp2_archive: std.Build.LazyPath,
    nghttp2_include: std.Build.LazyPath,
};

fn addNativeDependencies(
    b: *std.Build,
    libuv_source_dir: std.Build.LazyPath,
    nghttp2_source_dir: std.Build.LazyPath,
    optimize: std.builtin.OptimizeMode,
) NativeDependencies {
    const cc = b.fmt("{s} cc", .{b.graph.zig_exe});
    const cmake_build_type = switch (optimize) {
        .Debug => "Debug",
        .ReleaseSafe => "RelWithDebInfo",
        .ReleaseFast, .ReleaseSmall => "Release",
    };

    const build_libuv = addNativeBuild(
        b,
        "libuv",
        libuv_source_dir,
        cmake_build_type,
        cc,
    );
    const build_nghttp2 = addNativeBuild(
        b,
        "nghttp2",
        nghttp2_source_dir,
        cmake_build_type,
        cc,
    );

    return .{
        .libuv_archive = build_libuv.path(b, "libuv.a"),
        .nghttp2_archive = build_nghttp2.path(b, "lib/libnghttp2.a"),
        .nghttp2_include = build_nghttp2.path(b, "lib/includes"),
    };
}

fn addNativeBuild(
    b: *std.Build,
    name: []const u8,
    source_dir: std.Build.LazyPath,
    cmake_build_type: []const u8,
    cc: []const u8,
) std.Build.LazyPath {
    const run = b.addSystemCommand(&.{"bash"});
    run.addFileArg(b.path("tools/build_native.sh"));
    run.addArg(name);
    run.addDirectoryArg(source_dir);
    const output = run.addOutputDirectoryArg(name);
    run.addArgs(&.{ cmake_build_type, cc });
    return output;
}
