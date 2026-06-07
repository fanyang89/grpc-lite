#include "core/grpc_frame.h"

#include <cstdint>
#include <cstring>

namespace grpc_lite {
namespace core {

std::string EncodeGrpcFrame(std::string_view payload) {
  std::string frame;
  frame.resize(5 + payload.size());
  frame[0] = 0;
  const std::uint32_t size = static_cast<std::uint32_t>(payload.size());
  frame[1] = static_cast<char>((size >> 24) & 0xff);
  frame[2] = static_cast<char>((size >> 16) & 0xff);
  frame[3] = static_cast<char>((size >> 8) & 0xff);
  frame[4] = static_cast<char>(size & 0xff);
  if (!payload.empty()) {
    std::memcpy(frame.data() + 5, payload.data(), payload.size());
  }
  return frame;
}

Status DecodeGrpcFrame(std::string_view frame, std::string* payload) {
  if (frame.size() < 5) {
    return Status(StatusCode::kInvalidArgument,
                  "grpc request body is smaller than the frame header");
  }
  if (static_cast<unsigned char>(frame[0]) != 0) {
    return Status(StatusCode::kUnimplemented,
                  "compressed grpc messages are not supported yet");
  }

  const std::uint32_t size =
      (static_cast<std::uint32_t>(static_cast<unsigned char>(frame[1])) << 24) |
      (static_cast<std::uint32_t>(static_cast<unsigned char>(frame[2])) << 16) |
      (static_cast<std::uint32_t>(static_cast<unsigned char>(frame[3])) << 8) |
      static_cast<std::uint32_t>(static_cast<unsigned char>(frame[4]));
  if (frame.size() != size + 5U) {
    return Status(StatusCode::kInvalidArgument,
                  "grpc request body does not contain exactly one unary message");
  }

  payload->assign(frame.data() + 5, size);
  return Status::OK();
}

nghttp2_nv MakeHeader(std::string_view name, std::string_view value) {
  nghttp2_nv header{};
  header.name =
      reinterpret_cast<uint8_t*>(const_cast<char*>(name.data()));
  header.namelen = name.size();
  header.value =
      reinterpret_cast<uint8_t*>(const_cast<char*>(value.data()));
  header.valuelen = value.size();
  header.flags = NGHTTP2_NV_FLAG_NONE;
  return header;
}

const char* StatusCodeText(StatusCode code) {
  switch (code) {
    case StatusCode::kOk:
      return "0";
    case StatusCode::kCancelled:
      return "1";
    case StatusCode::kUnknown:
      return "2";
    case StatusCode::kInvalidArgument:
      return "3";
    case StatusCode::kDeadlineExceeded:
      return "4";
    case StatusCode::kNotFound:
      return "5";
    case StatusCode::kAlreadyExists:
      return "6";
    case StatusCode::kPermissionDenied:
      return "7";
    case StatusCode::kResourceExhausted:
      return "8";
    case StatusCode::kFailedPrecondition:
      return "9";
    case StatusCode::kAborted:
      return "10";
    case StatusCode::kOutOfRange:
      return "11";
    case StatusCode::kUnimplemented:
      return "12";
    case StatusCode::kInternal:
      return "13";
    case StatusCode::kUnavailable:
      return "14";
    case StatusCode::kDataLoss:
      return "15";
    case StatusCode::kUnauthenticated:
      return "16";
  }
  return "2";
}

StatusCode StatusCodeFromInt(int code) {
  if (code >= 0 && code <= 16) {
    return static_cast<StatusCode>(code);
  }
  return StatusCode::kUnknown;
}

}  // namespace core
}  // namespace grpc_lite
