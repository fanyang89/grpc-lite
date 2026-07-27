#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/grpc-lite-cpp-consumer.XXXXXX")
server_pid=
cleanup() {
    if [[ -n "$server_pid" ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf "$work_dir"
}
trap cleanup EXIT

zig build --prefix "$work_dir/stage"
cmake \
    -S "$project_root/tests/consumer/cpp" \
    -B "$work_dir/build" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$work_dir/stage"
cmake --build "$work_dir/build"
"$work_dir/build/grpc_lite_cpp_consumer"

port=$((30000 + $$ % 20000))
"$work_dir/stage/bin/grpc-lite-echo-server" "$port" >"$work_dir/server.log" 2>&1 &
server_pid=$!
for _ in {1..50}; do
    [[ -s "$work_dir/server.log" ]] && break
    sleep 0.02
done
[[ -s "$work_dir/server.log" ]]
"$work_dir/build/grpc_lite_cpp_consumer" "127.0.0.1:$port"
