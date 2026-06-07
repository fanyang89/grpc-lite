#ifndef GRPCPP_IMPL_CHANNEL_INTERFACE_H
#define GRPCPP_IMPL_CHANNEL_INTERFACE_H

#include <memory>
#include <string>
#include <vector>

#include <grpcpp/support/status.h>

namespace grpc {

class ClientContext;
class CompletionQueue;

}  // namespace grpc

namespace grpc_lite {
class ClientReader;
class ClientWriter;
class ClientReaderWriter;
}  // namespace grpc_lite

namespace grpc {

class ChannelInterface {
  public:
    virtual ~ChannelInterface() = default;

    virtual void* RegisterMethod(const char* method) = 0;

    virtual Status CallUnary(
        const char* method, ClientContext* context, const std::string& request_bytes,
        std::string* response_bytes
    ) = 0;

    virtual Status CallServerStreaming(
        const char* method, ClientContext* context, const std::string& request_bytes,
        std::vector<std::string>* response_messages
    ) {
        (void)method;
        (void)context;
        (void)request_bytes;
        (void)response_messages;
        return Status(StatusCode::UNIMPLEMENTED, "server streaming API not supported");
    }

    virtual Status CallClientStreaming(
        const char* method, ClientContext* context,
        const std::vector<std::string>& request_messages, std::string* response_bytes
    ) {
        (void)method;
        (void)context;
        (void)request_messages;
        (void)response_bytes;
        return Status(StatusCode::UNIMPLEMENTED, "client streaming API not supported");
    }

    virtual Status CallBidiStreaming(
        const char* method, ClientContext* context,
        const std::vector<std::string>& request_messages,
        std::vector<std::string>* response_messages
    ) {
        (void)method;
        (void)context;
        (void)request_messages;
        (void)response_messages;
        return Status(StatusCode::UNIMPLEMENTED, "bidi streaming API not supported");
    }

    virtual std::unique_ptr<grpc_lite::ClientReader> StartServerStreaming(
        const char* method, ClientContext* context, const std::string& request_bytes
    ) {
        (void)method;
        (void)context;
        (void)request_bytes;
        return nullptr;
    }

    virtual std::unique_ptr<grpc_lite::ClientWriter> StartClientStreaming(
        const char* method, ClientContext* context
    ) {
        (void)method;
        (void)context;
        return nullptr;
    }

    virtual std::unique_ptr<grpc_lite::ClientReaderWriter> StartBidiStreaming(
        const char* method, ClientContext* context
    ) {
        (void)method;
        (void)context;
        return nullptr;
    }
};

}  // namespace grpc

#endif  // GRPCPP_IMPL_CHANNEL_INTERFACE_H
