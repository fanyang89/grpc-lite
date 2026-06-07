#ifndef GRPC_LITE_PROTO3_ECHO_H_
#define GRPC_LITE_PROTO3_ECHO_H_

#include <string>

namespace demo {

struct EchoRequest {
    std::string message;
};

struct EchoReply {
    std::string message;
};

}  // namespace demo

#endif  // GRPC_LITE_PROTO3_ECHO_H_
