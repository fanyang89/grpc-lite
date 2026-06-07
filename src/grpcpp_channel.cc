#include <memory>
#include <string>
#include <utility>
#include <vector>

#include <grpcpp/client_context.h>
#include <grpcpp/create_channel.h>
#include <grpcpp/impl/channel_interface.h>
#include <grpcpp/support/status.h>

#include "grpc_lite/channel.h"
#include "grpc_lite/client_context.h"

namespace grpc {
namespace {

class ChannelImpl final : public ChannelInterface {
  public:
    explicit ChannelImpl(std::shared_ptr<grpc_lite::Channel> inner) : inner_(std::move(inner)) {}

    void* RegisterMethod(const char* method) override {
        (void)method;
        return nullptr;
    }

    Status CallUnary(
        const char* method, ClientContext* context, const std::string& request_bytes,
        std::string* response_bytes
    ) override {
        grpc_lite::ClientContext lite_context;
        if (context != nullptr) {
            for (const auto& md : context->metadata()) {
                lite_context.AddMetadata(md.first, md.second);
            }
            if (context->deadline() != std::chrono::system_clock::time_point{}) {
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
            static_cast<StatusCode>(static_cast<int>(lite_status.code())), lite_status.message()
        );
    }

    Status CallServerStreaming(
        const char* method, ClientContext* context, const std::string& request_bytes,
        std::vector<std::string>* response_messages
    ) override {
        grpc_lite::ClientContext lite_context;
        CopyRequestContext(context, &lite_context);
        grpc_lite::Status lite_status =
            inner_->CallServerStreaming(method, request_bytes, &lite_context, response_messages);
        CopyResponseContext(lite_context, context);
        return ConvertStatus(lite_status);
    }

    Status CallClientStreaming(
        const char* method, ClientContext* context,
        const std::vector<std::string>& request_messages, std::string* response_bytes
    ) override {
        grpc_lite::ClientContext lite_context;
        CopyRequestContext(context, &lite_context);
        grpc_lite::Status lite_status =
            inner_->CallClientStreaming(method, request_messages, &lite_context, response_bytes);
        CopyResponseContext(lite_context, context);
        return ConvertStatus(lite_status);
    }

    Status CallBidiStreaming(
        const char* method, ClientContext* context,
        const std::vector<std::string>& request_messages,
        std::vector<std::string>* response_messages
    ) override {
        grpc_lite::ClientContext lite_context;
        CopyRequestContext(context, &lite_context);
        grpc_lite::Status lite_status =
            inner_->CallBidiStreaming(method, request_messages, &lite_context, response_messages);
        CopyResponseContext(lite_context, context);
        return ConvertStatus(lite_status);
    }

    std::unique_ptr<grpc_lite::ClientReader> StartServerStreaming(
        const char* method, ClientContext* context, const std::string& request_bytes
    ) override {
        return inner_->StartServerStreaming(method, request_bytes, MakeLiveContext(context));
    }

    std::unique_ptr<grpc_lite::ClientWriter> StartClientStreaming(
        const char* method, ClientContext* context
    ) override {
        return inner_->StartClientStreaming(method, MakeLiveContext(context));
    }

    std::unique_ptr<grpc_lite::ClientReaderWriter> StartBidiStreaming(
        const char* method, ClientContext* context
    ) override {
        return inner_->StartBidiStreaming(method, MakeLiveContext(context));
    }

  private:
    grpc_lite::ClientContext* MakeLiveContext(ClientContext* context) {
        auto lite_context = std::make_unique<grpc_lite::ClientContext>();
        CopyRequestContext(context, lite_context.get());
        live_contexts_.push_back(std::move(lite_context));
        return live_contexts_.back().get();
    }

    static void CopyRequestContext(ClientContext* context, grpc_lite::ClientContext* lite_context) {
        if (context == nullptr) {
            return;
        }
        for (const auto& md : context->metadata()) {
            lite_context->AddMetadata(md.first, md.second);
        }
        if (context->deadline() != std::chrono::system_clock::time_point{}) {
            lite_context->SetDeadline(context->deadline());
        }
    }

    static void CopyResponseContext(
        grpc_lite::ClientContext& lite_context, ClientContext* context
    ) {
        if (context == nullptr) {
            return;
        }
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

    static Status ConvertStatus(const grpc_lite::Status& lite_status) {
        if (lite_status.ok()) {
            return Status(StatusCode::OK, "");
        }
        return Status(
            static_cast<StatusCode>(static_cast<int>(lite_status.code())), lite_status.message()
        );
    }

    std::shared_ptr<grpc_lite::Channel> inner_;
    std::vector<std::unique_ptr<grpc_lite::ClientContext>> live_contexts_;
};

}  // namespace

std::shared_ptr<ChannelInterface> CreateChannel(const std::string& target) {
    auto lite_channel = grpc_lite::Channel::Create(target);
    return std::make_shared<ChannelImpl>(std::move(lite_channel));
}

}  // namespace grpc
