#ifndef GRPCPP_IMPL_SERVICE_TYPE_H
#define GRPCPP_IMPL_SERVICE_TYPE_H

#include <grpcpp/impl/rpc_service_method.h>
#include <grpcpp/support/status.h>

#include <memory>
#include <vector>

namespace grpc {

class CompletionQueue;
class ServerCompletionQueue;
class ServerContext;

namespace internal {
class ServerAsyncStreamingInterface {
 public:
  virtual ~ServerAsyncStreamingInterface() = default;
  virtual void SendInitialMetadata(void* tag) = 0;
};
}  // namespace internal

class Service {
 public:
  Service() = default;
  virtual ~Service() = default;

  bool has_async_methods() const {
    for (const auto& method : methods_) {
      if (method && method->handler() == nullptr) {
        return true;
      }
    }
    return false;
  }

  bool has_synchronous_methods() const {
    for (const auto& method : methods_) {
      if (method &&
          method->api_type() == internal::RpcServiceMethod::ApiType::SYNC) {
        return true;
      }
    }
    return false;
  }

  bool has_callback_methods() const {
    for (const auto& method : methods_) {
      if (method && (method->api_type() ==
                         internal::RpcServiceMethod::ApiType::CALL_BACK ||
                     method->api_type() ==
                         internal::RpcServiceMethod::ApiType::RAW_CALL_BACK)) {
        return true;
      }
    }
    return false;
  }

  bool has_generic_methods() const {
    for (const auto& method : methods_) {
      if (method == nullptr) {
        return true;
      }
    }
    return false;
  }

  const std::vector<std::unique_ptr<internal::RpcServiceMethod>>& methods()
      const {
    return methods_;
  }

 protected:
  template <class Message>
  void RequestAsyncUnary(int index, grpc::ServerContext* context,
                         Message* request,
                         internal::ServerAsyncStreamingInterface* stream,
                         grpc::CompletionQueue* call_cq,
                         grpc::ServerCompletionQueue* notification_cq,
                         void* tag) {
    (void)index;
    (void)context;
    (void)request;
    (void)stream;
    (void)call_cq;
    (void)notification_cq;
    (void)tag;
  }

  void AddMethod(internal::RpcServiceMethod* method) {
    methods_.emplace_back(method);
  }

  void MarkMethodAsync(int index) {
    auto idx = static_cast<size_t>(index);
    methods_[idx]->SetServerApiType(
        internal::RpcServiceMethod::ApiType::ASYNC);
  }

  void MarkMethodRaw(int index) {
    auto idx = static_cast<size_t>(index);
    methods_[idx]->SetServerApiType(internal::RpcServiceMethod::ApiType::RAW);
  }

  void MarkMethodGeneric(int index) {
    auto idx = static_cast<size_t>(index);
    methods_[idx].reset();
  }

  void MarkMethodStreamed(int index, internal::MethodHandler* streamed_method) {
    auto idx = static_cast<size_t>(index);
    methods_[idx]->SetHandler(streamed_method);
    methods_[idx]->SetMethodType(internal::RpcMethod::BIDI_STREAMING);
  }

  void MarkMethodCallback(int index, internal::MethodHandler* handler) {
    auto idx = static_cast<size_t>(index);
    methods_[idx]->SetHandler(handler);
    methods_[idx]->SetServerApiType(
        internal::RpcServiceMethod::ApiType::CALL_BACK);
  }

  void MarkMethodRawCallback(int index, internal::MethodHandler* handler) {
    auto idx = static_cast<size_t>(index);
    methods_[idx]->SetHandler(handler);
    methods_[idx]->SetServerApiType(
        internal::RpcServiceMethod::ApiType::RAW_CALL_BACK);
  }

  internal::MethodHandler* GetHandler(int index) {
    auto idx = static_cast<size_t>(index);
    return methods_[idx]->handler();
  }

 private:
  std::vector<std::unique_ptr<internal::RpcServiceMethod>> methods_;
};

}  // namespace grpc

#endif  // GRPCPP_IMPL_SERVICE_TYPE_H
