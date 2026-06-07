#ifndef GRPCPP_SUPPORT_SYNC_STREAM_H
#define GRPCPP_SUPPORT_SYNC_STREAM_H

#include <memory>
#include <string>
#include <utility>

#include <grpcpp/impl/channel_interface.h>
#include <grpcpp/support/status.h>

#include "grpc_lite/stream.h"

namespace grpc {

inline Status ToGrpcStatus(const grpc_lite::Status& status) {
    if (status.ok()) {
        return Status(StatusCode::OK, "");
    }
    return Status(static_cast<StatusCode>(static_cast<int>(status.code())), status.message());
}

template <class R>
class ClientReader {
  public:
    ClientReader() = default;

    explicit ClientReader(std::unique_ptr<grpc_lite::ClientReader> inner)
        : inner_(std::move(inner)) {}

    bool Read(R* message) {
        if (inner_ == nullptr || message == nullptr) {
            return false;
        }
        std::string bytes;
        if (!inner_->Read(&bytes)) {
            return false;
        }
        return message->ParseFromString(bytes);
    }

    Status Finish() {
        if (inner_ == nullptr) {
            return Status(StatusCode::INTERNAL, "client reader is not initialized");
        }
        return ToGrpcStatus(inner_->Finish());
    }

  private:
    std::unique_ptr<grpc_lite::ClientReader> inner_;
};

template <class W>
class ClientWriter {
  public:
    ClientWriter() = default;

    explicit ClientWriter(std::unique_ptr<grpc_lite::ClientWriter> inner)
        : inner_(std::move(inner)) {}

    bool Write(const W& message) {
        if (inner_ == nullptr) {
            return false;
        }
        std::string bytes;
        if (!message.SerializeToString(&bytes)) {
            return false;
        }
        return inner_->Write(bytes);
    }

    bool WritesDone() {
        if (inner_ == nullptr) {
            return false;
        }
        return inner_->WritesDone();
    }

    template <class R>
    Status Finish(R* response) {
        if (inner_ == nullptr || response == nullptr) {
            return Status(StatusCode::INTERNAL, "client writer is not initialized");
        }
        std::string bytes;
        Status status = ToGrpcStatus(inner_->Finish(&bytes));
        if (status.ok() && !response->ParseFromString(bytes)) {
            return Status(StatusCode::INTERNAL, "failed to parse response");
        }
        return status;
    }

  private:
    std::unique_ptr<grpc_lite::ClientWriter> inner_;
};

template <class W, class R>
class ClientReaderWriter {
  public:
    ClientReaderWriter() = default;

    explicit ClientReaderWriter(std::unique_ptr<grpc_lite::ClientReaderWriter> inner)
        : inner_(std::move(inner)) {}

    bool Write(const W& message) {
        if (inner_ == nullptr) {
            return false;
        }
        std::string bytes;
        if (!message.SerializeToString(&bytes)) {
            return false;
        }
        return inner_->Write(bytes);
    }

    bool WritesDone() {
        if (inner_ == nullptr) {
            return false;
        }
        return inner_->WritesDone();
    }

    bool Read(R* message) {
        if (inner_ == nullptr || message == nullptr) {
            return false;
        }
        std::string bytes;
        if (!inner_->Read(&bytes)) {
            return false;
        }
        return message->ParseFromString(bytes);
    }

    Status Finish() {
        if (inner_ == nullptr) {
            return Status(StatusCode::INTERNAL, "client reader-writer is not initialized");
        }
        return ToGrpcStatus(inner_->Finish());
    }

  private:
    std::unique_ptr<grpc_lite::ClientReaderWriter> inner_;
};

template <class R>
class ServerReader {
  public:
    ServerReader() = default;

    explicit ServerReader(grpc_lite::ServerReader* inner) : inner_(inner) {}

    bool Read(R* message) {
        if (inner_ == nullptr || message == nullptr) {
            return false;
        }
        std::string bytes;
        if (!inner_->Read(&bytes)) {
            return false;
        }
        return message->ParseFromString(bytes);
    }

  private:
    grpc_lite::ServerReader* inner_ = nullptr;
};

template <class W>
class ServerWriter {
  public:
    ServerWriter() = default;

    explicit ServerWriter(grpc_lite::ServerWriter* inner) : inner_(inner) {}

    bool Write(const W& message) {
        if (inner_ == nullptr) {
            return false;
        }
        std::string bytes;
        if (!message.SerializeToString(&bytes)) {
            return false;
        }
        return inner_->Write(bytes);
    }

  private:
    grpc_lite::ServerWriter* inner_ = nullptr;
};

template <class W, class R>
class ServerReaderWriter {
  public:
    ServerReaderWriter() = default;

    explicit ServerReaderWriter(grpc_lite::ServerReaderWriter* inner) : inner_(inner) {}

    bool Read(R* message) {
        if (inner_ == nullptr || message == nullptr) {
            return false;
        }
        std::string bytes;
        if (!inner_->Read(&bytes)) {
            return false;
        }
        return message->ParseFromString(bytes);
    }

    bool Write(const W& message) {
        if (inner_ == nullptr) {
            return false;
        }
        std::string bytes;
        if (!message.SerializeToString(&bytes)) {
            return false;
        }
        return inner_->Write(bytes);
    }

  private:
    grpc_lite::ServerReaderWriter* inner_ = nullptr;
};

template <class RequestType, class ResponseType>
class ServerUnaryStreamer {
  public:
    ServerUnaryStreamer() = default;

    explicit ServerUnaryStreamer(grpc_lite::ServerReaderWriter*) {}
};

template <class RequestType, class ResponseType>
class ServerSplitStreamer {
  public:
    ServerSplitStreamer() = default;

    explicit ServerSplitStreamer(grpc_lite::ServerReaderWriter*) {}
};

}  // namespace grpc

#endif  // GRPCPP_SUPPORT_SYNC_STREAM_H
