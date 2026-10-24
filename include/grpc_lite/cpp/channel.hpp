#ifndef GRPC_LITE_CPP_CHANNEL_HPP
#define GRPC_LITE_CPP_CHANNEL_HPP

#include <grpc_lite/cpp/runtime.hpp>

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <string_view>
#include <utility>

namespace grpc_lite {

enum class LogLevel : std::uint32_t {
  Debug = GRPC_LITE_LOG_DEBUG,
  Info = GRPC_LITE_LOG_INFO,
  Warn = GRPC_LITE_LOG_WARN,
  Error = GRPC_LITE_LOG_ERROR,
};

using Logger = std::function<void(LogLevel, std::string_view)>;
// Logger callbacks may run concurrently on transport threads and must not throw.

struct ChannelOptions {
  bool allow_initial_offline = false;
  std::uint64_t initial_backoff_ns = UINT64_C(1000000000);
  std::uint64_t max_backoff_ns = UINT64_C(120000000000);
  std::uint32_t multiplier_millis = 1600;
  std::uint32_t jitter_percent = 20;
  Logger logger;
  std::uint64_t max_response_header_list_size = UINT64_C(65536);
  std::uint64_t max_unary_calls = 4096;
  std::uint64_t max_unary_request_bytes = UINT64_C(67108864);
  std::uint64_t max_streams = 1024;
  std::uint64_t max_stream_buffer_bytes = UINT64_C(1073741824);
};

struct UnaryAdmissionStats {
  std::uint64_t retained_calls = 0;
  std::uint64_t retained_request_bytes = 0;
  std::uint64_t rejected_calls = 0;
};

struct StreamAdmissionStats {
  std::uint64_t retained_streams = 0;
  std::uint64_t reserved_buffer_bytes = 0;
  std::uint64_t rejected_streams = 0;
};

// Owning ABI 1.9 snapshot values; field units and accounting boundaries match
// grpc_lite_channel_operational_stats in grpc_lite.h, not heap/RSS usage.
struct ChannelOperationalStats {
  std::uint64_t unary_retained_calls = 0;
  std::uint64_t unary_retained_request_bytes = 0;
  std::uint64_t unary_rejected_calls = 0;
  std::uint64_t stream_retained_streams = 0;
  std::uint64_t stream_reserved_buffer_bytes = 0;
  std::uint64_t stream_rejected_streams = 0;
  std::uint64_t active_unary_calls = 0;
  std::uint64_t active_streams = 0;
  std::uint64_t active_connections = 0;
  std::uint64_t pending_unary_calls = 0;
  std::uint64_t pending_unary_calls_high_water = 0;
  std::uint64_t stream_inbound_bytes = 0;
  std::uint64_t stream_inbound_bytes_high_water = 0;
  std::uint64_t stream_outbound_bytes = 0;
  std::uint64_t stream_outbound_bytes_high_water = 0;
  std::uint64_t socket_write_bytes = 0;
  std::uint64_t socket_write_bytes_high_water = 0;
  std::uint64_t terminal_ok = 0;
  std::uint64_t terminal_cancelled = 0;
  std::uint64_t terminal_deadline_exceeded = 0;
  std::uint64_t terminal_other = 0;
  std::uint64_t reconnect_attempts = 0;
  std::uint64_t reconnect_successes = 0;
  std::uint64_t reconnect_goaway = 0;
  std::uint64_t reconnect_transport_failure = 0;
};

class ClientStream;

class Channel {
 public:
  Channel() = default;
  ~Channel() { Reset(); }
  Channel(const Channel&) = delete;
  Channel& operator=(const Channel&) = delete;

  Channel(Channel&& other) noexcept
      : channel_(std::exchange(other.channel_, nullptr)),
        logger_(std::move(other.logger_)) {}
  Channel& operator=(Channel&& other) noexcept {
    if (this != &other) {
      Reset();
      channel_ = std::exchange(other.channel_, nullptr);
      logger_ = std::move(other.logger_);
    }
    return *this;
  }

  static Error CreateManaged(Runtime* runtime, std::string target,
                             ChannelOptions options, Channel* out) {
    if (out == nullptr) return Error(ErrorCode::InvalidArgument);
    auto logger = options.logger
                      ? std::make_unique<LoggerState>(std::move(options.logger))
                      : nullptr;
    grpc_lite_logger c_logger = GRPC_LITE_LOGGER_INIT;
    if (logger != nullptr) {
      c_logger.user_data = logger.get();
      c_logger.log = &Log;
    }
    grpc_lite_channel_options c_options = GRPC_LITE_CHANNEL_OPTIONS_INIT;
    c_options.allow_initial_offline = options.allow_initial_offline;
    c_options.initial_backoff_ns = options.initial_backoff_ns;
    c_options.max_backoff_ns = options.max_backoff_ns;
    c_options.multiplier_millis = options.multiplier_millis;
    c_options.jitter_percent = options.jitter_percent;
    c_options.logger = logger == nullptr ? nullptr : &c_logger;
    c_options.max_response_header_list_size =
        options.max_response_header_list_size;

    c_options.max_unary_calls = options.max_unary_calls;
    c_options.max_unary_request_bytes = options.max_unary_request_bytes;
    c_options.max_streams = options.max_streams;
    c_options.max_stream_buffer_bytes = options.max_stream_buffer_bytes;

    grpc_lite_channel* channel = nullptr;
    const Error error(grpc_lite_channel_create_managed(
        runtime == nullptr ? nullptr : runtime->runtime_, internal::Bytes(target),
        &c_options, &channel));
    if (!error.ok()) return error;
    *out = Channel(channel, std::move(logger));
    return {};
  }

  Error GetUnaryAdmissionStats(UnaryAdmissionStats* out) const {
    if (out == nullptr) return Error(ErrorCode::InvalidArgument);
    *out = {};
    grpc_lite_unary_admission_stats stats = GRPC_LITE_UNARY_ADMISSION_STATS_INIT;
    const Error error(grpc_lite_channel_get_unary_admission_stats(channel_, &stats));
    if (!error.ok()) return error;
    *out = {stats.retained_calls, stats.retained_request_bytes, stats.rejected_calls};
    return {};
  }

  Error GetStreamAdmissionStats(StreamAdmissionStats* out) const {
    if (out == nullptr) return Error(ErrorCode::InvalidArgument);
    *out = {};
    grpc_lite_stream_admission_stats stats = GRPC_LITE_STREAM_ADMISSION_STATS_INIT;
    const Error error(grpc_lite_channel_get_stream_admission_stats(channel_, &stats));
    if (!error.ok()) return error;
    *out = {stats.retained_streams, stats.reserved_buffer_bytes, stats.rejected_streams};
    return {};
  }

  // Safe alongside operations/shutdown/wait, including after Wait(), but not
  // owner destruction or moves. Stop/join readers before destroying the owner.
  // Samples are not global transactions; synchronize shared output storage.
  Error GetOperationalStats(ChannelOperationalStats* out) const {
    if (out == nullptr) return Error(ErrorCode::InvalidArgument);
    *out = {};
    grpc_lite_channel_operational_stats stats =
        GRPC_LITE_CHANNEL_OPERATIONAL_STATS_INIT;
    const Error error(
        grpc_lite_channel_get_operational_stats(channel_, &stats));
    if (!error.ok()) return error;
    out->unary_retained_calls = stats.unary_retained_calls;
    out->unary_retained_request_bytes = stats.unary_retained_request_bytes;
    out->unary_rejected_calls = stats.unary_rejected_calls;
    out->stream_retained_streams = stats.stream_retained_streams;
    out->stream_reserved_buffer_bytes = stats.stream_reserved_buffer_bytes;
    out->stream_rejected_streams = stats.stream_rejected_streams;
    out->active_unary_calls = stats.active_unary_calls;
    out->active_streams = stats.active_streams;
    out->active_connections = stats.active_connections;
    out->pending_unary_calls = stats.pending_unary_calls;
    out->pending_unary_calls_high_water = stats.pending_unary_calls_high_water;
    out->stream_inbound_bytes = stats.stream_inbound_bytes;
    out->stream_inbound_bytes_high_water =
        stats.stream_inbound_bytes_high_water;
    out->stream_outbound_bytes = stats.stream_outbound_bytes;
    out->stream_outbound_bytes_high_water =
        stats.stream_outbound_bytes_high_water;
    out->socket_write_bytes = stats.socket_write_bytes;
    out->socket_write_bytes_high_water = stats.socket_write_bytes_high_water;
    out->terminal_ok = stats.terminal_ok;
    out->terminal_cancelled = stats.terminal_cancelled;
    out->terminal_deadline_exceeded = stats.terminal_deadline_exceeded;
    out->terminal_other = stats.terminal_other;
    out->reconnect_attempts = stats.reconnect_attempts;
    out->reconnect_successes = stats.reconnect_successes;
    out->reconnect_goaway = stats.reconnect_goaway;
    out->reconnect_transport_failure = stats.reconnect_transport_failure;
    return {};
  }

  void Shutdown() { grpc_lite_channel_shutdown(channel_); }
  void Wait() { grpc_lite_channel_wait(channel_); }

 private:
  friend class ClientStream;
  struct LoggerState {
    explicit LoggerState(Logger value) : callback(std::move(value)) {}
    Logger callback;
  };

  Channel(grpc_lite_channel* channel, std::unique_ptr<LoggerState> logger)
      : channel_(channel), logger_(std::move(logger)) {}

  static void Log(void* user_data, std::uint32_t level,
                  grpc_lite_bytes_view message) noexcept {
    const auto* data = message.data == nullptr
                           ? ""
                           : reinterpret_cast<const char*>(message.data);
    static_cast<LoggerState*>(user_data)->callback(
        static_cast<LogLevel>(level), {data, message.size});
  }

  void Reset() {
    grpc_lite_channel_destroy(channel_);
    channel_ = nullptr;
    logger_.reset();
  }

  grpc_lite_channel* channel_ = nullptr;
  std::unique_ptr<LoggerState> logger_;
};

}  // namespace grpc_lite

#endif
