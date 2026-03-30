#ifndef GRPC_LITE_SERVICE_H_
#define GRPC_LITE_SERVICE_H_

#include <string>
#include <string_view>

#include "grpc_lite/server_context.h"
#include "grpc_lite/status.h"

namespace grpc_lite {

class Service {
 public:
  virtual ~Service() = default;

  virtual std::string service_name() const = 0;

  virtual Status HandleUnary(std::string_view method,
                             std::string_view request,
                             ServerContext* context,
                             std::string* response) {
    (void)method;
    (void)request;
    (void)context;
    if (response != nullptr) {
      response->clear();
    }
    return Status(StatusCode::kUnimplemented,
                  "service does not implement unary handling yet");
  }
};

}  // namespace grpc_lite

#endif  // GRPC_LITE_SERVICE_H_
