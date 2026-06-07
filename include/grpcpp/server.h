#ifndef GRPCPP_SERVER_H
#define GRPCPP_SERVER_H

#include <memory>
#include <vector>

namespace grpc_lite {
class Server;
class Service;
}  // namespace grpc_lite

namespace grpc {

class Server {
  public:
    explicit Server(std::unique_ptr<grpc_lite::Server> inner);
    ~Server();

    void Wait();
    void Shutdown();

    void AddOwnedService(std::unique_ptr<grpc_lite::Service> service);

  private:
    std::unique_ptr<grpc_lite::Server> inner_;
    std::vector<std::unique_ptr<grpc_lite::Service>> owned_services_;
};

}  // namespace grpc

#endif  // GRPCPP_SERVER_H
