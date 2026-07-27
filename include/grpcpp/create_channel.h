#ifndef GRPCPP_CREATE_CHANNEL_H
#define GRPCPP_CREATE_CHANNEL_H

#include <grpcpp/channel.h>
#include <grpcpp/security/credentials.h>

namespace grpc {

std::shared_ptr<Channel> CreateChannel(
    const std::string& target,
    const std::shared_ptr<ChannelCredentials>& credentials);

inline std::shared_ptr<Channel> CreateChannel(
    const std::string& target,
    const std::shared_ptr<ChannelCredentials>& credentials) {
  return std::shared_ptr<Channel>(new Channel(target, credentials));
}

}  // namespace grpc

#endif
