#include <iostream>
#include <string>
#include <string_view>

#include "grpc_lite/proto3/echo.h"
#include "proto3.hpp"

namespace {

bool ExpectEqual(std::string_view name, std::string_view actual,
                 std::string_view expected) {
  if (actual == expected) {
    return true;
  }
  std::cerr << name << " mismatch: actual size=" << actual.size()
            << ", expected size=" << expected.size() << "\n";
  return false;
}

bool ExpectTrue(std::string_view name, bool value) {
  if (value) {
    return true;
  }
  std::cerr << name << " failed\n";
  return false;
}

}  // namespace

int main() {
  bool ok = true;

  demo::EchoRequest request;
  request.message = "hello grpc-lite";

  const std::string golden_request =
      "\x0a\x0f"
      "hello grpc-lite";
  ok &= ExpectEqual("EchoRequest serialize", proto3::serialize(request),
                    golden_request);

  const demo::EchoRequest decoded_request =
      proto3::deserialize<demo::EchoRequest>(golden_request);
  ok &= ExpectTrue("EchoRequest deserialize",
                   decoded_request.message == "hello grpc-lite");

  demo::EchoReply reply;
  reply.message = "hello grpc-lite";
  ok &= ExpectEqual("EchoReply serialize", proto3::serialize(reply),
                    golden_request);

  const demo::EchoReply decoded_reply =
      proto3::deserialize<demo::EchoReply>(golden_request);
  ok &= ExpectTrue("EchoReply deserialize",
                   decoded_reply.message == "hello grpc-lite");

  ok &= ExpectEqual("default string omission",
                    proto3::serialize(demo::EchoRequest{}), "");

  return ok ? 0 : 1;
}
