#include <grpc_lite/grpc_lite.h>

#include <assert.h>
#include <stdint.h>
#include <string.h>

static grpc_lite_bytes_view bytes(const void *data, size_t size) {
  grpc_lite_bytes_view value = {(const uint8_t *)data, size};
  return value;
}

static uint32_t on_message(
    void *user_data,
    grpc_lite_client_stream *stream,
    grpc_lite_bytes_view payload,
    uint32_t compression) {
  (void)user_data;
  (void)stream;
  (void)payload;
  (void)compression;
  return GRPC_LITE_RECEIVE_CONTINUE;
}

static void on_terminal(
    void *user_data,
    grpc_lite_client_stream *stream,
    int32_t status_code,
    grpc_lite_bytes_view status_message,
    const grpc_lite_metadata_view *trailing_metadata) {
  (void)user_data;
  (void)stream;
  (void)status_code;
  (void)status_message;
  (void)trailing_metadata;
}

int main(void) {
  grpc_lite_unary_options options = GRPC_LITE_UNARY_OPTIONS_INIT;
  grpc_lite_client_stream_options stream_options =
      GRPC_LITE_CLIENT_STREAM_OPTIONS_INIT;
  grpc_lite_client_stream_callbacks callbacks =
      GRPC_LITE_CLIENT_STREAM_CALLBACKS_INIT;
  callbacks.on_message = on_message;
  callbacks.on_terminal = on_terminal;
  assert(options.struct_size == sizeof(options));
  assert(stream_options.struct_size == sizeof(stream_options));
  assert(callbacks.struct_size == sizeof(callbacks));
  assert(options.max_response_size == UINT64_C(4194304));
  assert(grpc_lite_unary_result_status_code(NULL) == 2);

  grpc_lite_metadata *metadata = NULL;
  grpc_lite_runtime *runtime = NULL;
  grpc_lite_metadata_entry_view entry;
  const uint8_t binary[] = {0, 1, 2};

  if (grpc_lite_abi_version() != GRPC_LITE_ABI_VERSION) return 1;
  if (grpc_lite_library_version()[0] == '\0') return 2;
  if ((grpc_lite_features() & GRPC_LITE_FEATURE_STREAMING) == 0) return 3;
  if ((grpc_lite_features() & GRPC_LITE_FEATURE_C_STREAMING) == 0) return 11;
  if (grpc_lite_metadata_create(&metadata) != GRPC_LITE_OK) return 4;
  if (grpc_lite_metadata_add(
          metadata,
          bytes("trace-bin", sizeof("trace-bin") - 1),
          bytes(binary, sizeof(binary))) != GRPC_LITE_OK) return 5;
  if (grpc_lite_metadata_count(metadata) != 1) return 6;
  if (grpc_lite_metadata_at(metadata, 0, &entry) != GRPC_LITE_OK) return 7;
  if (entry.key.size != sizeof("trace-bin") - 1 ||
      memcmp(entry.key.data, "trace-bin", entry.key.size) != 0) return 8;
  if (entry.value.size != sizeof(binary) ||
      memcmp(entry.value.data, binary, entry.value.size) != 0) return 9;
  grpc_lite_metadata_destroy(metadata);

  if (grpc_lite_runtime_create(&runtime) != GRPC_LITE_OK) return 10;
  grpc_lite_runtime_destroy(runtime);
  return 0;
}
