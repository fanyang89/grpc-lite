#include <grpcpp/grpcpp.h>
#include <grpcpp/impl/client_unary_call.h>

#include <cassert>
#include <memory>
#include <string>
#include <utility>

namespace {

class Message {
 public:
  explicit Message(std::string value = {}) : value_(std::move(value)) {}

  bool SerializeToString(std::string* output) const {
    *output = value_;
    return true;
  }

  bool ParseFromArray(const void* data, int size) {
    value_.assign(static_cast<const char*>(data), static_cast<size_t>(size));
    return true;
  }

  const std::string& value() const { return value_; }

 private:
  std::string value_;
};

class FakeChannel final : public grpc::ChannelInterface {
 public:
  grpc::Status CallUnary(const std::string& method,
                         grpc::ClientContext*, const std::string& request,
                         std::string* response) override {
    assert(method == "/demo.Echo/Echo");
    *response = request + " response";
    return grpc::Status::OK;
  }
};

class UnsupportedCredentials final : public grpc::ChannelCredentials {};

}  // namespace

int main() {
  grpc::Status denied(grpc::StatusCode::PERMISSION_DENIED, "denied");
  assert(!denied.ok());
  assert(denied.error_code() == grpc::StatusCode::PERMISSION_DENIED);
  assert(denied.error_message() == "denied");

  FakeChannel fake_channel;
  grpc::ClientContext context;
  assert(context.deadline() == std::chrono::system_clock::time_point::max());
  context.AddMetadata("x-test", "value");
  context.set_deadline(std::chrono::system_clock::now() +
                       std::chrono::seconds(1));
  Message response;
  const grpc::Status status = grpc::internal::BlockingUnaryCall(
      &fake_channel, grpc::internal::RpcMethod("/demo.Echo/Echo"), &context,
      Message("request"), &response);
  assert(status.ok());
  assert(response.value() == "request response");

  grpc::ClientContext extreme_context;
  extreme_context.set_deadline(std::chrono::system_clock::time_point::max());
  assert(extreme_context.deadline() == std::chrono::system_clock::time_point::max());
  extreme_context.set_deadline(std::chrono::system_clock::time_point::min());
  assert(extreme_context.deadline() == std::chrono::system_clock::time_point::min());

  auto channel = grpc::CreateChannel("invalid", grpc::InsecureChannelCredentials());
  std::string raw_response;
  const grpc::Status unavailable =
      channel->CallUnary("/demo.Echo/Echo", &context, "request", &raw_response);
  assert(!unavailable.ok());
  assert(unavailable.error_code() == grpc::StatusCode::INVALID_ARGUMENT);

  channel = grpc::CreateChannel("localhost:1", grpc::InsecureChannelCredentials());
  const grpc::Status runtime_required =
      channel->CallUnary("/demo.Echo/Echo", &context, "request", &raw_response);
  assert(runtime_required.error_code() == grpc::StatusCode::FAILED_PRECONDITION);

  channel = grpc::CreateChannel("127.0.0.1:1",
                                std::make_shared<UnsupportedCredentials>());
  const grpc::Status unsupported =
      channel->CallUnary("/demo.Echo/Echo", &context, "request", &raw_response);
  assert(unsupported.error_code() == grpc::StatusCode::UNIMPLEMENTED);
  return 0;
}
