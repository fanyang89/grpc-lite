pub const api = @cImport({
    @cInclude("nghttp2/nghttp2.h");
    @cInclude("uv.h");
});

test "native dependency versions are available" {
    const nghttp2 = api.nghttp2_version(0) orelse return error.MissingNghttp2Version;
    if (nghttp2.*.version_num == 0) return error.InvalidNghttp2Version;
    if (api.uv_version() == 0) return error.InvalidLibuvVersion;
}
