#include "grpc_lite/server.h"

#include <nghttp2/nghttp2.h>
#include <uv.h>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

#include "core/grpc_frame.h"
#include "grpc_lite/service.h"

namespace grpc_lite {

struct StreamState {
  std::string method;
  std::string path;
  std::string content_type;
  std::string request_body;
  std::string response_frame;
  std::vector<std::pair<std::string, std::string>> initial_metadata;
  std::vector<std::pair<std::string, std::string>> trailing_metadata;
  Status status;
  std::size_t response_offset = 0;
  bool response_submitted = false;
};

struct PendingWrite {
  uv_write_t request;
  uv_buf_t buffer;
  std::string data;
};

using core::DecodeGrpcFrame;
using core::EncodeGrpcFrame;
using core::MakeHeader;
using core::StatusCodeText;

bool StartsWith(std::string_view value, std::string_view prefix) {
  return value.size() >= prefix.size() && value.substr(0, prefix.size()) == prefix;
}


struct AddressParts {
  std::string host;
  int port = 0;
};

Status ParseAddress(std::string_view address, AddressParts* out) {
  const std::size_t separator = address.rfind(':');
  if (separator == std::string_view::npos) {
    return Status(StatusCode::kInvalidArgument,
                  "listening address must be in host:port form");
  }

  out->host = std::string(address.substr(0, separator));
  if (out->host.empty()) {
    out->host = "0.0.0.0";
  }

  const std::string port_text(address.substr(separator + 1));
  try {
    out->port = std::stoi(port_text);
  } catch (...) {
    return Status(StatusCode::kInvalidArgument,
                  "listening port must be numeric");
  }

  if (out->port <= 0 || out->port > 65535) {
    return Status(StatusCode::kInvalidArgument,
                  "listening port must be in the range 1-65535");
  }
  return Status::OK();
}

struct Http2Connection {
  uv_tcp_t handle{};
  ServerImpl* owner = nullptr;
  nghttp2_session* session = nullptr;
  std::unordered_map<int32_t, StreamState> streams;
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

  Server* server;
  uv_loop_t loop{};
  uv_tcp_t listener_handle{};
  bool loop_initialized = false;
  bool listener_initialized = false;
  bool shutting_down = false;
  std::vector<Http2Connection*> connections;
};

void FlushPendingWrites(Http2Connection* connection);
void CloseConnection(Http2Connection* connection);

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
        reinterpret_cast<const char*>(data), static_cast<std::size_t>(bytes));
  }
}

void FlushPendingWrites(Http2Connection* connection) {
  if (connection->closed || connection->write_in_flight ||
      connection->pending_writes.empty()) {
    return;
  }

  auto* pending = new PendingWrite();
  pending->data = connection->pending_writes.front();
  pending->buffer = uv_buf_init(pending->data.data(), pending->data.size());
  pending->request.data = pending;
  connection->write_in_flight = true;

  const int rc = uv_write(&pending->request,
                          reinterpret_cast<uv_stream_t*>(&connection->handle),
                          &pending->buffer, 1, AfterWrite);
  if (rc != 0) {
    connection->write_in_flight = false;
    FreeWrite(&pending->request);
    CloseConnection(connection);
  }
}

void SubmitGrpcResponse(Http2Connection* connection,
                        int32_t stream_id,
                        StreamState* stream) {
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
                              uint8_t* buffer, size_t length,
                              uint32_t* data_flags,
                              nghttp2_data_source* source,
                              void* user_data) -> ssize_t {
    (void)user_data;
    auto* state = static_cast<StreamState*>(source->ptr);

    const std::size_t remaining =
        state->response_frame.size() - state->response_offset;
    const std::size_t to_copy = std::min(remaining, length);
    if (to_copy != 0) {
      std::memcpy(buffer, state->response_frame.data() + state->response_offset,
                  to_copy);
      state->response_offset += to_copy;
    }

    if (state->response_offset == state->response_frame.size()) {
      *data_flags |= NGHTTP2_DATA_FLAG_EOF | NGHTTP2_DATA_FLAG_NO_END_STREAM;
      std::vector<nghttp2_nv> trailers;
      trailers.reserve(state->trailing_metadata.size() + 2);
      trailers.push_back(
          MakeHeader("grpc-status", StatusCodeText(state->status.code())));
      if (!state->status.message().empty()) {
        trailers.push_back(MakeHeader("grpc-message", state->status.message()));
      }
      for (const auto& metadata : state->trailing_metadata) {
        trailers.push_back(MakeHeader(metadata.first, metadata.second));
      }
      if (nghttp2_submit_trailer(session, current_stream_id, trailers.data(),
                                 trailers.size()) != 0) {
        return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
      }
    }

    return static_cast<ssize_t>(to_copy);
  };

  if (nghttp2_submit_response(connection->session, stream_id, headers.data(),
                              headers.size(), &provider) != 0) {
    CloseConnection(connection);
    return;
  }

  stream->response_submitted = true;
  QueueOutput(connection);
  FlushPendingWrites(connection);
}

Status ServerImpl::BuildUnaryResponse(StreamState* stream) {
  if (stream->method != "POST") {
    return Status(StatusCode::kUnimplemented,
                  "only POST grpc requests are supported");
  }
  if (!StartsWith(stream->content_type, "application/grpc")) {
    return Status(StatusCode::kInvalidArgument,
                  "content-type must start with application/grpc");
  }

  std::string request_payload;
  Status decode_status = DecodeGrpcFrame(stream->request_body, &request_payload);
  if (!decode_status.ok()) {
    return decode_status;
  }

  std::string method_name;
  Service* service = server->FindService(stream->path, &method_name);
  if (service == nullptr) {
    return Status(StatusCode::kUnimplemented,
                  "requested grpc method is not registered");
  }

  ServerContext context;
  std::string response_payload;
  Status status =
      service->HandleUnary(method_name, request_payload, &context, &response_payload);
  stream->initial_metadata = context.initial_metadata();
  stream->trailing_metadata = context.trailing_metadata();
  if (status.ok()) {
    stream->response_frame = EncodeGrpcFrame(response_payload);
  } else {
    stream->response_frame.clear();
  }
  return status;
}

void MaybeHandleRequest(Http2Connection* connection, int32_t stream_id) {
  auto it = connection->streams.find(stream_id);
  if (it == connection->streams.end() || it->second.response_submitted) {
    return;
  }

  it->second.status = connection->owner->BuildUnaryResponse(&it->second);
  SubmitGrpcResponse(connection, stream_id, &it->second);
}

int OnBeginHeaders(nghttp2_session* session, const nghttp2_frame* frame,
                   void* user_data) {
  (void)session;
  auto* connection = static_cast<Http2Connection*>(user_data);
  if (frame->hd.type == NGHTTP2_HEADERS &&
      frame->headers.cat == NGHTTP2_HCAT_REQUEST) {
    connection->streams[frame->hd.stream_id] = StreamState{};
  }
  return 0;
}

int OnHeader(nghttp2_session* session, const nghttp2_frame* frame,
             const uint8_t* name, size_t namelen, const uint8_t* value,
             size_t valuelen, uint8_t flags, void* user_data) {
  (void)session;
  (void)flags;
  auto* connection = static_cast<Http2Connection*>(user_data);
  if (frame->hd.type != NGHTTP2_HEADERS ||
      frame->headers.cat != NGHTTP2_HCAT_REQUEST) {
    return 0;
  }

  auto it = connection->streams.find(frame->hd.stream_id);
  if (it == connection->streams.end()) {
    return 0;
  }

  const std::string_view header_name(reinterpret_cast<const char*>(name), namelen);
  const std::string_view header_value(reinterpret_cast<const char*>(value), valuelen);
  if (header_name == ":method") {
    it->second.method.assign(header_value);
  } else if (header_name == ":path") {
    it->second.path.assign(header_value);
  } else if (header_name == "content-type") {
    it->second.content_type.assign(header_value);
  }
  return 0;
}

int OnDataChunkRecv(nghttp2_session* session, uint8_t flags, int32_t stream_id,
                    const uint8_t* data, size_t len, void* user_data) {
  (void)session;
  (void)flags;
  auto* connection = static_cast<Http2Connection*>(user_data);
  auto it = connection->streams.find(stream_id);
  if (it != connection->streams.end()) {
    it->second.request_body.append(reinterpret_cast<const char*>(data), len);
  }
  return 0;
}

int OnFrameRecv(nghttp2_session* session, const nghttp2_frame* frame,
                void* user_data) {
  (void)session;
  auto* connection = static_cast<Http2Connection*>(user_data);

  if (frame->hd.type == NGHTTP2_HEADERS &&
      frame->headers.cat == NGHTTP2_HCAT_REQUEST &&
      (frame->hd.flags & NGHTTP2_FLAG_END_STREAM) != 0) {
    MaybeHandleRequest(connection, frame->hd.stream_id);
  }

  if (frame->hd.type == NGHTTP2_DATA &&
      (frame->hd.flags & NGHTTP2_FLAG_END_STREAM) != 0) {
    MaybeHandleRequest(connection, frame->hd.stream_id);
  }
  return 0;
}

int OnStreamClose(nghttp2_session* session, int32_t stream_id,
                  uint32_t error_code, void* user_data) {
  (void)session;
  (void)error_code;
  auto* connection = static_cast<Http2Connection*>(user_data);
  connection->streams.erase(stream_id);
  return 0;
}

void OnConnectionClosed(uv_handle_t* handle) {
  auto* connection = static_cast<Http2Connection*>(handle->data);
  auto& connections = connection->owner->connections;
  connections.erase(
      std::remove(connections.begin(), connections.end(), connection),
      connections.end());
  if (connection->session != nullptr) {
    nghttp2_session_del(connection->session);
    connection->session = nullptr;
  }
  delete connection;
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
      static_cast<size_t>(nread));
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

  if (uv_accept(server_stream, reinterpret_cast<uv_stream_t*>(&connection->handle)) !=
      0) {
    uv_close(reinterpret_cast<uv_handle_t*>(&connection->handle),
             [](uv_handle_t* handle) {
               auto* failed = static_cast<Http2Connection*>(handle->data);
               delete failed;
             });
    return;
  }

  nghttp2_session_callbacks* callbacks = nullptr;
  nghttp2_session_callbacks_new(&callbacks);
  nghttp2_session_callbacks_set_on_begin_headers_callback(callbacks,
                                                          OnBeginHeaders);
  nghttp2_session_callbacks_set_on_header_callback(callbacks, OnHeader);
  nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks,
                                                            OnDataChunkRecv);
  nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, OnFrameRecv);
  nghttp2_session_callbacks_set_on_stream_close_callback(callbacks,
                                                         OnStreamClose);
  if (nghttp2_session_server_new(&connection->session, callbacks, connection) !=
      0) {
    nghttp2_session_callbacks_del(callbacks);
    CloseConnection(connection);
    return;
  }
  nghttp2_session_callbacks_del(callbacks);

  impl->connections.push_back(connection);
  nghttp2_submit_settings(connection->session, NGHTTP2_FLAG_NONE, nullptr, 0);
  QueueOutput(connection);
  FlushPendingWrites(connection);
  uv_read_start(reinterpret_cast<uv_stream_t*>(&connection->handle), AllocBuffer,
                AfterRead);
}

Status ServerImpl::Start(const Server::Listener& listener) {
  if (listener.use_tls) {
    return Status(StatusCode::kUnimplemented,
                  "tls listeners are not wired into the runtime yet");
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
    return Status(StatusCode::kUnimplemented,
                  "only IPv4 host:port listeners are supported for now");
  }

  if (uv_tcp_bind(&listener_handle,
                  reinterpret_cast<const sockaddr*>(&socket_address), 0) != 0) {
    Shutdown();
    return Status(StatusCode::kUnavailable, "failed to bind listening socket");
  }

  if (uv_listen(reinterpret_cast<uv_stream_t*>(&listener_handle), 128,
                OnNewConnection) != 0) {
    Shutdown();
    return Status(StatusCode::kUnavailable,
                  "failed to listen on the requested address");
  }
  return Status::OK();
}

void ServerImpl::Wait() { uv_run(&loop, UV_RUN_DEFAULT); }

void ServerImpl::Shutdown() {
  if (shutting_down) {
    return;
  }
  shutting_down = true;

  for (Http2Connection* connection : connections) {
    CloseConnection(connection);
  }
  if (listener_initialized && !uv_is_closing(reinterpret_cast<uv_handle_t*>(&listener_handle))) {
    uv_close(reinterpret_cast<uv_handle_t*>(&listener_handle), nullptr);
  }

  if (loop_initialized) {
    while (uv_run(&loop, UV_RUN_NOWAIT) != 0) {
    }
    uv_loop_close(&loop);
    loop_initialized = false;
    listener_initialized = false;
  }
}

Server::Server(std::vector<Listener> listeners)
    : listeners_(std::move(listeners)) {}

Server::~Server() { Shutdown(); }

void Server::AddService(Service* service) { services_.push_back(service); }

Status Server::Start() {
  if (listeners_.empty()) {
    return Status(StatusCode::kFailedPrecondition,
                  "server requires at least one listening port");
  }
  if (services_.empty()) {
    return Status(StatusCode::kFailedPrecondition,
                  "server requires at least one registered service");
  }

  if (listeners_.size() != 1U) {
    return Status(StatusCode::kUnimplemented,
                  "only a single listening port is supported for now");
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
    impl_.reset();
  }
  started_ = false;
}

bool Server::started() const { return started_; }

const std::vector<Server::Listener>& Server::listeners() const {
  return listeners_;
}

Service* Server::FindService(std::string_view path,
                             std::string* method_name) const {
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
