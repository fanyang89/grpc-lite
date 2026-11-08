#!/usr/bin/env bash
# Shared package preparation for isolated Zig consumers. The caller supplies
# project_root, work_dir, archive, and global_cache and owns cleanup.

# Import only requested packages so lazy integrations stay absent until tested.
prefetch_prepared_package() {
    local expected_hash=$1
    cp "$GRPC_LITE_DEPENDENCY_CACHE/p/$expected_hash.tar.gz" "$global_cache/p/"
    mkdir -p "$global_cache/p/$expected_hash"
    tar --extract --gzip --file "$global_cache/p/$expected_hash.tar.gz" \
        --strip-components=1 --directory "$global_cache/p/$expected_hash"
}

prefetch_url_package() {
    local url=$1
    local expected_hash=$2
    local archive_name=$3
    if [[ -n "${GRPC_LITE_DEPENDENCY_CACHE:-}" ]]; then
        prefetch_prepared_package "$expected_hash"
        return
    fi
    local dependency_archive="$work_dir/$archive_name"
    local package_dir="$global_cache/p/$expected_hash"

    curl --fail --location --silent --show-error --output "$dependency_archive" "$url"
    local actual_hash
    actual_hash=$(ZIG_GLOBAL_CACHE_DIR="$global_cache" zig fetch "$dependency_archive")
    if [[ "$actual_hash" != "$expected_hash" ]]; then
        printf 'package hash mismatch for %s: expected %s, got %s\n' \
            "$archive_name" "$expected_hash" "$actual_hash" >&2
        exit 1
    fi
    mkdir -p "$package_dir"
    tar --extract --gzip --file "$dependency_archive" --strip-components=1 --directory "$package_dir"
    tar --create --gzip --file "$global_cache/p/$expected_hash.tar.gz" --directory "$package_dir" .
}

prefetch_zigfetch_url_package() {
    local url=$1
    local expected_hash=$2
    local archive_name=$3
    if [[ -n "${GRPC_LITE_DEPENDENCY_CACHE:-}" ]]; then
        prefetch_prepared_package "$expected_hash"
        return
    fi
    local output
    local actual_hash

    output=$(ZIG_GLOBAL_CACHE_DIR="$global_cache" zigfetch "$url" 2>&1)
    actual_hash=${output##*$'\n'}
    if [[ "$actual_hash" != "$expected_hash" ]]; then
        printf 'package hash mismatch for %s: expected %s, got %s\n' \
            "$archive_name" "$expected_hash" "$actual_hash" >&2
        exit 1
    fi
    curl --fail --location --silent --show-error \
        --output "$global_cache/p/$expected_hash.tar.gz" "$url"
}

prefetch_native_packages() {
    prefetch_url_package \
        'https://codeload.github.com/nghttp2/nghttp2/tar.gz/68cb6900fde14c77f0cd7add0e094a862960eb99' \
        'N-V-__8AAPOqVwAHvwAVJJjhhX72DyDtjWw--9WUZf3-uKRX' \
        'nghttp2.tar.gz'
    prefetch_url_package \
        'https://codeload.github.com/c-ares/c-ares/tar.gz/refs/tags/v1.34.8' \
        'N-V-__8AAC2bMACCSbPXjtm12IrwNq-6EO8zPfR2QQy9a53e' \
        'cares.tar.gz'
    prefetch_zigfetch_url_package \
        'https://cpucycles.cr.yp.to/libcpucycles-20260625.tar.gz' \
        'N-V-__8AAHSUBAA_Vn8NXM2L9F21QFvrTIxbH9yvxs5cO-lY' \
        'cpucycles.tar.gz'
    prefetch_url_package \
        'https://codeload.github.com/wyzdwdz/nanozlog/tar.gz/a1ad3d52aec355c2dba7568fe18ec440937d4f81' \
        'nanozlog-0.1.0-5UtdH6f6AAACQMkivAT4xIQtfBDFG3JACCJRpnY5Up3P' \
        'nanozlog.tar.gz'
    prefetch_url_package \
        'https://codeload.github.com/rockorager/zeit/tar.gz/refs/tags/v0.10.0' \
        'zeit-0.10.0-5I6bkxS-AgAaI3lI3RsXsWnPw7sMCqJKoFnSB8_QRAoo' \
        'zeit.tar.gz'
}

package_worktree() {
    package_source="$work_dir/package"
    mkdir -p "$package_source"
    git -C "$project_root" archive HEAD | tar -x -C "$package_source"
    git -C "$project_root" diff --binary HEAD >"$work_dir/worktree.patch"
    if [[ -s "$work_dir/worktree.patch" ]]; then
        git -C "$package_source" apply --whitespace=nowarn "$work_dir/worktree.patch"
    fi
    while IFS= read -r -d '' path; do
        mkdir -p "$package_source/$(dirname "$path")"
        cp -a "$project_root/$path" "$package_source/$path"
    done < <(git -C "$project_root" ls-files --others --exclude-standard -z)
    tar -czf "$archive" -C "$package_source" .
    package_hash=$(ZIG_GLOBAL_CACHE_DIR="$global_cache" zig fetch "$archive")
}
