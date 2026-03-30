#ifndef GRPC_LITE_CHANNEL_H_
#define GRPC_LITE_CHANNEL_H_

#include <memory>
#include <string>

#include "grpc_lite/status.h"

namespace grpc_lite {

enum class SecurityMode {
  kInsecure,
  kTls,
};

struct ChannelOptions {
  SecurityMode security = SecurityMode::kInsecure;
  bool use_system_resolver = false;
};

class Channel {
 public:
  static std::shared_ptr<Channel> Create(std::string target,
                                         ChannelOptions options = {});

  const std::string& target() const;
  const ChannelOptions& options() const;
  bool SupportsProtocolCompatibility() const;

 private:
  Channel(std::string target, ChannelOptions options);

  std::string target_;
  ChannelOptions options_;
};

}  // namespace grpc_lite

#endif  // GRPC_LITE_CHANNEL_H_
