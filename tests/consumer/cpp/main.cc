#include "api.grpc.pb.h"

#include <grpc_lite/grpc_lite.hpp>
#include <grpcpp/grpcpp.h>

#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <iostream>
#include <mutex>
#include <string>
#include <type_traits>
#include <utility>

// Keep checks active in CMake Release builds, including calls with side effects.
#define REQUIRE(condition)                                            \
  do {                                                                \
    if (!(condition)) {                                               \
      std::cerr << __LINE__ << ": " << #condition << " failed\n";     \
      std::abort();                                                    \
    }                                                                 \
  } while (false)

static_assert(!std::is_copy_constructible_v<grpc_lite::Channel>);
static_assert(std::is_nothrow_move_constructible_v<grpc_lite::Channel>);
static_assert(!std::is_copy_constructible_v<grpc_lite::ClientStream>);
static_assert(std::is_nothrow_move_constructible_v<grpc_lite::ClientStream>);
static_assert(!std::is_copy_constructible_v<grpc_lite::ServerCall>);

// Check generated server override shapes without relying on grpcpp internals.
class Service final : public consumer::Echo::Service {
 public:
  grpc::Status Unary(grpc::ServerContext*, const consumer::Message*,
                     consumer::Message*) override { return grpc::Status::OK; }
  grpc::Status Upload(grpc::ServerContext*, grpc::ServerReader<consumer::Message>*,
                      consumer::Message*) override { return grpc::Status::OK; }
  grpc::Status Download(grpc::ServerContext*, const consumer::Message*,
                        grpc::ServerWriter<consumer::Message>*) override {
    return grpc::Status::OK;
  }
  grpc::Status Chat(grpc::ServerContext*,
                    grpc::ServerReaderWriter<consumer::Message,
                                             consumer::Message>*) override {
    return grpc::Status::OK;
  }
};

void SetDeadline(grpc::ClientContext& context) {
  context.set_deadline(std::chrono::system_clock::now() + std::chrono::seconds(5));
}

void RunConsumer(bool ipv6) {
  grpc_lite::Runtime runtime;
  REQUIRE(grpc_lite::Runtime::Create(&runtime).ok());
  grpc_lite::Server server;
  grpc_lite::ServerOptions server_options;
  server_options.host = ipv6 ? "::1" : "127.0.0.1";
  REQUIRE(grpc_lite::Server::Create(server_options, &server).ok());
  // A raw server echoes protobuf wire bytes; each fixture sends one message.
  grpc_lite::ServerStreamCallbacks handlers;
  handlers.on_message = [](grpc_lite::ServerStream stream,
                           const grpc_lite::ServerContext&, std::string bytes,
                           grpc_lite::Compression) {
    grpc_lite::ServerCall call;
    REQUIRE(stream.Retain(&call).ok());
    REQUIRE(call.Send(bytes).ok());
    return grpc_lite::ReceiveAction::Continue;
  };
  handlers.on_remote_end = [](grpc_lite::ServerStream stream,
                              const grpc_lite::ServerContext&) {
    grpc_lite::ServerCall call;
    REQUIRE(stream.Retain(&call).ok());
    REQUIRE(call.Finish({}).ok());
  };
  grpc_lite::ServerMethodOptions method_options;
  method_options.explicit_initial_metadata = false;
  for (const char* method : {"Unary", "Upload", "Download", "Chat"}) {
    REQUIRE(server.RegisterStream(std::string("/consumer.Echo/") + method,
                                   method_options, handlers).ok());
  }
  REQUIRE(server.Start().ok());
  std::uint32_t port = 0;
  REQUIRE(server.Port(&port).ok());
  const std::string target = std::string(ipv6 ? "[::1]:" : "127.0.0.1:") + std::to_string(port);
  // Wait for the initial connection before issuing fail-fast fixture RPCs.
  grpc::ChannelArguments arguments;
  arguments.SetAllowInitialOffline(false);
  auto channel = grpc::CreateCustomChannel(
      target, grpc::InsecureChannelCredentials(), arguments);
  auto stub = consumer::Echo::NewStub(channel);
  consumer::Message request;
  request.set_value(std::string("a\0b", 3));
  consumer::Message response;
  {
    grpc::ClientContext context;
    SetDeadline(context);
    const auto status = stub->Unary(&context, request, &response);
    if (!status.ok()) {
      std::cerr << "Unary failed: " << status.error_code() << ": "
                << status.error_message() << '\n';
    }
    REQUIRE(status.ok());
    REQUIRE(response.value() == request.value());
  }
  {
    grpc::ClientContext context;
    SetDeadline(context);
    REQUIRE(stub->Missing(&context, request, &response).error_code()
            == grpc::StatusCode::UNIMPLEMENTED);
  }
  {
    grpc::ClientContext context;
    SetDeadline(context);
    auto writer = stub->Upload(&context, &response);
    REQUIRE(writer->Write(request));
    REQUIRE(writer->WritesDone());
    REQUIRE(writer->Finish().ok());
    REQUIRE(response.value() == request.value());
  }
  {
    grpc::ClientContext context;
    SetDeadline(context);
    auto reader = stub->Download(&context, request);
    REQUIRE(reader->Read(&response));
    REQUIRE(response.value() == request.value());
    REQUIRE(!reader->Read(&response));
    REQUIRE(reader->Finish().ok());
  }
  {
    grpc::ClientContext context;
    SetDeadline(context);
    auto stream = stub->Chat(&context);
    REQUIRE(stream->Write(request));
    // Full duplex: read the response before half-closing requests.
    REQUIRE(stream->Read(&response));
    REQUIRE(response.value() == request.value());
    REQUIRE(stream->WritesDone());
    REQUIRE(!stream->Read(&response));
    REQUIRE(stream->Finish().ok());
  }

  // Low-level callbacks deliver owning strings/status values. Moved-from handles
  // fail predictably, and stream admission survives terminal notification.
  grpc_lite::Channel raw_channel;
  grpc_lite::ChannelOptions options;
  options.max_streams = 1;
  REQUIRE(grpc_lite::Channel::CreateManaged(&runtime, target, options,
                                           &raw_channel).ok());
  std::mutex mutex;
  std::condition_variable changed;
  bool done = false;
  std::size_t terminals = 0;
  grpc_lite::Status final_status;
  std::string owned_payload;
  grpc_lite::ClientStreamCallbacks callbacks;
  callbacks.on_message = [&](std::string bytes, grpc_lite::Compression) {
    owned_payload = std::move(bytes);
    return grpc_lite::ReceiveAction::Continue;
  };
  callbacks.on_terminal = [&](grpc_lite::Status status, grpc_lite::MetadataEntries) {
    std::lock_guard<std::mutex> lock(mutex);
    final_status = std::move(status);
    ++terminals;
    done = true;
    changed.notify_one();
  };
  grpc_lite::ClientStream stream;
  grpc_lite::ClientStreamOptions stream_options;
  stream_options.has_timeout = true;
  stream_options.timeout_ns = UINT64_C(5000000000);
  REQUIRE(grpc_lite::ClientStream::Open(raw_channel, "/consumer.Echo/Chat",
                                       stream_options, callbacks, &stream).ok());
  grpc_lite::ClientStream rejected;
  REQUIRE(grpc_lite::ClientStream::Open(raw_channel, "/consumer.Echo/Chat",
                                       stream_options, callbacks, &rejected).code()
          == grpc_lite::ErrorCode::WouldBlock);
  grpc_lite::ClientStream moved = std::move(stream);
  REQUIRE(stream.CloseSend().code() == grpc_lite::ErrorCode::InvalidState);
  std::string wire;
  REQUIRE(request.SerializeToString(&wire));
  REQUIRE(moved.Send(wire).ok());
  REQUIRE(moved.CloseSend().ok());
  {
    std::unique_lock<std::mutex> lock(mutex);
    REQUIRE(changed.wait_for(lock, std::chrono::seconds(5), [&] { return done; }));
  }
  raw_channel.Shutdown();
  raw_channel.Wait();
  REQUIRE(terminals == 1);
  REQUIRE(final_status.ok());
  REQUIRE(owned_payload == wire);
  grpc_lite::StreamAdmissionStats stats;
  REQUIRE(raw_channel.GetStreamAdmissionStats(&stats).ok());
  REQUIRE(stats.retained_streams == 1);
  moved = {};
  REQUIRE(raw_channel.GetStreamAdmissionStats(&stats).ok());
  REQUIRE(stats.retained_streams == 0);
  grpc_lite::Channel moved_channel = std::move(raw_channel);
  REQUIRE(raw_channel.GetStreamAdmissionStats(&stats).code()
          == grpc_lite::ErrorCode::InvalidArgument);
  moved_channel = {};
  REQUIRE(owned_payload == wire); // The callback copy survives owner destruction.
  server.ShutdownGracefully(UINT64_C(5000000000));
  server.Wait();
  std::cout << "PASS public C++ consumer " << (ipv6 ? "IPv6" : "IPv4")
            << ": unary, all streaming shapes, ownership, rejection\n";
}

int main() {
  RunConsumer(false);
  RunConsumer(true);
}
