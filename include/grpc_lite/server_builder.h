#ifndef GRPC_LITE_SERVER_BUILDER_H_
#define GRPC_LITE_SERVER_BUILDER_H_

#include <memory>
#include <string>
#include <vector>

#include "grpc_lite/server.h"

namespace grpc_lite {

class Service;

class ServerBuilder {
 public:
  void AddListeningPort(std::string address, bool use_tls = false);
  void RegisterService(Service* service);

  std::unique_ptr<Server> Build();

 private:
  std::vector<Server::Listener> listeners_;
  std::vector<Service*> services_;
};

}  // namespace grpc_lite

#endif  // GRPC_LITE_SERVER_BUILDER_H_
