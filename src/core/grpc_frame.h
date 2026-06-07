#ifndef GRPC_LITE_CORE_GRPC_FRAME_H_
#define GRPC_LITE_CORE_GRPC_FRAME_H_

#include <string>
#include <string_view>
#include <vector>

#include <nghttp2/nghttp2.h>

#include "grpc_lite/status.h"

namespace grpc_lite {
namespace core {

std::string EncodeGrpcFrame(std::string_view payload);
std::string EncodeGrpcFrames(const std::vector<std::string>& payloads);
Status DecodeGrpcFrame(std::string_view frame, std::string* payload);
Status DecodeGrpcFrames(std::string_view frames, std::vector<std::string>* payloads);

nghttp2_nv MakeHeader(std::string_view name, std::string_view value);

const char* StatusCodeText(StatusCode code);
StatusCode StatusCodeFromInt(int code);

}  // namespace core
}  // namespace grpc_lite

#endif  // GRPC_LITE_CORE_GRPC_FRAME_H_
