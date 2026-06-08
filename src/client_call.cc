#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

#include <nghttp2/nghttp2.h>

#include "core/grpc_frame.h"
#include "grpc_lite/channel.h"
#include "grpc_lite/client_context.h"

namespace grpc_lite {

namespace {

struct AddressParts {
    std::string host;
    int port = 0;
};

Status ParseAddress(std::string_view address, AddressParts* out) {
    const std::size_t separator = address.rfind(':');
    if (separator == std::string_view::npos) {
        return Status(StatusCode::kInvalidArgument, "target address must be in host:port form");
    }

    out->host = std::string(address.substr(0, separator));
    if (out->host.empty()) {
        out->host = "127.0.0.1";
    }

    const std::string port_text(address.substr(separator + 1));
    try {
        out->port = std::stoi(port_text);
    } catch (...) {
        return Status(StatusCode::kInvalidArgument, "target port must be numeric");
    }

    if (out->port <= 0 || out->port > 65535) {
        return Status(StatusCode::kInvalidArgument, "target port must be in the range 1-65535");
    }
    return Status::OK();
}

Status PushResponseFrames(
    std::string* pending, const uint8_t* data, size_t len,
    const std::shared_ptr<internal::MessageQueue>& responses
) {
    pending->append(reinterpret_cast<const char*>(data), len);
    for (;;) {
        if (pending->empty() || pending->size() < 5U) {
            return Status::OK();
        }
        if (static_cast<unsigned char>((*pending)[0]) != 0) {
            return Status(
                StatusCode::kUnimplemented, "compressed grpc messages are not supported yet"
            );
        }
        const std::uint32_t size =
            (static_cast<std::uint32_t>(static_cast<unsigned char>((*pending)[1])) << 24) |
            (static_cast<std::uint32_t>(static_cast<unsigned char>((*pending)[2])) << 16) |
            (static_cast<std::uint32_t>(static_cast<unsigned char>((*pending)[3])) << 8) |
            static_cast<std::uint32_t>(static_cast<unsigned char>((*pending)[4]));
        const std::size_t full_size = static_cast<std::size_t>(size) + 5U;
        if (pending->size() < full_size) {
            return Status::OK();
        }
        responses->Push(pending->substr(5, size));
        pending->erase(0, full_size);
    }
}

Status BuildFinalStatus(
    const std::string& http_status, int grpc_status, const std::string& grpc_message
) {
    if (http_status != "200") {
        return Status(StatusCode::kUnavailable, "server returned HTTP status " + http_status);
    }
    if (grpc_status < 0) {
        return Status(StatusCode::kInternal, "server did not send grpc-status trailer");
    }
    const StatusCode grpc_code = core::StatusCodeFromInt(grpc_status);
    return grpc_code == StatusCode::kOk ? Status::OK() : Status(grpc_code, grpc_message);
}

class ClientStream {
  public:
    ClientStream(std::string method, ClientContext* context)
        : method(std::move(method)),
          context(context),
          responses(std::make_shared<internal::MessageQueue>()) {}

    void Finish(Status finish_status) {
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (finished) {
                return;
            }
            status = std::move(finish_status);
            finished = true;
        }
        responses->Close(status);
        cv.notify_all();
    }

    Status Wait() {
        std::unique_lock<std::mutex> lock(mutex);
        if (context != nullptr && context->deadline() != std::chrono::system_clock::time_point{}) {
            if (!cv.wait_until(lock, context->deadline(), [this]() { return finished; })) {
                status = Status(StatusCode::kDeadlineExceeded, "deadline exceeded");
                finished = true;
                responses->Close(status);
            }
        } else {
            cv.wait(lock, [this]() { return finished; });
        }
        return status;
    }

    void CopyMetadata() {
        if (context == nullptr) {
            return;
        }
        context->SetServerInitialMetadata(initial_metadata);
        context->SetServerTrailingMetadata(trailing_metadata);
    }

    std::string method;
    ClientContext* context = nullptr;
    int32_t stream_id = 0;
    std::deque<std::string> outgoing;
    std::string current_outgoing;
    std::size_t current_outgoing_offset = 0;
    std::string pending_response_frame;
    std::shared_ptr<internal::MessageQueue> responses;
    std::vector<std::pair<std::string, std::string>> initial_metadata;
    std::vector<std::pair<std::string, std::string>> trailing_metadata;
    std::string http_status;
    int grpc_status = -1;
    std::string grpc_message;
    bool writes_done = false;
    bool finished = false;
    Status status;
    std::mutex mutex;
    std::condition_variable cv;
};

}  // namespace

class ChannelImpl : public std::enable_shared_from_this<ChannelImpl> {
  public:
    ChannelImpl(std::string target, ChannelOptions options)
        : target_(std::move(target)), options_(options) {}

    ~ChannelImpl() { Shutdown(); }

    Status StartCall(
        const std::string& method, ClientContext* context,
        const std::vector<std::string>& initial_messages, bool writes_done,
        std::shared_ptr<ClientStream>* out
    ) {
        JoinInactiveThreads();

        std::shared_ptr<ClientStream> stream = std::make_shared<ClientStream>(method, context);
        for (const auto& message : initial_messages) {
            stream->outgoing.push_back(core::EncodeGrpcFrame(message));
        }
        stream->writes_done = writes_done;

        std::unique_lock<std::mutex> lock(mutex_);
        Status connected = EnsureConnectedLocked();
        if (!connected.ok()) {
            stream->Finish(connected);
            *out = stream;
            return connected;
        }

        if (draining_) {
            if (!streams_.empty()) {
                Status status(StatusCode::kUnavailable, "connection is draining");
                stream->Finish(status);
                *out = stream;
                return status;
            }
            CloseConnectionLocked(Status(StatusCode::kUnavailable, "connection is draining"));
            lock.unlock();
            JoinReadThread();
            JoinKeepaliveThread();
            lock.lock();
            connected = EnsureConnectedLocked();
            if (!connected.ok()) {
                stream->Finish(connected);
                *out = stream;
                return connected;
            }
        }
        if (options_.max_concurrent_streams != 0 &&
            streams_.size() >= options_.max_concurrent_streams) {
            Status status(StatusCode::kResourceExhausted, "maximum concurrent streams exceeded");
            stream->Finish(status);
            *out = stream;
            return status;
        }

        std::vector<std::string> header_values{
            "POST", "http", method, target_, "application/grpc", "trailers", "identity"
        };
        std::vector<nghttp2_nv> headers;
        headers.push_back(core::MakeHeader(":method", header_values[0]));
        headers.push_back(core::MakeHeader(":scheme", header_values[1]));
        headers.push_back(core::MakeHeader(":path", header_values[2]));
        headers.push_back(core::MakeHeader(":authority", header_values[3]));
        headers.push_back(core::MakeHeader("content-type", header_values[4]));
        headers.push_back(core::MakeHeader("te", header_values[5]));
        headers.push_back(core::MakeHeader("grpc-encoding", header_values[6]));
        if (context != nullptr) {
            for (const auto& metadata : context->metadata()) {
                headers.push_back(core::MakeHeader(metadata.first, metadata.second));
            }
        }

        nghttp2_data_provider provider{};
        provider.source.ptr = stream.get();
        provider.read_callback = ReadRequestData;
        const int32_t stream_id = nghttp2_submit_request(
            session_, nullptr, headers.data(), headers.size(), &provider, stream.get()
        );
        if (stream_id < 0) {
            stream->Finish(Status(StatusCode::kInternal, "failed to submit HTTP/2 request"));
            *out = stream;
            return stream->status;
        }
        stream->stream_id = stream_id;
        streams_[stream_id] = stream;
        QueueOutputLocked();
        Status flush_status = FlushLocked();
        if (!flush_status.ok()) {
            stream->Finish(flush_status);
            streams_.erase(stream_id);
        }
        *out = stream;
        return Status::OK();
    }

    bool Write(const std::shared_ptr<ClientStream>& stream, std::string_view message) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (closed_ || stream->finished || stream->writes_done) {
            return false;
        }
        stream->outgoing.push_back(core::EncodeGrpcFrame(message));
        nghttp2_session_resume_data(session_, stream->stream_id);
        QueueOutputLocked();
        return FlushLocked().ok();
    }

    bool WritesDone(const std::shared_ptr<ClientStream>& stream) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (closed_ || stream->finished || stream->writes_done) {
            return false;
        }
        stream->writes_done = true;
        nghttp2_session_resume_data(session_, stream->stream_id);
        QueueOutputLocked();
        return FlushLocked().ok();
    }

    void Shutdown() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            CloseConnectionLocked(Status(StatusCode::kCancelled, "channel closed"));
            shutdown_ = true;
        }
        JoinReadThread();
        JoinKeepaliveThread();
    }

  private:
    static ssize_t
    ReadRequestData(nghttp2_session*, int32_t, uint8_t* buffer, size_t length, uint32_t* data_flags, nghttp2_data_source* source, void*) {
        auto* stream = static_cast<ClientStream*>(source->ptr);
        if (stream->current_outgoing.empty() && !stream->outgoing.empty()) {
            stream->current_outgoing = std::move(stream->outgoing.front());
            stream->outgoing.pop_front();
            stream->current_outgoing_offset = 0;
        }
        if (stream->current_outgoing.empty()) {
            if (stream->writes_done) {
                *data_flags |= NGHTTP2_DATA_FLAG_EOF;
                return 0;
            }
            return NGHTTP2_ERR_DEFERRED;
        }

        const std::size_t remaining =
            stream->current_outgoing.size() - stream->current_outgoing_offset;
        const std::size_t to_copy = std::min(remaining, length);
        if (to_copy != 0) {
            std::memcpy(
                buffer, stream->current_outgoing.data() + stream->current_outgoing_offset, to_copy
            );
            stream->current_outgoing_offset += to_copy;
        }
        if (stream->current_outgoing_offset == stream->current_outgoing.size()) {
            stream->current_outgoing.clear();
            stream->current_outgoing_offset = 0;
        }
        return static_cast<ssize_t>(to_copy);
    }

    static int OnHeader(
        nghttp2_session*, const nghttp2_frame* frame, const uint8_t* name, size_t namelen,
        const uint8_t* value, size_t valuelen, uint8_t, void* user_data
    ) {
        auto* self = static_cast<ChannelImpl*>(user_data);
        std::shared_ptr<ClientStream> stream = self->FindStream(frame->hd.stream_id);
        if (stream == nullptr) {
            return 0;
        }
        const std::string_view hname(reinterpret_cast<const char*>(name), namelen);
        const std::string_view hvalue(reinterpret_cast<const char*>(value), valuelen);
        if (frame->headers.cat == NGHTTP2_HCAT_RESPONSE) {
            if (hname == ":status") {
                stream->http_status.assign(hvalue);
            } else {
                stream->initial_metadata.emplace_back(std::string(hname), std::string(hvalue));
            }
        } else if (frame->headers.cat == NGHTTP2_HCAT_HEADERS) {
            if (hname == "grpc-status") {
                stream->grpc_status = std::atoi(std::string(hvalue).c_str());
            } else if (hname == "grpc-message") {
                stream->grpc_message.assign(hvalue);
            } else {
                stream->trailing_metadata.emplace_back(std::string(hname), std::string(hvalue));
            }
        }
        return 0;
    }

    static int OnData(
        nghttp2_session*, uint8_t, int32_t stream_id, const uint8_t* data, size_t len,
        void* user_data
    ) {
        auto* self = static_cast<ChannelImpl*>(user_data);
        std::shared_ptr<ClientStream> stream = self->FindStream(stream_id);
        if (stream == nullptr) {
            return 0;
        }
        Status status =
            PushResponseFrames(&stream->pending_response_frame, data, len, stream->responses);
        if (!status.ok()) {
            stream->Finish(status);
        }
        return 0;
    }

    static int OnFrameRecv(nghttp2_session*, const nghttp2_frame* frame, void* user_data) {
        auto* self = static_cast<ChannelImpl*>(user_data);
        if (frame->hd.type == NGHTTP2_GOAWAY) {
            self->draining_ = true;
        }
        if (frame->hd.type == NGHTTP2_PING && (frame->hd.flags & NGHTTP2_FLAG_ACK) != 0) {
            self->ping_outstanding_ = false;
        }
        return 0;
    }

    static int OnStreamClose(nghttp2_session*, int32_t stream_id, uint32_t, void* user_data) {
        auto* self = static_cast<ChannelImpl*>(user_data);
        std::shared_ptr<ClientStream> stream;
        auto it = self->streams_.find(stream_id);
        if (it == self->streams_.end()) {
            return 0;
        }
        stream = it->second;
        self->streams_.erase(it);
        Status status =
            BuildFinalStatus(stream->http_status, stream->grpc_status, stream->grpc_message);
        stream->Finish(status);
        return 0;
    }

    std::shared_ptr<ClientStream> FindStream(int32_t stream_id) {
        auto it = streams_.find(stream_id);
        if (it == streams_.end()) {
            return nullptr;
        }
        return it->second;
    }

    Status EnsureConnectedLocked() {
        if (session_ != nullptr && fd_ >= 0 && !closed_) {
            return Status::OK();
        }
        if (shutdown_) {
            return Status(StatusCode::kCancelled, "channel closed");
        }
        const auto now = std::chrono::steady_clock::now();
        if (next_connect_attempt_ > now) {
            return Status(StatusCode::kUnavailable, "connection backoff in progress");
        }

        AddressParts address;
        Status addr_status = ParseAddress(target_, &address);
        if (!addr_status.ok()) {
            return addr_status;
        }

        const int fd = ::socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) {
            Status status(StatusCode::kUnavailable, "failed to create socket");
            RecordConnectFailureLocked();
            return status;
        }

        sockaddr_in socket_address{};
        socket_address.sin_family = AF_INET;
        socket_address.sin_port = htons(static_cast<std::uint16_t>(address.port));
        if (::inet_pton(AF_INET, address.host.c_str(), &socket_address.sin_addr) != 1) {
            ::close(fd);
            return Status(StatusCode::kInvalidArgument, "only IPv4 targets are supported for now");
        }
        if (::connect(fd, reinterpret_cast<sockaddr*>(&socket_address), sizeof(socket_address)) !=
            0) {
            ::close(fd);
            Status status(StatusCode::kUnavailable, "failed to connect to server");
            RecordConnectFailureLocked();
            return status;
        }

        nghttp2_session_callbacks* callbacks = nullptr;
        nghttp2_session_callbacks_new(&callbacks);
        nghttp2_session_callbacks_set_on_header_callback(callbacks, OnHeader);
        nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, OnData);
        nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, OnFrameRecv);
        nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, OnStreamClose);
        if (nghttp2_session_client_new(&session_, callbacks, this) != 0) {
            nghttp2_session_callbacks_del(callbacks);
            ::close(fd);
            Status status(StatusCode::kInternal, "failed to create nghttp2 client session");
            RecordConnectFailureLocked();
            return status;
        }
        nghttp2_session_callbacks_del(callbacks);

        fd_ = fd;
        closed_ = false;
        draining_ = false;
        ping_outstanding_ = false;
        nghttp2_submit_settings(session_, NGHTTP2_FLAG_NONE, nullptr, 0);
        QueueOutputLocked();
        Status flush_status = FlushLocked();
        if (!flush_status.ok()) {
            CloseConnectionLocked(flush_status);
            RecordConnectFailureLocked();
            return flush_status;
        }
        backoff_delay_ = std::chrono::milliseconds(100);
        next_connect_attempt_ = {};
        read_thread_ = std::thread([this]() { ReadLoop(); });
        if (options_.keepalive_time.count() > 0) {
            keepalive_thread_ = std::thread([this]() { KeepaliveLoop(); });
        }
        return Status::OK();
    }

    void ReadLoop() {
        char buffer[8192];
        for (;;) {
            const ssize_t nread = ::recv(fd_, buffer, sizeof(buffer), 0);
            if (nread <= 0) {
                break;
            }
            std::lock_guard<std::mutex> lock(mutex_);
            if (session_ == nullptr) {
                break;
            }
            if (nghttp2_session_mem_recv(
                    session_, reinterpret_cast<const uint8_t*>(buffer), static_cast<size_t>(nread)
                ) < 0) {
                CloseConnectionLocked(Status(StatusCode::kInternal, "nghttp2 receive error"));
                return;
            }
            QueueOutputLocked();
            FlushLocked();
        }
        std::lock_guard<std::mutex> lock(mutex_);
        if (!closed_ && !shutdown_) {
            CloseConnectionLocked(Status(StatusCode::kUnavailable, "connection closed by server"));
        }
    }

    void QueueOutputLocked() {
        if (session_ == nullptr) {
            return;
        }
        const uint8_t* data = nullptr;
        for (;;) {
            const ssize_t bytes = nghttp2_session_mem_send(session_, &data);
            if (bytes <= 0) {
                return;
            }
            pending_writes_.emplace_back(
                reinterpret_cast<const char*>(data), static_cast<std::size_t>(bytes)
            );
        }
    }

    Status FlushLocked() {
        while (!pending_writes_.empty()) {
            std::string out = std::move(pending_writes_.front());
            pending_writes_.pop_front();
            std::string_view remaining(out);
            while (!remaining.empty()) {
                const ssize_t sent = ::send(fd_, remaining.data(), remaining.size(), MSG_NOSIGNAL);
                if (sent <= 0) {
                    Status status(StatusCode::kUnavailable, "write to server failed");
                    CloseConnectionLocked(status);
                    return status;
                }
                remaining.remove_prefix(static_cast<std::size_t>(sent));
            }
        }
        return Status::OK();
    }

    void CloseConnectionLocked(const Status& status) {
        if (closed_) {
            return;
        }
        closed_ = true;
        keepalive_cv_.notify_all();
        pending_writes_.clear();
        for (const auto& entry : streams_) {
            entry.second->Finish(status);
        }
        streams_.clear();
        if (fd_ >= 0) {
            ::shutdown(fd_, SHUT_RDWR);
            ::close(fd_);
            fd_ = -1;
        }
        if (session_ != nullptr) {
            nghttp2_session_del(session_);
            session_ = nullptr;
        }
    }

    void JoinReadThread() {
        if (read_thread_.joinable() && std::this_thread::get_id() != read_thread_.get_id()) {
            read_thread_.join();
        }
    }

    void JoinKeepaliveThread() {
        if (keepalive_thread_.joinable() &&
            std::this_thread::get_id() != keepalive_thread_.get_id()) {
            keepalive_thread_.join();
        }
    }

    void JoinInactiveThreads() {
        std::lock_guard<std::mutex> join_lock(join_mutex_);
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!closed_) {
                return;
            }
        }
        JoinReadThread();
        JoinKeepaliveThread();
    }

    void RecordConnectFailureLocked() {
        next_connect_attempt_ = std::chrono::steady_clock::now() + backoff_delay_;
        const auto next =
            std::chrono::duration_cast<std::chrono::milliseconds>(backoff_delay_ * 8 / 5);
        backoff_delay_ = std::min(next, std::chrono::milliseconds(120000));
    }

    void KeepaliveLoop() {
        std::unique_lock<std::mutex> lock(mutex_);
        for (;;) {
            if (keepalive_cv_.wait_for(lock, options_.keepalive_time, [this]() {
                    return shutdown_ || closed_;
                })) {
                return;
            }
            if (session_ == nullptr) {
                return;
            }
            if (ping_outstanding_) {
                const auto elapsed = std::chrono::steady_clock::now() - last_ping_;
                if (elapsed >= options_.keepalive_timeout) {
                    CloseConnectionLocked(Status(StatusCode::kUnavailable, "keepalive timeout"));
                    return;
                }
                continue;
            }
            std::uint8_t opaque_data[8] = {'g', 'r', 'p', 'c', '-', 'l', 'i', 't'};
            if (nghttp2_submit_ping(session_, NGHTTP2_FLAG_NONE, opaque_data) != 0) {
                CloseConnectionLocked(Status(StatusCode::kInternal, "failed to submit keepalive"));
                return;
            }
            ping_outstanding_ = true;
            last_ping_ = std::chrono::steady_clock::now();
            QueueOutputLocked();
            FlushLocked();
        }
    }

    std::string target_;
    ChannelOptions options_;
    std::mutex mutex_;
    std::mutex join_mutex_;
    std::condition_variable keepalive_cv_;
    int fd_ = -1;
    nghttp2_session* session_ = nullptr;
    std::thread read_thread_;
    std::thread keepalive_thread_;
    std::unordered_map<int32_t, std::shared_ptr<ClientStream>> streams_;
    std::deque<std::string> pending_writes_;
    bool closed_ = true;
    bool shutdown_ = false;
    bool draining_ = false;
    bool ping_outstanding_ = false;
    std::chrono::steady_clock::time_point last_ping_;
    std::chrono::steady_clock::time_point next_connect_attempt_;
    std::chrono::milliseconds backoff_delay_{100};
};

Channel::~Channel() = default;

std::shared_ptr<ChannelImpl> Channel::impl() {
    std::lock_guard<std::mutex> lock(impl_mutex_);
    if (impl_ == nullptr) {
        impl_ = std::make_shared<ChannelImpl>(target_, options_);
    }
    return impl_;
}

Status Channel::CallUnary(
    const std::string& method, const std::string& request_bytes, ClientContext* context,
    std::string* response_bytes
) {
    std::vector<std::string> responses;
    Status status = CallServerStreaming(method, request_bytes, context, &responses);
    if (!status.ok()) {
        return status;
    }
    if (responses.size() != 1U) {
        return Status(
            StatusCode::kInvalidArgument,
            "grpc request body does not contain exactly one unary message"
        );
    }
    *response_bytes = std::move(responses.front());
    return Status::OK();
}

Status Channel::CallServerStreaming(
    const std::string& method, const std::string& request_bytes, ClientContext* context,
    std::vector<std::string>* response_messages
) {
    std::shared_ptr<ClientStream> stream;
    Status start_status = impl()->StartCall(method, context, {request_bytes}, true, &stream);
    if (!start_status.ok()) {
        return start_status;
    }
    Status status = stream->Wait();
    std::string message;
    while (stream->responses->Read(&message)) {
        response_messages->push_back(std::move(message));
    }
    stream->CopyMetadata();
    return status;
}

std::unique_ptr<ClientReader> Channel::StartServerStreaming(
    const std::string& method, const std::string& request_bytes, ClientContext* context
) {
    std::shared_ptr<ClientStream> stream;
    std::shared_ptr<ChannelImpl> channel_impl = impl();
    Status status = channel_impl->StartCall(method, context, {request_bytes}, true, &stream);
    if (!status.ok()) {
        return std::make_unique<ClientReader>(std::move(status), std::vector<std::string>{});
    }
    return std::make_unique<ClientReader>(stream->responses, [stream]() mutable {
        Status finish_status = stream->Wait();
        stream->CopyMetadata();
        return finish_status;
    });
}

std::unique_ptr<ClientWriter> Channel::StartClientStreaming(
    const std::string& method, ClientContext* context
) {
    std::shared_ptr<ClientStream> stream;
    std::shared_ptr<ChannelImpl> channel_impl = impl();
    Status status = channel_impl->StartCall(method, context, {}, false, &stream);
    if (!status.ok()) {
        return std::make_unique<ClientWriter>(
            [status](const std::vector<std::string>&, std::string*) { return status; }
        );
    }
    return std::make_unique<ClientWriter>(
        [channel_impl, stream](std::string_view message) {
            return channel_impl->Write(stream, message);
        },
        [channel_impl, stream]() { return channel_impl->WritesDone(stream); },
        [stream](std::string* response) mutable {
            Status status = stream->Wait();
            std::string message;
            if (response != nullptr && stream->responses->Read(&message)) {
                *response = std::move(message);
            }
            stream->CopyMetadata();
            return status;
        }
    );
}

std::unique_ptr<ClientReaderWriter> Channel::StartBidiStreaming(
    const std::string& method, ClientContext* context
) {
    std::shared_ptr<ClientStream> stream;
    std::shared_ptr<ChannelImpl> channel_impl = impl();
    Status status = channel_impl->StartCall(method, context, {}, false, &stream);
    if (!status.ok()) {
        return std::make_unique<ClientReaderWriter>(
            [status](const std::vector<std::string>&, std::vector<std::string>*) { return status; }
        );
    }
    return std::make_unique<ClientReaderWriter>(
        [channel_impl, stream](std::string_view message) {
            return channel_impl->Write(stream, message);
        },
        [channel_impl, stream]() { return channel_impl->WritesDone(stream); }, stream->responses,
        [stream]() mutable {
            Status status = stream->Wait();
            stream->CopyMetadata();
            return status;
        }
    );
}

Status Channel::CallClientStreaming(
    const std::string& method, const std::vector<std::string>& request_messages,
    ClientContext* context, std::string* response_bytes
) {
    std::vector<std::string> responses;
    Status status = CallBidiStreaming(method, request_messages, context, &responses);
    if (!status.ok()) {
        return status;
    }
    if (responses.size() != 1U) {
        return Status(
            StatusCode::kInvalidArgument,
            "client streaming response must contain exactly one message"
        );
    }
    *response_bytes = std::move(responses.front());
    return Status::OK();
}

Status Channel::CallBidiStreaming(
    const std::string& method, const std::vector<std::string>& request_messages,
    ClientContext* context, std::vector<std::string>* response_messages
) {
    std::shared_ptr<ClientStream> stream;
    Status start_status = impl()->StartCall(method, context, request_messages, true, &stream);
    if (!start_status.ok()) {
        return start_status;
    }
    Status status = stream->Wait();
    std::string message;
    while (stream->responses->Read(&message)) {
        response_messages->push_back(std::move(message));
    }
    stream->CopyMetadata();
    return status;
}

}  // namespace grpc_lite
