#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_dir="$project_root/coverage"
test_binary="$project_root/zig-out/coverage/grpc-lite-tests"

if ! command -v kcov >/dev/null 2>&1; then
    echo "kcov is required to generate coverage" >&2
    exit 1
fi

rm -rf "$output_dir"
zig build coverage-bin
kcov \
    --include-path="$project_root/src" \
    --exclude-pattern="/.zig-cache/,/zig-pkg/,/third_party/" \
    "$output_dir" \
    "$test_binary"

reports=("$output_dir"/*/cobertura.xml)
if [[ ! -f "${reports[0]}" ]]; then
    echo "kcov did not produce a Cobertura report" >&2
    exit 1
fi

cp "${reports[0]}" "$output_dir/cobertura.xml"
printf 'Coverage report: %s\n' "$output_dir/cobertura.xml"
