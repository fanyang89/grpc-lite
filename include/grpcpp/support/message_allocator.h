#ifndef GRPCPP_SUPPORT_MESSAGE_ALLOCATOR_H
#define GRPCPP_SUPPORT_MESSAGE_ALLOCATOR_H

namespace grpc {

template <class RequestType, class ResponseType>
class MessageAllocator {
 public:
  virtual ~MessageAllocator() = default;
};

}  // namespace grpc

#endif  // GRPCPP_SUPPORT_MESSAGE_ALLOCATOR_H
