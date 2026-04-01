#ifndef GRPCPP_IMPL_SERVER_CALLBACK_HANDLERS_H
#define GRPCPP_IMPL_SERVER_CALLBACK_HANDLERS_H

#include <grpcpp/impl/rpc_service_method.h>
#include <grpcpp/server_context.h>
#include <grpcpp/support/byte_buffer.h>
#include <grpcpp/support/server_callback.h>
#include <grpcpp/support/status.h>

#include <functional>

namespace grpc {

template <class RequestType, class ResponseType>
class MessageAllocator;

namespace internal {

template <class RequestType, class ResponseType>
class CallbackUnaryHandler : public MethodHandler {
 public:
  explicit CallbackUnaryHandler(
      std::function<ServerUnaryReactor*(CallbackServerContext*,
                                        const RequestType*, ResponseType*)>
          func)
      : func_(std::move(func)) {}

  void RunHandler(const HandlerParameter& param) override {
    (void)param;
  }

  void SetMessageAllocator(
      MessageAllocator<RequestType, ResponseType>* allocator) {
    (void)allocator;
  }

 private:
  std::function<ServerUnaryReactor*(CallbackServerContext*,
                                    const RequestType*, ResponseType*)>
      func_;
};

}  // namespace internal
}  // namespace grpc

#endif  // GRPCPP_IMPL_SERVER_CALLBACK_HANDLERS_H
