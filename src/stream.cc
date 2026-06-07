#include "grpc_lite/stream.h"

#include <utility>

namespace grpc_lite {

namespace internal {

bool MessageQueue::Push(std::string message) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (closed_) {
            return false;
        }
        messages_.push_back(std::move(message));
    }
    cv_.notify_one();
    return true;
}

bool MessageQueue::Read(std::string* message) {
    std::unique_lock<std::mutex> lock(mutex_);
    cv_.wait(lock, [this]() { return !messages_.empty() || closed_; });
    if (messages_.empty()) {
        return false;
    }
    *message = std::move(messages_.front());
    messages_.pop_front();
    return true;
}

void MessageQueue::Close(Status status) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (closed_) {
            return;
        }
        closed_ = true;
        status_ = std::move(status);
    }
    cv_.notify_all();
}

Status MessageQueue::status() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return status_;
}

bool MessageQueue::closed() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return closed_;
}

}  // namespace internal

ServerReader::ServerReader(std::vector<std::string> messages) : messages_(std::move(messages)) {}

ServerReader::ServerReader(std::shared_ptr<internal::MessageQueue> queue)
    : queue_(std::move(queue)) {}

bool ServerReader::Read(std::string* message) {
    if (queue_ != nullptr) {
        return queue_->Read(message);
    }
    if (message == nullptr || next_ >= messages_.size()) {
        return false;
    }
    *message = messages_[next_++];
    return true;
}

ServerWriter::ServerWriter(std::vector<std::string>* messages) : messages_(messages) {}

ServerWriter::ServerWriter(WriteFn write) : write_(std::move(write)) {}

bool ServerWriter::Write(std::string_view message) {
    if (write_) {
        return write_(message);
    }
    if (messages_ == nullptr) {
        return false;
    }
    messages_->emplace_back(message);
    return true;
}

ServerReaderWriter::ServerReaderWriter(
    std::vector<std::string> requests, std::vector<std::string>* responses
)
    : reader_(std::move(requests)), writer_(responses) {}

ServerReaderWriter::ServerReaderWriter(
    std::shared_ptr<internal::MessageQueue> requests, ServerWriter::WriteFn write
)
    : reader_(std::move(requests)), writer_(std::move(write)) {}

bool ServerReaderWriter::Read(std::string* message) {
    return reader_.Read(message);
}

bool ServerReaderWriter::Write(std::string_view message) {
    return writer_.Write(message);
}

ClientReader::ClientReader(Status status, std::vector<std::string> messages)
    : status_(std::move(status)), messages_(std::move(messages)) {}

ClientReader::ClientReader(std::shared_ptr<internal::MessageQueue> messages, FinishFn finish)
    : finish_(std::move(finish)), queue_(std::move(messages)) {}

bool ClientReader::Read(std::string* message) {
    if (queue_ != nullptr) {
        return queue_->Read(message);
    }
    if (message == nullptr || next_ >= messages_.size()) {
        return false;
    }
    *message = messages_[next_++];
    return true;
}

Status ClientReader::Finish() {
    if (finish_) {
        return finish_();
    }
    return status_;
}

ClientWriter::ClientWriter(FinishFn finish) : finish_(std::move(finish)) {}

ClientWriter::ClientWriter(LiveWriteFn write, WritesDoneFn writes_done, LiveFinishFn finish)
    : live_write_(std::move(write)),
      live_writes_done_(std::move(writes_done)),
      live_finish_(std::move(finish)) {}

bool ClientWriter::Write(std::string_view message) {
    if (live_write_) {
        return live_write_(message);
    }
    if (writes_done_ || finished_) {
        return false;
    }
    messages_.emplace_back(message);
    return true;
}

bool ClientWriter::WritesDone() {
    if (live_writes_done_) {
        return live_writes_done_();
    }
    if (finished_) {
        return false;
    }
    writes_done_ = true;
    return true;
}

Status ClientWriter::Finish(std::string* response) {
    if (live_finish_) {
        return live_finish_(response);
    }
    if (!writes_done_) {
        writes_done_ = true;
    }
    if (!finished_) {
        status_ = finish_(messages_, response);
        finished_ = true;
    }
    return status_;
}

ClientReaderWriter::ClientReaderWriter(FinishFn finish) : finish_(std::move(finish)) {}

ClientReaderWriter::ClientReaderWriter(
    LiveWriteFn write, WritesDoneFn writes_done, std::shared_ptr<internal::MessageQueue> responses,
    LiveFinishFn finish
)
    : live_write_(std::move(write)),
      live_writes_done_(std::move(writes_done)),
      live_finish_(std::move(finish)),
      response_queue_(std::move(responses)) {}

bool ClientReaderWriter::Write(std::string_view message) {
    if (live_write_) {
        return live_write_(message);
    }
    if (writes_done_ || finished_) {
        return false;
    }
    requests_.emplace_back(message);
    return true;
}

bool ClientReaderWriter::WritesDone() {
    if (live_writes_done_) {
        return live_writes_done_();
    }
    if (finished_) {
        return false;
    }
    writes_done_ = true;
    return true;
}

bool ClientReaderWriter::Read(std::string* message) {
    if (response_queue_ != nullptr) {
        return response_queue_->Read(message);
    }
    EnsureFinished();
    if (message == nullptr || next_response_ >= responses_.size()) {
        return false;
    }
    *message = responses_[next_response_++];
    return true;
}

Status ClientReaderWriter::Finish() {
    EnsureFinished();
    return status_;
}

void ClientReaderWriter::EnsureFinished() {
    if (response_queue_ != nullptr) {
        if (!finished_) {
            status_ = live_finish_();
            finished_ = true;
        }
        return;
    }
    if (finished_) {
        return;
    }
    writes_done_ = true;
    status_ = finish_(requests_, &responses_);
    finished_ = true;
}

}  // namespace grpc_lite
