#ifndef GRPCPP_IMPL_RPC_SERVICE_METHOD_H
#define GRPCPP_IMPL_RPC_SERVICE_METHOD_H

#include <functional>
#include <memory>
#include <string>

#include <grpcpp/impl/rpc_method.h>

namespace grpc {

class ServerContext;

namespace internal {}  // namespace internal
}  // namespace grpc

namespace grpc_lite {
class ServerReader;
class ServerWriter;
class ServerReaderWriter;
}  // namespace grpc_lite

namespace grpc {
namespace internal {

class MethodHandler {
  public:
    virtual ~MethodHandler() = default;

    struct HandlerParameter {
        ServerContext* server_context;
        std::string request_bytes;
        std::string* response_bytes;
        grpc_lite::ServerReader* server_reader = nullptr;
        grpc_lite::ServerWriter* server_writer = nullptr;
        grpc_lite::ServerReaderWriter* server_reader_writer = nullptr;
        Status* status;
    };

    virtual void RunHandler(const HandlerParameter& param) = 0;
};

class RpcServiceMethod : public RpcMethod {
  public:
    enum class ApiType {
        SYNC,
        ASYNC,
        RAW,
        CALL_BACK,
        RAW_CALL_BACK,
    };

    RpcServiceMethod(const char* name, RpcMethod::RpcType type, MethodHandler* handler)
        : RpcMethod(name, type), api_type_(ApiType::SYNC), handler_(handler) {}

    MethodHandler* handler() const { return handler_.get(); }

    ApiType api_type() const { return api_type_; }

    void SetHandler(MethodHandler* handler) { handler_.reset(handler); }

    void SetServerApiType(ApiType type) { api_type_ = type; }

  private:
    ApiType api_type_;
    std::unique_ptr<MethodHandler> handler_;
};

}  // namespace internal
}  // namespace grpc

#endif  // GRPCPP_IMPL_RPC_SERVICE_METHOD_H
