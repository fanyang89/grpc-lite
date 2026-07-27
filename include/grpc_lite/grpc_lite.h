#ifndef GRPC_LITE_GRPC_LITE_H
#define GRPC_LITE_GRPC_LITE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GRPC_LITE_ABI_MAJOR 1u
#define GRPC_LITE_ABI_MINOR 0u
#define GRPC_LITE_ABI_VERSION \
  ((GRPC_LITE_ABI_MAJOR << 16) | GRPC_LITE_ABI_MINOR)

typedef int32_t grpc_lite_error;

enum {
  GRPC_LITE_OK = 0,
  GRPC_LITE_ERROR_INVALID_ARGUMENT = 1,
  GRPC_LITE_ERROR_INVALID_STATE = 2,
  GRPC_LITE_ERROR_OUT_OF_MEMORY = 3,
  GRPC_LITE_ERROR_UNSUPPORTED = 4,
  GRPC_LITE_ERROR_UNAVAILABLE = 5,
  GRPC_LITE_ERROR_OUT_OF_RANGE = 6,
  GRPC_LITE_ERROR_CLOSED = 7,
  GRPC_LITE_ERROR_INTERNAL = 255,
};

typedef uint64_t grpc_lite_feature_bits;

#define GRPC_LITE_FEATURE_RAW_UNARY (UINT64_C(1) << 0)
#define GRPC_LITE_FEATURE_STREAMING (UINT64_C(1) << 1)
#define GRPC_LITE_FEATURE_GZIP (UINT64_C(1) << 2)
#define GRPC_LITE_FEATURE_DNS (UINT64_C(1) << 3)
#define GRPC_LITE_FEATURE_TLS (UINT64_C(1) << 4)
#define GRPC_LITE_FEATURE_GRACEFUL_SERVER_DRAIN (UINT64_C(1) << 5)

typedef struct grpc_lite_runtime grpc_lite_runtime;
typedef struct grpc_lite_metadata grpc_lite_metadata;

typedef struct grpc_lite_bytes_view {
  const uint8_t *data;
  size_t size;
} grpc_lite_bytes_view;

typedef struct grpc_lite_metadata_entry_view {
  grpc_lite_bytes_view key;
  grpc_lite_bytes_view value;
} grpc_lite_metadata_entry_view;

uint32_t grpc_lite_abi_version(void);
/* Returned strings are immutable library-owned storage and must not be freed. */
const char *grpc_lite_library_version(void);
grpc_lite_feature_bits grpc_lite_features(void);
const char *grpc_lite_error_string(grpc_lite_error error_code);

/*
 * Runtime initialization must happen before the application creates threads.
 * Only one Runtime may be active. Destroy it after all dependent handles.
 * Every non-NULL owning handle must be destroyed exactly once.
 */
grpc_lite_error grpc_lite_runtime_create(grpc_lite_runtime **out_runtime);
void grpc_lite_runtime_destroy(grpc_lite_runtime *runtime);

/* Metadata handles require external synchronization when shared across threads. */
grpc_lite_error grpc_lite_metadata_create(grpc_lite_metadata **out_metadata);
void grpc_lite_metadata_destroy(grpc_lite_metadata *metadata);
/* Key and value bytes are copied before this function returns. */
grpc_lite_error grpc_lite_metadata_add(
    grpc_lite_metadata *metadata,
    grpc_lite_bytes_view key,
    grpc_lite_bytes_view value);
size_t grpc_lite_metadata_count(const grpc_lite_metadata *metadata);
/* Returned views are immutable and remain valid until metadata is destroyed. */
grpc_lite_error grpc_lite_metadata_at(
    const grpc_lite_metadata *metadata,
    size_t index,
    grpc_lite_metadata_entry_view *out_entry);

#ifdef __cplusplus
}
#endif

#endif
