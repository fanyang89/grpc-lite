#!/usr/bin/env bash
set -euo pipefail

library=$1
source_dir=$2
build_dir=$3
build_type=$4
cc=$5
cxx=$6
zig_exe=$7
target_triple=$8
force_link_source=$(realpath "$9")
wolfssl_patch=$(realpath "${10}")
sanitize_thread=${11}
sanitize_c=${12}
enable_gperftools=${13}
enable_tcmalloc=${14}

c_flags=(-fvisibility=hidden)

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
    "-DCMAKE_CXX_FLAGS=${c_flags[*]}"
    -DBUILD_SHARED_LIBS=OFF
)

case "$library" in
    nghttp2)
        CC="$cc" CXX="$cxx" cmake "${common_options[@]}" \
            -DENABLE_LIB_ONLY=ON \
            -DENABLE_APP=OFF \
            -DENABLE_EXAMPLES=OFF \
            -DENABLE_HPACK_TOOLS=OFF \
            -DENABLE_DOC=OFF \
            -DBUILD_TESTING=OFF \
            -DBUILD_STATIC_LIBS=ON
        ;;
    cares)
        CC="$cc" CXX="$cxx" cmake "${common_options[@]}" \
            -DCMAKE_INSTALL_LIBDIR=lib \
            -DCARES_STATIC=ON \
            -DCARES_SHARED=OFF \
            -DCARES_INSTALL=OFF \
            -DCARES_BUILD_TESTS=OFF \
            -DCARES_BUILD_CONTAINER_TESTS=OFF \
            -DCARES_BUILD_TOOLS=OFF \
            -DCARES_THREADS=ON
        ;;
    wolfssl)
        # Upstream CMake may remove generated headers from its source directory.
        source_copy="$build_dir/source"
        mkdir -p "$source_copy"
        cp -a "$source_dir/." "$source_copy"
        patch --batch --forward --fuzz=0 -d "$source_copy" -p1 < "$wolfssl_patch"
        common_options[1]="$source_copy"
        acceleration=()
        case "$target_triple" in
            x86_64-*)
                acceleration=(-DWOLFSSL_AESNI=yes -DWOLFSSL_INTEL_ASM=yes)
                ;;
        esac
        CC="$cc" ASM="$cc" cmake "${common_options[@]}" \
            -DCMAKE_SYSTEM_NAME=Linux \
            "-DCMAKE_SYSTEM_PROCESSOR=${target_triple%%-*}" \
            -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
            -DWOLFSSL_EXAMPLES=no \
            -DWOLFSSL_CRYPT_TESTS=no \
            -DWOLFSSL_ALPN=yes \
            -DWOLFSSL_SNI=yes \
            -DWOLFSSL_IP_ALT_NAME=yes \
            -DWOLFSSL_TLS13=yes \
            -DWOLFSSL_MLKEM=no \
            -DWOLFSSL_SYS_CA_CERTS=no \
            "${acceleration[@]}"
        cmake --build "$build_dir" --target wolfssl
        exit 0
        ;;
    gperftools)
        enable_heap_profiler=false
        if [[ "$enable_gperftools" == true && "$enable_tcmalloc" == true ]]; then
            enable_heap_profiler=true
        fi
        CC="$cc" CXX="$cxx" cmake "${common_options[@]}" \
            -DBUILD_TESTING=OFF \
            -DGPERFTOOLS_BUILD_CPU_PROFILER="$enable_gperftools" \
            -DGPERFTOOLS_BUILD_HEAP_PROFILER="$enable_heap_profiler" \
            -DGPERFTOOLS_BUILD_DEBUGALLOC=OFF \
            -Dgperftools_build_minimal=OFF \
            -Dgperftools_build_benchmark=OFF \
            -Dgperftools_enable_libunwind=OFF \
            -Dgperftools_enable_frame_pointers=ON
        if [[ "$enable_heap_profiler" == true ]]; then
            targets=(tcmalloc profiler)
            archives=(libtcmalloc.a libprofiler.a libstacktrace.a liblow_level_alloc.a libcommon.a)
        elif [[ "$enable_tcmalloc" == true ]]; then
            targets=(tcmalloc_minimal)
            archives=(libtcmalloc_minimal.a libcommon.a)
        else
            targets=(profiler)
            archives=(libprofiler.a libstacktrace.a libcommon.a)
        fi
        cmake --build "$build_dir" --target "${targets[@]}"
        archive="$build_dir/libgrpc_lite_gperftools.a"
        rm -f "$archive"
        {
            printf 'CREATE %s\n' "$archive"
            for dependency in "${archives[@]}"; do
                printf 'ADDLIB %s/%s\n' "$build_dir" "$dependency"
            done
            printf 'SAVE\nEND\n'
        } | "$zig_exe" ar -M
        gperftools_define=0
        tcmalloc_define=0
        [[ "$enable_gperftools" == true ]] && gperftools_define=1
        [[ "$enable_tcmalloc" == true ]] && tcmalloc_define=1
        "$zig_exe" cc -target "$target_triple" "${c_flags[@]}" \
            -DGRPC_LITE_ENABLE_GPERFTOOLS="$gperftools_define" \
            -DGRPC_LITE_ENABLE_TCMALLOC="$tcmalloc_define" \
            -c "$force_link_source" \
            -o "$build_dir/gperftools_force_link.o"
        exit 0
        ;;
    *)
        printf 'unsupported native library: %s\n' "$library" >&2
        exit 1
        ;;
esac

cmake --build "$build_dir"
