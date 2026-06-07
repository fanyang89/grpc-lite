#ifndef GRPC_LITE_SERVICE_H_
#define GRPC_LITE_SERVICE_H_

#include <string>
#include <string_view>

#include "server_context.h"
#include "status.h"
#include "stream.h"

namespace grpc_lite {

class Service {
  public:
    virtual ~Service() = default;

    virtual std::string service_name() const = 0;

    virtual RpcType method_type(std::string_view method) const {
        (void)method;
        return RpcType::kUnary;
    }

    virtual Status HandleUnary(
        std::string_view method, std::string_view request, ServerContext* context,
        std::string* response
    ) {
        (void)method;
        (void)request;
        (void)context;
        if (response != nullptr) {
            response->clear();
        }
        return Status(StatusCode::kUnimplemented, "service does not implement unary handling yet");
    }

    virtual Status HandleServerStreaming(
        std::string_view method, std::string_view request, ServerContext* context,
        ServerWriter* writer
    ) {
        (void)method;
        (void)request;
        (void)context;
        (void)writer;
        return Status(
            StatusCode::kUnimplemented, "service does not implement server streaming yet"
        );
    }

    virtual Status HandleClientStreaming(
        std::string_view method, ServerReader* reader, ServerContext* context, std::string* response
    ) {
        (void)method;
        (void)reader;
        (void)context;
        if (response != nullptr) {
            response->clear();
        }
        return Status(
            StatusCode::kUnimplemented, "service does not implement client streaming yet"
        );
    }

    virtual Status HandleBidiStreaming(
        std::string_view method, ServerReaderWriter* stream, ServerContext* context
    ) {
        (void)method;
        (void)stream;
        (void)context;
        return Status(StatusCode::kUnimplemented, "service does not implement bidi streaming yet");
    }
};

}  // namespace grpc_lite

#endif  // GRPC_LITE_SERVICE_H_
