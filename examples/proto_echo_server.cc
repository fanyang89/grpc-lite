#include <iostream>
#include <string_view>
#include <cstring>

#include "echo.grpc_lite.upb.h"
#include "grpc_lite/server_builder.h"
#include "upb/base/string_view.h"
#include "upb/mem/arena.h"

namespace {

upb_StringView CopyStringView(upb_StringView value, upb_Arena* arena) {
  if (value.size == 0) {
    return upb_StringView_FromDataAndSize("", 0);
  }

  char* copy = static_cast<char*>(upb_Arena_Malloc(arena, value.size));
  if (copy == nullptr) {
    return upb_StringView_FromDataAndSize(nullptr, 0);
  }
  std::memcpy(copy, value.data, value.size);
  return upb_StringView_FromDataAndSize(copy, value.size);
}

class ProtoEchoService final : public demo::EchoService {
 public:
  grpc_lite::Status Echo(grpc_lite::ServerContext* context,
                         const demo_EchoRequest* request,
                         demo_EchoReply* response,
                         upb_Arena* arena) override {
    context->AddInitialMetadata("x-grpc-lite-service", "demo.EchoService");
    context->AddTrailingMetadata("x-grpc-lite-method", "Echo");
    const upb_StringView request_message = demo_EchoRequest_message(request);
    const upb_StringView response_message = CopyStringView(request_message, arena);
    if (request_message.size != 0 && response_message.data == nullptr) {
      return grpc_lite::Status(grpc_lite::StatusCode::kInternal,
                               "failed to allocate response string in arena");
    }
    demo_EchoReply_set_message(response, response_message);
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
    std::cerr << "failed to start grpc-lite proto echo server: "
              << status.message() << "\n";
    return 1;
  }

  std::cout << "grpc-lite proto echo server listening on 0.0.0.0:50051\n";
  std::cout << "grpc path: /demo.EchoService/Echo\n";
  server->Wait();
  return 0;
}
