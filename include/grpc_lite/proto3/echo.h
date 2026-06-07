#ifndef GRPC_LITE_PROTO3_ECHO_H_
#define GRPC_LITE_PROTO3_ECHO_H_

#include <exception>
#include <string>

#include "proto3.hpp"

namespace demo {

struct EchoRequest {
    std::string message;

    bool SerializeToString(std::string* output) const {
        if (output == nullptr) {
            return false;
        }
        *output = proto3::serialize(*this);
        return true;
    }

    bool ParseFromString(const std::string& input) {
        try {
            proto3::deserialize_from(input, *this);
            return true;
        } catch (const std::exception&) {
            return false;
        }
    }
};

struct EchoReply {
    std::string message;

    bool SerializeToString(std::string* output) const {
        if (output == nullptr) {
            return false;
        }
        *output = proto3::serialize(*this);
        return true;
    }

    bool ParseFromString(const std::string& input) {
        try {
            proto3::deserialize_from(input, *this);
            return true;
        } catch (const std::exception&) {
            return false;
        }
    }
};

}  // namespace demo

#if !defined(GRPC_LITE_PROTO_USE_CPP26_META)
REFL_AUTO(type(demo::EchoRequest), field(message, proto3::field(1)))
REFL_AUTO(type(demo::EchoReply), field(message, proto3::field(1)))
#endif

#endif  // GRPC_LITE_PROTO3_ECHO_H_
