#include "grpc_lite/server_builder.h"

#include <memory>
#include <utility>

#include "grpc_lite/service.h"

namespace grpc_lite {

void ServerBuilder::AddListeningPort(std::string address, bool use_tls) {
  listeners_.push_back(Server::Listener{std::move(address), use_tls});
}

void ServerBuilder::RegisterService(Service* service) {
  services_.push_back(service);
}

std::unique_ptr<Server> ServerBuilder::Build() {
  auto server = std::make_unique<Server>(listeners_);
  for (Service* service : services_) {
    server->AddService(service);
  }
  return server;
}

}  // namespace grpc_lite
