#include <exception>
#include <iostream>
#include <string>
#include <string_view>
#include <utility>

#include "grpc_lite/proto3/echo.h"
#include "grpc_lite/server_builder.h"
#include "grpc_lite/service.h"
#include "proto3.hpp"

namespace {

class ProtoEchoService final : public grpc_lite::Service {
  public:
    std::string service_name() const override { return "demo.EchoService"; }

    grpc_lite::Status HandleUnary(
        std::string_view method, std::string_view request, grpc_lite::ServerContext* context,
        std::string* response
    ) override {
        if (method != "Echo") {
            return grpc_lite::Status(grpc_lite::StatusCode::kUnimplemented, "unknown method");
        }
        if (response == nullptr) {
            return grpc_lite::Status(
                grpc_lite::StatusCode::kInvalidArgument, "response output must not be null"
            );
        }

        demo::EchoRequest decoded_request;
        try {
            proto3::deserialize_from(request, decoded_request);
        } catch (const std::exception& e) {
            return grpc_lite::Status(grpc_lite::StatusCode::kInvalidArgument, e.what());
        }

        context->AddInitialMetadata("x-grpc-lite-service", "demo.EchoService");
        context->AddTrailingMetadata("x-grpc-lite-method", "Echo");

        demo::EchoReply encoded_response;
        encoded_response.message = std::move(decoded_request.message);
        *response = proto3::serialize(encoded_response);
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
        std::cerr << "failed to start grpc-lite proto echo server: " << status.message() << "\n";
        return 1;
    }

    std::cout << "grpc-lite proto echo server listening on 0.0.0.0:50051\n";
    std::cout << "grpc path: /demo.EchoService/Echo\n";
    server->Wait();
    return 0;
}
