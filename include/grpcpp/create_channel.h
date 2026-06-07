#ifndef GRPCPP_CREATE_CHANNEL_H
#define GRPCPP_CREATE_CHANNEL_H

#include <grpcpp/impl/channel_interface.h>

#include <memory>
#include <string>

namespace grpc {

std::shared_ptr<ChannelInterface> CreateChannel(
    const std::string& target);

}  // namespace grpc

#endif  // GRPCPP_CREATE_CHANNEL_H
