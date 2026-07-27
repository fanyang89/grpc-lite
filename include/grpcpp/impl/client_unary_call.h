#ifndef GRPCPP_IMPL_CLIENT_UNARY_CALL_H
#define GRPCPP_IMPL_CLIENT_UNARY_CALL_H

#include <grpcpp/channel.h>

#include <string>

namespace grpc::internal {

class RpcMethod {
 public:
  explicit RpcMethod(const char* name) : name_(name) {}
  const std::string& name() const { return name_; }

 private:
  std::string name_;
};

template <class Request, class Response>
Status BlockingUnaryCall(ChannelInterface* channel, const RpcMethod& method,
                         ClientContext* context, const Request& request,
                         Response* response) {
  if (channel == nullptr || context == nullptr || response == nullptr) {
    return {StatusCode::INVALID_ARGUMENT, "null unary call argument"};
  }
  std::string request_bytes;
  if (!request.SerializeToString(&request_bytes)) {
    return {StatusCode::INTERNAL, "failed to serialize request"};
  }
  std::string response_bytes;
  Status status = channel->CallUnary(method.name(), context, request_bytes,
                                     &response_bytes);
  if (!status.ok()) return status;
  if (!response->ParseFromArray(response_bytes.data(),
                                static_cast<int>(response_bytes.size()))) {
    return {StatusCode::INTERNAL, "failed to parse response"};
  }
  return status;
}

}  // namespace grpc::internal

#endif
