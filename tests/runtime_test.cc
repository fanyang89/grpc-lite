#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include "doctest/doctest.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <chrono>
#include <cstdint>
#include <memory>
#include <string>

#include "grpc_lite/channel.h"
#include "grpc_lite/client_context.h"
#include "grpc_lite/server.h"
#include "grpc_lite/server_builder.h"
#include "grpc_lite/status.h"
#include "test_support.h"

namespace {

using grpc_lite::StatusCode;

std::unique_ptr<grpc_lite::Server> BuildServer(
    grpc_lite::Service* service, const std::string& address, bool use_tls = false
) {
    grpc_lite::ServerBuilder builder;
    builder.AddListeningPort(address, use_tls);
    if (service != nullptr) {
        builder.RegisterService(service);
    }
    return builder.Build();
}

TEST_CASE("server start validates required configuration") {
    grpc_lite::test::EchoService service;

    grpc_lite::ServerBuilder no_listener_builder;
    no_listener_builder.RegisterService(&service);
    std::unique_ptr<grpc_lite::Server> no_listener = no_listener_builder.Build();
    grpc_lite::Status status = no_listener->Start();
    CHECK(status.code() == StatusCode::kFailedPrecondition);

    std::uint16_t port = 0;
    REQUIRE(grpc_lite::test::FindFreePort(&port));
    std::unique_ptr<grpc_lite::Server> no_service =
        BuildServer(nullptr, grpc_lite::test::LoopbackAddress(port));
    status = no_service->Start();
    CHECK(status.code() == StatusCode::kFailedPrecondition);
}

TEST_CASE("server start rejects unsupported listener configurations") {
    grpc_lite::test::EchoService service;

    std::unique_ptr<grpc_lite::Server> invalid_address = BuildServer(&service, "127.0.0.1");
    grpc_lite::Status status = invalid_address->Start();
    CHECK(status.code() == StatusCode::kInvalidArgument);

    std::unique_ptr<grpc_lite::Server> invalid_port = BuildServer(&service, "127.0.0.1:not-a-port");
    status = invalid_port->Start();
    CHECK(status.code() == StatusCode::kInvalidArgument);

    std::unique_ptr<grpc_lite::Server> ipv6 = BuildServer(&service, "[::1]:50051");
    status = ipv6->Start();
    CHECK(status.code() == StatusCode::kUnimplemented);

    std::uint16_t port = 0;
    REQUIRE(grpc_lite::test::FindFreePort(&port));
    std::unique_ptr<grpc_lite::Server> tls =
        BuildServer(&service, grpc_lite::test::LoopbackAddress(port), true);
    status = tls->Start();
    CHECK(status.code() == StatusCode::kUnimplemented);
}

TEST_CASE("server currently supports only one listener") {
    grpc_lite::test::EchoService service;
    std::uint16_t first = 0;
    std::uint16_t second = 0;
    REQUIRE(grpc_lite::test::FindFreePort(&first));
    REQUIRE(grpc_lite::test::FindFreePort(&second));

    grpc_lite::ServerBuilder builder;
    builder.AddListeningPort(grpc_lite::test::LoopbackAddress(first));
    builder.AddListeningPort(grpc_lite::test::LoopbackAddress(second));
    builder.RegisterService(&service);
    std::unique_ptr<grpc_lite::Server> server = builder.Build();

    const grpc_lite::Status status = server->Start();
    CHECK(status.code() == StatusCode::kUnimplemented);
}

TEST_CASE("server reports bind conflicts") {
    const int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    REQUIRE(fd >= 0);

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    REQUIRE(::bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0);
    REQUIRE(::listen(fd, 1) == 0);

    socklen_t len = sizeof(addr);
    REQUIRE(::getsockname(fd, reinterpret_cast<sockaddr*>(&addr), &len) == 0);
    const auto port = static_cast<std::uint16_t>(ntohs(addr.sin_port));

    grpc_lite::test::EchoService service;
    std::unique_ptr<grpc_lite::Server> server =
        BuildServer(&service, grpc_lite::test::LoopbackAddress(port));
    const grpc_lite::Status status = server->Start();
    CHECK(status.code() == StatusCode::kUnavailable);

    ::close(fd);
}

TEST_CASE("server shutdown is idempotent after successful start") {
    grpc_lite::test::EchoService service;
    grpc_lite::test::ServerScope server(service);
    std::string address;
    REQUIRE(server.Start(&address));
    server.Stop();
    server.Stop();
}

TEST_CASE("channel performs sequential unary calls with metadata and binary payloads") {
    grpc_lite::test::EchoService service;
    grpc_lite::test::ServerScope server(service);
    std::string address;
    REQUIRE(server.Start(&address));

    std::shared_ptr<grpc_lite::Channel> channel = grpc_lite::Channel::Create(address);
    REQUIRE(channel != nullptr);

    for (int i = 0; i < 8; ++i) {
        grpc_lite::ClientContext context;
        std::string response;
        const std::string request = "payload-" + std::to_string(i) + std::string("\0tail", 5);
        const grpc_lite::Status status =
            channel->CallUnary("/test.EchoService/Echo", request, &context, &response);

        CHECK(status.ok());
        CHECK(response == request);
        CHECK(grpc_lite::test::HasMetadata(
            context.server_initial_metadata(), "x-test-initial", "echo"
        ));
        CHECK(grpc_lite::test::HasMetadata(
            context.server_trailing_metadata(), "x-test-trailing", "echo-done"
        ));
    }
}

TEST_CASE("channel reports service status and missing methods") {
    grpc_lite::test::EchoService service;
    grpc_lite::test::ServerScope server(service);
    std::string address;
    REQUIRE(server.Start(&address));

    std::shared_ptr<grpc_lite::Channel> channel = grpc_lite::Channel::Create(address);
    REQUIRE(channel != nullptr);

    std::string response = "unchanged";
    grpc_lite::ClientContext fail_context;
    grpc_lite::Status status =
        channel->CallUnary("/test.EchoService/Fail", "request", &fail_context, &response);
    CHECK(status.code() == StatusCode::kInvalidArgument);
    CHECK(status.message() == "test failure");
    CHECK(grpc_lite::test::HasMetadata(
        fail_context.server_trailing_metadata(), "x-test-trailing", "failed"
    ));

    status = channel->CallUnary("/test.EchoService/Missing", "request", nullptr, &response);
    CHECK(status.code() == StatusCode::kUnimplemented);

    status = channel->CallUnary("/test.MissingService/Echo", "request", nullptr, &response);
    CHECK(status.code() == StatusCode::kUnimplemented);
}

TEST_CASE("channel validates bad targets before connecting") {
    std::shared_ptr<grpc_lite::Channel> missing_port = grpc_lite::Channel::Create("127.0.0.1");
    std::string response;
    grpc_lite::Status status =
        missing_port->CallUnary("/test.EchoService/Echo", "request", nullptr, &response);
    CHECK(status.code() == StatusCode::kInvalidArgument);

    std::shared_ptr<grpc_lite::Channel> invalid_port =
        grpc_lite::Channel::Create("127.0.0.1:not-a-port");
    status = invalid_port->CallUnary("/test.EchoService/Echo", "request", nullptr, &response);
    CHECK(status.code() == StatusCode::kInvalidArgument);

    std::shared_ptr<grpc_lite::Channel> out_of_range =
        grpc_lite::Channel::Create("127.0.0.1:70000");
    status = out_of_range->CallUnary("/test.EchoService/Echo", "request", nullptr, &response);
    CHECK(status.code() == StatusCode::kInvalidArgument);
}

TEST_CASE("channel preserves options and reports protocol compatibility") {
    grpc_lite::ChannelOptions options;
    options.security = grpc_lite::SecurityMode::kTls;
    options.use_system_resolver = true;

    std::shared_ptr<grpc_lite::Channel> channel =
        grpc_lite::Channel::Create("example.test:443", options);
    REQUIRE(channel != nullptr);
    CHECK(channel->target() == "example.test:443");
    CHECK(channel->options().security == grpc_lite::SecurityMode::kTls);
    CHECK(channel->options().use_system_resolver);
    CHECK(channel->SupportsProtocolCompatibility());
}

TEST_CASE("channel deadline expires while request is in flight") {
    grpc_lite::test::DelayedService service(std::chrono::milliseconds(200));
    grpc_lite::test::ServerScope server(service);
    std::string address;
    REQUIRE(server.Start(&address));

    std::shared_ptr<grpc_lite::Channel> channel = grpc_lite::Channel::Create(address);
    REQUIRE(channel != nullptr);

    grpc_lite::ClientContext expired_soon;
    expired_soon.SetDeadline(std::chrono::system_clock::now() + std::chrono::milliseconds(50));
    std::string response;
    grpc_lite::Status status =
        channel->CallUnary("/test.DelayedService/Echo", "slow", &expired_soon, &response);
    CHECK(status.code() == StatusCode::kDeadlineExceeded);

    grpc_lite::ClientContext enough_time;
    enough_time.SetDeadline(std::chrono::system_clock::now() + std::chrono::seconds(2));
    response.clear();
    status = channel->CallUnary("/test.DelayedService/Echo", "after-timeout", &enough_time, &response);
    CHECK(status.ok());
    CHECK(response == "after-timeout");
}

}  // namespace
