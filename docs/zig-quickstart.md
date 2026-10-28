---
title: Zig quickstart
description: Add grpc-lite to your application, generate protobuf code, and run a typed RPC.
---

# Zig quickstart

This guide builds a standalone Zig application. It starts a typed Echo server and
client in one process, performs a real loopback RPC, and shuts both down.

## 1. Add grpc-lite to your project

Use Zig **0.17.0** on Linux x86_64 or ARM64, with CMake, Ninja, and a POSIX shell
available on `PATH`. The build compiles the native C dependencies for you. The first
build needs network access to fetch dependencies, including the protobuf generator
and its protoc package. Runtime execution requires permission to use Linux io_uring.

In a new directory:

```sh
mkdir echo-app
cd echo-app
zig init
zig fetch --save=grpc_lite https://github.com/fanyang89/grpc-lite/archive/d64dc5e653c2a57bd34ee9a34a7b6ae7487b32fd.tar.gz
```

The URL pins the source revision used by this guide. `zig fetch` records the dependency
and its content hash in `build.zig.zon`; commit that file with your application.
For an existing project, run only the fetch command from its root.

If Zig's HTTP fetch fails with `HttpConnectionClosing`, download the same archive
with curl, then let Zig compute and record its package hash:

```sh
curl -fL https://github.com/fanyang89/grpc-lite/archive/d64dc5e653c2a57bd34ee9a34a7b6ae7487b32fd.tar.gz -o grpc-lite.tar.gz
zig fetch --save=grpc_lite ./grpc-lite.tar.gz
```

For a portable dependency declaration, replace the resulting local archive URL in
`build.zig.zon` with the HTTPS URL above, keeping the generated `.hash` unchanged.

The dependency is obtained with `b.dependency("grpc_lite", .{ .target = target,
.optimize = optimize, .protobuf = true })`. Typed applications use three modules:

| Import | Purpose |
| --- | --- |
| `grpc_lite` | Channel, Server, status and transport lifecycle |
| `grpc_lite_protobuf` | Typed service registration and client adapters |
| `grpc_lite_protobuf_runtime` | Runtime imported as `protobuf` by generated code |

The complete build file below wires all three together. For raw-byte applications,
set `.protobuf = false` and import only `grpc_lite`.

## 2. Define your service

Create `proto/echo.proto`:

```proto
syntax = "proto3";
package demo;

message EchoRequest { string message = 1; }
message EchoReply { string message = 1; }

service EchoService {
  rpc Echo(EchoRequest) returns (EchoReply);
}
```

## 3. Generate code in your build

Replace `build.zig` with:

```zig
const std = @import("std");
const grpc_build = @import("grpc_lite");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const grpc = b.dependency("grpc_lite", .{
        .target = target,
        .optimize = optimize,
        .protobuf = true,
    });
    const generated = grpc_build.createProtocStep(grpc, target, optimize, .{
        .source_files = &.{b.path("proto/echo.proto")},
        .include_directories = &.{b.path("proto")},
        .destination_directory = b.path(".zig-cache/echo-proto"),
    }) orelse return;
    const proto = b.createModule(.{
        .root_source_file = b.path(".zig-cache/echo-proto/demo.pb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{
            .name = "protobuf",
            .module = grpc.module("grpc_lite_protobuf_runtime"),
        }},
    });
    const exe = b.addExecutable(.{
        .name = "echo-app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "grpc_lite", .module = grpc.module("grpc_lite") },
                .{ .name = "grpc_lite_protobuf", .module = grpc.module("grpc_lite_protobuf") },
                .{ .name = "demo_proto", .module = proto },
            },
        }),
    });
    exe.step.dependOn(generated.step);
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    b.step("run", "Run the typed Echo example").dependOn(&run.step);
}
```

Generation runs before compilation. The generator groups output by protobuf package:
`package demo` produces `demo.pb.zig`. Keep generated files under `.zig-cache`, not
in version control. `orelse return` lets Zig resolve the lazy code-generation dependency.

## 4. Implement the typed server and client

Replace `src/main.zig` with:

```zig
const std = @import("std");
const grpc = @import("grpc_lite");
const grpc_pb = @import("grpc_lite_protobuf");
const demo = @import("demo_proto");

const AppError = error{OutOfMemory};
const State = struct {
    allocator: std.mem.Allocator,

    fn echo(self: *State, request: demo.EchoRequest) AppError!demo.EchoReply {
        return .{ .message = try self.allocator.dupe(u8, request.message) };
    }
};
const EchoApi = demo.EchoService(State, AppError);

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var state = State{ .allocator = allocator };
    var registration = grpc_pb.ServiceRegistration(EchoApi).init(
        allocator,
        &state,
        .{ .Echo = State.echo },
        .{},
    );
    defer registration.deinit();

    var server = try grpc.Server.init(allocator, .{});
    defer server.deinit();
    try registration.register(&server);
    try server.start();

    var address: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&address, "127.0.0.1:{d}", .{try server.port()});
    var channel = try grpc.Channel.init(allocator, target, .{});
    defer channel.deinit();
    var client = grpc_pb.ServiceClient(EchoApi).init(&channel);
    var result = try client.callUnary(
        allocator,
        "Echo",
        demo.EchoRequest{ .message = "hello" },
        .{},
    );
    defer result.deinit();
    if (!result.raw.status.isOk()) return error.RpcFailed;
    std.debug.print("Echo: {s}\n", .{result.response.?.message});
}
```

The generated service supplies the message types and method descriptors. The adapters
handle serialization and the `/demo.EchoService/Echo` path; you implement the handler
and call the client with typed messages.

Request fields are borrowed during the handler. The handler returns an owned response
allocated with the registration allocator; the adapter releases it after encoding.
Keep state and registration alive at stable addresses until the Server is destroyed.
The `defer` order above destroys the result, Channel and Server before registration.
Transport callbacks must not block.

## 5. Build and run

```sh
zig build
zig build run
```

Expected output: `Echo: hello`. The server chooses an available local port. A separate
client process instead connects its Channel to your server's address. Hostnames require
a [Runtime](zig-api.md#runtime-and-channels); this IPv4 loopback example does not.

Continue with [typed streaming](zig-api.md#protobuf), [TLS](zig-api.md#tls), and
[resource limits](resource-limits.md) when extending your application.
