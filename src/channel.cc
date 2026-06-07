#include "grpc_lite/channel.h"

#include <memory>
#include <utility>

#include "core/transport.h"

namespace grpc_lite {

std::shared_ptr<Channel> Channel::Create(std::string target,
                                         ChannelOptions options) {
  return std::shared_ptr<Channel>(new Channel(std::move(target), options));
}

const std::string& Channel::target() const { return target_; }

const ChannelOptions& Channel::options() const { return options_; }

bool Channel::SupportsProtocolCompatibility() const {
  return core::Nghttp2Version() != 0U;
}

Channel::Channel(std::string target, ChannelOptions options)
    : target_(std::move(target)), options_(options) {}

}  // namespace grpc_lite
