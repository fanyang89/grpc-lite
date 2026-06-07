#include "grpc_lite/server.h"

#include <uv.h>

#include <algorithm>
#include <atomic>
#include <csignal>
#include <cstdint>
#include <cstring>
#include <deque>
#include <functional>
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
#include "grpc_lite/service.h"

namespace grpc_lite {

struct StreamState {
    std::string method;
    std::string path;
    std::string content_type;
    std::string request_body;
    std::string pending_request_frame;
    std::string response_frame;
    std::deque<std::string> outgoing_frames;
    std::string current_outgoing_frame;
    std::vector<std::pair<std::string, std::string>> initial_metadata;
    std::vector<std::pair<std::string, std::string>> trailing_metadata;
    Status status;
    std::size_t response_offset = 0;
    std::size_t current_outgoing_offset = 0;
    std::shared_ptr<internal::MessageQueue> request_messages;
    RpcType rpc_type = RpcType::kUnary;
    bool response_submitted = false;
    bool trailers_submitted = false;
    bool handler_started = false;
    bool request_closed = false;
    bool live_response = false;
    bool response_done = false;
};

struct PendingWrite {
    uv_write_t request;
    uv_buf_t buffer;
    std::string data;
};

using core::DecodeGrpcFrame;
using core::DecodeGrpcFrames;
using core::EncodeGrpcFrame;
using core::EncodeGrpcFrames;
using core::MakeHeader;
using core::StatusCodeText;

bool StartsWith(std::string_view value, std::string_view prefix) {
    return value.size() >= prefix.size() && value.substr(0, prefix.size()) == prefix;
}

void IgnoreSigpipe() {
#ifdef SIGPIPE
    static std::once_flag once;
    std::call_once(once, []() { std::signal(SIGPIPE, SIG_IGN); });
#endif
}

struct AddressParts {
    std::string host;
    int port = 0;
};

Status ParseAddress(std::string_view address, AddressParts* out) {
    const std::size_t separator = address.rfind(':');
    if (separator == std::string_view::npos) {
        return Status(StatusCode::kInvalidArgument, "listening address must be in host:port form");
    }

    out->host = std::string(address.substr(0, separator));
    if (out->host.empty()) {
        out->host = "0.0.0.0";
    }

    const std::string port_text(address.substr(separator + 1));
    try {
        out->port = std::stoi(port_text);
    } catch (...) {
        return Status(StatusCode::kInvalidArgument, "listening port must be numeric");
    }

    if (out->port <= 0 || out->port > 65535) {
        return Status(StatusCode::kInvalidArgument, "listening port must be in the range 1-65535");
    }
    return Status::OK();
}

struct Http2Connection {
    uv_tcp_t handle{};
    ServerImpl* owner = nullptr;
    nghttp2_session* session = nullptr;
    std::unordered_map<int32_t, std::shared_ptr<StreamState>> streams;
    std::vector<std::string> pending_writes;
    bool write_in_flight = false;
    bool closed = false;
};

class ServerImpl {
  public:
    explicit ServerImpl(Server* server) : server(server) {}

    Status Start(const Server::Listener& listener);
    void Wait();
    void Shutdown();
    Status BuildUnaryResponse(StreamState* stream);
    Service* FindService(std::string_view path, std::string* method_name) const;

    Server* server;
    uv_loop_t loop{};
    uv_tcp_t listener_handle{};
    bool loop_initialized = false;
    bool listener_initialized = false;
    bool shutdown_signal_initialized = false;
    uv_async_t shutdown_signal{};
    uv_async_t command_signal{};
    bool command_signal_initialized = false;
    std::atomic<bool> shutting_down{false};
    std::vector<Http2Connection*> connections;
    std::mutex commands_mutex;
    std::vector<std::function<void()>> commands;
};

void FlushPendingWrites(Http2Connection* connection);
void CloseConnection(Http2Connection* connection);
void OnLoopShutdown(uv_async_t* handle);
void OnCommand(uv_async_t* handle);
int SubmitGrpcTrailers(nghttp2_session* session, int32_t stream_id, StreamState* stream);
void MaybeHandleRequest(Http2Connection* connection, int32_t stream_id);

void PostCommand(ServerImpl* impl, std::function<void()> command) {
    {
        std::lock_guard<std::mutex> lock(impl->commands_mutex);
        impl->commands.push_back(std::move(command));
    }
    if (impl->command_signal_initialized) {
        uv_async_send(&impl->command_signal);
    }
}

void FreeWrite(uv_write_t* request) {
    auto* pending = static_cast<PendingWrite*>(request->data);
    delete pending;
}

void AfterWrite(uv_write_t* request, int status) {
    auto* pending = static_cast<PendingWrite*>(request->data);
    auto* connection = static_cast<Http2Connection*>(request->handle->data);
    connection->write_in_flight = false;
    FreeWrite(request);

    if (status < 0) {
        CloseConnection(connection);
        return;
    }

    if (!connection->pending_writes.empty()) {
        connection->pending_writes.erase(connection->pending_writes.begin());
    }
    FlushPendingWrites(connection);
}

void QueueOutput(Http2Connection* connection) {
    const uint8_t* data = nullptr;
    for (;;) {
        const ssize_t bytes = nghttp2_session_mem_send(connection->session, &data);
        if (bytes < 0) {
            CloseConnection(connection);
            return;
        }
        if (bytes == 0) {
            return;
        }
        connection->pending_writes.emplace_back(
            reinterpret_cast<const char*>(data), static_cast<std::size_t>(bytes)
        );
    }
}

Status PushCompleteFrames(StreamState* stream, const uint8_t* data, size_t len) {
    stream->pending_request_frame.append(reinterpret_cast<const char*>(data), len);
    for (;;) {
        if (stream->pending_request_frame.empty()) {
            return Status::OK();
        }
        if (stream->pending_request_frame.size() < 5U) {
            return Status::OK();
        }
        if (static_cast<unsigned char>(stream->pending_request_frame[0]) != 0) {
            return Status(
                StatusCode::kUnimplemented, "compressed grpc messages are not supported yet"
            );
        }
        const std::string& frame = stream->pending_request_frame;
        const std::uint32_t size =
            (static_cast<std::uint32_t>(static_cast<unsigned char>(frame[1])) << 24) |
            (static_cast<std::uint32_t>(static_cast<unsigned char>(frame[2])) << 16) |
            (static_cast<std::uint32_t>(static_cast<unsigned char>(frame[3])) << 8) |
            static_cast<std::uint32_t>(static_cast<unsigned char>(frame[4]));
        const std::size_t full_size = static_cast<std::size_t>(size) + 5U;
        if (frame.size() < full_size) {
            return Status::OK();
        }
        if (stream->request_messages != nullptr) {
            stream->request_messages->Push(frame.substr(5, size));
        }
        stream->pending_request_frame.erase(0, full_size);
    }
}

ssize_t StreamingReadCallback(
    nghttp2_session* session, int32_t stream_id, uint8_t* buffer, size_t length,
    uint32_t* data_flags, nghttp2_data_source* source, void* user_data
) {
    (void)session;
    (void)stream_id;
    (void)user_data;
    auto* stream = static_cast<StreamState*>(source->ptr);

    if (stream->current_outgoing_frame.empty() && !stream->outgoing_frames.empty()) {
        stream->current_outgoing_frame = std::move(stream->outgoing_frames.front());
        stream->outgoing_frames.pop_front();
        stream->current_outgoing_offset = 0;
    }

    if (stream->current_outgoing_frame.empty()) {
        if (stream->response_done) {
            *data_flags |= NGHTTP2_DATA_FLAG_EOF | NGHTTP2_DATA_FLAG_NO_END_STREAM;
            if (SubmitGrpcTrailers(session, stream_id, stream) != 0) {
                return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
            }
            return 0;
        }
        return NGHTTP2_ERR_DEFERRED;
    }

    const std::size_t remaining =
        stream->current_outgoing_frame.size() - stream->current_outgoing_offset;
    const std::size_t to_copy = std::min(remaining, length);
    if (to_copy != 0) {
        std::memcpy(
            buffer, stream->current_outgoing_frame.data() + stream->current_outgoing_offset, to_copy
        );
        stream->current_outgoing_offset += to_copy;
    }
    if (stream->current_outgoing_offset == stream->current_outgoing_frame.size()) {
        stream->current_outgoing_frame.clear();
        stream->current_outgoing_offset = 0;
    }
    return static_cast<ssize_t>(to_copy);
}

int SubmitGrpcTrailers(nghttp2_session* session, int32_t stream_id, StreamState* stream) {
    if (stream->trailers_submitted) {
        return 0;
    }

    std::vector<nghttp2_nv> trailers;
    trailers.reserve(stream->trailing_metadata.size() + 2);
    trailers.push_back(MakeHeader("grpc-status", StatusCodeText(stream->status.code())));
    if (!stream->status.message().empty()) {
        trailers.push_back(MakeHeader("grpc-message", stream->status.message()));
    }
    for (const auto& metadata : stream->trailing_metadata) {
        trailers.push_back(MakeHeader(metadata.first, metadata.second));
    }

    const int rc = nghttp2_submit_trailer(session, stream_id, trailers.data(), trailers.size());
    if (rc == 0) {
        stream->trailers_submitted = true;
    }
    return rc;
}

void FlushPendingWrites(Http2Connection* connection) {
    if (connection->closed || connection->write_in_flight || connection->pending_writes.empty()) {
        return;
    }

    auto* pending = new PendingWrite();
    pending->data = connection->pending_writes.front();
    pending->buffer = uv_buf_init(pending->data.data(), pending->data.size());
    pending->request.data = pending;
    connection->write_in_flight = true;

    const int rc = uv_write(
        &pending->request, reinterpret_cast<uv_stream_t*>(&connection->handle), &pending->buffer, 1,
        AfterWrite
    );
    if (rc != 0) {
        connection->write_in_flight = false;
        FreeWrite(&pending->request);
        CloseConnection(connection);
    }
}

void EnsureStreamingResponse(
    Http2Connection* connection, int32_t stream_id, const std::shared_ptr<StreamState>& stream
) {
    if (connection->closed || stream->response_submitted) {
        if (stream->response_submitted) {
            nghttp2_session_resume_data(connection->session, stream_id);
        }
        return;
    }

    std::vector<nghttp2_nv> headers;
    headers.push_back(MakeHeader(":status", "200"));
    headers.push_back(MakeHeader("content-type", "application/grpc"));
    headers.push_back(MakeHeader("grpc-encoding", "identity"));
    for (const auto& metadata : stream->initial_metadata) {
        headers.push_back(MakeHeader(metadata.first, metadata.second));
    }

    nghttp2_data_provider provider{};
    provider.source.ptr = stream.get();
    provider.read_callback = StreamingReadCallback;
    if (nghttp2_submit_response(
            connection->session, stream_id, headers.data(), headers.size(), &provider
        ) != 0) {
        CloseConnection(connection);
        return;
    }
    stream->response_submitted = true;
}

void QueueStreamingMessage(
    Http2Connection* connection, int32_t stream_id, const std::shared_ptr<StreamState>& stream,
    std::string message
) {
    if (connection->closed || stream->response_done) {
        return;
    }
    stream->outgoing_frames.push_back(EncodeGrpcFrame(message));
    EnsureStreamingResponse(connection, stream_id, stream);
    QueueOutput(connection);
    FlushPendingWrites(connection);
}

void FinishStreamingResponse(
    Http2Connection* connection, int32_t stream_id, const std::shared_ptr<StreamState>& stream
) {
    if (connection->closed || stream->response_done) {
        return;
    }
    stream->response_done = true;
    EnsureStreamingResponse(connection, stream_id, stream);
    nghttp2_session_resume_data(connection->session, stream_id);
    QueueOutput(connection);
    FlushPendingWrites(connection);
}

void SubmitGrpcResponse(Http2Connection* connection, int32_t stream_id, StreamState* stream) {
    std::vector<nghttp2_nv> headers;
    headers.push_back(MakeHeader(":status", "200"));
    headers.push_back(MakeHeader("content-type", "application/grpc"));
    headers.push_back(MakeHeader("grpc-encoding", "identity"));
    for (const auto& metadata : stream->initial_metadata) {
        headers.push_back(MakeHeader(metadata.first, metadata.second));
    }

    nghttp2_data_provider provider{};
    provider.source.ptr = stream;
    provider.read_callback = [](nghttp2_session* session, int32_t current_stream_id,
                                uint8_t* buffer, size_t length, uint32_t* data_flags,
                                nghttp2_data_source* source, void* user_data) -> ssize_t {
        (void)user_data;
        auto* state = static_cast<StreamState*>(source->ptr);

        const std::size_t remaining = state->response_frame.size() - state->response_offset;
        const std::size_t to_copy = std::min(remaining, length);
        if (to_copy != 0) {
            std::memcpy(buffer, state->response_frame.data() + state->response_offset, to_copy);
            state->response_offset += to_copy;
        }

        if (state->response_offset == state->response_frame.size()) {
            *data_flags |= NGHTTP2_DATA_FLAG_EOF | NGHTTP2_DATA_FLAG_NO_END_STREAM;
            if (state->response_frame.empty() &&
                SubmitGrpcTrailers(session, current_stream_id, state) != 0) {
                return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
            }
        }

        return static_cast<ssize_t>(to_copy);
    };

    if (nghttp2_submit_response(
            connection->session, stream_id, headers.data(), headers.size(), &provider
        ) != 0) {
        CloseConnection(connection);
        return;
    }

    stream->response_submitted = true;
    QueueOutput(connection);
    FlushPendingWrites(connection);
}

int OnFrameSend(nghttp2_session* session, const nghttp2_frame* frame, void* user_data) {
    auto* connection = static_cast<Http2Connection*>(user_data);
    if (frame->hd.type != NGHTTP2_DATA) {
        return 0;
    }

    auto it = connection->streams.find(frame->hd.stream_id);
    if (it == connection->streams.end()) {
        return 0;
    }

    StreamState* stream = it->second.get();
    if (stream->response_offset == stream->response_frame.size() &&
        !stream->response_frame.empty() &&
        SubmitGrpcTrailers(session, frame->hd.stream_id, stream) != 0) {
        return NGHTTP2_ERR_CALLBACK_FAILURE;
    }
    return 0;
}

Status ServerImpl::BuildUnaryResponse(StreamState* stream) {
    if (stream->method != "POST") {
        return Status(StatusCode::kUnimplemented, "only POST grpc requests are supported");
    }
    if (!StartsWith(stream->content_type, "application/grpc")) {
        return Status(
            StatusCode::kInvalidArgument, "content-type must start with application/grpc"
        );
    }

    std::string method_name;
    Service* service = server->FindService(stream->path, &method_name);
    if (service == nullptr) {
        return Status(StatusCode::kUnimplemented, "requested grpc method is not registered");
    }

    std::vector<std::string> request_payloads;
    Status decode_status = DecodeGrpcFrames(stream->request_body, &request_payloads);
    if (!decode_status.ok()) {
        return decode_status;
    }

    ServerContext context;
    std::vector<std::string> response_payloads;
    Status status;
    switch (service->method_type(method_name)) {
        case RpcType::kUnary: {
            if (request_payloads.size() != 1U) {
                return Status(
                    StatusCode::kInvalidArgument,
                    "grpc request body does not contain exactly one unary message"
                );
            }
            std::string response_payload;
            status = service->HandleUnary(
                method_name, request_payloads.front(), &context, &response_payload
            );
            if (status.ok()) {
                response_payloads.push_back(std::move(response_payload));
            }
            break;
        }
        case RpcType::kServerStreaming: {
            if (request_payloads.size() != 1U) {
                return Status(
                    StatusCode::kInvalidArgument,
                    "server streaming request must contain exactly one message"
                );
            }
            ServerWriter writer(&response_payloads);
            status = service->HandleServerStreaming(
                method_name, request_payloads.front(), &context, &writer
            );
            break;
        }
        case RpcType::kClientStreaming: {
            ServerReader reader(std::move(request_payloads));
            std::string response_payload;
            status =
                service->HandleClientStreaming(method_name, &reader, &context, &response_payload);
            if (status.ok()) {
                response_payloads.push_back(std::move(response_payload));
            }
            break;
        }
        case RpcType::kBidiStreaming: {
            ServerReaderWriter rw(std::move(request_payloads), &response_payloads);
            status = service->HandleBidiStreaming(method_name, &rw, &context);
            break;
        }
    }

    stream->initial_metadata = context.initial_metadata();
    stream->trailing_metadata = context.trailing_metadata();
    if (status.ok()) {
        stream->response_frame = EncodeGrpcFrames(response_payloads);
    } else {
        stream->response_frame.clear();
    }
    return status;
}

Service* ServerImpl::FindService(std::string_view path, std::string* method_name) const {
    return server->FindService(path, method_name);
}

void StartLiveStreamingHandler(
    Http2Connection* connection, int32_t stream_id, const std::shared_ptr<StreamState>& stream
) {
    if (stream->handler_started) {
        return;
    }
    stream->handler_started = true;
    stream->live_response = true;

    std::string method_name;
    Service* service = connection->owner->FindService(stream->path, &method_name);
    if (service == nullptr) {
        stream->status =
            Status(StatusCode::kUnimplemented, "requested grpc method is not registered");
        stream->request_messages->Close(stream->status);
        FinishStreamingResponse(connection, stream_id, stream);
        return;
    }

    const auto write_message = [connection, stream_id, stream](std::string_view message) {
        const std::string copy(message);
        PostCommand(connection->owner, [connection, stream_id, stream, copy]() {
            QueueStreamingMessage(connection, stream_id, stream, copy);
        });
        return true;
    };

    std::thread([connection, stream_id, stream, service, method_name, write_message]() {
        ServerContext context;
        Status status;
        if (stream->rpc_type == RpcType::kServerStreaming) {
            std::string request;
            if (!stream->request_messages->Read(&request)) {
                status =
                    Status(StatusCode::kInvalidArgument, "server streaming request is missing");
            } else {
                std::string extra_request;
                if (stream->request_messages->Read(&extra_request)) {
                    status = Status(
                        StatusCode::kInvalidArgument,
                        "server streaming request must contain exactly one message"
                    );
                } else if (!stream->request_messages->status().ok()) {
                    status = stream->request_messages->status();
                } else {
                    ServerWriter writer([&context, connection, stream_id,
                                         stream](std::string_view message) {
                        const std::string copy(message);
                        const auto initial_metadata = context.initial_metadata();
                        PostCommand(
                            connection->owner,
                            [connection, stream_id, stream, copy, initial_metadata]() {
                                if (!stream->response_submitted) {
                                    stream->initial_metadata = initial_metadata;
                                }
                                QueueStreamingMessage(connection, stream_id, stream, copy);
                            }
                        );
                        return true;
                    });
                    status =
                        service->HandleServerStreaming(method_name, request, &context, &writer);
                }
            }
        } else if (stream->rpc_type == RpcType::kClientStreaming) {
            ServerReader reader(stream->request_messages);
            std::string response;
            status = service->HandleClientStreaming(method_name, &reader, &context, &response);
            if (status.ok() && !stream->request_messages->status().ok()) {
                status = stream->request_messages->status();
            }
            if (status.ok()) {
                const auto initial_metadata = context.initial_metadata();
                PostCommand(
                    connection->owner,
                    [connection, stream_id, stream, response, initial_metadata]() {
                        if (!stream->response_submitted) {
                            stream->initial_metadata = initial_metadata;
                        }
                        QueueStreamingMessage(connection, stream_id, stream, response);
                    }
                );
            }
        } else {
            ServerReaderWriter rw(
                stream->request_messages,
                [&context, connection, stream_id, stream](std::string_view message) {
                    const std::string copy(message);
                    const auto initial_metadata = context.initial_metadata();
                    PostCommand(
                        connection->owner,
                        [connection, stream_id, stream, copy, initial_metadata]() {
                            if (!stream->response_submitted) {
                                stream->initial_metadata = initial_metadata;
                            }
                            QueueStreamingMessage(connection, stream_id, stream, copy);
                        }
                    );
                    return true;
                }
            );
            status = service->HandleBidiStreaming(method_name, &rw, &context);
            if (status.ok() && !stream->request_messages->status().ok()) {
                status = stream->request_messages->status();
            }
        }

        auto trailing_metadata = context.trailing_metadata();
        auto initial_metadata = context.initial_metadata();
        PostCommand(
            connection->owner,
            [connection, stream_id, stream, status, trailing_metadata, initial_metadata]() {
                if (!stream->response_submitted) {
                    stream->initial_metadata = initial_metadata;
                }
                stream->trailing_metadata = trailing_metadata;
                stream->status = status;
                FinishStreamingResponse(connection, stream_id, stream);
            }
        );
    }).detach();
}

Status ResolveRpcType(Http2Connection* connection, const std::shared_ptr<StreamState>& stream) {
    if (stream->method != "POST") {
        return Status(StatusCode::kUnimplemented, "only POST grpc requests are supported");
    }
    if (!StartsWith(stream->content_type, "application/grpc")) {
        return Status(
            StatusCode::kInvalidArgument, "content-type must start with application/grpc"
        );
    }

    std::string method_name;
    Service* service = connection->owner->FindService(stream->path, &method_name);
    if (service == nullptr) {
        return Status(StatusCode::kUnimplemented, "requested grpc method is not registered");
    }
    stream->rpc_type = service->method_type(method_name);
    return Status::OK();
}

void MaybeStartLiveStreaming(
    Http2Connection* connection, int32_t stream_id, const std::shared_ptr<StreamState>& stream,
    bool request_complete
) {
    if (stream->handler_started) {
        if (request_complete && !stream->request_closed) {
            stream->request_closed = true;
            if (!stream->pending_request_frame.empty()) {
                stream->request_messages->Close(Status(
                    StatusCode::kInvalidArgument, "grpc request body contains a truncated message"
                ));
            } else {
                stream->request_messages->Close();
            }
        }
        return;
    }

    Status status = ResolveRpcType(connection, stream);
    if (!status.ok()) {
        stream->status = status;
        FinishStreamingResponse(connection, stream_id, stream);
        return;
    }
    if (stream->rpc_type == RpcType::kUnary) {
        if (request_complete) {
            MaybeHandleRequest(connection, stream_id);
        }
        return;
    }

    if (stream->rpc_type == RpcType::kClientStreaming ||
        stream->rpc_type == RpcType::kBidiStreaming) {
        StartLiveStreamingHandler(connection, stream_id, stream);
    }

    if (request_complete) {
        if (!stream->request_body.empty()) {
            Status parse_status = PushCompleteFrames(
                stream.get(), reinterpret_cast<const uint8_t*>(stream->request_body.data()),
                stream->request_body.size()
            );
            if (!parse_status.ok()) {
                stream->request_messages->Close(parse_status);
            }
        }
        if (stream->rpc_type == RpcType::kServerStreaming) {
            StartLiveStreamingHandler(connection, stream_id, stream);
        }
        stream->request_closed = true;
        if (!stream->pending_request_frame.empty()) {
            stream->request_messages->Close(Status(
                StatusCode::kInvalidArgument, "grpc request body contains a truncated message"
            ));
        } else {
            stream->request_messages->Close();
        }
    }
}

void MaybeHandleRequest(Http2Connection* connection, int32_t stream_id) {
    auto it = connection->streams.find(stream_id);
    if (it == connection->streams.end() || it->second->response_submitted) {
        return;
    }

    StreamState* stream = it->second.get();
    stream->status = connection->owner->BuildUnaryResponse(stream);
    SubmitGrpcResponse(connection, stream_id, stream);
}

int OnBeginHeaders(nghttp2_session* session, const nghttp2_frame* frame, void* user_data) {
    (void)session;
    auto* connection = static_cast<Http2Connection*>(user_data);
    if (frame->hd.type == NGHTTP2_HEADERS && frame->headers.cat == NGHTTP2_HCAT_REQUEST) {
        auto stream = std::make_shared<StreamState>();
        stream->request_messages = std::make_shared<internal::MessageQueue>();
        connection->streams[frame->hd.stream_id] = std::move(stream);
    }
    return 0;
}

int OnHeader(
    nghttp2_session* session, const nghttp2_frame* frame, const uint8_t* name, size_t namelen,
    const uint8_t* value, size_t valuelen, uint8_t flags, void* user_data
) {
    (void)session;
    (void)flags;
    auto* connection = static_cast<Http2Connection*>(user_data);
    if (frame->hd.type != NGHTTP2_HEADERS || frame->headers.cat != NGHTTP2_HCAT_REQUEST) {
        return 0;
    }

    auto it = connection->streams.find(frame->hd.stream_id);
    if (it == connection->streams.end()) {
        return 0;
    }

    const std::string_view header_name(reinterpret_cast<const char*>(name), namelen);
    const std::string_view header_value(reinterpret_cast<const char*>(value), valuelen);
    if (header_name == ":method") {
        it->second->method.assign(header_value);
    } else if (header_name == ":path") {
        it->second->path.assign(header_value);
    } else if (header_name == "content-type") {
        it->second->content_type.assign(header_value);
    }
    return 0;
}

int OnDataChunkRecv(
    nghttp2_session* session, uint8_t flags, int32_t stream_id, const uint8_t* data, size_t len,
    void* user_data
) {
    (void)session;
    (void)flags;
    auto* connection = static_cast<Http2Connection*>(user_data);
    auto it = connection->streams.find(stream_id);
    if (it != connection->streams.end()) {
        it->second->request_body.append(reinterpret_cast<const char*>(data), len);
        if (it->second->handler_started) {
            Status status = PushCompleteFrames(it->second.get(), data, len);
            if (!status.ok()) {
                it->second->status = status;
                it->second->request_messages->Close(status);
            }
        }
    }
    return 0;
}

int OnFrameRecv(nghttp2_session* session, const nghttp2_frame* frame, void* user_data) {
    (void)session;
    auto* connection = static_cast<Http2Connection*>(user_data);

    if (frame->hd.type == NGHTTP2_HEADERS && frame->headers.cat == NGHTTP2_HCAT_REQUEST &&
        (frame->hd.flags & NGHTTP2_FLAG_END_STREAM) == 0) {
        auto it = connection->streams.find(frame->hd.stream_id);
        if (it != connection->streams.end()) {
            MaybeStartLiveStreaming(connection, frame->hd.stream_id, it->second, false);
        }
    }

    if (((frame->hd.type == NGHTTP2_HEADERS && frame->headers.cat == NGHTTP2_HCAT_REQUEST) ||
         frame->hd.type == NGHTTP2_DATA) &&
        (frame->hd.flags & NGHTTP2_FLAG_END_STREAM) != 0) {
        auto it = connection->streams.find(frame->hd.stream_id);
        if (it != connection->streams.end()) {
            MaybeStartLiveStreaming(connection, frame->hd.stream_id, it->second, true);
        }
    }
    return 0;
}

int OnStreamClose(
    nghttp2_session* session, int32_t stream_id, uint32_t error_code, void* user_data
) {
    (void)session;
    (void)error_code;
    auto* connection = static_cast<Http2Connection*>(user_data);
    auto it = connection->streams.find(stream_id);
    if (it != connection->streams.end() && it->second->request_messages != nullptr) {
        it->second->request_messages->Close(Status(StatusCode::kCancelled, "stream closed"));
    }
    connection->streams.erase(stream_id);
    return 0;
}

void OnConnectionClosed(uv_handle_t* handle) {
    auto* connection = static_cast<Http2Connection*>(handle->data);
    auto& connections = connection->owner->connections;
    connections.erase(
        std::remove(connections.begin(), connections.end(), connection), connections.end()
    );
    if (connection->session != nullptr) {
        nghttp2_session_del(connection->session);
        connection->session = nullptr;
    }
    delete connection;
}

void OnLoopShutdown(uv_async_t* handle) {
    auto* impl = static_cast<ServerImpl*>(handle->data);

    if (!impl->loop_initialized) {
        return;
    }

    for (Http2Connection* connection : impl->connections) {
        CloseConnection(connection);
    }
    impl->connections.clear();

    if (impl->listener_initialized &&
        !uv_is_closing(reinterpret_cast<uv_handle_t*>(&impl->listener_handle))) {
        uv_close(reinterpret_cast<uv_handle_t*>(&impl->listener_handle), nullptr);
    }

    if (!uv_is_closing(reinterpret_cast<uv_handle_t*>(&impl->shutdown_signal))) {
        uv_close(reinterpret_cast<uv_handle_t*>(&impl->shutdown_signal), nullptr);
    }

    if (impl->command_signal_initialized &&
        !uv_is_closing(reinterpret_cast<uv_handle_t*>(&impl->command_signal))) {
        uv_close(reinterpret_cast<uv_handle_t*>(&impl->command_signal), nullptr);
    }
}

void OnCommand(uv_async_t* handle) {
    auto* impl = static_cast<ServerImpl*>(handle->data);
    std::vector<std::function<void()>> commands;
    {
        std::lock_guard<std::mutex> lock(impl->commands_mutex);
        commands.swap(impl->commands);
    }
    for (auto& command : commands) {
        command();
    }
}

void CloseConnection(Http2Connection* connection) {
    if (connection->closed) {
        return;
    }
    connection->closed = true;
    uv_read_stop(reinterpret_cast<uv_stream_t*>(&connection->handle));
    uv_close(reinterpret_cast<uv_handle_t*>(&connection->handle), OnConnectionClosed);
}

void AllocBuffer(uv_handle_t* handle, size_t suggested_size, uv_buf_t* buffer) {
    (void)handle;
    buffer->base = new char[suggested_size];
    buffer->len = suggested_size;
}

void AfterRead(uv_stream_t* stream, ssize_t nread, const uv_buf_t* buffer) {
    auto* connection = static_cast<Http2Connection*>(stream->data);
    std::unique_ptr<char[]> cleanup(buffer->base);

    if (nread < 0) {
        CloseConnection(connection);
        return;
    }
    if (nread == 0) {
        return;
    }

    const ssize_t consumed = nghttp2_session_mem_recv(
        connection->session, reinterpret_cast<const uint8_t*>(buffer->base),
        static_cast<size_t>(nread)
    );
    if (consumed < 0) {
        CloseConnection(connection);
        return;
    }

    QueueOutput(connection);
    FlushPendingWrites(connection);
}

void OnNewConnection(uv_stream_t* server_stream, int status) {
    auto* impl = static_cast<ServerImpl*>(server_stream->data);
    if (status < 0) {
        return;
    }

    auto* connection = new Http2Connection();
    connection->owner = impl;

    if (uv_tcp_init(&impl->loop, &connection->handle) != 0) {
        delete connection;
        return;
    }
    connection->handle.data = connection;

    if (uv_accept(server_stream, reinterpret_cast<uv_stream_t*>(&connection->handle)) != 0) {
        uv_close(reinterpret_cast<uv_handle_t*>(&connection->handle), [](uv_handle_t* handle) {
            auto* failed = static_cast<Http2Connection*>(handle->data);
            delete failed;
        });
        return;
    }

    nghttp2_session_callbacks* callbacks = nullptr;
    nghttp2_session_callbacks_new(&callbacks);
    nghttp2_session_callbacks_set_on_begin_headers_callback(callbacks, OnBeginHeaders);
    nghttp2_session_callbacks_set_on_header_callback(callbacks, OnHeader);
    nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, OnDataChunkRecv);
    nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, OnFrameRecv);
    nghttp2_session_callbacks_set_on_frame_send_callback(callbacks, OnFrameSend);
    nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, OnStreamClose);
    if (nghttp2_session_server_new(&connection->session, callbacks, connection) != 0) {
        nghttp2_session_callbacks_del(callbacks);
        CloseConnection(connection);
        return;
    }
    nghttp2_session_callbacks_del(callbacks);

    impl->connections.push_back(connection);
    nghttp2_submit_settings(connection->session, NGHTTP2_FLAG_NONE, nullptr, 0);
    QueueOutput(connection);
    FlushPendingWrites(connection);
    uv_read_start(reinterpret_cast<uv_stream_t*>(&connection->handle), AllocBuffer, AfterRead);
}

Status ServerImpl::Start(const Server::Listener& listener) {
    IgnoreSigpipe();

    if (listener.use_tls) {
        return Status(
            StatusCode::kUnimplemented, "tls listeners are not wired into the runtime yet"
        );
    }

    AddressParts address;
    Status address_status = ParseAddress(listener.address, &address);
    if (!address_status.ok()) {
        return address_status;
    }

    if (uv_loop_init(&loop) != 0) {
        return Status(StatusCode::kInternal, "failed to initialize libuv loop");
    }
    loop_initialized = true;

    if (uv_tcp_init(&loop, &listener_handle) != 0) {
        Shutdown();
        return Status(StatusCode::kInternal, "failed to initialize TCP listener");
    }
    listener_initialized = true;
    listener_handle.data = this;

    sockaddr_in socket_address{};
    if (uv_ip4_addr(address.host.c_str(), address.port, &socket_address) != 0) {
        Shutdown();
        return Status(
            StatusCode::kUnimplemented, "only IPv4 host:port listeners are supported for now"
        );
    }

    if (uv_tcp_bind(&listener_handle, reinterpret_cast<const sockaddr*>(&socket_address), 0) != 0) {
        Shutdown();
        return Status(StatusCode::kUnavailable, "failed to bind listening socket");
    }

    if (uv_listen(reinterpret_cast<uv_stream_t*>(&listener_handle), 128, OnNewConnection) != 0) {
        Shutdown();
        return Status(StatusCode::kUnavailable, "failed to listen on the requested address");
    }

    if (uv_async_init(&loop, &shutdown_signal, OnLoopShutdown) != 0) {
        Shutdown();
        return Status(StatusCode::kInternal, "failed to initialize shutdown signal");
    }
    shutdown_signal.data = this;
    shutdown_signal_initialized = true;

    if (uv_async_init(&loop, &command_signal, OnCommand) != 0) {
        Shutdown();
        return Status(StatusCode::kInternal, "failed to initialize command signal");
    }
    command_signal.data = this;
    command_signal_initialized = true;

    return Status::OK();
}

void ServerImpl::Wait() {
    if (loop_initialized) {
        uv_run(&loop, UV_RUN_DEFAULT);
        while (uv_run(&loop, UV_RUN_NOWAIT) != 0) {}
        uv_loop_close(&loop);
        loop_initialized = false;
        listener_initialized = false;
        shutdown_signal_initialized = false;
        command_signal_initialized = false;
    }
}

void ServerImpl::Shutdown() {
    if (shutting_down.exchange(true)) {
        return;
    }

    if (!shutdown_signal_initialized) {
        for (Http2Connection* connection : connections) {
            CloseConnection(connection);
        }
        connections.clear();

        if (listener_initialized &&
            !uv_is_closing(reinterpret_cast<uv_handle_t*>(&listener_handle))) {
            uv_close(reinterpret_cast<uv_handle_t*>(&listener_handle), nullptr);
        }

        if (loop_initialized) {
            while (uv_run(&loop, UV_RUN_NOWAIT) != 0) {}
            uv_loop_close(&loop);
            loop_initialized = false;
            listener_initialized = false;
            command_signal_initialized = false;
        }
        return;
    }

    if (loop_initialized && shutdown_signal_initialized) {
        uv_async_send(&shutdown_signal);
    }
}

Server::Server(std::vector<Listener> listeners) : listeners_(std::move(listeners)) {}

Server::~Server() {
    Shutdown();
}

void Server::AddService(Service* service) {
    services_.push_back(service);
}

Status Server::Start() {
    if (listeners_.empty()) {
        return Status(
            StatusCode::kFailedPrecondition, "server requires at least one listening port"
        );
    }
    if (services_.empty()) {
        return Status(
            StatusCode::kFailedPrecondition, "server requires at least one registered service"
        );
    }

    if (listeners_.size() != 1U) {
        return Status(
            StatusCode::kUnimplemented, "only a single listening port is supported for now"
        );
    }

    impl_ = std::make_unique<ServerImpl>(this);
    Status status = impl_->Start(listeners_.front());
    if (!status.ok()) {
        impl_.reset();
        return status;
    }

    started_ = true;
    return Status::OK();
}

void Server::Wait() {
    if (impl_ != nullptr) {
        impl_->Wait();
    }
}

void Server::Shutdown() {
    if (impl_ != nullptr) {
        impl_->Shutdown();
    }
    started_ = false;
}

bool Server::started() const {
    return started_;
}

const std::vector<Server::Listener>& Server::listeners() const {
    return listeners_;
}

Service* Server::FindService(std::string_view path, std::string* method_name) const {
    for (Service* service : services_) {
        const std::string prefix = "/" + service->service_name() + "/";
        if (StartsWith(path, prefix)) {
            if (method_name != nullptr) {
                method_name->assign(path.substr(prefix.size()));
            }
            return service;
        }
    }
    return nullptr;
}

}  // namespace grpc_lite
