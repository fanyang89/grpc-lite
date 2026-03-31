#include "grpc_lite/client_context.h"

#include <utility>

namespace grpc_lite {

void ClientContext::AddMetadata(std::string key, std::string value) {
  metadata_.emplace_back(std::move(key), std::move(value));
}

void ClientContext::SetDeadline(std::chrono::system_clock::time_point deadline) {
  deadline_ = deadline;
}

const std::vector<ClientContext::MetadataEntry>& ClientContext::metadata() const {
  return metadata_;
}

std::chrono::system_clock::time_point ClientContext::deadline() const {
  return deadline_;
}

const std::vector<ClientContext::MetadataEntry>&
ClientContext::server_initial_metadata() const {
  return server_initial_metadata_;
}

const std::vector<ClientContext::MetadataEntry>&
ClientContext::server_trailing_metadata() const {
  return server_trailing_metadata_;
}

void ClientContext::SetServerInitialMetadata(
    std::vector<MetadataEntry> metadata) {
  server_initial_metadata_ = std::move(metadata);
}

void ClientContext::SetServerTrailingMetadata(
    std::vector<MetadataEntry> metadata) {
  server_trailing_metadata_ = std::move(metadata);
}

}  // namespace grpc_lite
