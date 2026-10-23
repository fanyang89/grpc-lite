#include <grpc_lite/grpc_lite.h>

#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static grpc_lite_bytes_view bytes(const void *data, size_t size) {
  grpc_lite_bytes_view value = {(const uint8_t *)data, size};
  return value;
}

static void on_log(
    void *user_data,
    uint32_t level,
    grpc_lite_bytes_view message) {
  (void)user_data;
  (void)level;
  (void)message;
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

static uint32_t on_server_message(
    void *user_data,
    grpc_lite_server_stream *stream,
    const grpc_lite_server_context *context,
    grpc_lite_bytes_view payload,
    uint32_t compression) {
  (void)user_data;
  (void)stream;
  (void)context;
  (void)payload;
  (void)compression;
  return GRPC_LITE_RECEIVE_CONTINUE;
}

struct retained_stream_state {
  pthread_mutex_t mutex;
  pthread_cond_t completed;
  unsigned messages;
  unsigned terminals;
};

static uint32_t retained_on_message(
    void *user_data,
    grpc_lite_client_stream *stream,
    grpc_lite_bytes_view payload,
    uint32_t compression) {
  struct retained_stream_state *state = user_data;
  (void)stream;
  assert(compression == GRPC_LITE_COMPRESSION_IDENTITY);
  assert(payload.size == 8 && memcmp(payload.data, "response", 8) == 0);
  assert(pthread_mutex_lock(&state->mutex) == 0);
  assert(state->terminals == 0);
  ++state->messages;
  assert(pthread_mutex_unlock(&state->mutex) == 0);
  return GRPC_LITE_RECEIVE_CONTINUE;
}

static void retained_on_terminal(
    void *user_data,
    grpc_lite_client_stream *stream,
    int32_t status_code,
    grpc_lite_bytes_view status_message,
    const grpc_lite_metadata_view *trailing_metadata) {
  struct retained_stream_state *state = user_data;
  (void)stream;
  (void)status_message;
  (void)trailing_metadata;
  assert(status_code == 0);
  assert(pthread_mutex_lock(&state->mutex) == 0);
  assert(++state->terminals == 1);
  assert(pthread_cond_signal(&state->completed) == 0);
  assert(pthread_mutex_unlock(&state->mutex) == 0);
}

static void retained_server_on_remote_end(
    void *user_data,
    grpc_lite_server_stream *stream,
    const grpc_lite_server_context *context) {
  grpc_lite_server_call *call = NULL;
  (void)user_data;
  (void)context;
  assert(grpc_lite_server_stream_retain(stream, &call) == GRPC_LITE_OK);
  assert(grpc_lite_server_call_send(
      call, bytes("response", 8), GRPC_LITE_COMPRESSION_IDENTITY) == GRPC_LITE_OK);
  assert(grpc_lite_server_call_finish(
      call, 0, bytes(NULL, 0), NULL) == GRPC_LITE_OK);
  grpc_lite_server_call_destroy(call);
}

static void test_retained_results_and_stream_outlive_channel(void) {
  const grpc_lite_bytes_view method =
      {(const uint8_t *)"/test.Ownership/Echo", sizeof("/test.Ownership/Echo") - 1};
  grpc_lite_server *server = NULL;
  grpc_lite_server_method_options method_options = GRPC_LITE_SERVER_METHOD_OPTIONS_INIT;
  grpc_lite_server_method_callbacks method_callbacks = GRPC_LITE_SERVER_METHOD_CALLBACKS_INIT;
  method_options.explicit_initial_metadata = 0;
  method_callbacks.on_message = on_server_message;
  method_callbacks.on_remote_end = retained_server_on_remote_end;
  assert(grpc_lite_server_create(NULL, &server) == GRPC_LITE_OK);
  assert(grpc_lite_server_register_stream(
      server, method, &method_options, &method_callbacks) == GRPC_LITE_OK);
  assert(grpc_lite_server_start(server) == GRPC_LITE_OK);
  uint32_t port = 0;
  assert(grpc_lite_server_port(server, &port) == GRPC_LITE_OK);
  char target[32];
  const int target_size = snprintf(target, sizeof(target), "127.0.0.1:%u", (unsigned)port);
  assert(target_size > 0 && (size_t)target_size < sizeof(target));
  grpc_lite_channel_options channel_options = GRPC_LITE_CHANNEL_OPTIONS_INIT;
  channel_options.max_unary_calls = 1;
  channel_options.max_unary_request_bytes = method.size + 5 + 7;
  channel_options.max_streams = 1;
  channel_options.max_stream_buffer_bytes = 8192;
  grpc_lite_channel *channel = NULL;
  assert(grpc_lite_channel_create_managed(
      NULL, bytes(target, (size_t)target_size), &channel_options, &channel) == GRPC_LITE_OK);

  grpc_lite_unary_options unary_options = GRPC_LITE_UNARY_OPTIONS_INIT;
  unary_options.has_timeout = 1;
  unary_options.timeout_ns = UINT64_C(5000000000);
  grpc_lite_unary_result *results[2] = {NULL, NULL};
  grpc_lite_unary_admission_stats unary_stats = GRPC_LITE_UNARY_ADMISSION_STATS_INIT;
  for (size_t i = 0; i < 2; ++i) {
    assert(grpc_lite_channel_call_unary(
        channel, method, bytes("request", 7), &unary_options, &results[i]) == GRPC_LITE_OK);
    assert(grpc_lite_unary_result_status_code(results[i]) == 0);
    /* Copied results do not retain unary admission, even before result destroy. */
    assert(grpc_lite_channel_get_unary_admission_stats(channel, &unary_stats) == GRPC_LITE_OK);
    assert(unary_stats.retained_calls == 0 && unary_stats.retained_request_bytes == 0);
    assert(unary_stats.rejected_calls == 0);
  }

  struct retained_stream_state state = {
      PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, 0, 0};
  grpc_lite_client_stream_options stream_options = GRPC_LITE_CLIENT_STREAM_OPTIONS_INIT;
  stream_options.has_timeout = 1;
  stream_options.timeout_ns = UINT64_C(5000000000);
  stream_options.max_message_size = 1024;
  stream_options.max_inbound_buffer_size = 4096;
  stream_options.max_outbound_buffer_size = 4096;
  grpc_lite_client_stream_callbacks callbacks = GRPC_LITE_CLIENT_STREAM_CALLBACKS_INIT;
  callbacks.user_data = &state;
  callbacks.on_message = retained_on_message;
  callbacks.on_terminal = retained_on_terminal;
  grpc_lite_client_stream *stream = NULL;
  assert(grpc_lite_channel_open_stream(
      channel, method, &stream_options, &callbacks, &stream) == GRPC_LITE_OK);
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
  grpc_lite_stream_admission_stats stats = GRPC_LITE_STREAM_ADMISSION_STATS_INIT;
  assert(grpc_lite_channel_get_stream_admission_stats(channel, &stats) == GRPC_LITE_OK);
  assert(stats.retained_streams == 1 && stats.reserved_buffer_bytes == 8192);
  grpc_lite_client_stream *rejected = NULL;
  assert(grpc_lite_channel_open_stream(
      channel, method, &stream_options, &callbacks, &rejected) == GRPC_LITE_ERROR_WOULD_BLOCK);
  assert(rejected == NULL);
  assert(grpc_lite_channel_get_stream_admission_stats(channel, &stats) == GRPC_LITE_OK);
  assert(stats.retained_streams == 1 && stats.reserved_buffer_bytes == 8192);
  assert(stats.rejected_streams == 1);

  /* Actual destruction joins the loop; never query the released Channel. */
  grpc_lite_channel_destroy(channel);
  channel = NULL;
  assert(grpc_lite_client_stream_send(
      stream, bytes("late", 4), GRPC_LITE_COMPRESSION_IDENTITY) == GRPC_LITE_ERROR_CLOSED);
  assert(grpc_lite_client_stream_close_send(stream) == GRPC_LITE_ERROR_CLOSED);
  assert(grpc_lite_client_stream_resume_receive(stream) == GRPC_LITE_ERROR_CLOSED);
  grpc_lite_client_stream_cancel(stream);
  grpc_lite_client_stream_destroy(stream);
  assert(state.messages == 1 && state.terminals == 1);
  assert(pthread_cond_destroy(&state.completed) == 0);
  assert(pthread_mutex_destroy(&state.mutex) == 0);
  for (size_t i = 0; i < 2; ++i) {
    const grpc_lite_bytes_view payload = grpc_lite_unary_result_payload(results[i]);
    assert(payload.size == 8 && memcmp(payload.data, "response", 8) == 0);
    assert(grpc_lite_unary_result_status_code(results[i]) == 0);
    grpc_lite_unary_result_destroy(results[i]);
  }
  grpc_lite_server_destroy(server);
}

int main(void) {
  grpc_lite_unary_options options = GRPC_LITE_UNARY_OPTIONS_INIT;
  grpc_lite_channel_options channel_options = GRPC_LITE_CHANNEL_OPTIONS_INIT;
  grpc_lite_logger logger = GRPC_LITE_LOGGER_INIT;
  grpc_lite_client_stream_options stream_options =
      GRPC_LITE_CLIENT_STREAM_OPTIONS_INIT;
  grpc_lite_client_stream_callbacks callbacks =
      GRPC_LITE_CLIENT_STREAM_CALLBACKS_INIT;
  grpc_lite_server_options server_options = GRPC_LITE_SERVER_OPTIONS_INIT;
  grpc_lite_server_method_options method_options =
      GRPC_LITE_SERVER_METHOD_OPTIONS_INIT;
  grpc_lite_server_method_callbacks method_callbacks =
      GRPC_LITE_SERVER_METHOD_CALLBACKS_INIT;
  callbacks.on_message = on_message;
  callbacks.on_terminal = on_terminal;
  method_callbacks.on_message = on_server_message;
  logger.log = on_log;
  channel_options.logger = &logger;
  server_options.logger = &logger;
  assert(options.struct_size == sizeof(options));
  assert(channel_options.struct_size == sizeof(channel_options));
  assert(logger.struct_size == sizeof(logger));
  assert(stream_options.struct_size == sizeof(stream_options));
  assert(callbacks.struct_size == sizeof(callbacks));
  assert(server_options.struct_size == sizeof(server_options));
  assert(server_options.max_connections == UINT64_C(1024));
  assert(server_options.max_concurrent_streams_per_connection == 100);
  assert(server_options.cleartext_preface_timeout_ns == UINT64_C(10000000000));
  assert(server_options.connection_idle_timeout_ns == UINT64_C(300000000000));
  assert(method_options.struct_size == sizeof(method_options));
  assert(method_callbacks.struct_size == sizeof(method_callbacks));
  assert(options.max_response_size == UINT64_C(4194304));
  assert(channel_options.allow_initial_offline == 0);
  assert(channel_options.initial_backoff_ns == UINT64_C(1000000000));
  assert(channel_options.max_backoff_ns == UINT64_C(120000000000));
  assert(channel_options.multiplier_millis == 1600);
  assert(channel_options.jitter_percent == 20);
  assert(channel_options.max_response_header_list_size == UINT64_C(65536));
  assert(grpc_lite_unary_result_status_code(NULL) == 2);

  grpc_lite_metadata *metadata = NULL;
  grpc_lite_runtime *runtime = NULL;
  grpc_lite_channel *channel = NULL;
  grpc_lite_metadata_entry_view entry;
  const uint8_t binary[] = {0, 1, 2};

  if (grpc_lite_abi_version() != GRPC_LITE_ABI_VERSION) return 1;
  if (grpc_lite_library_version()[0] == '\0') return 2;
  if ((grpc_lite_features() & GRPC_LITE_FEATURE_STREAMING) == 0) return 3;
  if ((grpc_lite_features() & GRPC_LITE_FEATURE_C_STREAMING) == 0) return 11;
  if ((grpc_lite_features() & GRPC_LITE_FEATURE_C_SERVER) == 0) return 12;
  if ((grpc_lite_features() & GRPC_LITE_FEATURE_MANAGED_CHANNEL) == 0) return 13;
  if ((grpc_lite_features() & GRPC_LITE_FEATURE_LOGGING_CALLBACK) == 0) return 14;
  if ((grpc_lite_features() & GRPC_LITE_FEATURE_TLS) != 0) return 15;
  grpc_lite_server_call_abort(NULL);
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
  channel_options.max_streams = 1;
  channel_options.max_stream_buffer_bytes = 1;
  channel_options.max_unary_calls = 1;
  channel_options.max_unary_request_bytes = 1;
  channel_options.allow_initial_offline = 1;
  channel_options.initial_backoff_ns = UINT64_C(10000000000);
  channel_options.max_backoff_ns = UINT64_C(10000000000);
  if (grpc_lite_channel_create_managed(
          NULL,
          bytes("127.0.0.1:1", sizeof("127.0.0.1:1") - 1),
          &channel_options,
          &channel) != GRPC_LITE_OK) return 14;
  grpc_lite_unary_admission_stats stats = GRPC_LITE_UNARY_ADMISSION_STATS_INIT;
  assert(grpc_lite_channel_get_unary_admission_stats(channel, &stats) == GRPC_LITE_OK);
  assert(stats.retained_calls == 0 && stats.rejected_calls == 0);
  grpc_lite_unary_result *result = NULL;
  assert(grpc_lite_channel_call_unary(
      channel, bytes("/test.Echo/Unary", sizeof("/test.Echo/Unary") - 1),
      bytes("payload", 7), NULL, &result) == GRPC_LITE_OK);
  assert(grpc_lite_unary_result_status_code(result) == 8);
  grpc_lite_unary_result_destroy(result);
  assert(grpc_lite_channel_get_unary_admission_stats(channel, &stats) == GRPC_LITE_OK);
  assert(stats.retained_calls == 0 && stats.retained_request_bytes == 0);
  assert(stats.rejected_calls == 1);
  grpc_lite_stream_admission_stats stream_stats = GRPC_LITE_STREAM_ADMISSION_STATS_INIT;
  assert(grpc_lite_channel_get_stream_admission_stats(channel, &stream_stats) == GRPC_LITE_OK);
  assert(stream_stats.retained_streams == 0 && stream_stats.rejected_streams == 0);
  grpc_lite_client_stream *rejected_stream = NULL;
  assert(grpc_lite_channel_open_stream(
      channel, bytes("/test.Stream/Duplex", sizeof("/test.Stream/Duplex") - 1),
      NULL, &callbacks, &rejected_stream) == GRPC_LITE_ERROR_WOULD_BLOCK);
  assert(rejected_stream == NULL);
  assert(grpc_lite_channel_get_stream_admission_stats(channel, &stream_stats) == GRPC_LITE_OK);
  assert(stream_stats.retained_streams == 0 && stream_stats.reserved_buffer_bytes == 0);
  assert(stream_stats.rejected_streams == 1);
  grpc_lite_channel_shutdown(channel);
  grpc_lite_channel_wait(channel);
  grpc_lite_channel_destroy(channel);
  test_retained_results_and_stream_outlive_channel();
  return 0;
}
