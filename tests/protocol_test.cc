#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

#include <nghttp2/nghttp2.h>

#include "core/grpc_frame.h"
#include "doctest/doctest.h"
#include "grpc_lite/channel.h"
#include "grpc_lite/client_context.h"
#include "grpc_lite/status.h"
#include "test_support.h"

namespace {

using grpc_lite::StatusCode;

bool SendAll(int fd, std::string_view data) {
    while (!data.empty()) {
        const ssize_t sent = ::send(fd, data.data(), data.size(), MSG_NOSIGNAL);
        if (sent < 0) {
            if (errno == EINTR) {
                continue;
            }
            return false;
        }
        data.remove_prefix(static_cast<std::size_t>(sent));
    }
    return true;
}

void SetSocketTimeouts(int fd) {
    timeval timeout{};
    timeout.tv_sec = 5;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
}

bool FlushSession(int fd, nghttp2_session* session) {
    const std::uint8_t* data = nullptr;
    for (;;) {
        const ssize_t bytes = nghttp2_session_mem_send(session, &data);
        if (bytes < 0) {
            return false;
        }
        if (bytes == 0) {
            return true;
        }
        if (!SendAll(
                fd,
                std::string_view(
                    reinterpret_cast<const char*>(data), static_cast<std::size_t>(bytes)
                )
            )) {
            return false;
        }
    }
}

struct ResponseSpec {
    std::string http_status = "200";
    std::string body = grpc_lite::core::EncodeGrpcFrame("response");
    bool send_trailers = true;
    int grpc_status = 0;
    std::string grpc_message;
    std::vector<std::pair<std::string, std::string>> initial_metadata;
    std::vector<std::pair<std::string, std::string>> trailing_metadata;
};

struct CapturedRequest {
    std::string method;
    std::string path;
    std::string content_type;
    std::string body;
};

struct FakeServerState {
    ResponseSpec response;
    CapturedRequest request;
    int fd = -1;
    int32_t stream_id = 0;
    std::string grpc_status_text;
    std::size_t body_offset = 0;
    bool response_submitted = false;
    bool trailers_submitted = false;
    bool stream_closed = false;
};

std::vector<nghttp2_nv> BuildResponseTrailers(FakeServerState* state) {
    std::vector<nghttp2_nv> trailers;
    trailers.push_back(grpc_lite::core::MakeHeader("grpc-status", state->grpc_status_text));
    if (!state->response.grpc_message.empty()) {
        trailers.push_back(grpc_lite::core::MakeHeader("grpc-message", state->response.grpc_message)
        );
    }
    for (const auto& metadata : state->response.trailing_metadata) {
        trailers.push_back(grpc_lite::core::MakeHeader(metadata.first, metadata.second));
    }
    return trailers;
}

ssize_t FakeServerReadCallback(
    nghttp2_session* session, int32_t stream_id, std::uint8_t* buffer, std::size_t length,
    std::uint32_t* data_flags, nghttp2_data_source* source, void* user_data
) {
    (void)user_data;
    auto* state = static_cast<FakeServerState*>(source->ptr);
    const std::size_t remaining = state->response.body.size() - state->body_offset;
    const std::size_t to_copy = std::min(remaining, length);
    if (to_copy != 0) {
        std::memcpy(buffer, state->response.body.data() + state->body_offset, to_copy);
        state->body_offset += to_copy;
    }

    if (state->body_offset == state->response.body.size()) {
        *data_flags |= NGHTTP2_DATA_FLAG_EOF;
        if (state->response.send_trailers) {
            *data_flags |= NGHTTP2_DATA_FLAG_NO_END_STREAM;
            if (state->response.body.empty() && !state->trailers_submitted) {
                state->trailers_submitted = true;
                std::vector<nghttp2_nv> trailers = BuildResponseTrailers(state);
                if (nghttp2_submit_trailer(session, stream_id, trailers.data(), trailers.size()) !=
                    0) {
                    return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
                }
            }
        }
    }
    return static_cast<ssize_t>(to_copy);
}

void SubmitFakeResponse(nghttp2_session* session, FakeServerState* state) {
    if (state->response_submitted || state->stream_id == 0) {
        return;
    }
    state->response_submitted = true;
    state->grpc_status_text = std::to_string(state->response.grpc_status);

    std::string content_type = "application/grpc";
    std::vector<nghttp2_nv> headers;
    headers.push_back(grpc_lite::core::MakeHeader(":status", state->response.http_status));
    headers.push_back(grpc_lite::core::MakeHeader("content-type", content_type));
    for (const auto& metadata : state->response.initial_metadata) {
        headers.push_back(grpc_lite::core::MakeHeader(metadata.first, metadata.second));
    }

    nghttp2_data_provider provider{};
    provider.source.ptr = state;
    provider.read_callback = FakeServerReadCallback;
    nghttp2_submit_response(session, state->stream_id, headers.data(), headers.size(), &provider);
}

int FakeOnBeginHeaders(nghttp2_session*, const nghttp2_frame* frame, void* user_data) {
    auto* state = static_cast<FakeServerState*>(user_data);
    if (frame->hd.type == NGHTTP2_HEADERS && frame->headers.cat == NGHTTP2_HCAT_REQUEST) {
        state->stream_id = frame->hd.stream_id;
    }
    return 0;
}

int FakeOnHeader(
    nghttp2_session*, const nghttp2_frame* frame, const std::uint8_t* name, std::size_t namelen,
    const std::uint8_t* value, std::size_t valuelen, std::uint8_t, void* user_data
) {
    auto* state = static_cast<FakeServerState*>(user_data);
    if (frame->hd.stream_id != state->stream_id) {
        return 0;
    }

    const std::string_view header_name(reinterpret_cast<const char*>(name), namelen);
    const std::string_view header_value(reinterpret_cast<const char*>(value), valuelen);
    if (header_name == ":method") {
        state->request.method.assign(header_value);
    } else if (header_name == ":path") {
        state->request.path.assign(header_value);
    } else if (header_name == "content-type") {
        state->request.content_type.assign(header_value);
    }
    return 0;
}

int FakeOnDataChunk(
    nghttp2_session*, std::uint8_t, int32_t stream_id, const std::uint8_t* data, std::size_t len,
    void* user_data
) {
    auto* state = static_cast<FakeServerState*>(user_data);
    if (stream_id == state->stream_id) {
        state->request.body.append(reinterpret_cast<const char*>(data), len);
    }
    return 0;
}

int FakeOnFrameRecv(nghttp2_session* session, const nghttp2_frame* frame, void* user_data) {
    auto* state = static_cast<FakeServerState*>(user_data);
    if (frame->hd.stream_id != state->stream_id) {
        return 0;
    }
    if ((frame->hd.type == NGHTTP2_HEADERS || frame->hd.type == NGHTTP2_DATA) &&
        (frame->hd.flags & NGHTTP2_FLAG_END_STREAM) != 0) {
        SubmitFakeResponse(session, state);
        FlushSession(state->fd, session);
    }
    return 0;
}

int FakeOnFrameSend(nghttp2_session* session, const nghttp2_frame* frame, void* user_data) {
    auto* state = static_cast<FakeServerState*>(user_data);
    if (frame->hd.stream_id == state->stream_id && frame->hd.type == NGHTTP2_DATA &&
        state->response.send_trailers && !state->trailers_submitted) {
        state->trailers_submitted = true;
        std::vector<nghttp2_nv> trailers = BuildResponseTrailers(state);
        if (nghttp2_submit_trailer(session, state->stream_id, trailers.data(), trailers.size()) !=
            0) {
            return NGHTTP2_ERR_CALLBACK_FAILURE;
        }
    }
    return 0;
}

int FakeOnStreamClose(nghttp2_session*, int32_t stream_id, std::uint32_t, void* user_data) {
    auto* state = static_cast<FakeServerState*>(user_data);
    if (stream_id == state->stream_id) {
        state->stream_closed = true;
    }
    return 0;
}

class FakeHttp2Server {
  public:
    explicit FakeHttp2Server(ResponseSpec response) { state_.response = std::move(response); }

    ~FakeHttp2Server() { Stop(); }

    bool Start() {
        std::uint16_t port = 0;
        if (!grpc_lite::test::FindFreePort(&port)) {
            return false;
        }
        address_ = grpc_lite::test::LoopbackAddress(port);

        listen_fd_ = ::socket(AF_INET, SOCK_STREAM, 0);
        if (listen_fd_ < 0) {
            return false;
        }
        int reuse = 1;
        setsockopt(listen_fd_, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
        SetSocketTimeouts(listen_fd_);

        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        addr.sin_port = htons(port);
        if (::bind(listen_fd_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0 ||
            ::listen(listen_fd_, 1) != 0) {
            Stop();
            return false;
        }

        thread_ = std::thread([this]() { Run(); });
        return true;
    }

    void Stop() {
        if (listen_fd_ >= 0) {
            ::shutdown(listen_fd_, SHUT_RDWR);
        }
        if (state_.fd >= 0) {
            ::shutdown(state_.fd, SHUT_RDWR);
        }
        if (thread_.joinable()) {
            thread_.join();
        }
        if (listen_fd_ >= 0) {
            ::close(listen_fd_);
            listen_fd_ = -1;
        }
        if (state_.fd >= 0) {
            ::close(state_.fd);
            state_.fd = -1;
        }
    }

    const std::string& address() const { return address_; }

    const CapturedRequest& request() const { return state_.request; }

  private:
    void Run() {
        state_.fd = ::accept(listen_fd_, nullptr, nullptr);
        if (state_.fd < 0) {
            return;
        }
        SetSocketTimeouts(state_.fd);

        nghttp2_session_callbacks* callbacks = nullptr;
        nghttp2_session_callbacks_new(&callbacks);
        nghttp2_session_callbacks_set_on_begin_headers_callback(callbacks, FakeOnBeginHeaders);
        nghttp2_session_callbacks_set_on_header_callback(callbacks, FakeOnHeader);
        nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, FakeOnDataChunk);
        nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, FakeOnFrameRecv);
        nghttp2_session_callbacks_set_on_frame_send_callback(callbacks, FakeOnFrameSend);
        nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, FakeOnStreamClose);

        nghttp2_session* session = nullptr;
        nghttp2_session_server_new(&session, callbacks, &state_);
        nghttp2_session_callbacks_del(callbacks);
        nghttp2_submit_settings(session, NGHTTP2_FLAG_NONE, nullptr, 0);
        FlushSession(state_.fd, session);

        char buffer[4096];
        while (!state_.stream_closed) {
            const ssize_t nread = ::recv(state_.fd, buffer, sizeof(buffer), 0);
            if (nread <= 0) {
                break;
            }
            if (nghttp2_session_mem_recv(
                    session, reinterpret_cast<const std::uint8_t*>(buffer),
                    static_cast<std::size_t>(nread)
                ) < 0) {
                break;
            }
            FlushSession(state_.fd, session);
        }

        nghttp2_session_del(session);
    }

    ResponseSpec response_;
    FakeServerState state_;
    std::string address_;
    int listen_fd_ = -1;
    std::thread thread_;
};

struct RequestSpec {
    std::string method = "POST";
    std::string path = "/test.EchoService/Echo";
    bool include_content_type = true;
    std::string content_type = "application/grpc";
    std::string body = grpc_lite::core::EncodeGrpcFrame("request");
};

struct RawResponse {
    std::string http_status;
    std::string body;
    int grpc_status = -1;
    std::string grpc_message;
    std::vector<std::pair<std::string, std::string>> initial_metadata;
    std::vector<std::pair<std::string, std::string>> trailing_metadata;
};

struct RawClientState {
    RequestSpec request;
    RawResponse response;
    std::size_t body_offset = 0;
    int32_t stream_id = 0;
    bool stream_closed = false;
};

ssize_t
RawClientReadCallback(nghttp2_session*, int32_t, std::uint8_t* buffer, std::size_t length, std::uint32_t* data_flags, nghttp2_data_source* source, void*) {
    auto* state = static_cast<RawClientState*>(source->ptr);
    const std::size_t remaining = state->request.body.size() - state->body_offset;
    const std::size_t to_copy = std::min(remaining, length);
    if (to_copy != 0) {
        std::memcpy(buffer, state->request.body.data() + state->body_offset, to_copy);
        state->body_offset += to_copy;
    }
    if (state->body_offset == state->request.body.size()) {
        *data_flags |= NGHTTP2_DATA_FLAG_EOF;
    }
    return static_cast<ssize_t>(to_copy);
}

int RawOnHeader(
    nghttp2_session*, const nghttp2_frame* frame, const std::uint8_t* name, std::size_t namelen,
    const std::uint8_t* value, std::size_t valuelen, std::uint8_t, void* user_data
) {
    auto* state = static_cast<RawClientState*>(user_data);
    if (frame->hd.stream_id != state->stream_id) {
        return 0;
    }
    const std::string_view header_name(reinterpret_cast<const char*>(name), namelen);
    const std::string_view header_value(reinterpret_cast<const char*>(value), valuelen);
    if (header_name == "grpc-status") {
        state->response.grpc_status = std::atoi(std::string(header_value).c_str());
        return 0;
    }
    if (header_name == "grpc-message") {
        state->response.grpc_message.assign(header_value);
        return 0;
    }

    if (frame->headers.cat == NGHTTP2_HCAT_RESPONSE) {
        if (header_name == ":status") {
            state->response.http_status.assign(header_value);
        } else {
            state->response.initial_metadata.emplace_back(header_name, header_value);
        }
    } else if (frame->headers.cat == NGHTTP2_HCAT_HEADERS) {
        state->response.trailing_metadata.emplace_back(header_name, header_value);
    }
    return 0;
}

int RawOnData(
    nghttp2_session*, std::uint8_t, int32_t stream_id, const std::uint8_t* data, std::size_t len,
    void* user_data
) {
    auto* state = static_cast<RawClientState*>(user_data);
    if (stream_id == state->stream_id) {
        state->response.body.append(reinterpret_cast<const char*>(data), len);
    }
    return 0;
}

int RawOnStreamClose(nghttp2_session*, int32_t stream_id, std::uint32_t, void* user_data) {
    auto* state = static_cast<RawClientState*>(user_data);
    if (stream_id == state->stream_id) {
        state->stream_closed = true;
    }
    return 0;
}

RawResponse SendRawRequest(const std::string& address, RequestSpec request) {
    const std::size_t separator = address.rfind(':');
    REQUIRE(separator != std::string::npos);
    const std::string host = address.substr(0, separator);
    const int port = std::stoi(address.substr(separator + 1));

    const int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    REQUIRE(fd >= 0);
    SetSocketTimeouts(fd);

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(static_cast<std::uint16_t>(port));
    REQUIRE(::inet_pton(AF_INET, host.c_str(), &addr.sin_addr) == 1);
    REQUIRE(::connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0);

    RawClientState state;
    state.request = std::move(request);

    nghttp2_session_callbacks* callbacks = nullptr;
    nghttp2_session_callbacks_new(&callbacks);
    nghttp2_session_callbacks_set_on_header_callback(callbacks, RawOnHeader);
    nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, RawOnData);
    nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, RawOnStreamClose);

    nghttp2_session* session = nullptr;
    nghttp2_session_client_new(&session, callbacks, &state);
    nghttp2_session_callbacks_del(callbacks);
    nghttp2_submit_settings(session, NGHTTP2_FLAG_NONE, nullptr, 0);

    std::string scheme = "http";
    std::string authority = address;
    std::string te = "trailers";
    std::vector<nghttp2_nv> headers;
    headers.push_back(grpc_lite::core::MakeHeader(":method", state.request.method));
    headers.push_back(grpc_lite::core::MakeHeader(":scheme", scheme));
    headers.push_back(grpc_lite::core::MakeHeader(":path", state.request.path));
    headers.push_back(grpc_lite::core::MakeHeader(":authority", authority));
    headers.push_back(grpc_lite::core::MakeHeader("te", te));
    if (state.request.include_content_type) {
        headers.push_back(grpc_lite::core::MakeHeader("content-type", state.request.content_type));
    }

    nghttp2_data_provider provider{};
    provider.source.ptr = &state;
    provider.read_callback = RawClientReadCallback;
    state.stream_id =
        nghttp2_submit_request(session, nullptr, headers.data(), headers.size(), &provider, &state);
    REQUIRE(state.stream_id > 0);
    REQUIRE(FlushSession(fd, session));

    char buffer[4096];
    while (!state.stream_closed) {
        const ssize_t nread = ::recv(fd, buffer, sizeof(buffer), 0);
        if (nread <= 0) {
            break;
        }
        REQUIRE(
            nghttp2_session_mem_recv(
                session, reinterpret_cast<const std::uint8_t*>(buffer),
                static_cast<std::size_t>(nread)
            ) >= 0
        );
        REQUIRE(FlushSession(fd, session));
    }

    nghttp2_session_del(session);
    ::close(fd);
    return state.response;
}

TEST_CASE("channel rejects non-200 HTTP responses") {
    ResponseSpec response;
    response.http_status = "503";
    response.send_trailers = false;
    FakeHttp2Server server(response);
    REQUIRE(server.Start());

    std::shared_ptr<grpc_lite::Channel> channel = grpc_lite::Channel::Create(server.address());
    std::string response_body;
    const grpc_lite::Status status =
        channel->CallUnary("/test.EchoService/Echo", "request", nullptr, &response_body);

    CHECK(status.code() == StatusCode::kUnavailable);
    CHECK(status.message() == "server returned HTTP status 503");
    server.Stop();
}

TEST_CASE("channel rejects responses without grpc-status trailers") {
    ResponseSpec response;
    response.send_trailers = false;
    FakeHttp2Server server(response);
    REQUIRE(server.Start());

    std::shared_ptr<grpc_lite::Channel> channel = grpc_lite::Channel::Create(server.address());
    std::string response_body;
    const grpc_lite::Status status =
        channel->CallUnary("/test.EchoService/Echo", "request", nullptr, &response_body);

    CHECK(status.code() == StatusCode::kInternal);
    CHECK(status.message() == "server did not send grpc-status trailer");
    server.Stop();
}

TEST_CASE("channel rejects malformed successful response frames") {
    ResponseSpec response;
    response.body = std::string("\0\0\0", 3);
    FakeHttp2Server server(response);
    REQUIRE(server.Start());

    std::shared_ptr<grpc_lite::Channel> channel = grpc_lite::Channel::Create(server.address());
    std::string response_body;
    const grpc_lite::Status status =
        channel->CallUnary("/test.EchoService/Echo", "request", nullptr, &response_body);

    CHECK(status.code() == StatusCode::kInvalidArgument);
    server.Stop();
}

TEST_CASE("channel rejects compressed successful response frames") {
    ResponseSpec response;
    response.body = grpc_lite::core::EncodeGrpcFrame("compressed");
    response.body[0] = 1;
    FakeHttp2Server server(response);
    REQUIRE(server.Start());

    std::shared_ptr<grpc_lite::Channel> channel = grpc_lite::Channel::Create(server.address());
    std::string response_body;
    const grpc_lite::Status status =
        channel->CallUnary("/test.EchoService/Echo", "request", nullptr, &response_body);

    CHECK(status.code() == StatusCode::kUnimplemented);
    server.Stop();
}

TEST_CASE("channel preserves metadata and grpc error responses") {
    ResponseSpec response;
    response.body.clear();
    response.grpc_status = static_cast<int>(StatusCode::kInvalidArgument);
    response.grpc_message = "bad request";
    response.initial_metadata.push_back({"x-initial", "fake"});
    response.trailing_metadata.push_back({"x-trailing", "fake-done"});
    FakeHttp2Server server(response);
    REQUIRE(server.Start());

    grpc_lite::ClientContext context;
    std::shared_ptr<grpc_lite::Channel> channel = grpc_lite::Channel::Create(server.address());
    std::string response_body;
    const grpc_lite::Status status =
        channel->CallUnary("/test.EchoService/Echo", "request", &context, &response_body);

    CHECK(status.code() == StatusCode::kInvalidArgument);
    CHECK(status.message() == "bad request");
    CHECK(grpc_lite::test::HasMetadata(context.server_initial_metadata(), "x-initial", "fake"));
    CHECK(
        grpc_lite::test::HasMetadata(context.server_trailing_metadata(), "x-trailing", "fake-done")
    );
    server.Stop();
}

TEST_CASE("raw protocol client observes server rejection of invalid request metadata") {
    grpc_lite::test::EchoService service;
    grpc_lite::test::ServerScope server(service);
    std::string address;
    REQUIRE(server.Start(&address));
    std::this_thread::sleep_for(std::chrono::milliseconds(20));

    RequestSpec get_request;
    get_request.method = "GET";
    get_request.body.clear();
    RawResponse response = SendRawRequest(address, get_request);
    CHECK(response.http_status == "200");
    CHECK(response.grpc_status == static_cast<int>(StatusCode::kUnimplemented));

    RequestSpec missing_content_type;
    missing_content_type.include_content_type = false;
    response = SendRawRequest(address, missing_content_type);
    CHECK(response.grpc_status == static_cast<int>(StatusCode::kInvalidArgument));

    RequestSpec wrong_content_type;
    wrong_content_type.content_type = "application/json";
    response = SendRawRequest(address, wrong_content_type);
    CHECK(response.grpc_status == static_cast<int>(StatusCode::kInvalidArgument));
}

TEST_CASE("raw protocol client observes server rejection of invalid grpc frames") {
    grpc_lite::test::EchoService service;
    grpc_lite::test::ServerScope server(service);
    std::string address;
    REQUIRE(server.Start(&address));
    std::this_thread::sleep_for(std::chrono::milliseconds(20));

    RequestSpec compressed;
    compressed.body = grpc_lite::core::EncodeGrpcFrame("request");
    compressed.body[0] = 1;
    RawResponse response = SendRawRequest(address, compressed);
    CHECK(response.grpc_status == static_cast<int>(StatusCode::kUnimplemented));

    RequestSpec malformed;
    malformed.body = grpc_lite::core::EncodeGrpcFrame("request");
    malformed.body.pop_back();
    response = SendRawRequest(address, malformed);
    CHECK(response.grpc_status == static_cast<int>(StatusCode::kInvalidArgument));

    RequestSpec two_messages;
    two_messages.body =
        grpc_lite::core::EncodeGrpcFrame("one") + grpc_lite::core::EncodeGrpcFrame("two");
    response = SendRawRequest(address, two_messages);
    CHECK(response.grpc_status == static_cast<int>(StatusCode::kInvalidArgument));
}

TEST_CASE("raw protocol client observes server unknown service response") {
    grpc_lite::test::EchoService service;
    grpc_lite::test::ServerScope server(service);
    std::string address;
    REQUIRE(server.Start(&address));
    std::this_thread::sleep_for(std::chrono::milliseconds(20));

    RequestSpec request;
    request.path = "/test.MissingService/Echo";
    const RawResponse response = SendRawRequest(address, request);

    CHECK(response.http_status == "200");
    CHECK(response.grpc_status == static_cast<int>(StatusCode::kUnimplemented));
}

}  // namespace
