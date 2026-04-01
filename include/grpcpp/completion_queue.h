#ifndef GRPCPP_COMPLETION_QUEUE_H
#define GRPCPP_COMPLETION_QUEUE_H

namespace grpc {

class CompletionQueue {
 public:
  CompletionQueue() = default;
};

class ServerCompletionQueue : public CompletionQueue {
 public:
  ServerCompletionQueue() = default;
};

}  // namespace grpc

#endif  // GRPCPP_COMPLETION_QUEUE_H
