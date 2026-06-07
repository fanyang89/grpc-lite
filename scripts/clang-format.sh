#!/usr/bin/env bash

set -euo pipefail

usage() {
    printf 'Usage: %s <fmt|check>\n' "$0" >&2
}

if [[ $# -ne 1 ]]; then
    usage
    exit 1
fi

mode="$1"
case "$mode" in
    fmt)
        clang_format_args=(--style=file -i)
        ;;
    check)
        clang_format_args=(--style=file --dry-run --Werror)
        ;;
    *)
        usage
        exit 1
        ;;
esac

format_image="${FORMAT_IMAGE:-ghcr.io/fanyang89/clang-format:18}"
repo_root="$(git rev-parse --show-toplevel)"
host_uid="$(id -u)"
host_gid="$(id -g)"

cd "$repo_root"

files=()
while IFS= read -r file; do
    files+=("$file")
done < <(
    find include src tests examples -type f \( -name '*.cc' -o -name '*.h' -o -name '*.hpp' \) \
        ! -path '*/generated/*' ! -name '*.pb.*' | LC_ALL=C sort
)

if [[ ${#files[@]} -eq 0 ]]; then
    exit 0
fi

exec docker run --rm --user "$host_uid:$host_gid" -v "$repo_root:/grpc-lite" -w /grpc-lite \
    "$format_image" "${clang_format_args[@]}" "${files[@]}"
