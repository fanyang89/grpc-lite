#ifndef GRPCPP_IMPL_RPC_METHOD_H
#define GRPCPP_IMPL_RPC_METHOD_H

#include <grpcpp/impl/channel_interface.h>

#include <memory>

namespace grpc {
namespace internal {

class RpcMethod {
 public:
  enum RpcType {
    NORMAL_RPC = 0,
    CLIENT_STREAMING,
    SERVER_STREAMING,
    BIDI_STREAMING
  };

  RpcMethod(const char* name, RpcType type)
      : name_(name),
        suffix_for_stats_(nullptr),
        method_type_(type),
        channel_tag_(nullptr) {}

  RpcMethod(const char* name, const char* suffix_for_stats, RpcType type)
      : name_(name),
        suffix_for_stats_(suffix_for_stats),
        method_type_(type),
        channel_tag_(nullptr) {}

  RpcMethod(const char* name, RpcType type,
            const std::shared_ptr<ChannelInterface>& channel)
      : name_(name),
        suffix_for_stats_(nullptr),
        method_type_(type),
        channel_tag_(channel->RegisterMethod(name)) {}

  RpcMethod(const char* name, const char* suffix_for_stats, RpcType type,
            const std::shared_ptr<ChannelInterface>& channel)
      : name_(name),
        suffix_for_stats_(suffix_for_stats),
        method_type_(type),
        channel_tag_(channel->RegisterMethod(name)) {}

  const char* name() const { return name_; }
  const char* suffix_for_stats() const { return suffix_for_stats_; }
  RpcType method_type() const { return method_type_; }
  void SetMethodType(RpcType type) { method_type_ = type; }
  void* channel_tag() const { return channel_tag_; }

 private:
  const char* const name_;
  const char* const suffix_for_stats_;
  RpcType method_type_;
  void* const channel_tag_;
};

}  // namespace internal
}  // namespace grpc

#endif  // GRPCPP_IMPL_RPC_METHOD_H
