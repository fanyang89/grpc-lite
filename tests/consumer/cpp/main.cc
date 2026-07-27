#include <grpcpp/grpcpp.h>

#include <cassert>
#include <string>

int main(int argc, char** argv) {
  grpc::Status status(grpc::StatusCode::NOT_FOUND, "missing");
  assert(!status.ok());
  assert(status.error_message() == "missing");

  grpc::ClientContext context;
  context.AddMetadata("x-consumer", "value");
  auto channel = grpc::CreateChannel(argc == 2 ? argv[1] : "invalid",
                                     grpc::InsecureChannelCredentials());
  std::string response;
  const std::string request("\x0a\x05hello", 7);
  status = channel->CallUnary("/demo.EchoService/Echo", &context, request, &response);
  if (argc == 2) {
    assert(status.ok());
    assert(response == request);
    assert(context.GetServerInitialMetadata().count("x-grpc-lite-service") == 1);
    assert(context.GetServerTrailingMetadata().count("x-grpc-lite-method") == 1);
  } else {
    assert(status.error_code() == grpc::StatusCode::INVALID_ARGUMENT);
  }
  return 0;
}
