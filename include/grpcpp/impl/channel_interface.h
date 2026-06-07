#ifndef GRPCPP_IMPL_CHANNEL_INTERFACE_H
#define GRPCPP_IMPL_CHANNEL_INTERFACE_H

#include <memory>
#include <string>

#include <grpcpp/support/status.h>

namespace grpc {

class ClientContext;
class CompletionQueue;

class ChannelInterface {
 public:
  virtual ~ChannelInterface() = default;

  virtual void* RegisterMethod(const char* method) = 0;

  virtual Status CallUnary(const char* method, ClientContext* context,
                           const std::string& request_bytes,
                           std::string* response_bytes) = 0;
};

}  // namespace grpc

#endif  // GRPCPP_IMPL_CHANNEL_INTERFACE_H
