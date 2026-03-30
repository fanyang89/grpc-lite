#include "core/transport.h"

#include <uv.h>

namespace grpc_lite::core {

unsigned int LibuvVersion() { return uv_version(); }

}  // namespace grpc_lite::core
