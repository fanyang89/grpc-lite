#include "cpp_codegen.grpc.pb.h"

#include <cassert>
#include <string>
#include <type_traits>

namespace {

class FakeChannel final : public grpc::ChannelInterface {
 public:
  grpc::Status CallUnary(const std::string& method, grpc::ClientContext*,
                         const std::string& request,
                         std::string* response) override {
    assert(method == "/demo.EchoService/Echo");
    *response = request + " response";
    return grpc::Status::OK;
  }
};

}  // namespace

using ServerStreamSignature =
    std::unique_ptr<grpc::ClientReader<demo::EchoReply>> (
        demo::EchoService::StubInterface::*)(grpc::ClientContext*,
                                             const demo::EchoRequest&);
static_assert(std::is_same_v<decltype(&demo::EchoService::StubInterface::ServerStream),
                             ServerStreamSignature>);

class CompileEventService final : public demo::EchoService::EventService {
 public:
  void Echo(const grpc_lite::ServerContext&, demo::EchoRequest,
            grpc_lite::UnaryCall<demo::EchoReply>) noexcept override {}
  void ServerStream(
      const grpc_lite::ServerContext&, demo::EchoRequest,
      grpc_lite::ServerStreamingCall<demo::EchoReply>) noexcept override {}
};

int main() {
  auto channel = std::make_shared<FakeChannel>();
  assert(std::string(demo::EchoService::service_full_name()) == "demo.EchoService");
  auto stub = demo::EchoService::NewStub(channel, grpc::StubOptions{});
  demo::EchoRequest request;
  request.set_message("request");
  demo::EchoReply response;
  grpc::ClientContext context;
  const grpc::Status status = stub->Echo(&context, request, &response);
  assert(status.ok());
  assert(response.message() == "request response");
  return 0;
}
