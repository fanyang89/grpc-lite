#ifndef GRPCPP_SERVER_H
#define GRPCPP_SERVER_H

#include <memory>

namespace grpc_lite {
class Server;
}

namespace grpc {

class Server {
 public:
  explicit Server(std::unique_ptr<grpc_lite::Server> inner);
  ~Server();

  void Wait();
  void Shutdown();

 private:
  std::unique_ptr<grpc_lite::Server> inner_;
};

}  // namespace grpc

#endif  // GRPCPP_SERVER_H
