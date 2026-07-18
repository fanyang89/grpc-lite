const grpc = @import("grpc_lite");

pub fn main() void {
    _ = grpc.version;
    _ = grpc.Channel;
    _ = grpc.Server;
}
