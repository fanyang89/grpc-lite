#include "grpc_lite/server.h"

#include <utility>

#include "grpc_lite/service.h"

namespace grpc_lite {

Server::Server(std::vector<Listener> listeners)
    : listeners_(std::move(listeners)) {}

void Server::AddService(Service* service) { services_.push_back(service); }

Status Server::Start() {
  if (listeners_.empty()) {
    return Status(StatusCode::kFailedPrecondition,
                  "server requires at least one listening port");
  }
  if (services_.empty()) {
    return Status(StatusCode::kFailedPrecondition,
                  "server requires at least one registered service");
  }
  started_ = true;
  return Status::OK();
}

void Server::Shutdown() { started_ = false; }

bool Server::started() const { return started_; }

const std::vector<Server::Listener>& Server::listeners() const {
  return listeners_;
}

}  // namespace grpc_lite
