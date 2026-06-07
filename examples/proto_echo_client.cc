#include <exception>
#include <iostream>
#include <string>

#include "grpc_lite/channel.h"
#include "grpc_lite/client_context.h"
#include "grpc_lite/proto3/echo.h"
#include "proto3.hpp"

int main(int argc, char* argv[]) {
    const char* target = "127.0.0.1:50051";
    const char* message = "hello grpc-lite";
    if (argc > 1) {
        target = argv[1];
    }
    if (argc > 2) {
        message = argv[2];
    }

    auto channel = grpc_lite::Channel::Create(target);
    demo::EchoRequest request;
    request.message = message;
    const std::string request_bytes = proto3::serialize(request);

    grpc_lite::ClientContext context;
    std::string response_bytes;

    grpc_lite::Status status =
        channel->CallUnary("/demo.EchoService/Echo", request_bytes, &context, &response_bytes);
    if (!status.ok()) {
        std::cerr << "rpc failed (" << static_cast<int>(status.code()) << "): " << status.message()
                  << "\n";
        return 1;
    }

    demo::EchoReply response;
    try {
        response = proto3::deserialize<demo::EchoReply>(response_bytes);
    } catch (const std::exception& e) {
        std::cerr << "failed to parse response: " << e.what() << "\n";
        return 1;
    }

    std::cout << "response: " << response.message << "\n";

    for (const auto& md : context.server_initial_metadata()) {
        std::cout << "initial: " << md.first << " = " << md.second << "\n";
    }
    for (const auto& md : context.server_trailing_metadata()) {
        std::cout << "trailer: " << md.first << " = " << md.second << "\n";
    }

    return 0;
}
