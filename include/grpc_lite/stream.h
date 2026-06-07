#ifndef GRPC_LITE_STREAM_H_
#define GRPC_LITE_STREAM_H_

#include <condition_variable>
#include <cstddef>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "status.h"

namespace grpc_lite {

class ClientContext;

namespace internal {

class MessageQueue {
  public:
    bool Push(std::string message);
    bool Read(std::string* message);
    void Close(Status status = Status::OK());
    Status status() const;
    bool closed() const;

  private:
    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::deque<std::string> messages_;
    bool closed_ = false;
    Status status_;
};

}  // namespace internal

enum class RpcType {
    kUnary,
    kClientStreaming,
    kServerStreaming,
    kBidiStreaming,
};

class ServerReader {
  public:
    explicit ServerReader(std::vector<std::string> messages);
    explicit ServerReader(std::shared_ptr<internal::MessageQueue> queue);

    bool Read(std::string* message);

  private:
    std::shared_ptr<internal::MessageQueue> queue_;
    std::vector<std::string> messages_;
    std::size_t next_ = 0;
};

class ServerWriter {
  public:
    using WriteFn = std::function<bool(std::string_view)>;

    explicit ServerWriter(std::vector<std::string>* messages);
    explicit ServerWriter(WriteFn write);

    bool Write(std::string_view message);

  private:
    WriteFn write_;
    std::vector<std::string>* messages_ = nullptr;
};

class ServerReaderWriter {
  public:
    ServerReaderWriter(std::vector<std::string> requests, std::vector<std::string>* responses);
    ServerReaderWriter(
        std::shared_ptr<internal::MessageQueue> requests, ServerWriter::WriteFn write
    );

    bool Read(std::string* message);
    bool Write(std::string_view message);

  private:
    ServerReader reader_;
    ServerWriter writer_;
};

class ClientReader {
  public:
    using FinishFn = std::function<Status()>;

    ClientReader(Status status, std::vector<std::string> messages);
    ClientReader(std::shared_ptr<internal::MessageQueue> messages, FinishFn finish);

    bool Read(std::string* message);
    Status Finish();

  private:
    FinishFn finish_;
    std::shared_ptr<internal::MessageQueue> queue_;
    Status status_;
    std::vector<std::string> messages_;
    std::size_t next_ = 0;
};

class ClientWriter {
  public:
    using FinishFn = std::function<Status(const std::vector<std::string>&, std::string*)>;
    using LiveWriteFn = std::function<bool(std::string_view)>;
    using WritesDoneFn = std::function<bool()>;
    using LiveFinishFn = std::function<Status(std::string*)>;

    explicit ClientWriter(FinishFn finish);
    ClientWriter(LiveWriteFn write, WritesDoneFn writes_done, LiveFinishFn finish);

    bool Write(std::string_view message);
    bool WritesDone();
    Status Finish(std::string* response);

  private:
    FinishFn finish_;
    LiveWriteFn live_write_;
    WritesDoneFn live_writes_done_;
    LiveFinishFn live_finish_;
    std::vector<std::string> messages_;
    bool writes_done_ = false;
    bool finished_ = false;
    Status status_;
};

class ClientReaderWriter {
  public:
    using FinishFn =
        std::function<Status(const std::vector<std::string>&, std::vector<std::string>*)>;
    using LiveWriteFn = std::function<bool(std::string_view)>;
    using WritesDoneFn = std::function<bool()>;
    using LiveFinishFn = std::function<Status()>;

    explicit ClientReaderWriter(FinishFn finish);
    ClientReaderWriter(
        LiveWriteFn write, WritesDoneFn writes_done,
        std::shared_ptr<internal::MessageQueue> responses, LiveFinishFn finish
    );

    bool Write(std::string_view message);
    bool WritesDone();
    bool Read(std::string* message);
    Status Finish();

  private:
    void EnsureFinished();

    FinishFn finish_;
    LiveWriteFn live_write_;
    WritesDoneFn live_writes_done_;
    LiveFinishFn live_finish_;
    std::shared_ptr<internal::MessageQueue> response_queue_;
    std::vector<std::string> requests_;
    std::vector<std::string> responses_;
    std::size_t next_response_ = 0;
    bool writes_done_ = false;
    bool finished_ = false;
    Status status_;
};

}  // namespace grpc_lite

#endif  // GRPC_LITE_STREAM_H_
