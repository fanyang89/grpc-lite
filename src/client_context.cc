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

}  // namespace grpc_lite
