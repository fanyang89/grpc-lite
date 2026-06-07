#ifndef GRPCPP_SUPPORT_SERVER_CALLBACK_H
#define GRPCPP_SUPPORT_SERVER_CALLBACK_H

namespace grpc {

class ServerUnaryReactor {
 public:
  virtual ~ServerUnaryReactor() = default;
};

}  // namespace grpc

#endif  // GRPCPP_SUPPORT_SERVER_CALLBACK_H
