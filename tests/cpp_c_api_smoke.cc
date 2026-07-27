#include <grpc_lite/grpc_lite.h>

#include <cassert>
#include <cstdint>
#include <cstddef>
#include <string_view>
#include <type_traits>

static_assert(std::is_same_v<grpc_lite_error, std::int32_t>);
static_assert(std::is_same_v<grpc_lite_feature_bits, std::uint64_t>);
static_assert(sizeof(grpc_lite_bytes_view) == 2 * sizeof(std::size_t));
static_assert(alignof(grpc_lite_bytes_view) == alignof(std::size_t));
static_assert(offsetof(grpc_lite_bytes_view, data) == 0);
static_assert(offsetof(grpc_lite_bytes_view, size) == sizeof(void *));
static_assert(sizeof(grpc_lite_metadata_entry_view) ==
              2 * sizeof(grpc_lite_bytes_view));

int main() {
  grpc_lite_unary_options options = GRPC_LITE_UNARY_OPTIONS_INIT;
  grpc_lite_client_stream_options stream_options =
      GRPC_LITE_CLIENT_STREAM_OPTIONS_INIT;
  grpc_lite_client_stream_callbacks callbacks =
      GRPC_LITE_CLIENT_STREAM_CALLBACKS_INIT;
  grpc_lite_server_options server_options = GRPC_LITE_SERVER_OPTIONS_INIT;
  grpc_lite_server_method_options method_options =
      GRPC_LITE_SERVER_METHOD_OPTIONS_INIT;
  grpc_lite_server_method_callbacks method_callbacks =
      GRPC_LITE_SERVER_METHOD_CALLBACKS_INIT;
  static_assert(std::is_standard_layout_v<grpc_lite_unary_options>);
  static_assert(std::is_standard_layout_v<grpc_lite_client_stream_options>);
  static_assert(std::is_standard_layout_v<grpc_lite_client_stream_callbacks>);
  static_assert(std::is_standard_layout_v<grpc_lite_server_options>);
  static_assert(std::is_standard_layout_v<grpc_lite_server_method_options>);
  static_assert(std::is_standard_layout_v<grpc_lite_server_method_callbacks>);
  assert(options.struct_size == sizeof(options));
  assert(stream_options.struct_size == sizeof(stream_options));
  assert(callbacks.struct_size == sizeof(callbacks));
  assert(server_options.struct_size == sizeof(server_options));
  assert(method_options.struct_size == sizeof(method_options));
  assert(method_callbacks.struct_size == sizeof(method_callbacks));

  if (grpc_lite_abi_version() != GRPC_LITE_ABI_VERSION) return 1;
  if (std::string_view(grpc_lite_error_string(GRPC_LITE_OK)) != "ok") return 2;

  grpc_lite_metadata *metadata = nullptr;
  if (grpc_lite_metadata_create(&metadata) != GRPC_LITE_OK) return 3;
  grpc_lite_metadata_destroy(metadata);
  return 0;
}
