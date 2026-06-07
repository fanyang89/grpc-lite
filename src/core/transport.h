#ifndef GRPC_LITE_SRC_CORE_TRANSPORT_H_
#define GRPC_LITE_SRC_CORE_TRANSPORT_H_

#include <cstdint>
#include <string>

#include "grpc_lite/status.h"

namespace grpc_lite::core {

struct TransportFeatures {
  bool supports_http2 = false;
  bool supports_client = false;
  bool supports_server = false;
  bool supports_tls = false;
  bool supports_dns = false;
};

class Transport {
 public:
  virtual ~Transport() = default;

  virtual const char* name() const = 0;
  virtual TransportFeatures features() const = 0;
  virtual Status Initialize() = 0;
};

std::uint32_t Nghttp2Version();
unsigned int LibuvVersion();

}  // namespace grpc_lite::core

#endif  // GRPC_LITE_SRC_CORE_TRANSPORT_H_
