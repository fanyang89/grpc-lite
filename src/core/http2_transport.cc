#include "core/transport.h"

#include <nghttp2/nghttp2.h>

namespace grpc_lite::core {

namespace {

class Http2Transport final : public Transport {
 public:
  const char* name() const override { return "nghttp2"; }

  TransportFeatures features() const override {
    return TransportFeatures{
        true,
        true,
        true,
#ifdef GRPC_LITE_HAS_OPENSSL
        true,
#else
        false,
#endif
#ifdef GRPC_LITE_HAS_CARES
        true,
#else
        false,
#endif
    };
  }

  Status Initialize() override { return Status::OK(); }
};

}  // namespace

std::uint32_t Nghttp2Version() {
  const nghttp2_info* info = nghttp2_version(0);
  return info == nullptr ? 0U : info->version_num;
}

unsigned int LibuvVersion();

}  // namespace grpc_lite::core
