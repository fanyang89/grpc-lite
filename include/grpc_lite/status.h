#ifndef GRPC_LITE_STATUS_H_
#define GRPC_LITE_STATUS_H_

#include <string>

namespace grpc_lite {

enum class StatusCode {
  kOk = 0,
  kCancelled = 1,
  kUnknown = 2,
  kInvalidArgument = 3,
  kDeadlineExceeded = 4,
  kNotFound = 5,
  kAlreadyExists = 6,
  kPermissionDenied = 7,
  kResourceExhausted = 8,
  kFailedPrecondition = 9,
  kAborted = 10,
  kOutOfRange = 11,
  kUnimplemented = 12,
  kInternal = 13,
  kUnavailable = 14,
  kDataLoss = 15,
  kUnauthenticated = 16,
};

class Status {
 public:
  Status();
  Status(StatusCode code, std::string message);

  static Status OK();

  bool ok() const;
  StatusCode code() const;
  const std::string& message() const;

 private:
  StatusCode code_;
  std::string message_;
};

}  // namespace grpc_lite

#endif  // GRPC_LITE_STATUS_H_
