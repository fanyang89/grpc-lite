#!/usr/bin/env bash
set -euo pipefail

input=$1
output=$2
zig=$3
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/grpc-lite-static.XXXXXX")
cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT

index=0
add_object() {
    local source=$1
    cp "$source" "$work_dir/$(printf '%08d.o' "$index")"
    index=$((index + 1))
}

while IFS= read -r member; do
    if archive_members=$("$zig" ar t "$member" 2>/dev/null); then
        while IFS= read -r object; do
            object_path="$work_dir/$(printf '%08d.o' "$index")"
            "$zig" ar p "$member" "$object" >"$object_path"
            index=$((index + 1))
        done <<<"$archive_members"
    else
        add_object "$member"
    fi
done < <("$zig" ar t "$input")

"$zig" ar rcs "$output" "$work_dir"/*.o
