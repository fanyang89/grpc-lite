#include <iostream>

#include "grpc_lite/server_builder.h"
#include "grpc_lite/service.h"

namespace {

class EchoService final : public grpc_lite::Service {
 public:
  std::string service_name() const override { return "demo.EchoService"; }

  grpc_lite::Status HandleUnary(std::string_view method,
                                std::string_view request,
                                grpc_lite::ServerContext* context,
                                std::string* response) override {
    context->AddInitialMetadata("x-grpc-lite-service", "demo.EchoService");
    context->AddTrailingMetadata("x-grpc-lite-method", std::string(method));
    *response = std::string(request);
    return grpc_lite::Status::OK();
  }
};

}  // namespace

int main() {
  EchoService service;

  grpc_lite::ServerBuilder builder;
  builder.AddListeningPort("0.0.0.0:50051");
  builder.RegisterService(&service);

  auto server = builder.Build();
  const grpc_lite::Status status = server->Start();
  if (!status.ok()) {
    std::cerr << "failed to start grpc-lite server: " << status.message()
              << "\n";
    return 1;
  }

  std::cout << "grpc-lite echo server listening on 0.0.0.0:50051\n";
  std::cout << "grpc path: /demo.EchoService/Echo\n";
  server->Wait();
  return 0;
}
