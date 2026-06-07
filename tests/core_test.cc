#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include "doctest/doctest.h"

#include <chrono>
#include <cstdint>
#include <string>
#include <vector>

#include <grpcpp/support/byte_buffer.h>

#include "core/grpc_frame.h"
#include "grpc_lite/client_context.h"
#include "grpc_lite/server_context.h"
#include "grpc_lite/status.h"

namespace {

using grpc_lite::StatusCode;

TEST_CASE("grpc frame encodes and decodes unary payloads") {
    const std::string payload("abc\0xyz", 7);
    const std::string frame = grpc_lite::core::EncodeGrpcFrame(payload);

    REQUIRE(frame.size() == payload.size() + 5U);
    CHECK(static_cast<unsigned char>(frame[0]) == 0U);
    CHECK(static_cast<unsigned char>(frame[1]) == 0U);
    CHECK(static_cast<unsigned char>(frame[2]) == 0U);
    CHECK(static_cast<unsigned char>(frame[3]) == 0U);
    CHECK(static_cast<unsigned char>(frame[4]) == payload.size());

    std::string decoded;
    const grpc_lite::Status status = grpc_lite::core::DecodeGrpcFrame(frame, &decoded);
    CHECK(status.ok());
    CHECK(decoded == payload);
}

TEST_CASE("grpc frame handles empty payload") {
    const std::string frame = grpc_lite::core::EncodeGrpcFrame("");
    CHECK(frame == std::string(5, '\0'));

    std::string decoded = "unchanged";
    const grpc_lite::Status status = grpc_lite::core::DecodeGrpcFrame(frame, &decoded);
    CHECK(status.ok());
    CHECK(decoded.empty());
}

TEST_CASE("grpc frame rejects malformed inputs") {
    std::string decoded;

    grpc_lite::Status status = grpc_lite::core::DecodeGrpcFrame("\0\0\0", &decoded);
    CHECK(status.code() == StatusCode::kInvalidArgument);

    std::string compressed = grpc_lite::core::EncodeGrpcFrame("payload");
    compressed[0] = 1;
    status = grpc_lite::core::DecodeGrpcFrame(compressed, &decoded);
    CHECK(status.code() == StatusCode::kUnimplemented);

    std::string too_short = grpc_lite::core::EncodeGrpcFrame("payload");
    too_short.pop_back();
    status = grpc_lite::core::DecodeGrpcFrame(too_short, &decoded);
    CHECK(status.code() == StatusCode::kInvalidArgument);

    const std::string two_messages =
        grpc_lite::core::EncodeGrpcFrame("one") + grpc_lite::core::EncodeGrpcFrame("two");
    status = grpc_lite::core::DecodeGrpcFrame(two_messages, &decoded);
    CHECK(status.code() == StatusCode::kInvalidArgument);
}

TEST_CASE("status code text maps every grpc code") {
    struct Case {
        StatusCode code;
        int value;
        const char* text;
    };

    const std::vector<Case> cases = {
        {StatusCode::kOk, 0, "0"},
        {StatusCode::kCancelled, 1, "1"},
        {StatusCode::kUnknown, 2, "2"},
        {StatusCode::kInvalidArgument, 3, "3"},
        {StatusCode::kDeadlineExceeded, 4, "4"},
        {StatusCode::kNotFound, 5, "5"},
        {StatusCode::kAlreadyExists, 6, "6"},
        {StatusCode::kPermissionDenied, 7, "7"},
        {StatusCode::kResourceExhausted, 8, "8"},
        {StatusCode::kFailedPrecondition, 9, "9"},
        {StatusCode::kAborted, 10, "10"},
        {StatusCode::kOutOfRange, 11, "11"},
        {StatusCode::kUnimplemented, 12, "12"},
        {StatusCode::kInternal, 13, "13"},
        {StatusCode::kUnavailable, 14, "14"},
        {StatusCode::kDataLoss, 15, "15"},
        {StatusCode::kUnauthenticated, 16, "16"},
    };

    for (const Case& test_case : cases) {
        CHECK(std::string(grpc_lite::core::StatusCodeText(test_case.code)) == test_case.text);
        CHECK(grpc_lite::core::StatusCodeFromInt(test_case.value) == test_case.code);
    }
    CHECK(grpc_lite::core::StatusCodeFromInt(-1) == StatusCode::kUnknown);
    CHECK(grpc_lite::core::StatusCodeFromInt(17) == StatusCode::kUnknown);
}

TEST_CASE("status and contexts preserve values") {
    CHECK(grpc_lite::Status().ok());
    CHECK(grpc_lite::Status::OK().ok());

    const grpc_lite::Status error(StatusCode::kUnavailable, "offline");
    CHECK(!error.ok());
    CHECK(error.code() == StatusCode::kUnavailable);
    CHECK(error.message() == "offline");

    grpc_lite::ClientContext client_context;
    client_context.AddMetadata("x-client", "value");
    const auto deadline = std::chrono::system_clock::now() + std::chrono::seconds(10);
    client_context.SetDeadline(deadline);
    REQUIRE(client_context.metadata().size() == 1U);
    CHECK(client_context.metadata()[0].first == "x-client");
    CHECK(client_context.metadata()[0].second == "value");
    CHECK(client_context.deadline() == deadline);

    grpc_lite::ServerContext server_context;
    server_context.AddInitialMetadata("x-initial", "one");
    server_context.AddTrailingMetadata("x-trailing", "two");
    REQUIRE(server_context.initial_metadata().size() == 1U);
    REQUIRE(server_context.trailing_metadata().size() == 1U);
    CHECK(server_context.initial_metadata()[0].first == "x-initial");
    CHECK(server_context.trailing_metadata()[0].second == "two");
}

TEST_CASE("grpcpp byte buffer stores empty binary and multi-slice payloads") {
    grpc::ByteBuffer empty;
    std::string serialized = "unchanged";
    CHECK(empty.SerializeToString(&serialized));
    CHECK(serialized.empty());

    const grpc::Slice slices[] = {grpc::Slice(std::string("abc", 3)),
                                  grpc::Slice(std::string("\0def", 4))};
    grpc::ByteBuffer buffer(slices, 2);
    CHECK(buffer.SerializeToString(&serialized));
    CHECK(serialized == std::string("abc\0def", 7));

    grpc::Slice dumped;
    const grpc::Status dump_status = buffer.DumpToSingleSlice(&dumped);
    CHECK(dump_status.ok());
    CHECK(dumped.size() == 7U);
    CHECK(std::string(reinterpret_cast<const char*>(dumped.begin()), dumped.size()) == serialized);

    CHECK(!buffer.SerializeToString(nullptr));
    CHECK(buffer.DumpToSingleSlice(nullptr).error_code() == grpc::StatusCode::INTERNAL);
}

}  // namespace
