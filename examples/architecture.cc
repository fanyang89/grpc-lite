#include <iostream>

#include "grpc_lite/channel.h"
#include "grpc_lite/server_builder.h"
#include "grpc_lite/service.h"
#include "grpc_lite/version.h"

namespace {

class EchoService final : public grpc_lite::Service {
 public:
  std::string service_name() const override { return "demo.EchoService"; }
};

}  // namespace

int main() {
  EchoService service;

  grpc_lite::ServerBuilder builder;
  builder.AddListeningPort("0.0.0.0:50051");
  builder.RegisterService(&service);

  auto server = builder.Build();
  const grpc_lite::Status status = server->Start();
  auto channel = grpc_lite::Channel::Create("127.0.0.1:50051");

  std::cout << "grpc-lite " << grpc_lite::VersionString() << "\n";
  std::cout << "service: " << service.service_name() << "\n";
  std::cout << "server started: " << status.ok() << "\n";
  std::cout << "http2 compatible transport: "
            << channel->SupportsProtocolCompatibility() << "\n";

  server->Shutdown();
  return status.ok() ? 0 : 1;
}
