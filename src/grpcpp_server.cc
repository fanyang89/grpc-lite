#include <grpcpp/server.h>
#include <grpcpp/server_builder.h>

#include <grpcpp/impl/rpc_service_method.h>
#include <grpcpp/impl/service_type.h>
#include <grpcpp/server_context.h>

#include "grpc_lite/server.h"
#include "grpc_lite/server_builder.h"
#include "grpc_lite/service.h"

#include <memory>
#include <string>
#include <string_view>

namespace grpc {
namespace {

class ServiceAdapter : public grpc_lite::Service {
 public:
  explicit ServiceAdapter(grpc::Service* grpc_service)
      : grpc_service_(grpc_service) {
    const auto& methods = grpc_service_->methods();
    if (!methods.empty() && methods[0]) {
      service_name_ = methods[0]->name();
      auto pos = service_name_.find('/');
      if (pos == 0) {
        service_name_ = service_name_.substr(1);
      }
      pos = service_name_.rfind('/');
      if (pos != std::string::npos) {
        service_name_ = service_name_.substr(0, pos);
      }
    }
  }

  std::string service_name() const override { return service_name_; }

  grpc_lite::Status HandleUnary(std::string_view method,
                                std::string_view request,
                                grpc_lite::ServerContext* lite_context,
                                std::string* response) override {
    const auto& methods = grpc_service_->methods();
    for (const auto& m : methods) {
      if (!m) continue;
      std::string_view full_name = m->name();
      auto slash = full_name.rfind('/');
      std::string_view method_name =
          (slash != std::string_view::npos)
              ? full_name.substr(slash + 1)
              : full_name;
      if (method_name == method) {
        grpc::ServerContext grpc_context;
        internal::MethodHandler* handler = m->handler();
        if (handler == nullptr) {
          return grpc_lite::Status(grpc_lite::StatusCode::kUnimplemented,
                                  "method has no handler");
        }
        grpc::Status grpc_status;
        std::string response_bytes;
        internal::MethodHandler::HandlerParameter param;
        param.server_context = &grpc_context;
        param.request_bytes = std::string(request);
        param.response_bytes = &response_bytes;
        param.status = &grpc_status;
        handler->RunHandler(param);

        for (const auto& md : grpc_context.initial_metadata()) {
          lite_context->AddInitialMetadata(md.first, md.second);
        }
        for (const auto& md : grpc_context.trailing_metadata()) {
          lite_context->AddTrailingMetadata(md.first, md.second);
        }

        if (grpc_status.ok()) {
          *response = std::move(response_bytes);
          return grpc_lite::Status::OK();
        }

        return grpc_lite::Status(
            static_cast<grpc_lite::StatusCode>(
                static_cast<int>(grpc_status.error_code())),
            grpc_status.error_message());
      }
    }
    return grpc_lite::Status(grpc_lite::StatusCode::kUnimplemented,
                             "unknown method");
  }

 private:
  grpc::Service* grpc_service_;
  std::string service_name_;
};

}  // namespace

Server::Server(std::unique_ptr<grpc_lite::Server> inner)
    : inner_(std::move(inner)) {}

Server::~Server() { Shutdown(); }

void Server::Wait() {
  if (inner_) {
    inner_->Wait();
  }
}

void Server::Shutdown() {
  if (inner_) {
    inner_->Shutdown();
  }
}

std::unique_ptr<Server> ServerBuilder::BuildAndStart() {
  grpc_lite::ServerBuilder lite_builder;
  lite_builder.AddListeningPort(address_);

  std::vector<std::unique_ptr<ServiceAdapter>> adapters;
  for (auto* service : services_) {
    auto adapter = std::make_unique<ServiceAdapter>(service);
    lite_builder.RegisterService(adapter.get());
    adapters.push_back(std::move(adapter));
  }

  auto lite_server = lite_builder.Build();
  grpc_lite::Status status = lite_server->Start();
  if (!status.ok()) {
    return nullptr;
  }

  auto server = std::make_unique<Server>(std::move(lite_server));
  // Transfer adapter ownership — store them alongside the server.
  // For simplicity, leak them (they must outlive the server).
  // A production implementation would store them in Server.
  for (auto& a : adapters) {
    a.release();
  }
  return server;
}

}  // namespace grpc
