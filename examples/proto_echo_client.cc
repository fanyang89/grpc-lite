#include <cstring>
#include <iostream>

#include "echo.grpc_lite.upb.h"
#include "grpc_lite/channel.h"
#include "grpc_lite/client_context.h"
#include "upb/base/string_view.h"
#include "upb/mem/arena.h"

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
  demo::EchoService_Stub stub(channel);

  upb_Arena* arena = upb_Arena_New();
  if (arena == nullptr) {
    std::cerr << "failed to allocate arena\n";
    return 1;
  }

  demo_EchoRequest* request = demo_EchoRequest_new(arena);
  demo_EchoRequest_set_message(
      request, upb_StringView_FromDataAndSize(message, std::strlen(message)));

  grpc_lite::ClientContext context;
  demo_EchoReply* response = nullptr;

  grpc_lite::Status status = stub.Echo(&context, request, &response, arena);
  if (!status.ok()) {
    std::cerr << "rpc failed (" << static_cast<int>(status.code())
              << "): " << status.message() << "\n";
    upb_Arena_Free(arena);
    return 1;
  }

  const upb_StringView reply_message = demo_EchoReply_message(response);
  std::cout << "response: "
            << std::string(reply_message.data, reply_message.size) << "\n";

  for (const auto& md : context.server_initial_metadata()) {
    std::cout << "initial: " << md.first << " = " << md.second << "\n";
  }
  for (const auto& md : context.server_trailing_metadata()) {
    std::cout << "trailer: " << md.first << " = " << md.second << "\n";
  }

  upb_Arena_Free(arena);
  return 0;
}
