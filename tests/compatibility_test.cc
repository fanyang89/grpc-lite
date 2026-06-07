#include <arpa/inet.h>

#include <chrono>
#include <iostream>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <string_view>
#include <thread>
#include <utility>

#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#include "channel.h"
#include "client_context.h"
#include "server.h"
#include "server_builder.h"
#include "service.h"

#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include "doctest/doctest.h"

#include <grpcpp/client_context.h>
#include <grpcpp/create_channel.h>
#include <grpcpp/impl/channel_interface.h>
#include <grpcpp/impl/client_unary_call.h>
#include <grpcpp/impl/rpc_method.h>
#include <grpcpp/impl/rpc_service_method.h>
#include <grpcpp/impl/service_type.h>
#include <grpcpp/server.h>
#include <grpcpp/server_builder.h>
#include <grpcpp/server_context.h>
#include <grpcpp/support/byte_buffer.h>
#include <grpcpp/support/method_handler.h>

namespace {

bool FindFreePort(std::uint16_t* out_port) {
  const int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    return false;
  }

  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = 0;

  if (::bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
    ::close(fd);
    return false;
  }

  socklen_t len = sizeof(addr);
  if (::getsockname(fd, reinterpret_cast<sockaddr*>(&addr), &len) != 0) {
    ::close(fd);
    return false;
  }

  *out_port = ntohs(addr.sin_port);
  ::close(fd);
  return *out_port != 0;
}

class LiteCompatService final : public grpc_lite::Service {
 public:
  std::string service_name() const override { return "test.CompatService"; }

  grpc_lite::Status HandleUnary(std::string_view method,
                                std::string_view request,
                                grpc_lite::ServerContext* context,
                                std::string* response) override {
    if (method == "Echo") {
      if (response == nullptr) {
        return {grpc_lite::StatusCode::kInvalidArgument,
                "response output must not be null"};
      }
      context->AddInitialMetadata("x-server", "lite");
      context->AddTrailingMetadata("x-server-trail", "lite-ok");
      *response = "resp:";
      response->append(request);
      return grpc_lite::Status::OK();
    }
    if (method == "Fail") {
      return {grpc_lite::StatusCode::kInvalidArgument, "lite-invalid"};
    }
    return {grpc_lite::StatusCode::kUnimplemented, "unknown method"};
  }
};

class LiteServerScope {
 public:
  explicit LiteServerScope(grpc_lite::Service& service) : service_(service) {}

  bool Start(std::string* address) {
    for (int attempt = 0; attempt < 6; ++attempt) {
      std::uint16_t port;
      if (!FindFreePort(&port)) {
        return false;
      }

      grpc_lite::ServerBuilder builder;
      builder.AddListeningPort("127.0.0.1:" + std::to_string(port));
      builder.RegisterService(&service_);

      server_ = builder.Build();
      if (server_ == nullptr) {
        return false;
      }

      const grpc_lite::Status status = server_->Start();
      if (!status.ok()) {
        server_.reset();
        continue;
      }

      address_ = "127.0.0.1:" + std::to_string(port);
      if (address != nullptr) {
        *address = address_;
      }

      thread_ = std::thread([this]() { server_->Wait(); });
      return true;
    }
    return false;
  }

  void Stop() {
    if (server_ != nullptr) {
      server_->Shutdown();
    }
    if (thread_.joinable()) {
      thread_.join();
    }
    server_.reset();
  }

  ~LiteServerScope() { Stop(); }

 private:
  grpc_lite::Service& service_;
  std::string address_;
  std::unique_ptr<grpc_lite::Server> server_;
  std::thread thread_;
};

bool ByteBufferToString(const grpc::ByteBuffer& buffer, std::string* output) {
  grpc::Slice slice;
  const grpc::Status status = buffer.DumpToSingleSlice(&slice);
  if (!status.ok()) {
    return false;
  }
  output->assign(reinterpret_cast<const char*>(slice.begin()), slice.size());
  return true;
}

grpc::Status GrpcppCallUnary(std::shared_ptr<grpc::ChannelInterface> channel,
                            const std::string& method,
                            grpc::ClientContext* context,
                            const std::string& request,
                            std::string* response) {
  grpc::Slice request_slice(request);
  grpc::ByteBuffer request_buffer(&request_slice, 1);
  grpc::ByteBuffer response_buffer;

  const grpc::Status status = grpc::internal::BlockingUnaryCall<grpc::ByteBuffer,
                                                              grpc::ByteBuffer>(
      channel.get(),
      grpc::internal::RpcMethod(method.c_str(),
                               grpc::internal::RpcMethod::NORMAL_RPC),
      context, request_buffer, &response_buffer);
  if (!status.ok()) {
    return status;
  }
  if (!ByteBufferToString(response_buffer, response)) {
    return {grpc::StatusCode::INTERNAL, "invalid response payload"};
  }
  return status;
}

class GrpcppCompatService final : public grpc::Service {
 public:
  GrpcppCompatService() {
    AddMethod(new grpc::internal::RpcServiceMethod(
        "/test.GrpcppCompatService/Echo",
        grpc::internal::RpcMethod::RpcType::NORMAL_RPC,
        new grpc::internal::RpcMethodHandler<GrpcppCompatService, grpc::ByteBuffer,
                                            grpc::ByteBuffer>(
            [](GrpcppCompatService*, grpc::ServerContext* context,
               const grpc::ByteBuffer* request, grpc::ByteBuffer* response)
                 -> grpc::Status {
              if (request == nullptr || response == nullptr) {
                return {grpc::StatusCode::INTERNAL, "invalid request"};
              }
              grpc::Slice request_slice;
              if (!request->DumpToSingleSlice(&request_slice).ok()) {
                return {grpc::StatusCode::INVALID_ARGUMENT, "invalid request"};
              }
              const std::string request_value(
                  reinterpret_cast<const char*>(request_slice.begin()),
                  request_slice.size());

              context->AddInitialMetadata("x-server", "grpcpp");
              const std::string response_value = "grpcpp-echo:" + request_value;
              grpc::Slice response_slice(response_value);
              *response = grpc::ByteBuffer(&response_slice, 1);
              return grpc::Status(grpc::StatusCode::OK, "");
            },
            this)));

    AddMethod(new grpc::internal::RpcServiceMethod(
        "/test.GrpcppCompatService/Fail",
        grpc::internal::RpcMethod::RpcType::NORMAL_RPC,
        new grpc::internal::RpcMethodHandler<GrpcppCompatService,
                                            grpc::ByteBuffer, grpc::ByteBuffer>(
            [](GrpcppCompatService*, grpc::ServerContext*,
               const grpc::ByteBuffer*, grpc::ByteBuffer*) -> grpc::Status {
              return {grpc::StatusCode::UNIMPLEMENTED, "grpcpp-unimplemented"};
            },
            this)));
  }
};

class GrpcppServerScope {
 public:
  explicit GrpcppServerScope(grpc::Service& service) : service_(service) {}

  bool Start(std::string* address) {
    for (int attempt = 0; attempt < 6; ++attempt) {
      std::uint16_t port;
      if (!FindFreePort(&port)) {
        return false;
      }

      grpc::ServerBuilder builder;
      builder.AddListeningPort("127.0.0.1:" + std::to_string(port));
      builder.RegisterService(&service_);

      server_ = builder.BuildAndStart();
      if (server_ == nullptr) {
        continue;
      }

      address_ = "127.0.0.1:" + std::to_string(port);
      if (address != nullptr) {
        *address = address_;
      }

      thread_ = std::thread([this]() { server_->Wait(); });
      return true;
    }
    return false;
  }

  void Stop() {
    if (server_ != nullptr) {
      server_->Shutdown();
    }
    if (thread_.joinable()) {
      thread_.join();
    }
    server_.reset();
  }

  ~GrpcppServerScope() { Stop(); }

 private:
  grpc::Service& service_;
  std::string address_;
  std::unique_ptr<grpc::Server> server_;
  std::thread thread_;
};

TEST_CASE("grpc_lite unary interoperability") {
  LiteCompatService service;
  LiteServerScope server(service);
  std::string address;
  REQUIRE(server.Start(&address));

  auto channel = grpc_lite::Channel::Create(address);
  REQUIRE(channel != nullptr);

  std::string response;
  grpc_lite::ClientContext context;
  const std::string request = "hello";

  const grpc_lite::Status ok_status =
      channel->CallUnary("/test.CompatService/Echo", request, &context, &response);
  CHECK(ok_status.ok());
  CHECK(response == "resp:hello");
  CHECK(context.server_initial_metadata().size() >= 1);
  bool lite_has_x_server = false;
  for (const auto& metadata : context.server_initial_metadata()) {
    if (metadata.first == "x-server") {
      lite_has_x_server = true;
      break;
    }
  }
  CHECK(lite_has_x_server);

  response.clear();
  const grpc_lite::Status invalid_frame_status =
      channel->CallUnary("/test.CompatService/Echo", std::string("\x01", 1),
                         nullptr, &response);
  CHECK(invalid_frame_status.ok());
  CHECK(response == "resp:\x01");

  grpc_lite::Status fail_status =
      channel->CallUnary("/test.CompatService/Fail", request, nullptr, &response);
  CHECK(static_cast<int>(fail_status.code()) ==
        static_cast<int>(grpc_lite::StatusCode::kInvalidArgument));
  CHECK(fail_status.message() == std::string("lite-invalid"));

  const grpc_lite::Status unimplemented_status =
      channel->CallUnary("/test.CompatService/Missing", request, nullptr, &response);
  CHECK(static_cast<int>(unimplemented_status.code()) ==
        static_cast<int>(grpc_lite::StatusCode::kUnimplemented));

  grpc_lite::ClientContext expired_context;
  expired_context.SetDeadline(std::chrono::system_clock::now() -
                             std::chrono::seconds(1));
  const grpc_lite::Status timeout_status =
      channel->CallUnary("/test.CompatService/Echo", request,
                         &expired_context, &response);
  CHECK(static_cast<int>(timeout_status.code()) ==
        static_cast<int>(grpc_lite::StatusCode::kDeadlineExceeded));
}

TEST_CASE("grpcpp unary interoperability") {
  GrpcppCompatService service;
  GrpcppServerScope server(service);
  std::string address;
  REQUIRE(server.Start(&address));

  auto channel = grpc::CreateChannel(address);
  REQUIRE(channel != nullptr);

  const std::string request = "grpcpp";

  grpc::ClientContext context;
  std::string response;
  const grpc::Status ok_status =
      GrpcppCallUnary(channel, "/test.GrpcppCompatService/Echo", &context,
                      request, &response);
  CHECK(ok_status.ok());
  CHECK(response == "grpcpp-echo:grpcpp");
  bool grpcpp_has_x_server = false;
  for (const auto& metadata : context.GetServerInitialMetadata()) {
    if (metadata.first == "x-server") {
      grpcpp_has_x_server = true;
      break;
    }
  }
  CHECK(grpcpp_has_x_server);

  const grpc::Status fail_status =
      GrpcppCallUnary(channel, "/test.GrpcppCompatService/Fail", &context,
                      request, &response);
  CHECK(fail_status.error_code() == grpc::StatusCode::UNIMPLEMENTED);
  CHECK(fail_status.error_message() == std::string("grpcpp-unimplemented"));

  grpc::ClientContext deadline_context;
  deadline_context.set_deadline(std::chrono::system_clock::now() -
                               std::chrono::seconds(1));
  const grpc::Status deadline_status =
      GrpcppCallUnary(channel, "/test.GrpcppCompatService/Echo",
                      &deadline_context, request, &response);
  CHECK(deadline_status.error_code() == grpc::StatusCode::DEADLINE_EXCEEDED);
}

}  // namespace
