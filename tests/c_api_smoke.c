#include <grpc_lite/grpc_lite.h>

#include <stdint.h>
#include <string.h>

static grpc_lite_bytes_view bytes(const void *data, size_t size) {
  grpc_lite_bytes_view value = {(const uint8_t *)data, size};
  return value;
}

int main(void) {
  grpc_lite_metadata *metadata = NULL;
  grpc_lite_runtime *runtime = NULL;
  grpc_lite_metadata_entry_view entry;
  const uint8_t binary[] = {0, 1, 2};

  if (grpc_lite_abi_version() != GRPC_LITE_ABI_VERSION) return 1;
  if (grpc_lite_library_version()[0] == '\0') return 2;
  if ((grpc_lite_features() & GRPC_LITE_FEATURE_STREAMING) == 0) return 3;
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
