#ifndef GRPCPP_SERVER_BUILDER_H
#define GRPCPP_SERVER_BUILDER_H

#include <grpcpp/impl/service_type.h>
#include <grpcpp/support/status.h>

#include <memory>
#include <string>
#include <vector>

namespace grpc {

class Server;

class ServerBuilder {
 public:
  ServerBuilder() = default;

  ServerBuilder& AddListeningPort(const std::string& addr,
                                  void* creds = nullptr,
                                  int* selected_port = nullptr) {
    (void)creds;
    (void)selected_port;
    address_ = addr;
    return *this;
  }

  ServerBuilder& RegisterService(Service* service) {
    services_.push_back(service);
    return *this;
  }

  std::unique_ptr<Server> BuildAndStart();

 private:
  std::string address_;
  std::vector<Service*> services_;
};

}  // namespace grpc

#endif  // GRPCPP_SERVER_BUILDER_H
