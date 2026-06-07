#include <uv.h>

#include "core/transport.h"

namespace grpc_lite::core {

unsigned int LibuvVersion() {
    return uv_version();
}

}  // namespace grpc_lite::core
