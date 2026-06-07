#ifndef GRPCPP_SUPPORT_SYNC_STREAM_H
#define GRPCPP_SUPPORT_SYNC_STREAM_H

namespace grpc {

template <class R>
class ServerReader {
 public:
  ServerReader() = default;
};

template <class W>
class ServerWriter {
 public:
  ServerWriter() = default;
};

template <class W, class R>
class ServerReaderWriter {
 public:
  ServerReaderWriter() = default;
};

template <class RequestType, class ResponseType>
class ServerUnaryStreamer {
 public:
  ServerUnaryStreamer() = default;
};

template <class RequestType, class ResponseType>
class ServerSplitStreamer {
 public:
  ServerSplitStreamer() = default;
};

}  // namespace grpc

#endif  // GRPCPP_SUPPORT_SYNC_STREAM_H
