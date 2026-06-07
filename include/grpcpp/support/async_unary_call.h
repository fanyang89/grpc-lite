#ifndef GRPCPP_SUPPORT_ASYNC_UNARY_CALL_H
#define GRPCPP_SUPPORT_ASYNC_UNARY_CALL_H

#include <grpcpp/impl/channel_interface.h>
#include <grpcpp/impl/rpc_method.h>
#include <grpcpp/support/status.h>

#include <memory>

namespace grpc {

class ClientContext;
class CompletionQueue;

template <class R>
class ClientAsyncResponseReaderInterface {
 public:
  virtual ~ClientAsyncResponseReaderInterface() = default;
  virtual void StartCall() = 0;
  virtual void ReadInitialMetadata(void* tag) = 0;
  virtual void Finish(R* msg, Status* status, void* tag) = 0;
};

template <class R>
class ClientAsyncResponseReader final
    : public ClientAsyncResponseReaderInterface<R> {
 public:
  void StartCall() override {}
  void ReadInitialMetadata(void* tag) override { (void)tag; }
  void Finish(R* msg, Status* status, void* tag) override {
    (void)msg;
    (void)tag;
    *status = Status(StatusCode::UNIMPLEMENTED,
                     "async CQ API not supported by grpc-lite");
  }
};

namespace internal {

class ClientAsyncResponseReaderHelper {
 public:
  template <class Response, class Request, class BaseResponse, class BaseRequest>
  static ClientAsyncResponseReader<Response>* Create(
      ChannelInterface* channel, CompletionQueue* cq,
      const internal::RpcMethod& method, ClientContext* context,
      const Request& request) {
    (void)channel;
    (void)cq;
    (void)method;
    (void)context;
    (void)request;
    return new ClientAsyncResponseReader<Response>();
  }
};

}  // namespace internal
}  // namespace grpc

#endif  // GRPCPP_SUPPORT_ASYNC_UNARY_CALL_H
