#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/grpc-lite-raw-consumer.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

archive="$work_dir/grpc-lite.tar.gz"
consumer="$work_dir/consumer"
global_cache="$work_dir/global-cache"
mkdir -p "$consumer/src" "$global_cache/p"

source "$project_root/tests/consumer/zig_common.sh"
prefetch_native_packages
prefetch_url_package \
    'https://codeload.github.com/fanyang89/gperftools/tar.gz/1a01cd2cf8f7000845d343fa8e0bbac70378858b' \
    'N-V-__8AAGKVkABvsDVHhSU8seHKvtJ8Q23b9Y0OMiFVWt-y' \
    'gperftools.tar.gz'

package_worktree

cp "$project_root/tests/consumer/raw/build.zig" "$consumer/build.zig"
cp "$project_root/tests/consumer/raw/src/main.zig" "$consumer/src/main.zig"
cp "$project_root/tests/consumer/raw/src/gperftools.zig" "$consumer/src/gperftools.zig"
cat >"$consumer/build.zig.zon" <<EOF
.{
    .name = .grpc_lite_raw_consumer,
    .version = "0.0.0",
    .minimum_zig_version = "0.17.0",
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
/usr/bin/timeout --kill-after=2s 30s "$consumer/zig-out/bin/grpc-lite-raw-consumer"
ZIG_GLOBAL_CACHE_DIR="$global_cache" zig build --build-file "$consumer/build.zig" \
    -Doptimize=ReleaseSafe --summary all
/usr/bin/timeout --kill-after=2s 30s "$consumer/zig-out/bin/grpc-lite-raw-consumer"
ZIG_GLOBAL_CACHE_DIR="$global_cache" zig build --build-file "$consumer/build.zig" \
    -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe \
    -Dsanitize-thread=true -Dsanitize-c=false --summary all
ZIG_GLOBAL_CACHE_DIR="$global_cache" zig build --build-file "$consumer/build.zig" \
    -Doptimize=Debug -Dsanitize-thread=false -Dsanitize-c=true --summary all
wolfssl_path="$consumer/zig-pkg/N-V-__8AAM2AGgrmA8dlFOS4GWaTOEXwdZvSYXeSgZpe09he"
if [[ -e "$wolfssl_path" || -L "$wolfssl_path" ]]; then
    printf '%s\n' 'raw consumer unexpectedly resolved optional wolfSSL' >&2
    exit 1
fi
prefetch_url_package \
    'https://codeload.github.com/wolfSSL/wolfssl/tar.gz/3c5eead44904df64e6a5a1f4ebdce377d35a849a' \
    'N-V-__8AAM2AGgrmA8dlFOS4GWaTOEXwdZvSYXeSgZpe09he' \
    'wolfssl.tar.gz'
ZIG_GLOBAL_CACHE_DIR="$global_cache" zig build --build-file "$consumer/build.zig" \
    -Dtls=true --summary all
/usr/bin/timeout --kill-after=2s 30s "$consumer/zig-out/bin/grpc-lite-raw-consumer"
ZIG_GLOBAL_CACHE_DIR="$global_cache" zig build --build-file "$consumer/build.zig" \
    -Doptimize=ReleaseFast -Dgperftools=true --summary all
"$consumer/zig-out/bin/grpc-lite-raw-consumer"

if find "$consumer/zig-pkg" -maxdepth 1 -name 'protobuf-*' -print -quit | grep -q .; then
    printf '%s\n' 'raw -Dprotobuf=false consumer unexpectedly resolved zig-protobuf' >&2
    exit 1
fi
grpc_proto_path="$consumer/zig-pkg/N-V-__8AAMvUAgBnxziu_Kuqr4AuJ00Vke6R0R-Rc1A26DRX"
if [[ -e "$grpc_proto_path" || -L "$grpc_proto_path" ]]; then
    printf '%s\n' 'raw consumer unexpectedly resolved grpc-proto' >&2
    exit 1
fi
