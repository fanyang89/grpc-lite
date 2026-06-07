#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include "doctest/doctest.h"

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <memory>
#include <string>
#include <thread>
#include <utility>
#include <vector>

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
#include <grpcpp/support/async_unary_call.h>
#include <grpcpp/support/byte_buffer.h>
#include <grpcpp/support/client_callback.h>
#include <grpcpp/support/method_handler.h>

#include "test_support.h"

namespace {

class FakeChannel final : public grpc::ChannelInterface {
  public:
    void* RegisterMethod(const char* method) override {
        registered_method = method == nullptr ? "" : method;
        return nullptr;
    }

    grpc::Status CallUnary(
        const char* method, grpc::ClientContext*, const std::string& request_bytes,
        std::string* response_bytes
    ) override {
        called_method = method == nullptr ? "" : method;
        captured_request = request_bytes;
        if (!status.ok()) {
            return status;
        }
        *response_bytes = response;
        return grpc::Status(grpc::StatusCode::OK, "");
    }

    grpc::Status status;
    std::string response;
    std::string registered_method;
    std::string called_method;
    std::string captured_request;
};

struct SerializableMessage {
    std::string value;

    bool SerializeToString(std::string* output) const {
        if (output == nullptr) {
            return false;
        }
        *output = value;
        return true;
    }

    bool ParseFromString(const std::string& input) {
        value = input;
        return true;
    }
};

struct FailingSerializeMessage {
    bool SerializeToString(std::string*) const { return false; }
};

struct FailingParseMessage {
    bool ParseFromString(const std::string&) { return false; }
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
            if (!grpc_lite::test::FindFreePort(&port)) {
                return false;
            }

            grpc::ServerBuilder builder;
            builder.AddListeningPort(grpc_lite::test::LoopbackAddress(port));
            builder.RegisterService(&service_);
            server_ = builder.BuildAndStart();
            if (server_ == nullptr) {
                continue;
            }

            const std::string selected_address = grpc_lite::test::LoopbackAddress(port);
            if (address != nullptr) {
                *address = selected_address;
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
    std::unique_ptr<grpc::Server> server_;
    std::thread thread_;
};

grpc::ByteBuffer MakeBuffer(const std::string& value) {
    grpc::Slice slice(value);
    return grpc::ByteBuffer(&slice, 1);
}

std::string ToString(const grpc::ByteBuffer& buffer) {
    grpc::Slice slice;
    const grpc::Status status = buffer.DumpToSingleSlice(&slice);
    REQUIRE(status.ok());
    return std::string(reinterpret_cast<const char*>(slice.begin()), slice.size());
}

grpc::Status CallUnary(
    const std::shared_ptr<grpc::ChannelInterface>& channel, const std::string& method,
    const std::string& request, std::string* response
) {
    grpc::ClientContext context;
    grpc::ByteBuffer response_buffer;
    const grpc::Status status = grpc::internal::BlockingUnaryCall<grpc::ByteBuffer, grpc::ByteBuffer>(
        channel.get(), grpc::internal::RpcMethod(method.c_str(), grpc::internal::RpcMethod::NORMAL_RPC),
        &context, MakeBuffer(request), &response_buffer
    );
    if (status.ok()) {
        *response = ToString(response_buffer);
    }
    return status;
}

class MultiMethodService final : public grpc::Service {
  public:
    explicit MultiMethodService(std::string service_name) : service_name_(std::move(service_name)) {
        method_names_.reserve(2);
        AddUnary("Echo", [](std::string request) { return request; });
        AddUnary("Upper", [](std::string request) {
            std::transform(request.begin(), request.end(), request.begin(), [](unsigned char c) {
                return static_cast<char>(std::toupper(c));
            });
            return request;
        });
    }

  private:
    void AddUnary(const std::string& method, std::string (*handler)(std::string)) {
        const std::string full_name = "/" + service_name_ + "/" + method;
        method_names_.push_back(full_name);
        AddMethod(new grpc::internal::RpcServiceMethod(
            method_names_.back().c_str(), grpc::internal::RpcMethod::NORMAL_RPC,
            new grpc::internal::RpcMethodHandler<MultiMethodService, grpc::ByteBuffer,
                                                  grpc::ByteBuffer>(
                [handler](MultiMethodService*, grpc::ServerContext*, const grpc::ByteBuffer* request,
                          grpc::ByteBuffer* response) {
                    const std::string response_value = handler(ToString(*request));
                    *response = MakeBuffer(response_value);
                    return grpc::Status(grpc::StatusCode::OK, "");
                },
                this
            )
        ));
    }

    std::string service_name_;
    std::vector<std::string> method_names_;
};

class RejectingParseService final : public grpc::Service {
  public:
    RejectingParseService() {
        AddMethod(new grpc::internal::RpcServiceMethod(
            "/test.RejectingParseService/Reject", grpc::internal::RpcMethod::NORMAL_RPC,
            new grpc::internal::RpcMethodHandler<RejectingParseService, FailingParseMessage,
                                                  grpc::ByteBuffer>(
                [](RejectingParseService*, grpc::ServerContext*, const FailingParseMessage*,
                   grpc::ByteBuffer*) {
                    return grpc::Status(grpc::StatusCode::OK, "unexpected");
                },
                this
            )
        ));
    }
};

TEST_CASE("blocking unary call serializes request and parses response") {
    FakeChannel channel;
    channel.response = "server-response";

    grpc::ClientContext context;
    SerializableMessage request{"client-request"};
    SerializableMessage response;
    const grpc::Status status = grpc::internal::BlockingUnaryCall<SerializableMessage,
                                                                  SerializableMessage>(
        &channel, grpc::internal::RpcMethod("/test.Service/Method", grpc::internal::RpcMethod::NORMAL_RPC),
        &context, request, &response
    );

    CHECK(status.ok());
    CHECK(channel.called_method == "/test.Service/Method");
    CHECK(channel.captured_request == "client-request");
    CHECK(response.value == "server-response");
}

TEST_CASE("blocking unary call reports serialize and parse failures") {
    FakeChannel channel;
    grpc::ClientContext context;
    FailingSerializeMessage bad_request;
    SerializableMessage response;

    grpc::Status status = grpc::internal::BlockingUnaryCall<FailingSerializeMessage,
                                                            SerializableMessage>(
        &channel, grpc::internal::RpcMethod("/test.Service/Method", grpc::internal::RpcMethod::NORMAL_RPC),
        &context, bad_request, &response
    );
    CHECK(status.error_code() == grpc::StatusCode::INTERNAL);

    SerializableMessage request{"client-request"};
    FailingParseMessage bad_response;
    channel.response = "unparseable";
    status = grpc::internal::BlockingUnaryCall<SerializableMessage, FailingParseMessage>(
        &channel, grpc::internal::RpcMethod("/test.Service/Method", grpc::internal::RpcMethod::NORMAL_RPC),
        &context, request, &bad_response
    );
    CHECK(status.error_code() == grpc::StatusCode::INTERNAL);
}

TEST_CASE("async and callback client shims report unsupported APIs") {
    grpc::ClientAsyncResponseReader<grpc::ByteBuffer> reader;
    grpc::ByteBuffer response;
    grpc::Status status;
    reader.StartCall();
    reader.ReadInitialMetadata(nullptr);
    reader.Finish(&response, &status, nullptr);
    CHECK(status.error_code() == grpc::StatusCode::UNIMPLEMENTED);
    CHECK(status.error_message() == "async CQ API not supported by grpc-lite");

    bool callback_ran = false;
    grpc::internal::CallbackUnaryCall<grpc::ByteBuffer, grpc::ByteBuffer, grpc::ByteBuffer,
                                      grpc::ByteBuffer>(
        nullptr, grpc::internal::RpcMethod("/test.Service/Method", grpc::internal::RpcMethod::NORMAL_RPC),
        nullptr, nullptr, nullptr, [&](grpc::Status callback_status) {
            callback_ran = true;
            CHECK(callback_status.error_code() == grpc::StatusCode::UNIMPLEMENTED);
            CHECK(callback_status.error_message() == "callback API not supported by grpc-lite");
        }
    );
    CHECK(callback_ran);
}

TEST_CASE("grpcpp server dispatches multiple methods") {
    MultiMethodService service("test.MultiMethodService");
    GrpcppServerScope server(service);
    std::string address;
    REQUIRE(server.Start(&address));

    std::shared_ptr<grpc::ChannelInterface> channel = grpc::CreateChannel(address);
    std::string response;
    grpc::Status status = CallUnary(channel, "/test.MultiMethodService/Echo", "mixed", &response);
    CHECK(status.ok());
    CHECK(response == "mixed");

    status = CallUnary(channel, "/test.MultiMethodService/Upper", "mixed", &response);
    CHECK(status.ok());
    CHECK(response == "MIXED");
}

TEST_CASE("grpcpp server dispatches multiple services") {
    MultiMethodService first("test.FirstService");
    MultiMethodService second("test.SecondService");

    std::uint16_t port = 0;
    REQUIRE(grpc_lite::test::FindFreePort(&port));
    grpc::ServerBuilder builder;
    builder.AddListeningPort(grpc_lite::test::LoopbackAddress(port));
    builder.RegisterService(&first);
    builder.RegisterService(&second);
    std::unique_ptr<grpc::Server> server = builder.BuildAndStart();
    REQUIRE(server != nullptr);
    std::thread server_thread([&server]() { server->Wait(); });

    std::shared_ptr<grpc::ChannelInterface> channel =
        grpc::CreateChannel(grpc_lite::test::LoopbackAddress(port));
    std::string response;
    grpc::Status status = CallUnary(channel, "/test.FirstService/Upper", "one", &response);
    CHECK(status.ok());
    CHECK(response == "ONE");

    status = CallUnary(channel, "/test.SecondService/Upper", "two", &response);
    CHECK(status.ok());
    CHECK(response == "TWO");

    server->Shutdown();
    server_thread.join();
}

TEST_CASE("grpcpp method handler reports parse failures") {
    RejectingParseService service;
    GrpcppServerScope server(service);
    std::string address;
    REQUIRE(server.Start(&address));

    std::shared_ptr<grpc::ChannelInterface> channel = grpc::CreateChannel(address);
    std::string response;
    const grpc::Status status =
        CallUnary(channel, "/test.RejectingParseService/Reject", "bad-request", &response);
    CHECK(status.error_code() == grpc::StatusCode::INTERNAL);
    CHECK(status.error_message() == "failed to parse request");
}

TEST_CASE("server builder ignores selected port in compatibility shim") {
    grpc::ServerBuilder builder;
    int selected_port = 1234;
    builder.AddListeningPort("127.0.0.1:1", nullptr, &selected_port);
    CHECK(selected_port == 1234);
}

}  // namespace
