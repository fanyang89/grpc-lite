#ifndef GRPCPP_SUPPORT_STATUS_H
#define GRPCPP_SUPPORT_STATUS_H

#include <string>

namespace grpc {

enum StatusCode {
  OK = 0,
  CANCELLED = 1,
  UNKNOWN = 2,
  INVALID_ARGUMENT = 3,
  DEADLINE_EXCEEDED = 4,
  NOT_FOUND = 5,
  ALREADY_EXISTS = 6,
  PERMISSION_DENIED = 7,
  RESOURCE_EXHAUSTED = 8,
  FAILED_PRECONDITION = 9,
  ABORTED = 10,
  OUT_OF_RANGE = 11,
  UNIMPLEMENTED = 12,
  INTERNAL = 13,
  UNAVAILABLE = 14,
  DATA_LOSS = 15,
  UNAUTHENTICATED = 16,
  DO_NOT_USE = -1,
};

class Status {
 public:
  Status() : code_(StatusCode::OK) {}
  Status(StatusCode code, const std::string& message)
      : code_(code), message_(message) {}

  bool ok() const { return code_ == StatusCode::OK; }
  StatusCode error_code() const { return code_; }
  const std::string& error_message() const { return message_; }

 private:
  StatusCode code_;
  std::string message_;
};

}  // namespace grpc

#endif  // GRPCPP_SUPPORT_STATUS_H
