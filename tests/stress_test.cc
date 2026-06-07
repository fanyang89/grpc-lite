#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include <atomic>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "doctest/doctest.h"
#include "grpc_lite/channel.h"
#include "grpc_lite/client_context.h"
#include "test_support.h"

namespace {

std::string MakePayload(std::size_t size) {
    std::string payload;
    payload.resize(size);
    for (std::size_t i = 0; i < payload.size(); ++i) {
        payload[i] = static_cast<char>((i * 131U) & 0xffU);
    }
    return payload;
}

TEST_CASE("server handles many sequential unary calls") {
    grpc_lite::test::EchoService service;
    grpc_lite::test::ServerScope server(service);
    std::string address;
    REQUIRE(server.Start(&address));

    std::shared_ptr<grpc_lite::Channel> channel = grpc_lite::Channel::Create(address);
    REQUIRE(channel != nullptr);

    for (int i = 0; i < 100; ++i) {
        grpc_lite::ClientContext context;
        std::string response;
        const std::string request = "sequential-" + std::to_string(i);
        const grpc_lite::Status status =
            channel->CallUnary("/test.EchoService/Echo", request, &context, &response);

        REQUIRE(status.ok());
        CHECK(response == request);
        CHECK(grpc_lite::test::HasMetadata(
            context.server_trailing_metadata(), "x-test-trailing", "echo-done"
        ));
    }
}

TEST_CASE("server handles concurrent unary calls") {
    grpc_lite::test::EchoService service;
    grpc_lite::test::ServerScope server(service);
    std::string address;
    REQUIRE(server.Start(&address));

    constexpr int kThreadCount = 8;
    constexpr int kCallsPerThread = 20;
    std::atomic<int> failures{0};
    std::vector<std::thread> threads;
    threads.reserve(kThreadCount);

    for (int thread_index = 0; thread_index < kThreadCount; ++thread_index) {
        threads.emplace_back([&, thread_index]() {
            std::shared_ptr<grpc_lite::Channel> channel = grpc_lite::Channel::Create(address);
            for (int call_index = 0; call_index < kCallsPerThread; ++call_index) {
                const std::string request = "thread-" + std::to_string(thread_index) + "-call-" +
                    std::to_string(call_index);
                std::string response;
                const grpc_lite::Status status =
                    channel->CallUnary("/test.EchoService/Echo", request, nullptr, &response);
                if (!status.ok() || response != request) {
                    failures.fetch_add(1, std::memory_order_relaxed);
                }
            }
        });
    }

    for (std::thread& thread : threads) {
        thread.join();
    }

    CHECK(failures.load(std::memory_order_relaxed) == 0);
}

TEST_CASE("server handles large unary payloads") {
    grpc_lite::test::EchoService service;
    grpc_lite::test::ServerScope server(service);
    std::string address;
    REQUIRE(server.Start(&address));

    std::shared_ptr<grpc_lite::Channel> channel = grpc_lite::Channel::Create(address);
    REQUIRE(channel != nullptr);

    for (std::size_t size : {64U * 1024U, 1024U * 1024U}) {
        const std::string request = MakePayload(size);
        grpc_lite::ClientContext context;
        std::string response;
        const grpc_lite::Status status =
            channel->CallUnary("/test.EchoService/Echo", request, &context, &response);

        REQUIRE(status.ok());
        CHECK(response == request);
        CHECK(grpc_lite::test::HasMetadata(
            context.server_initial_metadata(), "x-test-initial", "echo"
        ));
    }
}

}  // namespace
