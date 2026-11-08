#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
temp_root="${TMPDIR:-$HOME/tmp}/opencode"
mkdir -p "$temp_root"
work_dir=$(mktemp -d "$temp_root/grpc-lite-typed-consumer.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
archive="$work_dir/grpc-lite.tar.gz"
consumer="$work_dir/consumer"
global_cache="$work_dir/global-cache"
mkdir -p "$consumer/src" "$consumer/proto" "$global_cache/p"

source "$project_root/tests/consumer/zig_common.sh"
prefetch_native_packages
prefetch_url_package \
    'https://codeload.github.com/lalinsky/zio/tar.gz/c5716c4698a7a25be4390812804638e9fb37cdd0' \
    'zio-0.19.0-xHbVVAbeLgAuWEhoWtYJBuh7fO9e6_EIUFT-SasjLG-a' \
    'zio.tar.gz'
prefetch_url_package \
    'https://github.com/Arwalk/zig-protobuf/archive/e9e18c7664b8c950e5fc679259c968dd66ccc48b.tar.gz' \
    'protobuf-7.0.0-0e82aqFhNADVgEgPYPI7ddEg_dzhphBToYgkjQTrMKWv' \
    'protobuf.tar.gz'
prefetch_url_package \
    'https://codeload.github.com/grpc/grpc-proto/tar.gz/99135b19189588fcc787acb84cff27991787473d' \
    'N-V-__8AAMvUAgBnxziu_Kuqr4AuJ00Vke6R0R-Rc1A26DRX' \
    'grpc-proto.tar.gz'

# Normally leave protoc uncached to exercise lazy dependency resolution. An
# explicit local archive supports environments where Zig's HTTP fetch fails.
if [[ -n "${GRPC_LITE_PROTOC_ARCHIVE:-}" ]]; then
    case $(uname -m) in
        x86_64) protoc_arch=x86_64 ;;
        aarch64|arm64) protoc_arch=aarch_64 ;;
        *) printf 'unsupported protoc host architecture: %s\n' "$(uname -m)" >&2; exit 1 ;;
    esac
    protoc_hash=$(python3 - "$global_cache/p/protobuf-7.0.0-0e82aqFhNADVgEgPYPI7ddEg_dzhphBToYgkjQTrMKWv/build.zig.zon" "$protoc_arch" <<'PY'
from pathlib import Path
import re
import sys

manifest = Path(sys.argv[1]).read_text()
entry = re.search(r'\.@"protoc-linux-' + sys.argv[2] + r'"\s*=\s*\.\{(.*?)\}', manifest, re.S)
if entry is None:
    raise SystemExit("host protoc dependency not found")
print(re.search(r'\.hash\s*=\s*"([^"]+)"', entry[1])[1])
PY
    )
    actual_hash=$(ZIG_GLOBAL_CACHE_DIR="$global_cache" zig fetch "$GRPC_LITE_PROTOC_ARCHIVE")
    if [[ "$actual_hash" != "$protoc_hash" ]]; then
        printf 'protoc package hash mismatch: expected %s, got %s\n' "$protoc_hash" "$actual_hash" >&2
        exit 1
    fi
fi

package_worktree
# Compile the tutorial's actual build file, rather than a second copy that can
# drift. Inputs come from the source snapshot; no generated code is copied.
python3 - "$package_source" "$consumer" <<'PY'
from pathlib import Path
import re
import shutil
import sys

package, consumer = map(Path, sys.argv[1:])
blocks = re.findall(r"```zig\n(.*?)\n```", (package / "docs/zig-async.md").read_text(), re.S)
builds = [block for block in blocks if 'const grpc_build = @import("grpc_lite");' in block]
if len(builds) != 1:
    raise SystemExit("expected exactly one standalone build.zig in docs/zig-async.md")
(consumer / "build.zig").write_text(builds[0] + "\n")
shutil.copy2(package / "examples/zio_typed.zig", consumer / "src/main.zig")
shutil.copy2(package / "proto/echo.proto", consumer / "proto/echo.proto")
PY
cat >"$consumer/build.zig.zon" <<EOF
.{
    .name = .grpc_lite_typed_consumer,
    .version = "0.0.0",
    .fingerprint = 0x4a65243371713683,
    .minimum_zig_version = "0.17.0",
    .dependencies = .{
        .grpc_lite = .{ .url = "file://$archive", .hash = "$package_hash" },
        .zio = .{
            .url = "https://codeload.github.com/lalinsky/zio/tar.gz/c5716c4698a7a25be4390812804638e9fb37cdd0",
            .hash = "zio-0.19.0-xHbVVAbeLgAuWEhoWtYJBuh7fO9e6_EIUFT-SasjLG-a",
        },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src", "proto" },
}
EOF

for optimize in Debug ReleaseSafe; do
    ZIG_GLOBAL_CACHE_DIR="$global_cache" zig build --build-file "$consumer/build.zig" \
        -Doptimize="$optimize" --summary all
    /usr/bin/timeout --kill-after=2s 30s "$consumer/zig-out/bin/typed-task-echo"
done
printf '%s\n' 'PASS typed task package consumer: documented build, generated protobuf, unary and all streaming cardinalities'
