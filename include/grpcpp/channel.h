#ifndef GRPCPP_CHANNEL_H
#define GRPCPP_CHANNEL_H

#include <grpc_lite/grpc_lite.h>
#include <grpcpp/client_context.h>
#include <grpcpp/security/credentials.h>
#include <grpcpp/support/status.h>

#include <chrono>
#include <cstdint>
#include <limits>
#include <memory>
#include <string>

namespace grpc {

class ChannelInterface {
 public:
  virtual ~ChannelInterface() = default;
  virtual Status CallUnary(const std::string& method, ClientContext* context,
                           const std::string& request,
                           std::string* response) = 0;
};

class Channel final : public ChannelInterface {
 public:
  ~Channel() override;
  Channel(const Channel&) = delete;
  Channel& operator=(const Channel&) = delete;

  Status CallUnary(const std::string& method, ClientContext* context,
                   const std::string& request, std::string* response) override;

 private:
  friend std::shared_ptr<Channel> CreateChannel(
      const std::string&, const std::shared_ptr<class ChannelCredentials>&);
  Channel(const std::string& target,
          const std::shared_ptr<ChannelCredentials>& credentials);

  grpc_lite_channel* channel_ = nullptr;
  Status construction_status_;
};

namespace internal {

inline grpc_lite_bytes_view ByteView(const std::string& value) {
  return {reinterpret_cast<const uint8_t*>(value.data()), value.size()};
}

inline std::string CopyBytes(grpc_lite_bytes_view value) {
  if (value.size == 0) return {};
  return {reinterpret_cast<const char*>(value.data), value.size};
}

inline Status AbiStatus(grpc_lite_error error) {
  StatusCode code = StatusCode::INTERNAL;
  switch (error) {
    case GRPC_LITE_ERROR_INVALID_ARGUMENT:
      code = StatusCode::INVALID_ARGUMENT;
      break;
    case GRPC_LITE_ERROR_OUT_OF_MEMORY:
      code = StatusCode::RESOURCE_EXHAUSTED;
      break;
    case GRPC_LITE_ERROR_UNSUPPORTED:
      code = StatusCode::UNIMPLEMENTED;
      break;
    case GRPC_LITE_ERROR_UNAVAILABLE:
    case GRPC_LITE_ERROR_CLOSED:
      code = StatusCode::UNAVAILABLE;
      break;
    case GRPC_LITE_ERROR_INVALID_STATE:
      code = StatusCode::FAILED_PRECONDITION;
      break;
    default:
      break;
  }
  return {code, grpc_lite_error_string(error)};
}

inline void CopyMetadata(const grpc_lite_unary_result* result, uint32_t trailing,
                         ClientContext::MetadataMap* output) {
  output->clear();
  const size_t count = grpc_lite_unary_result_metadata_count(result, trailing);
  for (size_t index = 0; index < count; ++index) {
    grpc_lite_metadata_entry_view entry{};
    if (grpc_lite_unary_result_metadata_at(result, trailing, index, &entry) !=
        GRPC_LITE_OK) return;
    output->emplace(CopyBytes(entry.key), CopyBytes(entry.value));
  }
}

}  // namespace internal

inline Channel::Channel(
    const std::string& target,
    const std::shared_ptr<ChannelCredentials>& credentials) {
  if (credentials == nullptr || !credentials->is_insecure()) {
    construction_status_ =
        {StatusCode::UNIMPLEMENTED, "only insecure channel credentials are supported"};
    return;
  }
  const grpc_lite_error error = grpc_lite_channel_create(
      nullptr, internal::ByteView(target), &channel_);
  if (error != GRPC_LITE_OK) construction_status_ = internal::AbiStatus(error);
}

inline Channel::~Channel() { grpc_lite_channel_destroy(channel_); }

inline Status Channel::CallUnary(const std::string& method,
                                 ClientContext* context,
                                 const std::string& request,
                                 std::string* response) {
  if (!construction_status_.ok()) return construction_status_;
  if (context == nullptr || response == nullptr) {
    return {StatusCode::INVALID_ARGUMENT, "null unary call argument"};
  }
  grpc_lite_metadata* metadata = nullptr;
  grpc_lite_error error = grpc_lite_metadata_create(&metadata);
  if (error != GRPC_LITE_OK) return internal::AbiStatus(error);
  struct MetadataDestroyer {
    void operator()(grpc_lite_metadata* value) const { grpc_lite_metadata_destroy(value); }
  };
  std::unique_ptr<grpc_lite_metadata, MetadataDestroyer> metadata_owner(metadata);
  for (const auto& entry : context->metadata_) {
    error = grpc_lite_metadata_add(metadata, internal::ByteView(entry.first),
                                   internal::ByteView(entry.second));
    if (error != GRPC_LITE_OK) return internal::AbiStatus(error);
  }

  grpc_lite_unary_options options = GRPC_LITE_UNARY_OPTIONS_INIT;
  options.metadata = metadata;
  if (context->has_deadline_) {
    const long double now = std::chrono::duration<long double>(
                                std::chrono::system_clock::now().time_since_epoch()).count();
    const long double seconds = context->deadline_seconds_ - now;
    const long double max_seconds =
        static_cast<long double>(std::numeric_limits<uint64_t>::max()) / 1000000000.0L;
    options.has_timeout = 1;
    if (seconds <= 0) {
      options.timeout_ns = 0;
    } else if (seconds >= max_seconds) {
      options.timeout_ns = std::numeric_limits<uint64_t>::max();
    } else {
      options.timeout_ns = static_cast<uint64_t>(seconds * 1000000000.0L);
    }
  }

  grpc_lite_unary_result* result = nullptr;
  error = grpc_lite_channel_call_unary(
      channel_, internal::ByteView(method), internal::ByteView(request), &options,
      &result);
  if (error != GRPC_LITE_OK) return internal::AbiStatus(error);
  struct ResultDestroyer {
    void operator()(grpc_lite_unary_result* value) const {
      grpc_lite_unary_result_destroy(value);
    }
  };
  std::unique_ptr<grpc_lite_unary_result, ResultDestroyer> result_owner(result);

  internal::CopyMetadata(result, 0, &context->initial_metadata_);
  internal::CopyMetadata(result, 1, &context->trailing_metadata_);
  Status status(
      static_cast<StatusCode>(grpc_lite_unary_result_status_code(result)),
      internal::CopyBytes(grpc_lite_unary_result_status_message(result)));
  if (!status.ok()) return status;
  *response = internal::CopyBytes(grpc_lite_unary_result_payload(result));
  return status;
}

}  // namespace grpc

#endif
