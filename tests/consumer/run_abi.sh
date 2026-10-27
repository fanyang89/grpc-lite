#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$project_root"
temporary="${TMPDIR:-$HOME/tmp}/opencode"
mkdir -p "$temporary"
work_dir=$(mktemp -d "$temporary/grpc-lite-abi-consumer.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

zig build install-c-sdk -Dprotobuf=false -Doptimize=ReleaseSafe --prefix "$work_dir/stage"
python3 -B tools/check_c_abi.py \
    --include "$work_dir/stage/include" \
    --library "$work_dir/stage/lib/libgrpc_lite.so.1"
python3 -B tests/check_c_abi_test.py

# No current include path: the consumer sees only the released header snapshot.
read -r -a compiler <<< "${CC:-cc}"
"${compiler[@]}" -std=c11 -Wall -Wextra -Werror -pthread \
    -I tests/consumer/abi/baseline tests/consumer/abi/consumer.c \
    -L "$work_dir/stage/lib" -Wl,-rpath,"$work_dir/stage/lib" \
    -l:libgrpc_lite.so.1 -o "$work_dir/consumer"
# Force eager symbol binding and the freshly built shared library, never a system
# installation or a static archive. The timeout also bounds runtime init/shutdown.
LD_BIND_NOW=1 LD_LIBRARY_PATH="$work_dir/stage/lib" timeout 60 "$work_dir/consumer"
