#ifndef GRPCPP_IMPL_CLIENT_UNARY_CALL_H
#define GRPCPP_IMPL_CLIENT_UNARY_CALL_H

#include <grpcpp/client_context.h>
#include <grpcpp/impl/channel_interface.h>
#include <grpcpp/impl/rpc_method.h>
#include <grpcpp/support/status.h>

#include <string>
#include <type_traits>

namespace grpc {
namespace internal {

template <class InputMessage, class OutputMessage,
          class BaseInputMessage = InputMessage,
          class BaseOutputMessage = OutputMessage>
Status BlockingUnaryCall(ChannelInterface* channel, const RpcMethod& method,
                         grpc::ClientContext* context,
                         const InputMessage& request, OutputMessage* result) {
  static_assert(std::is_base_of<BaseInputMessage, InputMessage>::value,
                "Invalid input message specification");
  static_assert(std::is_base_of<BaseOutputMessage, OutputMessage>::value,
                "Invalid output message specification");

  std::string request_bytes;
  if (!request.SerializeToString(&request_bytes)) {
    return Status(StatusCode::INTERNAL, "failed to serialize request");
  }

  std::string response_bytes;
  Status status =
      channel->CallUnary(method.name(), context, request_bytes, &response_bytes);
  if (!status.ok()) {
    return status;
  }

  if (!result->ParseFromString(response_bytes)) {
    return Status(StatusCode::INTERNAL, "failed to parse response");
  }
  return Status(StatusCode::OK, "");
}

}  // namespace internal
}  // namespace grpc

#endif  // GRPCPP_IMPL_CLIENT_UNARY_CALL_H
