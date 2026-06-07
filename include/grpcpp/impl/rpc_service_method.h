#ifndef GRPCPP_IMPL_RPC_SERVICE_METHOD_H
#define GRPCPP_IMPL_RPC_SERVICE_METHOD_H

#include <grpcpp/impl/rpc_method.h>

#include <functional>
#include <memory>
#include <string>

namespace grpc {

class ServerContext;

namespace internal {

class MethodHandler {
 public:
  virtual ~MethodHandler() = default;

  struct HandlerParameter {
    ServerContext* server_context;
    std::string request_bytes;
    std::string* response_bytes;
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

  RpcServiceMethod(const char* name, RpcMethod::RpcType type,
                   MethodHandler* handler)
      : RpcMethod(name, type),
        api_type_(ApiType::SYNC),
        handler_(handler) {}

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
