#include <iostream>
#include <string>
#include <string_view>

#include "echo.pb.h"
#include "grpc_lite/server_builder.h"
#include "grpc_lite/service.h"

namespace {

class ProtoEchoService final : public grpc_lite::Service {
 public:
  std::string service_name() const override { return "demo.EchoService"; }

  grpc_lite::Status HandleUnary(std::string_view method,
                                std::string_view request,
                                grpc_lite::ServerContext* context,
                                std::string* response) override {
    if (method != "Echo") {
      return grpc_lite::Status(grpc_lite::StatusCode::kUnimplemented,
                               "only demo.EchoService/Echo is implemented");
    }

    demo::EchoRequest echo_request;
    if (!echo_request.ParseFromArray(request.data(),
                                     static_cast<int>(request.size()))) {
      return grpc_lite::Status(grpc_lite::StatusCode::kInvalidArgument,
                               "failed to parse demo.EchoRequest");
    }

    demo::EchoReply echo_reply;
    echo_reply.set_message(echo_request.message());
    if (!echo_reply.SerializeToString(response)) {
      return grpc_lite::Status(grpc_lite::StatusCode::kInternal,
                               "failed to serialize demo.EchoReply");
    }

    context->AddInitialMetadata("x-grpc-lite-service", "demo.EchoService");
    context->AddTrailingMetadata("x-grpc-lite-method", "Echo");
    return grpc_lite::Status::OK();
  }
};

}  // namespace

int main() {
  ProtoEchoService service;

  grpc_lite::ServerBuilder builder;
  builder.AddListeningPort("0.0.0.0:50051");
  builder.RegisterService(&service);

  auto server = builder.Build();
  const grpc_lite::Status status = server->Start();
  if (!status.ok()) {
    std::cerr << "failed to start grpc-lite proto echo server: "
              << status.message() << "\n";
    return 1;
  }

  std::cout << "grpc-lite proto echo server listening on 0.0.0.0:50051\n";
  std::cout << "grpc path: /demo.EchoService/Echo\n";
  server->Wait();
  return 0;
}
