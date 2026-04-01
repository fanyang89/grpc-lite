#include <iostream>
#include <string>

#include "echo.grpc.pb.h"
#include <grpcpp/server_builder.h>
#include <grpcpp/server.h>
#include <grpcpp/server_context.h>
#include <grpcpp/support/status.h>

class EchoServiceImpl final : public demo::EchoService::Service {
 public:
  grpc::Status Echo(grpc::ServerContext* context,
                    const demo::EchoRequest* request,
                    demo::EchoReply* response) override {
    context->AddInitialMetadata("x-grpc-lite-compat", "upstream-codegen");
    response->set_message(request->message());
    return grpc::Status(grpc::StatusCode::OK, "");
  }
};

int main() {
  EchoServiceImpl service;

  grpc::ServerBuilder builder;
  builder.AddListeningPort("0.0.0.0:50051");
  builder.RegisterService(&service);

  auto server = builder.BuildAndStart();
  if (!server) {
    std::cerr << "failed to start server\n";
    return 1;
  }

  std::cout << "grpc-lite compat server listening on 0.0.0.0:50051\n";
  server->Wait();
  return 0;
}
