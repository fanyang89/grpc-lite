#ifndef GRPC_LITE_SERVICE_H_
#define GRPC_LITE_SERVICE_H_

#include <string>

namespace grpc_lite {

class Service {
 public:
  virtual ~Service() = default;

  virtual std::string service_name() const = 0;
};

}  // namespace grpc_lite

#endif  // GRPC_LITE_SERVICE_H_
