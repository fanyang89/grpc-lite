#!/usr/bin/env bash
set -euo pipefail

library=$1
source_dir=$2
build_dir=$3
build_type=$4
cc=$5
sanitize_thread=$6
sanitize_c=$7

c_flags=()

if [[ "$sanitize_thread" == true && "$sanitize_c" == true ]]; then
    printf 'ThreadSanitizer and UndefinedBehaviorSanitizer are mutually exclusive\n' >&2
    exit 1
fi

if [[ "$sanitize_thread" == true ]]; then
    c_flags+=(-fsanitize=thread)
fi
if [[ "$sanitize_c" == true ]]; then
    c_flags+=(-fsanitize=undefined -fno-sanitize-recover=undefined)
else
    c_flags+=(-fno-sanitize=undefined)
fi
if [[ "$sanitize_thread" == true || "$sanitize_c" == true ]]; then
    c_flags+=(-fno-omit-frame-pointer)
fi

if [[ "$sanitize_thread" == true || "$sanitize_c" == true ]]; then
    c_flags+=(-g)
fi

common_options=(
    -S "$source_dir"
    -B "$build_dir"
    -G Ninja
    "-DCMAKE_BUILD_TYPE=$build_type"
    "-DCMAKE_C_FLAGS=${c_flags[*]}"
    -DBUILD_SHARED_LIBS=OFF
)

case "$library" in
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
