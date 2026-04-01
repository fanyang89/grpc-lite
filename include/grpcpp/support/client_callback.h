#ifndef GRPCPP_SUPPORT_CLIENT_CALLBACK_H
#define GRPCPP_SUPPORT_CLIENT_CALLBACK_H

#include <grpcpp/impl/channel_interface.h>
#include <grpcpp/impl/rpc_method.h>
#include <grpcpp/support/status.h>

#include <functional>

namespace grpc {

class ClientContext;

class ClientUnaryReactor {
 public:
  virtual ~ClientUnaryReactor() = default;
};

namespace internal {

template <class Request, class Response, class BaseRequest, class BaseResponse>
void CallbackUnaryCall(ChannelInterface* channel,
                       const RpcMethod& method,
                       ClientContext* context,
                       const Request* request,
                       Response* response,
                       std::function<void(Status)> on_completion) {
  (void)channel;
  (void)method;
  (void)context;
  (void)request;
  (void)response;
  on_completion(Status(StatusCode::UNIMPLEMENTED,
                       "callback API not supported by grpc-lite"));
}

class ClientCallbackUnaryFactory {
 public:
  template <class BaseRequest, class BaseResponse>
  static void Create(ChannelInterface* channel,
                     const RpcMethod& method,
                     ClientContext* context,
                     const void* request,
                     void* response,
                     ClientUnaryReactor* reactor) {
    (void)channel;
    (void)method;
    (void)context;
    (void)request;
    (void)response;
    (void)reactor;
  }
};

}  // namespace internal
}  // namespace grpc

#endif  // GRPCPP_SUPPORT_CLIENT_CALLBACK_H
