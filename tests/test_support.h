#ifndef GRPC_LITE_TEST_SUPPORT_H_
#define GRPC_LITE_TEST_SUPPORT_H_

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#include <chrono>
#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <thread>
#include <utility>

#include <grpcpp/impl/service_type.h>
#include <grpcpp/server.h>
#include <grpcpp/server_builder.h>

#include "grpc_lite/server.h"
#include "grpc_lite/server_builder.h"
#include "grpc_lite/service.h"

namespace grpc_lite::test {

inline bool FindFreePort(std::uint16_t* out_port) {
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

inline std::string LoopbackAddress(std::uint16_t port) {
    return "127.0.0.1:" + std::to_string(port);
}

inline bool HasMetadata(
    const std::vector<std::pair<std::string, std::string>>& metadata, std::string_view key,
    std::string_view value
) {
    for (const auto& entry : metadata) {
        if (entry.first == key && entry.second == value) {
            return true;
        }
    }
    return false;
}

class EchoService final : public Service {
  public:
    std::string service_name() const override { return "test.EchoService"; }

    Status HandleUnary(
        std::string_view method, std::string_view request, ServerContext* context,
        std::string* response
    ) override {
        if (method == "Echo") {
            context->AddInitialMetadata("x-test-initial", "echo");
            context->AddTrailingMetadata("x-test-trailing", "echo-done");
            *response = std::string(request);
            return Status::OK();
        }
        if (method == "Fail") {
            context->AddTrailingMetadata("x-test-trailing", "failed");
            return Status(StatusCode::kInvalidArgument, "test failure");
        }
        return Status(StatusCode::kUnimplemented, "unknown method");
    }
};

class DelayedService final : public Service {
  public:
    explicit DelayedService(std::chrono::milliseconds delay) : delay_(delay) {}

    std::string service_name() const override { return "test.DelayedService"; }

    Status HandleUnary(
        std::string_view method, std::string_view request, ServerContext*, std::string* response
    ) override {
        if (method != "Echo") {
            return Status(StatusCode::kUnimplemented, "unknown method");
        }
        std::this_thread::sleep_for(delay_);
        *response = std::string(request);
        return Status::OK();
    }

  private:
    std::chrono::milliseconds delay_;
};

class ServerScope {
  public:
    explicit ServerScope(Service& service) : service_(service) {}
    ServerScope(const ServerScope&) = delete;
    ServerScope& operator=(const ServerScope&) = delete;

    ~ServerScope() { Stop(); }

    bool Start(std::string* address) {
        for (int attempt = 0; attempt < 8; ++attempt) {
            std::uint16_t port = 0;
            if (!FindFreePort(&port)) {
                return false;
            }

            ServerBuilder builder;
            builder.AddListeningPort(LoopbackAddress(port));
            builder.RegisterService(&service_);
            server_ = builder.Build();
            if (server_ == nullptr) {
                return false;
            }

            const Status status = server_->Start();
            if (!status.ok()) {
                server_.reset();
                continue;
            }

            address_ = LoopbackAddress(port);
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

  private:
    Service& service_;
    std::string address_;
    std::unique_ptr<Server> server_;
    std::thread thread_;
};

class GrpcppServerScope {
  public:
    explicit GrpcppServerScope(grpc::Service& service) : service_(service) {}
    GrpcppServerScope(const GrpcppServerScope&) = delete;
    GrpcppServerScope& operator=(const GrpcppServerScope&) = delete;

    ~GrpcppServerScope() { Stop(); }

    bool Start(std::string* address) {
        for (int attempt = 0; attempt < 8; ++attempt) {
            std::uint16_t port = 0;
            if (!FindFreePort(&port)) {
                return false;
            }

            grpc::ServerBuilder builder;
            builder.AddListeningPort(LoopbackAddress(port));
            builder.RegisterService(&service_);
            server_ = builder.BuildAndStart();
            if (server_ == nullptr) {
                continue;
            }

            address_ = LoopbackAddress(port);
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

  private:
    grpc::Service& service_;
    std::string address_;
    std::unique_ptr<grpc::Server> server_;
    std::thread thread_;
};

}  // namespace grpc_lite::test

#endif  // GRPC_LITE_TEST_SUPPORT_H_
