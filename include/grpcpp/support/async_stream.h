#ifndef GRPCPP_SUPPORT_ASYNC_STREAM_H
#define GRPCPP_SUPPORT_ASYNC_STREAM_H

#include <grpcpp/impl/service_type.h>
#include <grpcpp/support/byte_buffer.h>

namespace grpc {

template <class R>
class ClientAsyncReaderInterface {
 public:
  virtual ~ClientAsyncReaderInterface() = default;
};

template <class W>
class ClientAsyncWriterInterface {
 public:
  virtual ~ClientAsyncWriterInterface() = default;
};

template <class W, class R>
class ClientAsyncReaderWriterInterface {
 public:
  virtual ~ClientAsyncReaderWriterInterface() = default;
};

template <class W>
class ServerAsyncResponseWriter
    : public internal::ServerAsyncStreamingInterface {
 public:
  ServerAsyncResponseWriter() = default;
  void SendInitialMetadata(void* tag) override { (void)tag; }
};

}  // namespace grpc

#endif  // GRPCPP_SUPPORT_ASYNC_STREAM_H
