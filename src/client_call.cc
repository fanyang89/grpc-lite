#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#include <uv.h>

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
#include <utility>
#include <vector>

#include <nghttp2/nghttp2.h>

#include "core/grpc_frame.h"
#include "grpc_lite/channel.h"
#include "grpc_lite/client_context.h"

namespace grpc_lite {

namespace {

struct ClientCallState {
    uv_loop_t* loop = nullptr;
    uv_tcp_t tcp_handle{};
    uv_connect_t connect_req{};
    uv_timer_t deadline_timer{};
    nghttp2_session* session = nullptr;

    std::string request_frame;
    std::size_t send_offset = 0;

    std::string response_body;
    std::vector<std::pair<std::string, std::string>> initial_metadata;
    std::vector<std::pair<std::string, std::string>> trailing_metadata;

    int grpc_status = -1;
    std::string grpc_message;
    std::string http_status;

    bool stream_closed = false;
    bool has_deadline = false;
    bool deadline_expired = false;
    bool closed = false;
    Status transport_error;
    int32_t stream_id = 0;

    std::string method;
    std::string authority;
    std::vector<std::pair<std::string, std::string>> client_metadata;

    std::vector<std::string> pending_writes;
    bool write_in_flight = false;
};

struct PendingWrite {
    uv_write_t request;
    uv_buf_t buffer;
    std::string data;
};

void CloseClient(ClientCallState* state);

void FreeWrite(uv_write_t* request) {
    auto* pending = static_cast<PendingWrite*>(request->data);
    delete pending;
}

void FlushPendingWrites(ClientCallState* state);

void AfterWrite(uv_write_t* request, int status) {
    auto* state = static_cast<ClientCallState*>(request->handle->data);
    state->write_in_flight = false;
    FreeWrite(request);

    if (status < 0) {
        state->transport_error = Status(StatusCode::kUnavailable, "write to server failed");
        CloseClient(state);
        return;
    }

    if (!state->pending_writes.empty()) {
        state->pending_writes.erase(state->pending_writes.begin());
    }
    FlushPendingWrites(state);
}

void FlushPendingWrites(ClientCallState* state) {
    if (state->closed || state->write_in_flight || state->pending_writes.empty()) {
        return;
    }

    auto* pending = new PendingWrite();
    pending->data = state->pending_writes.front();
    pending->buffer = uv_buf_init(pending->data.data(), pending->data.size());
    pending->request.data = pending;
    state->write_in_flight = true;

    const int rc = uv_write(
        &pending->request, reinterpret_cast<uv_stream_t*>(&state->tcp_handle), &pending->buffer, 1,
        AfterWrite
    );
    if (rc != 0) {
        state->write_in_flight = false;
        FreeWrite(&pending->request);
        state->transport_error = Status(StatusCode::kUnavailable, "failed to queue write");
        CloseClient(state);
    }
}

void QueueOutput(ClientCallState* state) {
    const uint8_t* data = nullptr;
    for (;;) {
        const ssize_t bytes = nghttp2_session_mem_send(state->session, &data);
        if (bytes < 0) {
            state->transport_error = Status(StatusCode::kInternal, "nghttp2 send error");
            CloseClient(state);
            return;
        }
        if (bytes == 0) {
            return;
        }
        state->pending_writes.emplace_back(
            reinterpret_cast<const char*>(data), static_cast<std::size_t>(bytes)
        );
    }
}

void OnHandleClosed(uv_handle_t* handle) {
    (void)handle;
}

void CloseClient(ClientCallState* state) {
    if (state->closed) {
        return;
    }
    state->closed = true;
    uv_read_stop(reinterpret_cast<uv_stream_t*>(&state->tcp_handle));
    if (state->has_deadline &&
        !uv_is_closing(reinterpret_cast<uv_handle_t*>(&state->deadline_timer))) {
        uv_close(reinterpret_cast<uv_handle_t*>(&state->deadline_timer), OnHandleClosed);
    }
    if (!uv_is_closing(reinterpret_cast<uv_handle_t*>(&state->tcp_handle))) {
        uv_close(reinterpret_cast<uv_handle_t*>(&state->tcp_handle), OnHandleClosed);
    }
}

int OnHeaderCallback(
    nghttp2_session* session, const nghttp2_frame* frame, const uint8_t* name, size_t namelen,
    const uint8_t* value, size_t valuelen, uint8_t flags, void* user_data
) {
    (void)session;
    (void)flags;
    auto* state = static_cast<ClientCallState*>(user_data);

    if (frame->hd.stream_id != state->stream_id) {
        return 0;
    }

    const std::string_view hname(reinterpret_cast<const char*>(name), namelen);
    const std::string_view hvalue(reinterpret_cast<const char*>(value), valuelen);

    if (frame->headers.cat == NGHTTP2_HCAT_RESPONSE) {
        if (hname == ":status") {
            state->http_status.assign(hvalue);
        } else {
            state->initial_metadata.emplace_back(std::string(hname), std::string(hvalue));
        }
    } else if (frame->headers.cat == NGHTTP2_HCAT_HEADERS) {
        if (hname == "grpc-status") {
            state->grpc_status = std::atoi(std::string(hvalue).c_str());
        } else if (hname == "grpc-message") {
            state->grpc_message.assign(hvalue);
        } else {
            state->trailing_metadata.emplace_back(std::string(hname), std::string(hvalue));
        }
    }

    return 0;
}

int OnDataChunkRecvCallback(
    nghttp2_session* session, uint8_t flags, int32_t stream_id, const uint8_t* data, size_t len,
    void* user_data
) {
    (void)session;
    (void)flags;
    auto* state = static_cast<ClientCallState*>(user_data);
    if (stream_id == state->stream_id) {
        state->response_body.append(reinterpret_cast<const char*>(data), len);
    }
    return 0;
}

int OnFrameRecvCallback(nghttp2_session* session, const nghttp2_frame* frame, void* user_data) {
    (void)session;
    (void)user_data;
    return 0;
}

int OnStreamCloseCallback(
    nghttp2_session* session, int32_t stream_id, uint32_t error_code, void* user_data
) {
    (void)session;
    (void)error_code;
    auto* state = static_cast<ClientCallState*>(user_data);
    if (stream_id == state->stream_id) {
        state->stream_closed = true;
        CloseClient(state);
    }
    return 0;
}

void AllocBuffer(uv_handle_t* handle, size_t suggested_size, uv_buf_t* buffer) {
    (void)handle;
    buffer->base = new char[suggested_size];
    buffer->len = suggested_size;
}

void AfterRead(uv_stream_t* stream, ssize_t nread, const uv_buf_t* buffer) {
    auto* state = static_cast<ClientCallState*>(stream->data);
    std::unique_ptr<char[]> cleanup(buffer->base);

    if (nread < 0) {
        if (!state->stream_closed) {
            state->transport_error =
                Status(StatusCode::kUnavailable, "connection closed by server");
        }
        CloseClient(state);
        return;
    }
    if (nread == 0) {
        return;
    }

    const ssize_t consumed = nghttp2_session_mem_recv(
        state->session, reinterpret_cast<const uint8_t*>(buffer->base), static_cast<size_t>(nread)
    );
    if (consumed < 0) {
        state->transport_error = Status(StatusCode::kInternal, "nghttp2 receive error");
        CloseClient(state);
        return;
    }

    QueueOutput(state);
    FlushPendingWrites(state);
}

ssize_t RequestDataProvider(
    nghttp2_session* session, int32_t stream_id, uint8_t* buf, size_t length, uint32_t* data_flags,
    nghttp2_data_source* source, void* user_data
) {
    (void)session;
    (void)stream_id;
    (void)user_data;
    auto* state = static_cast<ClientCallState*>(source->ptr);

    const std::size_t remaining = state->request_frame.size() - state->send_offset;
    const std::size_t to_copy = std::min(remaining, length);
    if (to_copy != 0) {
        std::memcpy(buf, state->request_frame.data() + state->send_offset, to_copy);
        state->send_offset += to_copy;
    }

    if (state->send_offset == state->request_frame.size()) {
        *data_flags |= NGHTTP2_DATA_FLAG_EOF;
    }

    return static_cast<ssize_t>(to_copy);
}

void OnDeadlineExpired(uv_timer_t* timer) {
    auto* state = static_cast<ClientCallState*>(timer->data);
    state->deadline_expired = true;
    state->transport_error = Status(StatusCode::kDeadlineExceeded, "deadline exceeded");
    if (state->session != nullptr) {
        nghttp2_session_terminate_session(state->session, NGHTTP2_NO_ERROR);
        QueueOutput(state);
        FlushPendingWrites(state);
    }
    CloseClient(state);
}

void OnConnect(uv_connect_t* req, int status) {
    auto* state = static_cast<ClientCallState*>(req->data);

    if (status < 0) {
        state->transport_error = Status(StatusCode::kUnavailable, "failed to connect to server");
        CloseClient(state);
        return;
    }

    nghttp2_session_callbacks* callbacks = nullptr;
    nghttp2_session_callbacks_new(&callbacks);
    nghttp2_session_callbacks_set_on_header_callback(callbacks, OnHeaderCallback);
    nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, OnDataChunkRecvCallback);
    nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, OnFrameRecvCallback);
    nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, OnStreamCloseCallback);

    if (nghttp2_session_client_new(&state->session, callbacks, state) != 0) {
        nghttp2_session_callbacks_del(callbacks);
        state->transport_error =
            Status(StatusCode::kInternal, "failed to create nghttp2 client session");
        CloseClient(state);
        return;
    }
    nghttp2_session_callbacks_del(callbacks);

    nghttp2_submit_settings(state->session, NGHTTP2_FLAG_NONE, nullptr, 0);

    std::string content_type = "application/grpc";
    std::string te = "trailers";
    std::string scheme = "http";
    std::string post = "POST";
    std::string encoding = "identity";

    std::vector<nghttp2_nv> headers;
    headers.push_back(core::MakeHeader(":method", post));
    headers.push_back(core::MakeHeader(":scheme", scheme));
    headers.push_back(core::MakeHeader(":path", state->method));
    headers.push_back(core::MakeHeader(":authority", state->authority));
    headers.push_back(core::MakeHeader("content-type", content_type));
    headers.push_back(core::MakeHeader("te", te));
    headers.push_back(core::MakeHeader("grpc-encoding", encoding));
    for (const auto& md : state->client_metadata) {
        headers.push_back(core::MakeHeader(md.first, md.second));
    }

    nghttp2_data_provider provider{};
    provider.source.ptr = state;
    provider.read_callback = RequestDataProvider;

    state->stream_id = nghttp2_submit_request(
        state->session, nullptr, headers.data(), headers.size(), &provider, state
    );
    if (state->stream_id < 0) {
        state->transport_error = Status(StatusCode::kInternal, "failed to submit HTTP/2 request");
        CloseClient(state);
        return;
    }

    QueueOutput(state);
    FlushPendingWrites(state);

    uv_read_start(reinterpret_cast<uv_stream_t*>(&state->tcp_handle), AllocBuffer, AfterRead);
}

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

class LiveClientCall : public std::enable_shared_from_this<LiveClientCall> {
  public:
    LiveClientCall(std::string target, std::string method, ClientContext* context)
        : target_(std::move(target)),
          method_(std::move(method)),
          context_(context),
          responses_(std::make_shared<internal::MessageQueue>()) {}

    ~LiveClientCall() { Close(); }

    Status Start() {
        AddressParts address;
        Status addr_status = ParseAddress(target_, &address);
        if (!addr_status.ok()) {
            status_ = addr_status;
            responses_->Close(status_);
            return status_;
        }

        fd_ = ::socket(AF_INET, SOCK_STREAM, 0);
        if (fd_ < 0) {
            status_ = Status(StatusCode::kUnavailable, "failed to create socket");
            responses_->Close(status_);
            return status_;
        }

        sockaddr_in socket_address{};
        socket_address.sin_family = AF_INET;
        socket_address.sin_port = htons(static_cast<std::uint16_t>(address.port));
        if (::inet_pton(AF_INET, address.host.c_str(), &socket_address.sin_addr) != 1) {
            status_ =
                Status(StatusCode::kInvalidArgument, "only IPv4 targets are supported for now");
            responses_->Close(status_);
            return status_;
        }
        if (::connect(fd_, reinterpret_cast<sockaddr*>(&socket_address), sizeof(socket_address)) !=
            0) {
            status_ = Status(StatusCode::kUnavailable, "failed to connect to server");
            responses_->Close(status_);
            return status_;
        }

        nghttp2_session_callbacks* callbacks = nullptr;
        nghttp2_session_callbacks_new(&callbacks);
        nghttp2_session_callbacks_set_on_header_callback(callbacks, OnHeader);
        nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, OnData);
        nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, OnStreamClose);
        if (nghttp2_session_client_new(&session_, callbacks, this) != 0) {
            nghttp2_session_callbacks_del(callbacks);
            status_ = Status(StatusCode::kInternal, "failed to create nghttp2 client session");
            responses_->Close(status_);
            return status_;
        }
        nghttp2_session_callbacks_del(callbacks);

        nghttp2_submit_settings(session_, NGHTTP2_FLAG_NONE, nullptr, 0);

        std::string content_type = "application/grpc";
        std::string te = "trailers";
        std::string scheme = "http";
        std::string post = "POST";
        std::string encoding = "identity";

        std::vector<nghttp2_nv> headers;
        headers.push_back(core::MakeHeader(":method", post));
        headers.push_back(core::MakeHeader(":scheme", scheme));
        headers.push_back(core::MakeHeader(":path", method_));
        headers.push_back(core::MakeHeader(":authority", target_));
        headers.push_back(core::MakeHeader("content-type", content_type));
        headers.push_back(core::MakeHeader("te", te));
        headers.push_back(core::MakeHeader("grpc-encoding", encoding));
        if (context_ != nullptr) {
            for (const auto& md : context_->metadata()) {
                headers.push_back(core::MakeHeader(md.first, md.second));
            }
        }

        nghttp2_data_provider provider{};
        provider.source.ptr = this;
        provider.read_callback = ReadRequestData;
        stream_id_ = nghttp2_submit_request(
            session_, nullptr, headers.data(), headers.size(), &provider, this
        );
        if (stream_id_ < 0) {
            status_ = Status(StatusCode::kInternal, "failed to submit HTTP/2 request");
            responses_->Close(status_);
            return status_;
        }

        {
            std::lock_guard<std::mutex> lock(session_mutex_);
            FlushLocked();
        }

        io_thread_ = std::thread([self = shared_from_this()]() { self->ReadLoop(); });
        return Status::OK();
    }

    std::shared_ptr<internal::MessageQueue> responses() const { return responses_; }

    bool Write(std::string_view message) {
        std::lock_guard<std::mutex> lock(session_mutex_);
        if (closed_ || writes_done_) {
            return false;
        }
        outgoing_.push_back(core::EncodeGrpcFrame(message));
        nghttp2_session_resume_data(session_, stream_id_);
        FlushLocked();
        return true;
    }

    bool WritesDone() {
        std::lock_guard<std::mutex> lock(session_mutex_);
        if (closed_ || writes_done_) {
            return false;
        }
        writes_done_ = true;
        nghttp2_session_resume_data(session_, stream_id_);
        FlushLocked();
        return true;
    }

    Status Finish(std::string* unary_response = nullptr) {
        WritesDone();
        if (unary_response != nullptr) {
            std::string response;
            if (responses_->Read(&response)) {
                *unary_response = std::move(response);
            }
        }
        Join();
        CopyMetadata();
        return status_;
    }

    void Close() {
        {
            std::lock_guard<std::mutex> lock(session_mutex_);
            if (!closed_) {
                closed_ = true;
                if (fd_ >= 0) {
                    ::shutdown(fd_, SHUT_RDWR);
                }
            }
        }
        Join();
        if (session_ != nullptr) {
            nghttp2_session_del(session_);
            session_ = nullptr;
        }
        if (fd_ >= 0) {
            ::close(fd_);
            fd_ = -1;
        }
    }

  private:
    static ssize_t
    ReadRequestData(nghttp2_session*, int32_t, uint8_t* buffer, size_t length, uint32_t* data_flags, nghttp2_data_source* source, void*) {
        auto* self = static_cast<LiveClientCall*>(source->ptr);
        if (self->current_outgoing_.empty() && !self->outgoing_.empty()) {
            self->current_outgoing_ = std::move(self->outgoing_.front());
            self->outgoing_.pop_front();
            self->current_outgoing_offset_ = 0;
        }
        if (self->current_outgoing_.empty()) {
            if (self->writes_done_) {
                *data_flags |= NGHTTP2_DATA_FLAG_EOF;
                return 0;
            }
            return NGHTTP2_ERR_DEFERRED;
        }
        const std::size_t remaining =
            self->current_outgoing_.size() - self->current_outgoing_offset_;
        const std::size_t to_copy = std::min(remaining, length);
        if (to_copy != 0) {
            std::memcpy(
                buffer, self->current_outgoing_.data() + self->current_outgoing_offset_, to_copy
            );
            self->current_outgoing_offset_ += to_copy;
        }
        if (self->current_outgoing_offset_ == self->current_outgoing_.size()) {
            self->current_outgoing_.clear();
            self->current_outgoing_offset_ = 0;
        }
        return static_cast<ssize_t>(to_copy);
    }

    static int OnHeader(
        nghttp2_session*, const nghttp2_frame* frame, const uint8_t* name, size_t namelen,
        const uint8_t* value, size_t valuelen, uint8_t, void* user_data
    ) {
        auto* self = static_cast<LiveClientCall*>(user_data);
        if (frame->hd.stream_id != self->stream_id_) {
            return 0;
        }
        const std::string_view hname(reinterpret_cast<const char*>(name), namelen);
        const std::string_view hvalue(reinterpret_cast<const char*>(value), valuelen);
        if (frame->headers.cat == NGHTTP2_HCAT_RESPONSE) {
            if (hname == ":status") {
                self->http_status_.assign(hvalue);
            } else {
                self->initial_metadata_.emplace_back(std::string(hname), std::string(hvalue));
            }
        } else if (frame->headers.cat == NGHTTP2_HCAT_HEADERS) {
            if (hname == "grpc-status") {
                self->grpc_status_ = std::atoi(std::string(hvalue).c_str());
            } else if (hname == "grpc-message") {
                self->grpc_message_.assign(hvalue);
            } else {
                self->trailing_metadata_.emplace_back(std::string(hname), std::string(hvalue));
            }
        }
        return 0;
    }

    static int OnData(
        nghttp2_session*, uint8_t, int32_t stream_id, const uint8_t* data, size_t len,
        void* user_data
    ) {
        auto* self = static_cast<LiveClientCall*>(user_data);
        if (stream_id != self->stream_id_) {
            return 0;
        }
        Status status = self->PushResponseFrames(data, len);
        if (!status.ok()) {
            self->status_ = status;
            self->responses_->Close(status);
        }
        return 0;
    }

    static int OnStreamClose(nghttp2_session*, int32_t stream_id, uint32_t, void* user_data) {
        auto* self = static_cast<LiveClientCall*>(user_data);
        if (stream_id != self->stream_id_) {
            return 0;
        }
        self->stream_closed_ = true;
        if (self->http_status_ != "200") {
            self->status_ = Status(
                StatusCode::kUnavailable, "server returned HTTP status " + self->http_status_
            );
        } else if (self->grpc_status_ < 0) {
            self->status_ =
                Status(StatusCode::kInternal, "server did not send grpc-status trailer");
        } else {
            const StatusCode grpc_code = core::StatusCodeFromInt(self->grpc_status_);
            self->status_ = grpc_code == StatusCode::kOk ? Status::OK()
                                                         : Status(grpc_code, self->grpc_message_);
        }
        self->responses_->Close(self->status_);
        return 0;
    }

    Status PushResponseFrames(const uint8_t* data, size_t len) {
        pending_response_frame_.append(reinterpret_cast<const char*>(data), len);
        for (;;) {
            if (pending_response_frame_.empty() || pending_response_frame_.size() < 5U) {
                return Status::OK();
            }
            if (static_cast<unsigned char>(pending_response_frame_[0]) != 0) {
                return Status(
                    StatusCode::kUnimplemented, "compressed grpc messages are not supported yet"
                );
            }
            const std::uint32_t size =
                (static_cast<std::uint32_t>(static_cast<unsigned char>(pending_response_frame_[1]))
                 << 24) |
                (static_cast<std::uint32_t>(static_cast<unsigned char>(pending_response_frame_[2]))
                 << 16) |
                (static_cast<std::uint32_t>(static_cast<unsigned char>(pending_response_frame_[3]))
                 << 8) |
                static_cast<std::uint32_t>(static_cast<unsigned char>(pending_response_frame_[4]));
            const std::size_t full_size = static_cast<std::size_t>(size) + 5U;
            if (pending_response_frame_.size() < full_size) {
                return Status::OK();
            }
            responses_->Push(pending_response_frame_.substr(5, size));
            pending_response_frame_.erase(0, full_size);
        }
    }

    void ReadLoop() {
        char buffer[4096];
        while (!stream_closed_) {
            const ssize_t nread = ::recv(fd_, buffer, sizeof(buffer), 0);
            if (nread <= 0) {
                break;
            }
            std::lock_guard<std::mutex> lock(session_mutex_);
            if (nghttp2_session_mem_recv(
                    session_, reinterpret_cast<const uint8_t*>(buffer), static_cast<size_t>(nread)
                ) < 0) {
                status_ = Status(StatusCode::kInternal, "nghttp2 receive error");
                responses_->Close(status_);
                break;
            }
            FlushLocked();
        }
        if (!stream_closed_) {
            status_ = Status(StatusCode::kUnavailable, "connection closed by server");
            responses_->Close(status_);
        }
    }

    void FlushLocked() {
        const uint8_t* data = nullptr;
        for (;;) {
            const ssize_t bytes = nghttp2_session_mem_send(session_, &data);
            if (bytes <= 0) {
                return;
            }
            std::string_view out(
                reinterpret_cast<const char*>(data), static_cast<std::size_t>(bytes)
            );
            while (!out.empty()) {
                const ssize_t sent = ::send(fd_, out.data(), out.size(), MSG_NOSIGNAL);
                if (sent <= 0) {
                    status_ = Status(StatusCode::kUnavailable, "write to server failed");
                    responses_->Close(status_);
                    return;
                }
                out.remove_prefix(static_cast<std::size_t>(sent));
            }
        }
    }

    void Join() {
        if (io_thread_.joinable()) {
            io_thread_.join();
        }
    }

    void CopyMetadata() {
        if (context_ == nullptr) {
            return;
        }
        context_->SetServerInitialMetadata(initial_metadata_);
        context_->SetServerTrailingMetadata(trailing_metadata_);
    }

    std::string target_;
    std::string method_;
    ClientContext* context_ = nullptr;
    int fd_ = -1;
    nghttp2_session* session_ = nullptr;
    int32_t stream_id_ = 0;
    std::mutex session_mutex_;
    std::thread io_thread_;
    std::deque<std::string> outgoing_;
    std::string current_outgoing_;
    std::size_t current_outgoing_offset_ = 0;
    std::string pending_response_frame_;
    std::shared_ptr<internal::MessageQueue> responses_;
    std::vector<std::pair<std::string, std::string>> initial_metadata_;
    std::vector<std::pair<std::string, std::string>> trailing_metadata_;
    std::string http_status_;
    int grpc_status_ = -1;
    std::string grpc_message_;
    Status status_;
    bool writes_done_ = false;
    bool stream_closed_ = false;
    bool closed_ = false;
};

Status PerformStreamingCall(
    const std::string& target, const std::string& method,
    const std::vector<std::string>& request_messages, ClientContext* context,
    std::vector<std::string>* response_messages
) {
    AddressParts address;
    Status addr_status = ParseAddress(target, &address);
    if (!addr_status.ok()) {
        return addr_status;
    }

    uv_loop_t loop;
    if (uv_loop_init(&loop) != 0) {
        return Status(StatusCode::kInternal, "failed to initialize libuv loop");
    }

    ClientCallState state;
    state.loop = &loop;
    state.method = method;
    state.authority = target;
    state.request_frame = core::EncodeGrpcFrames(request_messages);
    if (context != nullptr) {
        for (const auto& md : context->metadata()) {
            state.client_metadata.push_back(md);
        }
    }

    if (uv_tcp_init(&loop, &state.tcp_handle) != 0) {
        uv_loop_close(&loop);
        return Status(StatusCode::kInternal, "failed to initialize TCP handle");
    }
    state.tcp_handle.data = &state;

    if (context != nullptr && context->deadline() != std::chrono::system_clock::time_point{}) {
        const auto now = std::chrono::system_clock::now();
        const auto timeout =
            std::chrono::duration_cast<std::chrono::milliseconds>(context->deadline() - now);
        if (timeout.count() <= 0) {
            uv_close(reinterpret_cast<uv_handle_t*>(&state.tcp_handle), OnHandleClosed);
            uv_run(&loop, UV_RUN_DEFAULT);
            uv_loop_close(&loop);
            return Status(StatusCode::kDeadlineExceeded, "deadline exceeded");
        }
        if (uv_timer_init(&loop, &state.deadline_timer) == 0) {
            state.deadline_timer.data = &state;
            state.has_deadline = true;
            uv_timer_start(
                &state.deadline_timer, OnDeadlineExpired, static_cast<uint64_t>(timeout.count()), 0
            );
        }
    }

    sockaddr_in socket_address{};
    if (uv_ip4_addr(address.host.c_str(), address.port, &socket_address) != 0) {
        CloseClient(&state);
        uv_run(&loop, UV_RUN_DEFAULT);
        uv_loop_close(&loop);
        return Status(StatusCode::kInvalidArgument, "only IPv4 targets are supported for now");
    }

    state.connect_req.data = &state;
    if (uv_tcp_connect(
            &state.connect_req, &state.tcp_handle,
            reinterpret_cast<const sockaddr*>(&socket_address), OnConnect
        ) != 0) {
        CloseClient(&state);
        uv_run(&loop, UV_RUN_DEFAULT);
        uv_loop_close(&loop);
        return Status(StatusCode::kUnavailable, "failed to initiate connection");
    }

    uv_run(&loop, UV_RUN_DEFAULT);

    if (state.session != nullptr) {
        nghttp2_session_del(state.session);
        state.session = nullptr;
    }
    uv_loop_close(&loop);

    if (!state.transport_error.ok()) {
        return state.transport_error;
    }

    if (state.http_status != "200") {
        return Status(StatusCode::kUnavailable, "server returned HTTP status " + state.http_status);
    }

    if (context != nullptr) {
        context->SetServerInitialMetadata(std::move(state.initial_metadata));
        context->SetServerTrailingMetadata(std::move(state.trailing_metadata));
    }

    if (state.grpc_status < 0) {
        return Status(StatusCode::kInternal, "server did not send grpc-status trailer");
    }

    const StatusCode grpc_code = core::StatusCodeFromInt(state.grpc_status);
    if (grpc_code != StatusCode::kOk) {
        return Status(grpc_code, state.grpc_message);
    }

    return core::DecodeGrpcFrames(state.response_body, response_messages);
}

}  // namespace

Status Channel::CallUnary(
    const std::string& method, const std::string& request_bytes, ClientContext* context,
    std::string* response_bytes
) {
    AddressParts address;
    Status addr_status = ParseAddress(target_, &address);
    if (!addr_status.ok()) {
        return addr_status;
    }

    uv_loop_t loop;
    if (uv_loop_init(&loop) != 0) {
        return Status(StatusCode::kInternal, "failed to initialize libuv loop");
    }

    ClientCallState state;
    state.loop = &loop;
    state.method = method;
    state.authority = target_;
    state.request_frame = core::EncodeGrpcFrame(request_bytes);
    if (context != nullptr) {
        for (const auto& md : context->metadata()) {
            state.client_metadata.push_back(md);
        }
    }

    if (uv_tcp_init(&loop, &state.tcp_handle) != 0) {
        uv_loop_close(&loop);
        return Status(StatusCode::kInternal, "failed to initialize TCP handle");
    }
    state.tcp_handle.data = &state;

    // Set up deadline timer if configured.
    if (context != nullptr && context->deadline() != std::chrono::system_clock::time_point{}) {
        const auto now = std::chrono::system_clock::now();
        const auto timeout =
            std::chrono::duration_cast<std::chrono::milliseconds>(context->deadline() - now);
        if (timeout.count() <= 0) {
            uv_close(reinterpret_cast<uv_handle_t*>(&state.tcp_handle), OnHandleClosed);
            uv_run(&loop, UV_RUN_DEFAULT);
            uv_loop_close(&loop);
            return Status(StatusCode::kDeadlineExceeded, "deadline exceeded");
        }
        if (uv_timer_init(&loop, &state.deadline_timer) == 0) {
            state.deadline_timer.data = &state;
            state.has_deadline = true;
            uv_timer_start(
                &state.deadline_timer, OnDeadlineExpired, static_cast<uint64_t>(timeout.count()), 0
            );
        }
    }

    sockaddr_in socket_address{};
    if (uv_ip4_addr(address.host.c_str(), address.port, &socket_address) != 0) {
        CloseClient(&state);
        uv_run(&loop, UV_RUN_DEFAULT);
        uv_loop_close(&loop);
        return Status(StatusCode::kInvalidArgument, "only IPv4 targets are supported for now");
    }

    state.connect_req.data = &state;
    if (uv_tcp_connect(
            &state.connect_req, &state.tcp_handle,
            reinterpret_cast<const sockaddr*>(&socket_address), OnConnect
        ) != 0) {
        CloseClient(&state);
        uv_run(&loop, UV_RUN_DEFAULT);
        uv_loop_close(&loop);
        return Status(StatusCode::kUnavailable, "failed to initiate connection");
    }

    uv_run(&loop, UV_RUN_DEFAULT);

    if (state.session != nullptr) {
        nghttp2_session_del(state.session);
        state.session = nullptr;
    }
    uv_loop_close(&loop);

    // Check transport-level errors first.
    if (!state.transport_error.ok()) {
        return state.transport_error;
    }

    // Check HTTP status.
    if (state.http_status != "200") {
        return Status(StatusCode::kUnavailable, "server returned HTTP status " + state.http_status);
    }

    // Populate context with server metadata.
    if (context != nullptr) {
        context->SetServerInitialMetadata(std::move(state.initial_metadata));
        context->SetServerTrailingMetadata(std::move(state.trailing_metadata));
    }

    // Check gRPC status from trailers.
    if (state.grpc_status < 0) {
        return Status(StatusCode::kInternal, "server did not send grpc-status trailer");
    }

    const StatusCode grpc_code = core::StatusCodeFromInt(state.grpc_status);
    if (grpc_code != StatusCode::kOk) {
        return Status(grpc_code, state.grpc_message);
    }

    // Decode the gRPC response frame.
    return core::DecodeGrpcFrame(state.response_body, response_bytes);
}

Status Channel::CallServerStreaming(
    const std::string& method, const std::string& request_bytes, ClientContext* context,
    std::vector<std::string>* response_messages
) {
    return PerformStreamingCall(target_, method, {request_bytes}, context, response_messages);
}

std::unique_ptr<ClientReader> Channel::StartServerStreaming(
    const std::string& method, const std::string& request_bytes, ClientContext* context
) {
    auto call = std::make_shared<LiveClientCall>(target_, method, context);
    Status status = call->Start();
    if (!status.ok()) {
        return std::make_unique<ClientReader>(std::move(status), std::vector<std::string>{});
    }
    call->Write(request_bytes);
    call->WritesDone();
    return std::make_unique<ClientReader>(call->responses(), [call]() mutable {
        return call->Finish();
    });
}

std::unique_ptr<ClientWriter> Channel::StartClientStreaming(
    const std::string& method, ClientContext* context
) {
    auto call = std::make_shared<LiveClientCall>(target_, method, context);
    Status status = call->Start();
    if (!status.ok()) {
        return std::make_unique<ClientWriter>(
            [status](const std::vector<std::string>&, std::string*) { return status; }
        );
    }
    return std::make_unique<ClientWriter>(
        [call](std::string_view message) { return call->Write(message); },
        [call]() { return call->WritesDone(); },
        [call](std::string* response) mutable { return call->Finish(response); }
    );
}

std::unique_ptr<ClientReaderWriter> Channel::StartBidiStreaming(
    const std::string& method, ClientContext* context
) {
    auto call = std::make_shared<LiveClientCall>(target_, method, context);
    Status status = call->Start();
    if (!status.ok()) {
        return std::make_unique<ClientReaderWriter>(
            [status](const std::vector<std::string>&, std::vector<std::string>*) { return status; }
        );
    }
    return std::make_unique<ClientReaderWriter>(
        [call](std::string_view message) { return call->Write(message); },
        [call]() { return call->WritesDone(); }, call->responses(),
        [call]() mutable { return call->Finish(); }
    );
}

Status Channel::CallClientStreaming(
    const std::string& method, const std::vector<std::string>& request_messages,
    ClientContext* context, std::string* response_bytes
) {
    std::vector<std::string> responses;
    Status status = PerformStreamingCall(target_, method, request_messages, context, &responses);
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
    return PerformStreamingCall(target_, method, request_messages, context, response_messages);
}

}  // namespace grpc_lite
