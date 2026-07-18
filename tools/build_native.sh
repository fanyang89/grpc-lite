#!/usr/bin/env bash
set -euo pipefail

library=$1
source_dir=$2
build_dir=$3
build_type=$4
cc=$5

common_options=(
    -S "$source_dir"
    -B "$build_dir"
    -G Ninja
    "-DCMAKE_BUILD_TYPE=$build_type"
    -DCMAKE_C_FLAGS=-fno-sanitize=undefined
    -DBUILD_SHARED_LIBS=OFF
)

case "$library" in
    libuv)
        CC="$cc" cmake "${common_options[@]}" \
            -DLIBUV_BUILD_SHARED=OFF \
            -DLIBUV_BUILD_TESTS=OFF \
            -DLIBUV_BUILD_BENCH=OFF
        ;;
    nghttp2)
        CC="$cc" cmake "${common_options[@]}" \
            -DENABLE_LIB_ONLY=ON \
            -DENABLE_APP=OFF \
            -DENABLE_EXAMPLES=OFF \
            -DENABLE_HPACK_TOOLS=OFF \
            -DENABLE_DOC=OFF \
            -DBUILD_TESTING=OFF \
            -DBUILD_STATIC_LIBS=ON
        ;;
    *)
        printf 'unsupported native library: %s\n' "$library" >&2
        exit 1
        ;;
esac

cmake --build "$build_dir"
