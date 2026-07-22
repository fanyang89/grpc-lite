#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/grpc-lite-raw-consumer.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

archive="$work_dir/grpc-lite.tar.gz"
consumer="$work_dir/consumer"
global_cache="$work_dir/global-cache"
mkdir -p "$consumer/src" "$global_cache"

prefetch_package() {
    local url=$1
    local expected_hash=$2
    local archive_name=$3
    local dependency_archive="$work_dir/$archive_name"

    curl --fail --location --silent --show-error --output "$dependency_archive" "$url"
    local actual_hash
    actual_hash=$(ZIG_GLOBAL_CACHE_DIR="$global_cache" zig fetch "$dependency_archive")
    if [[ "$actual_hash" != "$expected_hash" ]]; then
        printf 'package hash mismatch for %s: expected %s, got %s\n' \
            "$archive_name" "$expected_hash" "$actual_hash" >&2
        exit 1
    fi
}

prefetch_package \
    'https://codeload.github.com/libuv/libuv/tar.gz/1cfa32ff59c076ffb6ed735bbc8c18361558661f' \
    'N-V-__8AACwTRQDmmfDj0GPrcObUmVnktArTdpjkEvRZXTx0' \
    'libuv.tar.gz'
prefetch_package \
    'https://codeload.github.com/nghttp2/nghttp2/tar.gz/68cb6900fde14c77f0cd7add0e094a862960eb99' \
    'N-V-__8AAPOqVwAHvwAVJJjhhX72DyDtjWw--9WUZf3-uKRX' \
    'nghttp2.tar.gz'

git -C "$project_root" archive --format=tar.gz --output="$archive" HEAD
package_hash=$(ZIG_GLOBAL_CACHE_DIR="$global_cache" zig fetch "$archive")

cp "$project_root/tests/consumer/raw/build.zig" "$consumer/build.zig"
cp "$project_root/tests/consumer/raw/src/main.zig" "$consumer/src/main.zig"
cat >"$consumer/build.zig.zon" <<EOF
.{
    .name = .grpc_lite_raw_consumer,
    .version = "0.0.0",
    .minimum_zig_version = "0.16.0",
    .fingerprint = 0x7b2e24f38b336dd0,
    .dependencies = .{
        .grpc_lite = .{
            .url = "file://$archive",
            .hash = "$package_hash",
        },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
EOF

ZIG_GLOBAL_CACHE_DIR="$global_cache" zig build --build-file "$consumer/build.zig" --summary all
ZIG_GLOBAL_CACHE_DIR="$global_cache" zig build --build-file "$consumer/build.zig" \
    -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe \
    -Dsanitize-thread=true -Dsanitize-c=false --summary all
ZIG_GLOBAL_CACHE_DIR="$global_cache" zig build --build-file "$consumer/build.zig" \
    -Doptimize=Debug -Dsanitize-thread=false -Dsanitize-c=true --summary all

protobuf_path="$consumer/zig-pkg/protobuf-5.0.0-0e82avKUKAAVwTWJzTIEZ14Fu0zC11_lElR8tE6H__y1"
if [[ -e "$protobuf_path" || -L "$protobuf_path" ]]; then
    printf '%s\n' 'raw consumer unexpectedly resolved zig-protobuf' >&2
    exit 1
fi
