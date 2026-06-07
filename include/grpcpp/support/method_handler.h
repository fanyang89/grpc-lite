#ifndef GRPCPP_SUPPORT_METHOD_HANDLER_H
#define GRPCPP_SUPPORT_METHOD_HANDLER_H

#include <grpcpp/impl/rpc_service_method.h>
#include <grpcpp/server_context.h>
#include <grpcpp/support/status.h>
#include <grpcpp/support/sync_stream.h>

#include <functional>

namespace grpc {
namespace internal {

template <class ServiceType, class RequestType, class ResponseType,
          class BaseRequestType = RequestType,
          class BaseResponseType = ResponseType>
class RpcMethodHandler : public MethodHandler {
 public:
  RpcMethodHandler(
      std::function<grpc::Status(ServiceType*, grpc::ServerContext*,
                                 const RequestType*, ResponseType*)>
          func,
      ServiceType* service)
      : func_(func), service_(service) {}

  void RunHandler(const HandlerParameter& param) override {
    RequestType request;
    if (!request.ParseFromString(param.request_bytes)) {
      *param.status = Status(StatusCode::INTERNAL,
                             "failed to parse request");
      return;
    }
    ResponseType response;
    *param.status = func_(service_, param.server_context, &request, &response);
    if (param.status->ok()) {
      (void)response.SerializeToString(param.response_bytes);
    }
  }

 private:
  std::function<grpc::Status(ServiceType*, grpc::ServerContext*,
                             const RequestType*, ResponseType*)>
      func_;
  ServiceType* service_;
};

template <class ServiceType, class RequestType, class ResponseType>
class ClientStreamingHandler : public MethodHandler {
 public:
  ClientStreamingHandler(
      std::function<grpc::Status(ServiceType*, grpc::ServerContext*,
                                 ServerReader<RequestType>*, ResponseType*)>
          func,
      ServiceType* service)
      : func_(func), service_(service) {}

  void RunHandler(const HandlerParameter& param) override {
    (void)param;
  }

 private:
  std::function<grpc::Status(ServiceType*, grpc::ServerContext*,
                             ServerReader<RequestType>*, ResponseType*)>
      func_;
  ServiceType* service_;
};

template <class ServiceType, class RequestType, class ResponseType>
class ServerStreamingHandler : public MethodHandler {
 public:
  ServerStreamingHandler(
      std::function<grpc::Status(ServiceType*, grpc::ServerContext*,
                                 const RequestType*, ServerWriter<ResponseType>*)>
          func,
      ServiceType* service)
      : func_(func), service_(service) {}

  void RunHandler(const HandlerParameter& param) override {
    (void)param;
  }

 private:
  std::function<grpc::Status(ServiceType*, grpc::ServerContext*,
                             const RequestType*, ServerWriter<ResponseType>*)>
      func_;
  ServiceType* service_;
};

template <class Streamer, bool WriteNeeded>
class TemplatedBidiStreamingHandler : public MethodHandler {
 public:
  explicit TemplatedBidiStreamingHandler(
      std::function<grpc::Status(grpc::ServerContext*, Streamer*)> func)
      : func_(std::move(func)) {}

  void RunHandler(const HandlerParameter& param) override {
    (void)param;
  }

 private:
  std::function<grpc::Status(grpc::ServerContext*, Streamer*)> func_;
};

template <class ServiceType, class RequestType, class ResponseType>
class BidiStreamingHandler
    : public TemplatedBidiStreamingHandler<
          ServerReaderWriter<ResponseType, RequestType>, false> {
 public:
  BidiStreamingHandler(
      std::function<grpc::Status(ServiceType*, grpc::ServerContext*,
                                 ServerReaderWriter<ResponseType, RequestType>*)>
          func,
      ServiceType* service)
      : TemplatedBidiStreamingHandler<
            ServerReaderWriter<ResponseType, RequestType>, false>(
            [func, service](grpc::ServerContext* ctx,
                            ServerReaderWriter<ResponseType, RequestType>* stream) {
              return func(service, ctx, stream);
            }) {}
};

template <class RequestType, class ResponseType>
class StreamedUnaryHandler
    : public TemplatedBidiStreamingHandler<
          ServerUnaryStreamer<RequestType, ResponseType>, true> {
 public:
  explicit StreamedUnaryHandler(
      std::function<grpc::Status(grpc::ServerContext*,
                                 ServerUnaryStreamer<RequestType, ResponseType>*)>
          func)
      : TemplatedBidiStreamingHandler<
            ServerUnaryStreamer<RequestType, ResponseType>, true>(
            std::move(func)) {}
};

template <class RequestType, class ResponseType>
class SplitServerStreamingHandler
    : public TemplatedBidiStreamingHandler<
          ServerSplitStreamer<RequestType, ResponseType>, false> {
 public:
  explicit SplitServerStreamingHandler(
      std::function<grpc::Status(grpc::ServerContext*,
                                 ServerSplitStreamer<RequestType, ResponseType>*)>
          func)
      : TemplatedBidiStreamingHandler<
            ServerSplitStreamer<RequestType, ResponseType>, false>(
            std::move(func)) {}
};

}  // namespace internal
}  // namespace grpc

#endif  // GRPCPP_SUPPORT_METHOD_HANDLER_H
