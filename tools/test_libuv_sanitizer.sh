#!/usr/bin/env bash
set -euo pipefail

mode=${1:?usage: test_libuv_sanitizer.sh <asan|msan|tsan|ubsan>}
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_dir="$repo_dir/third_party/libuv"
build_dir="$repo_dir/.zig-cache/libuv-native-sanitizer-$mode"

cmake_options=(
    -S "$source_dir"
    -B "$build_dir"
    -G Ninja
    -DBUILD_TESTING=ON
    -DLIBUV_BUILD_TESTS=ON
    -DLIBUV_BUILD_BENCH=OFF
)
cc=$(command -v clang)

case "$mode" in
    asan)
        cmake_options+=(-DASAN=ON -DCMAKE_BUILD_TYPE=Debug)
        ;;
    msan)
        cmake_options+=(-DMSAN=ON -DCMAKE_BUILD_TYPE=Debug)
        ;;
    tsan)
        cmake_options+=(-DTSAN=ON -DCMAKE_BUILD_TYPE=Release)
        ;;
    ubsan)
        cmake_options+=(-DUBSAN=ON -DCMAKE_BUILD_TYPE=Debug)
        ;;
    *)
        printf 'unsupported sanitizer: %s\n' "$mode" >&2
        exit 1
        ;;
esac

CC="$cc" cmake "${cmake_options[@]}"
cmake --build "$build_dir" --target uv_run_tests_a

runner="$build_dir/uv_run_tests_a"
case "$mode" in
    asan)
        (cd "$source_dir" && ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 "$runner")
        ;;
    msan)
        (cd "$source_dir" && MSAN_OPTIONS=halt_on_error=1 "$runner")
        ;;
    tsan)
        (cd "$source_dir" && TSAN_OPTIONS="halt_on_error=1:exitcode=66:suppressions=$source_dir/tsansupp.txt" "$runner")
        ;;
    ubsan)
        (cd "$source_dir" && UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 "$runner")
        ;;
esac
