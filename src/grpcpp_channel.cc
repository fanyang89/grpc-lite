#include <grpcpp/create_channel.h>

#include <grpcpp/client_context.h>
#include <grpcpp/impl/channel_interface.h>
#include <grpcpp/support/status.h>

#include "grpc_lite/channel.h"
#include "grpc_lite/client_context.h"

#include <memory>
#include <string>

namespace grpc {
namespace {

class ChannelImpl final : public ChannelInterface {
 public:
  explicit ChannelImpl(std::shared_ptr<grpc_lite::Channel> inner)
      : inner_(std::move(inner)) {}

  void* RegisterMethod(const char* method) override {
    (void)method;
    return nullptr;
  }

  Status CallUnary(const char* method, ClientContext* context,
                   const std::string& request_bytes,
                   std::string* response_bytes) override {
    grpc_lite::ClientContext lite_context;
    if (context != nullptr) {
      for (const auto& md : context->metadata()) {
        lite_context.AddMetadata(md.first, md.second);
      }
      if (context->deadline() !=
          std::chrono::system_clock::time_point{}) {
        lite_context.SetDeadline(context->deadline());
      }
    }

    grpc_lite::Status lite_status =
        inner_->CallUnary(method, request_bytes, &lite_context, response_bytes);

    if (context != nullptr) {
      std::vector<std::pair<std::string, std::string>> initial;
      for (const auto& md : lite_context.server_initial_metadata()) {
        initial.push_back(md);
      }
      context->SetServerInitialMetadata(std::move(initial));

      std::vector<std::pair<std::string, std::string>> trailing;
      for (const auto& md : lite_context.server_trailing_metadata()) {
        trailing.push_back(md);
      }
      context->SetServerTrailingMetadata(std::move(trailing));
    }

    if (lite_status.ok()) {
      return Status(StatusCode::OK, "");
    }

    return Status(
        static_cast<StatusCode>(static_cast<int>(lite_status.code())),
        lite_status.message());
  }

 private:
  std::shared_ptr<grpc_lite::Channel> inner_;
};

}  // namespace

std::shared_ptr<ChannelInterface> CreateChannel(const std::string& target) {
  auto lite_channel = grpc_lite::Channel::Create(target);
  return std::make_shared<ChannelImpl>(std::move(lite_channel));
}

}  // namespace grpc
