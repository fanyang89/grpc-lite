#include "grpc_lite/status.h"

#include <utility>

namespace grpc_lite {

Status::Status() : code_(StatusCode::kOk) {}

Status::Status(StatusCode code, std::string message)
    : code_(code), message_(std::move(message)) {}

Status Status::OK() { return Status(); }

bool Status::ok() const { return code_ == StatusCode::kOk; }

StatusCode Status::code() const { return code_; }

const std::string& Status::message() const { return message_; }

}  // namespace grpc_lite
