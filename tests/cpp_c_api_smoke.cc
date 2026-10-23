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
static_assert(std::is_standard_layout_v<grpc_lite_logger>);
static_assert(offsetof(grpc_lite_logger, struct_size) == 0);
static_assert(std::is_standard_layout_v<grpc_lite_channel_options>);
static_assert(offsetof(grpc_lite_channel_options, struct_size) == 0);
static_assert(offsetof(grpc_lite_channel_options, allow_initial_offline) ==
              sizeof(std::size_t));
static_assert(offsetof(grpc_lite_channel_options, initial_backoff_ns) ==
              2 * sizeof(std::size_t));
static_assert(offsetof(grpc_lite_channel_options, max_backoff_ns) ==
              offsetof(grpc_lite_channel_options, initial_backoff_ns) + 8);
static_assert(offsetof(grpc_lite_channel_options, multiplier_millis) ==
              offsetof(grpc_lite_channel_options, max_backoff_ns) + 8);
static_assert(offsetof(grpc_lite_channel_options, jitter_percent) ==
              offsetof(grpc_lite_channel_options, multiplier_millis) + 4);
static_assert(offsetof(grpc_lite_channel_options,
                       max_response_header_list_size) ==
              offsetof(grpc_lite_channel_options, logger) + sizeof(void *));

static_assert(offsetof(grpc_lite_channel_options, max_unary_calls) ==
              offsetof(grpc_lite_channel_options, max_response_header_list_size) + 8);
static_assert(offsetof(grpc_lite_channel_options, max_unary_request_bytes) ==
              offsetof(grpc_lite_channel_options, max_unary_calls) + 8);
static_assert(std::is_standard_layout_v<grpc_lite_unary_admission_stats>);
static_assert(offsetof(grpc_lite_unary_admission_stats, struct_size) == 0);

static_assert(offsetof(grpc_lite_channel_options, max_streams) ==
              offsetof(grpc_lite_channel_options, max_unary_request_bytes) + 8);
static_assert(offsetof(grpc_lite_channel_options, max_stream_buffer_bytes) ==
              offsetof(grpc_lite_channel_options, max_streams) + 8);
static_assert(std::is_standard_layout_v<grpc_lite_stream_admission_stats>);
static_assert(offsetof(grpc_lite_stream_admission_stats, struct_size) == 0);

static_assert(std::is_standard_layout_v<grpc_lite_channel_operational_stats>);
static_assert(offsetof(grpc_lite_channel_operational_stats, struct_size) == 0);
static_assert(sizeof(grpc_lite_channel_operational_stats) == 208);
static_assert(alignof(grpc_lite_channel_operational_stats) ==
              alignof(std::uint64_t));
static_assert(std::is_standard_layout_v<grpc_lite_server_operational_stats>);
static_assert(offsetof(grpc_lite_server_operational_stats, struct_size) == 0);
static_assert(sizeof(grpc_lite_server_operational_stats) == 120);
static_assert(alignof(grpc_lite_server_operational_stats) ==
              alignof(std::uint64_t));

#define CHECK_OPERATIONAL_FIELD(type, field, offset)                   \
  static_assert(std::is_same_v<decltype(type::field), std::uint64_t>); \
  static_assert(offsetof(type, field) == offset)
CHECK_OPERATIONAL_FIELD(grpc_lite_channel_operational_stats,
                        unary_retained_calls, 8);
CHECK_OPERATIONAL_FIELD(grpc_lite_channel_operational_stats,
                        unary_retained_request_bytes, 16);
CHECK_OPERATIONAL_FIELD(grpc_lite_channel_operational_stats,
                        unary_rejected_calls, 24);
CHECK_OPERATIONAL_FIELD(grpc_lite_channel_operational_stats,
                        stream_retained_streams, 32);
CHECK_OPERATIONAL_FIELD(grpc_lite_channel_operational_stats,
                        stream_reserved_buffer_bytes, 40);
CHECK_OPERATIONAL_FIELD(grpc_lite_channel_operational_stats,
                        stream_rejected_streams, 48);
CHECK_OPERATIONAL_FIELD(grpc_lite_channel_operational_stats, active_unary_calls,
                        56);
CHECK_OPERATIONAL_FIELD(grpc_lite_channel_operational_stats, active_streams,
                        64);
CHECK_OPERATIONAL_FIELD(grpc_lite_channel_operational_stats, active_connections,
                        72);
CHECK_OPERATIONAL_FIELD(grpc_lite_channel_operational_stats,
                        pending_unary_calls, 80);
CHECK_OPERATIONAL_FIELD(grpc_lite_channel_operational_stats,
                        pending_unary_calls_high_water, 88);
CHECK_OPERATIONAL_FIELD(grpc_lite_channel_operational_stats,
                        stream_inbound_bytes, 96);
CHECK_OPERATIONAL_FIELD(grpc_lite_channel_operational_stats,
                        stream_inbound_bytes_high_water, 104);
CHECK_OPERATIONAL_FIELD(grpc_lite_channel_operational_stats,
                        stream_outbound_bytes, 112);
CHECK_OPERATIONAL_FIELD(grpc_lite_channel_operational_stats,
                        stream_outbound_bytes_high_water, 120);
CHECK_OPERATIONAL_FIELD(grpc_lite_channel_operational_stats, socket_write_bytes,
                        128);
CHECK_OPERATIONAL_FIELD(grpc_lite_channel_operational_stats,
                        socket_write_bytes_high_water, 136);
CHECK_OPERATIONAL_FIELD(grpc_lite_channel_operational_stats, terminal_ok, 144);
CHECK_OPERATIONAL_FIELD(grpc_lite_channel_operational_stats, terminal_cancelled,
                        152);
CHECK_OPERATIONAL_FIELD(grpc_lite_channel_operational_stats,
                        terminal_deadline_exceeded, 160);
CHECK_OPERATIONAL_FIELD(grpc_lite_channel_operational_stats, terminal_other,
                        168);
CHECK_OPERATIONAL_FIELD(grpc_lite_channel_operational_stats, reconnect_attempts,
                        176);
CHECK_OPERATIONAL_FIELD(grpc_lite_channel_operational_stats,
                        reconnect_successes, 184);
CHECK_OPERATIONAL_FIELD(grpc_lite_channel_operational_stats, reconnect_goaway,
                        192);
CHECK_OPERATIONAL_FIELD(grpc_lite_channel_operational_stats,
                        reconnect_transport_failure, 200);
CHECK_OPERATIONAL_FIELD(grpc_lite_server_operational_stats,
                        admitted_connections, 8);
CHECK_OPERATIONAL_FIELD(grpc_lite_server_operational_stats, active_rpcs, 16);
CHECK_OPERATIONAL_FIELD(grpc_lite_server_operational_stats,
                        rejected_connections, 24);
CHECK_OPERATIONAL_FIELD(grpc_lite_server_operational_stats,
                        pre_ack_rejected_streams, 32);
CHECK_OPERATIONAL_FIELD(grpc_lite_server_operational_stats,
                        streaming_outbound_reserved_bytes, 40);
CHECK_OPERATIONAL_FIELD(grpc_lite_server_operational_stats,
                        streaming_outbound_reserved_bytes_high_water_sum, 48);
CHECK_OPERATIONAL_FIELD(grpc_lite_server_operational_stats,
                        socket_queued_write_bytes, 56);
CHECK_OPERATIONAL_FIELD(grpc_lite_server_operational_stats,
                        socket_queued_write_bytes_high_water_sum, 64);
CHECK_OPERATIONAL_FIELD(grpc_lite_server_operational_stats,
                        close_peer_transport, 72);
CHECK_OPERATIONAL_FIELD(grpc_lite_server_operational_stats,
                        close_protocol_local, 80);
CHECK_OPERATIONAL_FIELD(grpc_lite_server_operational_stats,
                        close_preface_timeout, 88);
CHECK_OPERATIONAL_FIELD(grpc_lite_server_operational_stats, close_idle_timeout,
                        96);
CHECK_OPERATIONAL_FIELD(grpc_lite_server_operational_stats,
                        close_graceful_drain, 104);
CHECK_OPERATIONAL_FIELD(grpc_lite_server_operational_stats,
                        close_forced_shutdown, 112);
#undef CHECK_OPERATIONAL_FIELD

void TestOperationalStats() {
  grpc_lite_channel_operational_stats channel =
      GRPC_LITE_CHANNEL_OPERATIONAL_STATS_INIT;
  assert(channel.struct_size == sizeof(channel));
  constexpr std::uint64_t grpc_lite_channel_operational_stats::*
      fields_channel[] = {
          &grpc_lite_channel_operational_stats::unary_retained_calls,
          &grpc_lite_channel_operational_stats::unary_retained_request_bytes,
          &grpc_lite_channel_operational_stats::unary_rejected_calls,
          &grpc_lite_channel_operational_stats::stream_retained_streams,
          &grpc_lite_channel_operational_stats::stream_reserved_buffer_bytes,
          &grpc_lite_channel_operational_stats::stream_rejected_streams,
          &grpc_lite_channel_operational_stats::active_unary_calls,
          &grpc_lite_channel_operational_stats::active_streams,
          &grpc_lite_channel_operational_stats::active_connections,
          &grpc_lite_channel_operational_stats::pending_unary_calls,
          &grpc_lite_channel_operational_stats::pending_unary_calls_high_water,
          &grpc_lite_channel_operational_stats::stream_inbound_bytes,
          &grpc_lite_channel_operational_stats::stream_inbound_bytes_high_water,
          &grpc_lite_channel_operational_stats::stream_outbound_bytes,
          &grpc_lite_channel_operational_stats::
              stream_outbound_bytes_high_water,
          &grpc_lite_channel_operational_stats::socket_write_bytes,
          &grpc_lite_channel_operational_stats::socket_write_bytes_high_water,
          &grpc_lite_channel_operational_stats::terminal_ok,
          &grpc_lite_channel_operational_stats::terminal_cancelled,
          &grpc_lite_channel_operational_stats::terminal_deadline_exceeded,
          &grpc_lite_channel_operational_stats::terminal_other,
          &grpc_lite_channel_operational_stats::reconnect_attempts,
          &grpc_lite_channel_operational_stats::reconnect_successes,
          &grpc_lite_channel_operational_stats::reconnect_goaway,
          &grpc_lite_channel_operational_stats::reconnect_transport_failure,
      };
  for (auto field : fields_channel) {
    assert(channel.*field == 0);
    channel.*field = UINT64_MAX;
  }
  assert(grpc_lite_channel_get_operational_stats(nullptr, nullptr) ==
         GRPC_LITE_ERROR_INVALID_ARGUMENT);
  assert(grpc_lite_channel_get_operational_stats(nullptr, &channel) ==
         GRPC_LITE_ERROR_INVALID_ARGUMENT);
  assert(channel.struct_size == sizeof(channel));
  for (auto field : fields_channel) assert(channel.*field == 0);
  grpc_lite_server_operational_stats server =
      GRPC_LITE_SERVER_OPERATIONAL_STATS_INIT;
  assert(server.struct_size == sizeof(server));
  constexpr std::uint64_t grpc_lite_server_operational_stats::*
      fields_server[] = {
          &grpc_lite_server_operational_stats::admitted_connections,
          &grpc_lite_server_operational_stats::active_rpcs,
          &grpc_lite_server_operational_stats::rejected_connections,
          &grpc_lite_server_operational_stats::pre_ack_rejected_streams,
          &grpc_lite_server_operational_stats::
              streaming_outbound_reserved_bytes,
          &grpc_lite_server_operational_stats::
              streaming_outbound_reserved_bytes_high_water_sum,
          &grpc_lite_server_operational_stats::socket_queued_write_bytes,
          &grpc_lite_server_operational_stats::
              socket_queued_write_bytes_high_water_sum,
          &grpc_lite_server_operational_stats::close_peer_transport,
          &grpc_lite_server_operational_stats::close_protocol_local,
          &grpc_lite_server_operational_stats::close_preface_timeout,
          &grpc_lite_server_operational_stats::close_idle_timeout,
          &grpc_lite_server_operational_stats::close_graceful_drain,
          &grpc_lite_server_operational_stats::close_forced_shutdown,
      };
  for (auto field : fields_server) {
    assert(server.*field == 0);
    server.*field = UINT64_MAX;
  }
  assert(grpc_lite_server_get_operational_stats(nullptr, nullptr) ==
         GRPC_LITE_ERROR_INVALID_ARGUMENT);
  assert(grpc_lite_server_get_operational_stats(nullptr, &server) ==
         GRPC_LITE_ERROR_INVALID_ARGUMENT);
  assert(server.struct_size == sizeof(server));
  for (auto field : fields_server) assert(server.*field == 0);
}

int main() {
  TestOperationalStats();
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
  static_assert(std::is_standard_layout_v<grpc_lite_unary_options>);
  static_assert(std::is_standard_layout_v<grpc_lite_client_stream_options>);
  static_assert(std::is_standard_layout_v<grpc_lite_client_stream_callbacks>);
  static_assert(std::is_standard_layout_v<grpc_lite_server_options>);
  static_assert(std::is_standard_layout_v<grpc_lite_server_method_options>);
  static_assert(std::is_standard_layout_v<grpc_lite_server_method_callbacks>);
  assert(options.struct_size == sizeof(options));
  assert(channel_options.struct_size == sizeof(channel_options));
  assert(logger.struct_size == sizeof(logger));
  assert(stream_options.struct_size == sizeof(stream_options));
  assert(callbacks.struct_size == sizeof(callbacks));
  assert(server_options.struct_size == sizeof(server_options));
  assert(method_options.struct_size == sizeof(method_options));
  assert(method_callbacks.struct_size == sizeof(method_callbacks));

  if (grpc_lite_abi_version() != GRPC_LITE_ABI_VERSION) return 1;
  if (std::string_view(grpc_lite_error_string(GRPC_LITE_OK)) != "ok") return 2;
  if ((grpc_lite_features() & GRPC_LITE_FEATURE_MANAGED_CHANNEL) == 0) return 4;
  if ((grpc_lite_features() & GRPC_LITE_FEATURE_LOGGING_CALLBACK) == 0) return 6;
  assert(channel_options.initial_backoff_ns == UINT64_C(1000000000));
  assert(channel_options.max_backoff_ns == UINT64_C(120000000000));
  assert(channel_options.max_response_header_list_size == UINT64_C(65536));
  assert(channel_options.max_streams == 1024);
  assert(channel_options.max_stream_buffer_bytes == UINT64_C(1073741824));
  grpc_lite_stream_admission_stats stream_stats = GRPC_LITE_STREAM_ADMISSION_STATS_INIT;
  assert(stream_stats.struct_size == sizeof(stream_stats));
  assert(grpc_lite_channel_get_stream_admission_stats(nullptr, &stream_stats) ==
         GRPC_LITE_ERROR_INVALID_ARGUMENT);
  assert(channel_options.max_unary_calls == 4096);
  assert(channel_options.max_unary_request_bytes == UINT64_C(67108864));
  grpc_lite_unary_admission_stats stats = GRPC_LITE_UNARY_ADMISSION_STATS_INIT;
  assert(stats.struct_size == sizeof(stats));
  assert(grpc_lite_channel_get_unary_admission_stats(nullptr, &stats) ==
         GRPC_LITE_ERROR_INVALID_ARGUMENT);
  grpc_lite_channel *channel = reinterpret_cast<grpc_lite_channel *>(1);
  const grpc_lite_bytes_view invalid_target = {
      reinterpret_cast<const std::uint8_t *>("invalid"), 7};
  if (grpc_lite_channel_create_managed(
          nullptr, invalid_target, nullptr, &channel) !=
      GRPC_LITE_ERROR_INVALID_ARGUMENT) return 5;
  assert(channel == nullptr);
  grpc_lite_channel_shutdown(nullptr);
  grpc_lite_channel_wait(nullptr);
  grpc_lite_server_call_abort(nullptr);

  grpc_lite_metadata *metadata = nullptr;
  if (grpc_lite_metadata_create(&metadata) != GRPC_LITE_OK) return 3;
  grpc_lite_metadata_destroy(metadata);
  return 0;
}
