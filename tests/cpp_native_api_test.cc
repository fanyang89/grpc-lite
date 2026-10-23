#include <grpc_lite/grpc_lite.hpp>

#include <atomic>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <type_traits>
#include <utility>

using grpc_lite::Channel;
using grpc_lite::ClientStream;
using grpc_lite::Metadata;
using grpc_lite::Runtime;
using grpc_lite::Server;
using grpc_lite::ServerCall;

static_assert(!std::is_copy_constructible_v<Runtime>);
static_assert(std::is_nothrow_move_constructible_v<Runtime>);
static_assert(!std::is_copy_constructible_v<Metadata>);
static_assert(std::is_nothrow_move_constructible_v<Metadata>);
static_assert(!std::is_copy_constructible_v<Channel>);
static_assert(std::is_nothrow_move_constructible_v<Channel>);
static_assert(!std::is_copy_constructible_v<ClientStream>);
static_assert(std::is_nothrow_move_constructible_v<ClientStream>);
static_assert(!std::is_copy_constructible_v<Server>);
static_assert(std::is_nothrow_move_constructible_v<Server>);
static_assert(!std::is_copy_constructible_v<ServerCall>);
static_assert(std::is_nothrow_move_constructible_v<ServerCall>);

static_assert(std::is_standard_layout_v<grpc_lite::ChannelOperationalStats>);
static_assert(std::is_trivially_copyable_v<grpc_lite::ChannelOperationalStats>);
static_assert(sizeof(grpc_lite::ChannelOperationalStats) ==
              25 * sizeof(std::uint64_t));
static_assert(std::is_same_v<decltype(&Channel::GetOperationalStats),
                             grpc_lite::Error (Channel::*)(
                                 grpc_lite::ChannelOperationalStats*) const>);
static_assert(std::is_standard_layout_v<grpc_lite::ServerOperationalStats>);
static_assert(std::is_trivially_copyable_v<grpc_lite::ServerOperationalStats>);
static_assert(sizeof(grpc_lite::ServerOperationalStats) ==
              14 * sizeof(std::uint64_t));
static_assert(std::is_same_v<decltype(&Server::GetOperationalStats),
                             grpc_lite::Error (Server::*)(
                                 grpc_lite::ServerOperationalStats*) const>);

namespace {

// Typed member pointers cover every payload field without padding comparisons.
constexpr std::uint64_t grpc_lite::ChannelOperationalStats::*
    kChannelOperationalFields[] = {
        &grpc_lite::ChannelOperationalStats::unary_retained_calls,
        &grpc_lite::ChannelOperationalStats::unary_retained_request_bytes,
        &grpc_lite::ChannelOperationalStats::unary_rejected_calls,
        &grpc_lite::ChannelOperationalStats::stream_retained_streams,
        &grpc_lite::ChannelOperationalStats::stream_reserved_buffer_bytes,
        &grpc_lite::ChannelOperationalStats::stream_rejected_streams,
        &grpc_lite::ChannelOperationalStats::active_unary_calls,
        &grpc_lite::ChannelOperationalStats::active_streams,
        &grpc_lite::ChannelOperationalStats::active_connections,
        &grpc_lite::ChannelOperationalStats::pending_unary_calls,
        &grpc_lite::ChannelOperationalStats::pending_unary_calls_high_water,
        &grpc_lite::ChannelOperationalStats::stream_inbound_bytes,
        &grpc_lite::ChannelOperationalStats::stream_inbound_bytes_high_water,
        &grpc_lite::ChannelOperationalStats::stream_outbound_bytes,
        &grpc_lite::ChannelOperationalStats::stream_outbound_bytes_high_water,
        &grpc_lite::ChannelOperationalStats::socket_write_bytes,
        &grpc_lite::ChannelOperationalStats::socket_write_bytes_high_water,
        &grpc_lite::ChannelOperationalStats::terminal_ok,
        &grpc_lite::ChannelOperationalStats::terminal_cancelled,
        &grpc_lite::ChannelOperationalStats::terminal_deadline_exceeded,
        &grpc_lite::ChannelOperationalStats::terminal_other,
        &grpc_lite::ChannelOperationalStats::reconnect_attempts,
        &grpc_lite::ChannelOperationalStats::reconnect_successes,
        &grpc_lite::ChannelOperationalStats::reconnect_goaway,
        &grpc_lite::ChannelOperationalStats::reconnect_transport_failure,
};

void CheckEmptyChannelOperationalStats(const Channel& owner) {
  grpc_lite::ChannelOperationalStats stats;
  for (auto field : kChannelOperationalFields) {
    assert(stats.*field == 0);
    stats.*field = UINT64_MAX;
  }
  assert(owner.GetOperationalStats(nullptr).code() ==
         grpc_lite::ErrorCode::InvalidArgument);
  assert(owner.GetOperationalStats(&stats).code() ==
         grpc_lite::ErrorCode::InvalidArgument);
  for (auto field : kChannelOperationalFields) assert(stats.*field == 0);
}

// Typed member pointers cover every payload field without padding comparisons.
constexpr std::uint64_t grpc_lite::ServerOperationalStats::*
    kServerOperationalFields[] = {
        &grpc_lite::ServerOperationalStats::admitted_connections,
        &grpc_lite::ServerOperationalStats::active_rpcs,
        &grpc_lite::ServerOperationalStats::rejected_connections,
        &grpc_lite::ServerOperationalStats::pre_ack_rejected_streams,
        &grpc_lite::ServerOperationalStats::streaming_outbound_reserved_bytes,
        &grpc_lite::ServerOperationalStats::
            streaming_outbound_reserved_bytes_high_water_sum,
        &grpc_lite::ServerOperationalStats::socket_queued_write_bytes,
        &grpc_lite::ServerOperationalStats::
            socket_queued_write_bytes_high_water_sum,
        &grpc_lite::ServerOperationalStats::close_peer_transport,
        &grpc_lite::ServerOperationalStats::close_protocol_local,
        &grpc_lite::ServerOperationalStats::close_preface_timeout,
        &grpc_lite::ServerOperationalStats::close_idle_timeout,
        &grpc_lite::ServerOperationalStats::close_graceful_drain,
        &grpc_lite::ServerOperationalStats::close_forced_shutdown,
};

void CheckEmptyServerOperationalStats(const Server& owner) {
  grpc_lite::ServerOperationalStats stats;
  for (auto field : kServerOperationalFields) {
    assert(stats.*field == 0);
    stats.*field = UINT64_MAX;
  }
  assert(owner.GetOperationalStats(nullptr).code() ==
         grpc_lite::ErrorCode::InvalidArgument);
  assert(owner.GetOperationalStats(&stats).code() ==
         grpc_lite::ErrorCode::InvalidArgument);
  for (auto field : kServerOperationalFields) assert(stats.*field == 0);
}

void TestMetadata() {
  Metadata metadata;
  assert(Metadata::Create(&metadata).ok());
  assert(metadata.Add("x-order", "first").ok());
  assert(metadata.Add("x-order", "second").ok());
  const std::string binary("a\0b", 3);
  assert(metadata.Add("trace-bin", binary).ok());

  grpc_lite::MetadataEntries entries;
  assert(metadata.CopyEntries(&entries).ok());
  assert(entries.size() == 3);
  assert(entries[0] == std::make_pair(std::string("x-order"),
                                      std::string("first")));
  assert(entries[1] == std::make_pair(std::string("x-order"),
                                      std::string("second")));
  assert(entries[2].first == "trace-bin");
  assert(entries[2].second == binary);

  std::string key;
  std::string value;
  assert(metadata.At(2, &key, &value).ok());
  assert(key == "trace-bin");
  assert(value == binary);
}

void TestInvalidObjects() {
  ServerCall call;
  ServerCall clone;
  assert(call.id() == 0);
  assert(!call.cancelled());
  assert(!call.terminal());
  call.Abort();
  assert(call.Clone(&clone).code() == grpc_lite::ErrorCode::InvalidState);
  assert(call.Send("x").code() == grpc_lite::ErrorCode::InvalidState);
  assert(call.ResumeReceive().code() == grpc_lite::ErrorCode::InvalidState);

  auto logger_token = std::make_shared<int>(1);
  std::weak_ptr<int> weak = logger_token;
  grpc_lite::ChannelOptions options;
  assert(options.max_response_header_list_size == UINT64_C(65536));
  options.max_response_header_list_size = 4096;
  options.logger = [token = std::move(logger_token)](
                       grpc_lite::LogLevel, std::string_view) {};
  Channel channel;
  grpc_lite::StreamAdmissionStats stream_stats;
  assert(channel.GetStreamAdmissionStats(&stream_stats).code() == grpc_lite::ErrorCode::InvalidArgument);
  assert(channel.GetStreamAdmissionStats(nullptr).code() == grpc_lite::ErrorCode::InvalidArgument);
  assert(options.max_streams == 1024);
  assert(options.max_stream_buffer_bytes == UINT64_C(1073741824));
  grpc_lite::UnaryAdmissionStats stats;
  assert(channel.GetUnaryAdmissionStats(&stats).code() == grpc_lite::ErrorCode::InvalidArgument);
  assert(channel.GetUnaryAdmissionStats(nullptr).code() == grpc_lite::ErrorCode::InvalidArgument);
  assert(options.max_unary_calls == 4096);
  assert(options.max_unary_request_bytes == UINT64_C(67108864));
  const grpc_lite::Error error =
      Channel::CreateManaged(nullptr, "invalid", std::move(options), &channel);
  assert(error.code() == grpc_lite::ErrorCode::InvalidArgument);
  options.logger = {};
  assert(weak.expired());
  options = {};
  options.allow_initial_offline = true;
  options.max_unary_calls = 0;
  assert(Channel::CreateManaged(nullptr, "127.0.0.1:1", options, &channel).code() ==
         grpc_lite::ErrorCode::InvalidArgument);
  options.max_unary_calls = 1;
  options.max_unary_request_bytes = 0;
  assert(Channel::CreateManaged(nullptr, "127.0.0.1:1", options, &channel).code() ==
         grpc_lite::ErrorCode::InvalidArgument);
  options.max_unary_request_bytes = 1;
  options.max_streams = 0;
  assert(Channel::CreateManaged(nullptr, "127.0.0.1:1", options, &channel).code() ==
         grpc_lite::ErrorCode::InvalidArgument);
  options.max_streams = 1;
  options.max_stream_buffer_bytes = 0;
  assert(Channel::CreateManaged(nullptr, "127.0.0.1:1", options, &channel).code() ==
         grpc_lite::ErrorCode::InvalidArgument);
  options.max_stream_buffer_bytes = 1;
  assert(Channel::CreateManaged(nullptr, "127.0.0.1:1", options, &channel).ok());
  assert(channel.GetUnaryAdmissionStats(&stats).ok());
  assert(stats.retained_calls == 0 && stats.retained_request_bytes == 0);
  assert(stats.rejected_calls == 0);
  assert(channel.GetStreamAdmissionStats(&stream_stats).ok());
  assert(stream_stats.retained_streams == 0 && stream_stats.reserved_buffer_bytes == 0);
  assert(stream_stats.rejected_streams == 0);
  channel.Shutdown();
  channel.Wait();
}

void TestRejectedOpenCleanup() {
  grpc_lite::ChannelOptions channel_options;
  channel_options.allow_initial_offline = true;
  channel_options.max_stream_buffer_bytes = UINT64_C(16777216);
  Channel channel;
  assert(Channel::CreateManaged(nullptr, "127.0.0.1:1", channel_options,
                                &channel).ok());
  // No live transport can race validation, quota rejection, or enqueue rejection.
  channel.Shutdown();
  channel.Wait();
  std::atomic<unsigned> callback_count{0};
  std::uint64_t rejected_streams = 0;
  for (unsigned case_index = 0; case_index < 5; ++case_index) {
    grpc_lite::ClientStreamOptions options;
    std::string method = "/test.Native/Rejected";
    auto expected = grpc_lite::ErrorCode::InvalidArgument;
    switch (case_index) {
      case 0: method = "invalid"; break;
      case 1: options.send_compression = static_cast<grpc_lite::Compression>(2); break;
      case 2: options.max_message_size = 0; break;
      case 3:
        options.max_inbound_buffer_size = UINT64_C(16777216);
        expected = grpc_lite::ErrorCode::WouldBlock;
        ++rejected_streams;
        break;
      case 4: expected = grpc_lite::ErrorCode::Unavailable; break;
    }
    auto token = std::make_shared<int>(1);
    std::weak_ptr<int> weak = token;
    grpc_lite::ClientStreamCallbacks callbacks;
    callbacks.on_headers = [&](grpc_lite::MetadataEntries) { ++callback_count; };
    callbacks.on_message = [&](std::string, grpc_lite::Compression) {
      ++callback_count;
      return grpc_lite::ReceiveAction::Continue;
    };
    callbacks.on_remote_end = [&] { ++callback_count; };
    callbacks.on_writable = [&] { ++callback_count; };
    callbacks.on_terminal = [&, token = std::move(token)](
        grpc_lite::Status, grpc_lite::MetadataEntries) { ++callback_count; };
    ClientStream rejected;
    assert(ClientStream::Open(channel, method, options, std::move(callbacks),
                              &rejected).code() == expected);
    callbacks = {};
    // Failed Open releases its allocated callback state and leaves no stream owner.
    assert(weak.expired());
    assert(rejected.Send("x").code() == grpc_lite::ErrorCode::InvalidState);
    assert(callback_count.load() == 0);
    grpc_lite::StreamAdmissionStats stats;
    assert(channel.GetStreamAdmissionStats(&stats).ok());
    assert(stats.retained_streams == 0 && stats.reserved_buffer_bytes == 0);
    assert(stats.rejected_streams == rejected_streams);
  }
}

void TestOperationalStats() {
  Channel empty_channel;
  Server empty_server;
  CheckEmptyChannelOperationalStats(empty_channel);
  CheckEmptyServerOperationalStats(empty_server);

  Server server;
  assert(Server::Create({}, &server).ok());
  grpc_lite::ServerOperationalStats server_stats;
  const Server& server_view = server;
  assert(server_view.GetOperationalStats(&server_stats).ok());
  for (auto field : kServerOperationalFields) assert(server_stats.*field == 0);
  assert(server_view.GetOperationalStats(nullptr).code() ==
         grpc_lite::ErrorCode::InvalidArgument);
  Server moved_server(std::move(server));
  CheckEmptyServerOperationalStats(server);
  server = std::move(moved_server);
  CheckEmptyServerOperationalStats(moved_server);
  assert(server.Start().ok());
  std::uint32_t port = 0;
  assert(server.Port(&port).ok());

  Channel channel;
  assert(Channel::CreateManaged(nullptr, "127.0.0.1:" + std::to_string(port),
                                {}, &channel)
             .ok());
  grpc_lite::ChannelOperationalStats channel_stats;
  const Channel& channel_view = channel;
  assert(channel_view.GetOperationalStats(&channel_stats).ok());
  assert(channel_stats.active_connections == 1);
  assert(channel_stats.active_unary_calls == 0);
  assert(channel_stats.active_streams == 0);
  assert(channel_view.GetOperationalStats(nullptr).code() ==
         grpc_lite::ErrorCode::InvalidArgument);
  Channel moved_channel(std::move(channel));
  CheckEmptyChannelOperationalStats(channel);
  channel = std::move(moved_channel);
  CheckEmptyChannelOperationalStats(moved_channel);
  assert(server_view.GetOperationalStats(&server_stats).ok());
  // Independent live samples are not compared for equality.
  assert(server_stats.active_rpcs == 0);

  channel.Shutdown();
  channel.Wait();
  server.Shutdown();
  server.Wait();
  assert(channel_view.GetOperationalStats(&channel_stats).ok());
  assert(channel_stats.active_connections == 0);
  assert(channel_stats.socket_write_bytes == 0);
  assert(server_view.GetOperationalStats(&server_stats).ok());
  assert(server_stats.admitted_connections == 0);
  assert(server_stats.active_rpcs == 0);
  assert(server_stats.streaming_outbound_reserved_bytes == 0);
  assert(server_stats.socket_queued_write_bytes == 0);

  // Once both owners are joined and no stream handles exist, every field is
  // stable. Copies own their values and remain valid after owner destruction.
  const auto channel_copy = channel_stats;
  const auto server_copy = server_stats;
  assert(channel_view.GetOperationalStats(&channel_stats).ok());
  assert(server_view.GetOperationalStats(&server_stats).ok());
  for (auto field : kChannelOperationalFields)
    assert(channel_stats.*field == channel_copy.*field);
  for (auto field : kServerOperationalFields)
    assert(server_stats.*field == server_copy.*field);
  channel = {};
  server = {};
  CheckEmptyChannelOperationalStats(channel);
  CheckEmptyServerOperationalStats(server);
  for (auto field : kChannelOperationalFields)
    assert(channel_stats.*field == channel_copy.*field);
  for (auto field : kServerOperationalFields)
    assert(server_stats.*field == server_copy.*field);
}

struct RoundTripState {
  std::mutex mutex;
  std::condition_variable completed;
  unsigned headers_received = 0;
  unsigned messages = 0;
  unsigned terminals = 0;
  bool client_ok = false;
  bool server_context_ok = false;
  bool server_terminal = false;
  std::size_t started_call_id = 0;
  std::size_t terminal_call_id = 0;
  grpc_lite::MetadataEntries headers;
  grpc_lite::MetadataEntries trailers;
  std::string response;
};

void TestRoundTripRetainedStreamOwnership() {
  // Inbound capacity must cover the default 64 KiB stream window.
  constexpr std::uint64_t inbound_capacity = 64 * 1024;
  constexpr std::uint64_t outbound_capacity = 4096;
  constexpr std::uint64_t reserved_bytes = inbound_capacity + outbound_capacity;
  Runtime runtime;
  assert(Runtime::Create(&runtime).ok());

  Metadata initial_metadata;
  Metadata trailing_metadata;
  assert(Metadata::Create(&initial_metadata).ok());
  assert(Metadata::Create(&trailing_metadata).ok());
  assert(initial_metadata.Add("x-header", "one").ok());
  assert(initial_metadata.Add("x-header", "two").ok());
  assert(trailing_metadata.Add("trace-bin", std::string("\0\1", 2)).ok());

  RoundTripState state;
  std::atomic<int> log_count{0};
  Server server;
  grpc_lite::ServerOptions server_options;
  assert(server_options.max_connections == UINT64_C(1024));
  assert(server_options.max_concurrent_streams_per_connection == 100);
  assert(server_options.cleartext_preface_timeout_ns == UINT64_C(10000000000));
  assert(server_options.connection_idle_timeout_ns == UINT64_C(300000000000));
  server_options.max_connections = UINT64_C(2048);
  server_options.max_concurrent_streams_per_connection = 128;
  server_options.logger = [&log_count](grpc_lite::LogLevel,
                                        std::string_view) {
    log_count.fetch_add(1, std::memory_order_relaxed);
  };
  assert(Server::Create(std::move(server_options), &server).ok());

  grpc_lite::ServerStreamCallbacks server_callbacks;
  server_callbacks.on_start = [&state](grpc_lite::ServerStream& stream,
                                        const grpc_lite::ServerContext&) {
    ServerCall call;
    assert(stream.Retain(&call).ok());
    state.started_call_id = call.id();
  };
  server_callbacks.on_message =
      [&state, &initial_metadata](grpc_lite::ServerStream& stream,
                                  const grpc_lite::ServerContext& context,
                                  std::string payload,
                                  grpc_lite::Compression compression) {
        state.server_context_ok =
            payload == std::string("request\0bytes", 13) &&
            compression == grpc_lite::Compression::Identity &&
            context.request_compression() == grpc_lite::Compression::Identity &&
            context.request_metadata().size() == 2 &&
            context.request_metadata()[0].first == "x-client" &&
            context.request_metadata()[0].second == "first" &&
            context.request_metadata()[1].first == "x-client-bin" &&
            context.request_metadata()[1].second == std::string("\0x", 2);
        ServerCall call;
        assert(stream.Retain(&call).ok());
        assert(call.id() != 0);
        assert(call.SendInitialMetadata(&initial_metadata).ok());
        return grpc_lite::ReceiveAction::Continue;
      };
  server_callbacks.on_remote_end =
      [&trailing_metadata](grpc_lite::ServerStream& stream,
                           const grpc_lite::ServerContext&) {
        ServerCall call;
        assert(stream.Retain(&call).ok());
        assert(call.Send(std::string("response\0bytes", 14)).ok());
        assert(call.Finish({}, &trailing_metadata).ok());
      };
  server_callbacks.on_terminal =
      [&state](std::size_t call_id, grpc_lite::ServerTerminalReason reason) {
        std::lock_guard<std::mutex> lock(state.mutex);
        state.server_terminal =
            reason == grpc_lite::ServerTerminalReason::Completed;
        state.terminal_call_id = call_id;
      };
  assert(server.RegisterStream("/test.Native/Echo", {},
                               std::move(server_callbacks))
             .ok());
  assert(server.Start().ok());
  std::uint32_t port = 0;
  assert(server.Port(&port).ok());
  assert(port != 0);

  auto logger_token = std::make_shared<int>(2);
  std::weak_ptr<int> logger_weak = logger_token;
  auto callback_token = std::make_shared<int>(3);
  std::weak_ptr<int> callback_weak = callback_token;
  ClientStream survivor;
  {
    grpc_lite::ChannelOptions channel_options;
    channel_options.max_streams = 1;
    channel_options.max_stream_buffer_bytes = reserved_bytes;
    channel_options.logger =
        [token = std::move(logger_token), &log_count](
            grpc_lite::LogLevel, std::string_view) {
          assert(*token == 2);
          log_count.fetch_add(1, std::memory_order_relaxed);
        };
    Channel channel;
    assert(Channel::CreateManaged(
               &runtime, "127.0.0.1:" + std::to_string(port),
               std::move(channel_options), &channel)
               .ok());
    grpc_lite::ChannelOperationalStats live_channel_stats;
    assert(channel.GetOperationalStats(&live_channel_stats).ok());
    assert(live_channel_stats.active_connections == 1);
    grpc_lite::ServerOperationalStats live_server_stats;
    assert(server.GetOperationalStats(&live_server_stats).ok());
    assert(live_server_stats.active_rpcs == 0);
    channel_options.logger = {};
    assert(!logger_weak.expired());

    Metadata request_metadata;
    assert(Metadata::Create(&request_metadata).ok());
    assert(request_metadata.Add("x-client", "first").ok());
    assert(request_metadata.Add("x-client-bin", std::string("\0x", 2)).ok());
    grpc_lite::ClientStreamOptions stream_options;
    stream_options.metadata = &request_metadata;
    stream_options.has_timeout = true;
    stream_options.timeout_ns = UINT64_C(5000000000);
    stream_options.max_message_size = 1024;
    stream_options.max_inbound_buffer_size = inbound_capacity;
    stream_options.max_outbound_buffer_size = outbound_capacity;
    grpc_lite::ClientStreamCallbacks client_callbacks;
    client_callbacks.on_headers = [&state](grpc_lite::MetadataEntries entries) {
      std::lock_guard<std::mutex> lock(state.mutex);
      assert(state.headers_received == state.terminals);
      ++state.headers_received;
      state.headers = std::move(entries);
    };
    client_callbacks.on_message =
        [&state](std::string payload, grpc_lite::Compression compression) {
          std::lock_guard<std::mutex> lock(state.mutex);
          assert(state.messages == state.terminals);
          ++state.messages;
          state.response = std::move(payload);
          assert(compression == grpc_lite::Compression::Identity);
          return grpc_lite::ReceiveAction::Continue;
        };
    client_callbacks.on_terminal =
        [&state, token = std::move(callback_token)](
            grpc_lite::Status status, grpc_lite::MetadataEntries trailers) {
          assert(*token == 3);
          assert(status.ok());
          std::lock_guard<std::mutex> lock(state.mutex);
          state.client_ok = status.ok();
          state.trailers = std::move(trailers);
          ++state.terminals;
          state.completed.notify_one();
        };

    ClientStream stream;
    assert(ClientStream::Open(channel, "/test.Native/Echo", stream_options,
                              client_callbacks, &stream)
               .ok());
    // Rejected sends must not change admission or poison the following valid send.
    grpc_lite::StreamAdmissionStats before_send;
    assert(channel.GetStreamAdmissionStats(&before_send).ok());
    assert(before_send.retained_streams == 1 && before_send.reserved_buffer_bytes == reserved_bytes);
    assert(before_send.rejected_streams == 0);
    assert(stream.Send(std::string(1025, 'x')).code() == grpc_lite::ErrorCode::OutOfRange);
    assert(stream.Send("x", grpc_lite::Compression::Gzip).code() ==
           grpc_lite::ErrorCode::InvalidArgument);
    assert(stream.Send("x", static_cast<grpc_lite::Compression>(2)).code() ==
           grpc_lite::ErrorCode::InvalidArgument);
    grpc_lite::StreamAdmissionStats after_send;
    assert(channel.GetStreamAdmissionStats(&after_send).ok());
    assert(after_send.retained_streams == before_send.retained_streams);
    assert(after_send.reserved_buffer_bytes == before_send.reserved_buffer_bytes);
    assert(after_send.rejected_streams == before_send.rejected_streams);
    assert(stream.Send(std::string("request\0bytes", 13)).ok());
    assert(stream.CloseSend().ok());

    std::unique_lock<std::mutex> lock(state.mutex);
    assert(state.completed.wait_for(lock, std::chrono::seconds(5),
                                    [&state] { return state.terminals == 1; }));
    lock.unlock();
    grpc_lite::StreamAdmissionStats stats;
    assert(channel.GetStreamAdmissionStats(&stats).ok());
    assert(stats.retained_streams == 1 && stats.reserved_buffer_bytes == reserved_bytes);
    ClientStream rejected;
    assert(ClientStream::Open(channel, "/test.Native/Echo", stream_options,
                              client_callbacks, &rejected).code() ==
           grpc_lite::ErrorCode::WouldBlock);
    assert(channel.GetStreamAdmissionStats(&stats).ok());
    assert(stats.retained_streams == 1 && stats.reserved_buffer_bytes == reserved_bytes);
    assert(stats.rejected_streams == 1);

    // Moving transfers the reservation; resetting releases only the new owner.
    ClientStream moved = std::move(stream);
    assert(stream.Send("late").code() == grpc_lite::ErrorCode::InvalidState);
    assert(channel.GetStreamAdmissionStats(&stats).ok());
    assert(stats.retained_streams == 1 && stats.reserved_buffer_bytes == reserved_bytes);
    moved = ClientStream{};
    // Terminal notification can precede transport retirement. Observe release,
    // rather than relying on a sleep or assuming callback return retires it.
    const auto release_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(5);
    do {
      assert(channel.GetStreamAdmissionStats(&stats).ok());
      if (stats.retained_streams == 0) break;
      assert(std::chrono::steady_clock::now() < release_deadline);
      std::this_thread::yield();
    } while (true);
    assert(stats.reserved_buffer_bytes == 0 && stats.rejected_streams == 1);
    assert(ClientStream::Open(channel, "/test.Native/Echo", stream_options,
                              std::move(client_callbacks), &survivor).ok());
    client_callbacks = {};
    assert(survivor.Send(std::string("request\0bytes", 13)).ok());
    assert(survivor.CloseSend().ok());
    lock.lock();
    assert(state.completed.wait_for(lock, std::chrono::seconds(5),
                                    [&state] { return state.terminals == 2; }));
    lock.unlock();
    channel.Shutdown();
    channel.Wait();
    assert(channel.GetStreamAdmissionStats(&stats).ok());
    assert(stats.retained_streams == 1 && stats.reserved_buffer_bytes == reserved_bytes);
    assert(stats.rejected_streams == 1);
    grpc_lite::ChannelOperationalStats stopped;
    assert(channel.GetOperationalStats(&stopped).ok());
    // Joined Channel: the terminal stream still owns its admission reservation.
    grpc_lite::UnaryAdmissionStats unary_admission;
    grpc_lite::StreamAdmissionStats stream_admission;
    assert(channel.GetUnaryAdmissionStats(&unary_admission).ok());
    assert(channel.GetStreamAdmissionStats(&stream_admission).ok());
    assert(stopped.unary_retained_calls == unary_admission.retained_calls);
    assert(stopped.unary_retained_request_bytes ==
           unary_admission.retained_request_bytes);
    assert(stopped.unary_rejected_calls == unary_admission.rejected_calls);
    assert(stopped.stream_retained_streams ==
           stream_admission.retained_streams);
    assert(stopped.stream_reserved_buffer_bytes ==
           stream_admission.reserved_buffer_bytes);
    assert(stopped.stream_rejected_streams ==
           stream_admission.rejected_streams);
    assert(stopped.stream_retained_streams == 1);
    assert(stopped.stream_reserved_buffer_bytes ==
           stream_options.max_inbound_buffer_size +
               stream_options.max_outbound_buffer_size);
    assert(stopped.active_unary_calls == 0);
    assert(stopped.active_streams == 0);
    assert(stopped.active_connections == 0);
    assert(stopped.pending_unary_calls == 0);
    assert(stopped.pending_unary_calls_high_water == 0);
    assert(stopped.stream_inbound_bytes == 0);
    assert(stopped.stream_outbound_bytes == 0);
    assert(stopped.stream_outbound_bytes_high_water >= 18);
    assert(stopped.socket_write_bytes == 0);
    assert(stopped.socket_write_bytes_high_water > 0);
    assert(stopped.terminal_ok == 2);
    assert(stopped.terminal_cancelled == 0);
    assert(stopped.terminal_deadline_exceeded == 0);
    assert(stopped.terminal_other == 0);
    assert(stopped.reconnect_attempts == 0);
    assert(stopped.reconnect_successes == 0);
    assert(stopped.reconnect_goaway == 0);
    assert(stopped.reconnect_transport_failure == 0);
  }  // Destroy the actual Channel while survivor still owns its stream.
  assert(logger_weak.expired());
  assert(!callback_weak.expired());
  assert(survivor.Send("late").code() == grpc_lite::ErrorCode::Closed);
  assert(survivor.CloseSend().code() == grpc_lite::ErrorCode::Closed);
  assert(survivor.ResumeReceive().code() == grpc_lite::ErrorCode::Closed);
  survivor.Cancel();
  survivor = ClientStream{};
  assert(callback_weak.expired());
  assert(state.headers_received == 2 && state.messages == 2);
  assert(state.terminals == 2);

  server.ShutdownGracefully(UINT64_C(1000000000));
  server.Wait();
  grpc_lite::ServerOperationalStats stopped_server;
  assert(server.GetOperationalStats(&stopped_server).ok());
  assert(stopped_server.admitted_connections == 0);
  assert(stopped_server.active_rpcs == 0);
  assert(stopped_server.rejected_connections == 0);
  assert(stopped_server.pre_ack_rejected_streams == 0);
  assert(stopped_server.streaming_outbound_reserved_bytes == 0);
  assert(stopped_server.streaming_outbound_reserved_bytes_high_water_sum >= 19);
  assert(stopped_server.socket_queued_write_bytes == 0);
  assert(stopped_server.socket_queued_write_bytes_high_water_sum > 0);
  assert(stopped_server.close_protocol_local == 0);
  assert(stopped_server.close_preface_timeout == 0);
  assert(stopped_server.close_idle_timeout == 0);
  // Peer close and graceful drain can race; only the disjoint total is fixed.
  assert(stopped_server.close_peer_transport +
             stopped_server.close_graceful_drain +
             stopped_server.close_forced_shutdown ==
         1);
  assert(state.client_ok);
  assert(state.server_context_ok);
  assert(state.server_terminal);
  assert(state.started_call_id != 0);
  assert(state.terminal_call_id == state.started_call_id);
  assert(state.headers.size() == 2);
  assert(state.headers[0].second == "one");
  assert(state.headers[1].second == "two");
  assert(state.response == std::string("response\0bytes", 14));
  assert(state.trailers.size() == 1);
  assert(state.trailers[0].first == "trace-bin");
  assert(state.trailers[0].second == std::string("\0\1", 2));
  assert(log_count.load(std::memory_order_relaxed) > 0);
}

}  // namespace

int main() {
  TestMetadata();
  TestInvalidObjects();
  TestRejectedOpenCleanup();
  TestOperationalStats();
  TestRoundTripRetainedStreamOwnership();
  return 0;
}
