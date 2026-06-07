#include <iostream>
#include <string>

#include "echo.grpc.pb.h"
#include <grpcpp/create_channel.h>
#include <grpcpp/client_context.h>
#include <grpcpp/support/status.h>

int main(int argc, char* argv[]) {
  const char* target = "127.0.0.1:50051";
  const char* message = "hello grpc-lite compat";
  if (argc > 1) target = argv[1];
  if (argc > 2) message = argv[2];

  auto channel = grpc::CreateChannel(target);
  auto stub = demo::EchoService::NewStub(channel);

  demo::EchoRequest request;
  request.set_message(message);

  demo::EchoReply response;
  grpc::ClientContext context;

  grpc::Status status = stub->Echo(&context, request, &response);
  if (!status.ok()) {
    std::cerr << "rpc failed (" << status.error_code() << "): "
              << status.error_message() << "\n";
    return 1;
  }

  std::cout << "response: " << response.message() << "\n";

  for (const auto& md : context.GetServerInitialMetadata()) {
    std::cout << "initial: " << md.first << " = " << md.second << "\n";
  }
  for (const auto& md : context.GetServerTrailingMetadata()) {
    std::cout << "trailer: " << md.first << " = " << md.second << "\n";
  }

  return 0;
}
