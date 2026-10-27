/* This translation unit must use only the frozen v0.5.0 C header. */
#define _GNU_SOURCE
#include <grpc_lite/grpc_lite.h>

#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#if GRPC_LITE_ABI_VERSION != ((1u << 16) | 6u)
#error "The ABI consumer must be compiled against the released ABI 1.6 header"
#endif

#define END_OF(type, field) (offsetof(type, field) + sizeof(((type *)0)->field))

static grpc_lite_bytes_view bytes(const char *text) {
  grpc_lite_bytes_view view = {(const uint8_t *)text, strlen(text)};
  return view;
}

/* Put a real old-sized allocation next to PROT_NONE, not a shortened current
 * object. Round only for alignment (the server's final uint32_t has padding). */
struct prefix {
  void *mapping;
  size_t mapping_size;
  void *data;
};

static struct prefix copy_prefix(const void *options, size_t size) {
  const long page_size = sysconf(_SC_PAGESIZE);
  assert(page_size > 0);
  const size_t page = (size_t)page_size;
  const size_t alignment = _Alignof(uint64_t);
  const size_t extent = (size + alignment - 1) / alignment * alignment;
  assert(extent <= page);
  void *mapping = mmap(NULL, page * 2, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  assert(mapping != MAP_FAILED);
  assert(mprotect((uint8_t *)mapping + page, page, PROT_NONE) == 0);
  void *data = (uint8_t *)mapping + page - extent;
  memcpy(data, options, size);
  memcpy(data, &size, sizeof(size));
  struct prefix result = {mapping, page * 2, data};
  return result;
}

static void release_prefix(struct prefix value) {
  assert(munmap(value.mapping, value.mapping_size) == 0);
}

static uint32_t server_message(
    void *user_data, grpc_lite_server_stream *stream,
    const grpc_lite_server_context *context,
    grpc_lite_bytes_view payload, uint32_t compression) {
  (void)user_data;
  (void)stream;
  (void)context;
  assert(compression == GRPC_LITE_COMPRESSION_IDENTITY);
  assert(payload.size == 7 && memcmp(payload.data, "request", 7) == 0);
  return GRPC_LITE_RECEIVE_CONTINUE;
}

static void server_end(
    void *user_data, grpc_lite_server_stream *stream,
    const grpc_lite_server_context *context) {
  (void)user_data;
  assert(grpc_lite_server_context_has_deadline(context) == 1);
  grpc_lite_server_call *call = NULL;
  assert(grpc_lite_server_stream_retain(stream, &call) == GRPC_LITE_OK);
  assert(grpc_lite_server_call_send(
      call, bytes("response"), GRPC_LITE_COMPRESSION_IDENTITY) == GRPC_LITE_OK);
  assert(grpc_lite_server_call_finish(call, 0, bytes(""), NULL) == GRPC_LITE_OK);
  grpc_lite_server_call_destroy(call);
}

struct stream_state {
  pthread_mutex_t mutex;
  pthread_cond_t completed;
  unsigned messages;
  unsigned terminals;
};

static uint32_t client_message(
    void *user_data, grpc_lite_client_stream *stream,
    grpc_lite_bytes_view payload, uint32_t compression) {
  struct stream_state *state = user_data;
  (void)stream;
  assert(compression == GRPC_LITE_COMPRESSION_IDENTITY);
  assert(payload.size == 8 && memcmp(payload.data, "response", 8) == 0);
  assert(pthread_mutex_lock(&state->mutex) == 0);
  ++state->messages;
  assert(pthread_mutex_unlock(&state->mutex) == 0);
  return GRPC_LITE_RECEIVE_CONTINUE;
}

static void client_terminal(
    void *user_data, grpc_lite_client_stream *stream, int32_t status,
    grpc_lite_bytes_view message, const grpc_lite_metadata_view *trailing) {
  struct stream_state *state = user_data;
  (void)stream;
  (void)message;
  (void)trailing;
  assert(status == 0);
  assert(pthread_mutex_lock(&state->mutex) == 0);
  ++state->terminals;
  assert(pthread_cond_signal(&state->completed) == 0);
  assert(pthread_mutex_unlock(&state->mutex) == 0);
}

static void round_trip(grpc_lite_channel *channel) {
  const grpc_lite_bytes_view method = bytes("/abi.Baseline/Echo");
  grpc_lite_unary_options unary = GRPC_LITE_UNARY_OPTIONS_INIT;
  unary.has_timeout = 1;
  unary.timeout_ns = UINT64_C(5000000000);
  grpc_lite_unary_result *result = NULL;
  assert(grpc_lite_channel_call_unary(
      channel, method, bytes("request"), &unary, &result) == GRPC_LITE_OK);
  assert(grpc_lite_unary_result_status_code(result) == 0);
  const grpc_lite_bytes_view payload = grpc_lite_unary_result_payload(result);
  assert(payload.size == 8 && memcmp(payload.data, "response", 8) == 0);
  grpc_lite_unary_result_destroy(result);

  struct stream_state state = {
      PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, 0, 0};
  grpc_lite_client_stream_options options = GRPC_LITE_CLIENT_STREAM_OPTIONS_INIT;
  options.has_timeout = 1;
  options.timeout_ns = UINT64_C(5000000000);
  grpc_lite_client_stream_callbacks callbacks = GRPC_LITE_CLIENT_STREAM_CALLBACKS_INIT;
  callbacks.user_data = &state;
  callbacks.on_message = client_message;
  callbacks.on_terminal = client_terminal;
  grpc_lite_client_stream *stream = NULL;
  assert(grpc_lite_channel_open_stream(
      channel, method, &options, &callbacks, &stream) == GRPC_LITE_OK);
  assert(grpc_lite_client_stream_send(
      stream, bytes("request"), GRPC_LITE_COMPRESSION_IDENTITY) == GRPC_LITE_OK);
  assert(grpc_lite_client_stream_close_send(stream) == GRPC_LITE_OK);
  struct timespec deadline;
  assert(timespec_get(&deadline, TIME_UTC) == TIME_UTC);
  deadline.tv_sec += 5;
  assert(pthread_mutex_lock(&state.mutex) == 0);
  while (state.terminals == 0) {
    assert(pthread_cond_timedwait(&state.completed, &state.mutex, &deadline) == 0);
  }
  assert(state.messages == 1 && state.terminals == 1);
  assert(pthread_mutex_unlock(&state.mutex) == 0);
  grpc_lite_client_stream_destroy(stream);
  assert(pthread_cond_destroy(&state.completed) == 0);
  assert(pthread_mutex_destroy(&state.mutex) == 0);
}

int main(void) {
  const uint32_t abi = grpc_lite_abi_version();
  assert((abi >> 16) == GRPC_LITE_ABI_MAJOR);
  assert((abi & 0xffff) >= GRPC_LITE_ABI_MINOR);
  assert(grpc_lite_library_version()[0] != '\0');
  const grpc_lite_feature_bits required =
      GRPC_LITE_FEATURE_RAW_UNARY | GRPC_LITE_FEATURE_C_STREAMING |
      GRPC_LITE_FEATURE_C_SERVER | GRPC_LITE_FEATURE_MANAGED_CHANNEL;
  assert((grpc_lite_features() & required) == required);
  grpc_lite_runtime *runtime = NULL;
  assert(grpc_lite_runtime_create(&runtime) == GRPC_LITE_OK);
  const size_t server_sizes[] = {
      END_OF(grpc_lite_server_options, max_outbound_buffer_size),
      END_OF(grpc_lite_server_options, logger),
      END_OF(grpc_lite_server_options, max_connections),
      END_OF(grpc_lite_server_options, cleartext_preface_timeout_ns),
      END_OF(grpc_lite_server_options, connection_idle_timeout_ns),
      END_OF(grpc_lite_server_options, max_concurrent_streams_per_connection),
      sizeof(grpc_lite_server_options)};
  const size_t channel_sizes[] = {
      END_OF(grpc_lite_channel_options, jitter_percent),
      END_OF(grpc_lite_channel_options, logger),
      sizeof(grpc_lite_channel_options)};
  for (size_t s = 0; s < sizeof(server_sizes) / sizeof(server_sizes[0]); ++s) {
    grpc_lite_server_options options = GRPC_LITE_SERVER_OPTIONS_INIT;
    struct prefix storage = copy_prefix(&options, server_sizes[s]);
    grpc_lite_server *server = NULL;
    assert(grpc_lite_server_create(storage.data, &server) == GRPC_LITE_OK);
    release_prefix(storage);
    grpc_lite_server_method_options method = GRPC_LITE_SERVER_METHOD_OPTIONS_INIT;
    method.explicit_initial_metadata = 0;
    grpc_lite_server_method_callbacks callbacks = GRPC_LITE_SERVER_METHOD_CALLBACKS_INIT;
    callbacks.on_message = server_message;
    callbacks.on_remote_end = server_end;
    assert(grpc_lite_server_register_stream(
        server, bytes("/abi.Baseline/Echo"), &method, &callbacks) == GRPC_LITE_OK);
    assert(grpc_lite_server_start(server) == GRPC_LITE_OK);
    uint32_t port = 0;
    assert(grpc_lite_server_port(server, &port) == GRPC_LITE_OK);
    char target[32];
    const int size = snprintf(target, sizeof(target), "127.0.0.1:%u", (unsigned)port);
    assert(size > 0 && (size_t)size < sizeof(target));
    for (size_t c = 0; c < sizeof(channel_sizes) / sizeof(channel_sizes[0]); ++c) {
      grpc_lite_channel_options channel_options = GRPC_LITE_CHANNEL_OPTIONS_INIT;
      storage = copy_prefix(&channel_options, channel_sizes[c]);
      grpc_lite_channel *channel = NULL;
      assert(grpc_lite_channel_create_managed(
          runtime, bytes(target), storage.data, &channel) == GRPC_LITE_OK);
      release_prefix(storage);
      round_trip(channel);
      grpc_lite_channel_shutdown(channel);
      grpc_lite_channel_wait(channel);
      grpc_lite_channel_destroy(channel);
    }
    grpc_lite_server_shutdown_gracefully(server, UINT64_C(5000000000));
    grpc_lite_server_wait(server);
    grpc_lite_server_destroy(server);
  }
  grpc_lite_runtime_destroy(runtime);
  puts("Released-header C consumer passed: 7 server prefixes x 3 channel prefixes, unary + streaming");
  return 0;
}
